#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

create_ipa_user() {
    echo "$2" | ipa user-add $1 --cn="$1 user" --first="$1" --last="user" --password
}

##### MAIN BEGINS HERE #####

# NGK(TODO) - Disable SELinux policy to allow Keystone to run in httpd.  This
# is a temporary workaround until BZ#1138424 is fixed and available in the base
# SELinux policy in RHEL/CentOS.
setenforce 0

# Source our IPA config for IPA settings
. /mnt/ipa.conf

# Save the IPA FQDN and IP for later use
IPA_FQDN=$VM_FQDN
IPA_IP=$VM_IP

# Source our config for RDO settings
. /mnt/rdo.conf

# Use IPA for DNS discovery
sed -i "s/^nameserver .*/nameserver $IPA_IP/g" /etc/resolv.conf

# turn off and permanently disable firewall
systemctl stop firewalld.service
systemctl disable firewalld.service

# Join IPA
ipa-client-install -U -p admin@$IPA_REALM -w $IPA_PASSWORD

# RDO requires EPEL
yum install -y epel-release

# Set up the rdo-release repo
yum install -y https://rdo.fedorapeople.org/openstack-juno/rdo-release-juno.rpm
if [ -n "$USE_DELOREAN" ] ; then
    wget -O /etc/yum.repos.d/delorean.repo \
        http://trunk.rdoproject.org/centos70/current/delorean.repo
    wget -O /etc/yum.repos.d/rdo-kilo.repo \
        http://copr.fedoraproject.org/coprs/apevec/RDO-Kilo/repo/epel-7/apevec-RDO-Kilo-epel-7.repo
    wget -O /etc/yum.repos.d/pycrypto.repo \
        http://copr.fedoraproject.org/coprs/npmccallum/python-cryptography/repo/epel-7/npmccallum-python-cryptography-epel-7.repo
fi

# Install packstack
yum install -y openstack-packstack

# Set up SSH
ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

# Set up our answerfile
HOME=/root packstack --gen-answer-file=/root/answerfile.txt
sed -i 's/CONFIG_HEAT_INSTALL=n/CONFIG_HEAT_INSTALL=y/g' /root/answerfile.txt
sed -i 's/CONFIG_NEUTRON_INSTALL=y/CONFIG_NEUTRON_INSTALL=n/g' /root/answerfile.txt
sed -i "s/CONFIG_\(.*\)_PW=.*/CONFIG_\1_PW=$RDO_PASSWORD/g" /root/answerfile.txt
sed -i 's/CONFIG_KEYSTONE_SERVICE_NAME=keystone/CONFIG_KEYSTONE_SERVICE_NAME=httpd/g' /root/answerfile.txt
sed -i 's/CONFIG_PROVISION_DEMO=y/CONFIG_PROVISION_DEMO=n/g' /root/answerfile.txt

# Install RDO
HOME=/root packstack --debug --answer-file=/root/answerfile.txt

# Authenticate as IPA admin
echo "$IPA_PASSWORD" | kinit admin

# Add a keystone user that Keystone will bind as
create_ipa_user keystone $RDO_PASSWORD

# Add a demo user
create_ipa_user demo $RDO_PASSWORD

# Get rid of the admin Kerberos ticket
kdestroy

# Set up IPA domain config in Keystone
suffix=`echo $VM_DOMAIN | sed -e 's/^/dc=/' -e 's/\./,dc=/g'`

mkdir /etc/keystone/domains
cat > /etc/keystone/domains/keystone.${IPA_REALM}.conf << EOF
[ldap]
url=ldaps://$IPA_FQDN
user=uid=keystone,cn=users,cn=accounts,$suffix
password=$RDO_PASSWORD
suffix=$suffix
user_tree_dn=cn=users,cn=accounts,$suffix
user_objectclass=person
user_id_attribute=uid
user_name_attribute=uid
user_mail_attribute=mail
user_allow_create=false
user_allow_update=false
user_allow_delete=false
group_tree_dn=cn=groups,cn=accounts,$suffix
group_objectclass=groupOfNames
group_id_attribute=cn
group_name_attribute=cn
group_member_attribute=member
group_desc_attribute=description
group_allow_create=false
group_allow_update=false
group_allow_delete=false
user_enabled_attribute=nsAccountLock
user_enabled_default=False
user_enabled_invert=true

[identity]
driver = keystone.identity.backends.ldap.Identity
EOF

chown -R keystone:keystone /etc/keystone/domains

# Enable domain specific config for Keystone
openstack-config --set /etc/keystone/keystone.conf identity domain_specific_drivers_enabled true
openstack-config --set /etc/keystone/keystone.conf identity domain_config_dir /etc/keystone/domains

# Create the admin domain
openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name default \
          --os-project-domain-name default \
          --os-project-name admin \
          domain create --description admin_domain --enable admin_domain

admin_domain_id=`openstack --os-identity-api-version 3 --os-auth-url http://$VM_FQDN:35357/v3 --os-username admin \
    --os-password $RDO_PASSWORD --os-user-domain-name default --os-project-domain-name default \
    --os-project-name admin domain show admin_domain -f value -c id`

# Create the cloud admin and make them the admin of the admin domain
openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name default \
          --os-project-domain-name default \
          --os-project-name admin \
          user create --domain admin_domain --password $RDO_PASSWORD --enable cloud_admin

cloud_admin_id=`openstack --os-identity-api-version 3 --os-auth-url http://$VM_FQDN:35357/v3 --os-username admin \
    --os-password $RDO_PASSWORD --os-user-domain-name default --os-project-domain-name default \
    --os-project-name admin user list --domain admin_domain -f csv --quote none\
    | grep ",cloud_admin$" | sed -e 's/,cloud_admin//g'`

openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name default \
          --os-project-domain-name default \
          --os-project-name admin \
          role add --user $cloud_admin_id --domain admin_domain admin

# Use the domain aware v3cloudpolicy policy file
cp /usr/share/keystone/policy.v3cloudsample.json /etc/keystone
chown keystone:keystone /etc/keystone/policy.v3cloudsample.json
sed -i "s/admin_domain_id/$admin_domain_id/g" /etc/keystone/policy.v3cloudsample.json
openstack-config --set /etc/keystone/keystone.conf DEFAULT policy_file /etc/keystone/policy.v3cloudsample.json

# Restart Keystone so we can use the new domain-aware policy
systemctl restart httpd.service

# Create the IPA domain in Keystone
openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-user-domain-name admin_domain \
          --os-username cloud_admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name admin_domain \
          --os-domain-name admin_domain \
          domain create --description ipa --enable $IPA_REALM

# Keystone needs to be restarted to load the domain specific configuration
systemctl restart httpd.service

# Make the IPA 'admin' user the admin our our new IPA domain
ipa_admin_id=`openstack --os-identity-api-version 3 --os-auth-url http://$VM_FQDN:35357/v3 --os-user-domain-name admin_domain \
    --os-username cloud_admin --os-password $RDO_PASSWORD --os-domain-name admin_domain user list --domain $IPA_REALM -f csv \
    --quote none | grep ",admin$" | sed -e 's/,admin//g'`

openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-username cloud_admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name admin_domain \
          --os-domain-name admin_domain \
          role add --domain $IPA_REALM --user $ipa_admin_id admin

# Add a project to our domain and grant the admin and _member_ roles to the admin user
ipa_domain_id=`openstack --os-identity-api-version 3 --os-auth-url http://$VM_FQDN:35357/v3 --os-user-domain-name admin_domain \
    --os-username cloud_admin --os-password $RDO_PASSWORD --os-domain-name admin_domain domain show \
    -f value -c id $IPA_REALM`

openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name $IPA_REALM \
          --os-domain-name $IPA_REALM \
          project create demo --domain $ipa_domain_id

demo_project_id=`openstack --os-identity-api-version 3 --os-auth-url http://$VM_FQDN:35357/v3 --os-username admin \
    --os-password $RDO_PASSWORD --os-user-domain-name $IPA_REALM --os-project-domain-name $IPA_REALM \
    --os-domain-name $IPA_REALM project show demo --domain $ipa_domain_id -f value -c id`

openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name $IPA_REALM \
          --os-project-domain-name $IPA_REALM \
          --os-domain-name $IPA_REALM \
          role add --project $demo_project_id --user $ipa_admin_id admin

openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name $IPA_REALM \
          --os-project-domain-name $IPA_REALM \
          --os-domain-name $IPA_REALM \
          role add --project $demo_project_id --user $ipa_admin_id _member_

# Grant the _member_ role on our demo project to the demo LDAP user
demo_user_id=`openstack --os-identity-api-version 3 --os-auth-url http://$VM_FQDN:35357/v3 \
    --os-user-domain-name admin_domain --os-username cloud_admin --os-password $RDO_PASSWORD \
    --os-domain-name admin_domain user list --domain $IPA_REALM -f csv --quote none \
    | grep ",demo$" | sed -e 's/,demo//g'`

openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name $IPA_REALM \
          --os-project-domain-name $IPA_REALM \
          --os-domain-name $IPA_REALM \
          role add --project $demo_project_id --user $demo_user_id _member_

# Configure Horizon to use our LDAP domain
cat >> /etc/openstack-dashboard/local_settings << EOF
OPENSTACK_API_VERSIONS = {
     "identity": 3
}
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = '$IPA_REALM'
EOF

sed -i "s/^OPENSTACK_KEYSTONE_URL = .*/OPENSTACK_KEYSTONE_URL = \"http:\/\/$VM_FQDN:5000\/v3\"/g" \
    /etc/openstack-dashboard/local_settings

sed -i "s/^    'name': 'native',/    'name': 'ldap',/g" \
    /etc/openstack-dashboard/local_settings

sed -i "s/^    'can_edit_user': True,/    'can_edit_user': False,/g" \
    /etc/openstack-dashboard/local_settings

sed -i "s/^    'can_edit_group': True,/    'can_edit_group': False,/g" \
    /etc/openstack-dashboard/local_settings

# Sync our Keystone v3 policy with Horizon
mv /etc/openstack-dashboard/keystone_policy.json /etc/openstack-dashboard/keystone_policy.json.orig
cp /etc/keystone/policy.v3cloudsample.json /etc/openstack-dashboard/keystone_policy.json

# Restart Horizon
systemctl restart httpd.service

# NGK(TODO) - this is a workaround for LP#1427878
# Update Nova to allow it to validate tokens using the
# v3 Identity API.
sed -i "s/^auth_version\(.*\)/#auth_version\1/g" /usr/share/nova/nova-dist.conf

# NGK(TODO) - this is a workaround for LP#1428376
# Update Swift to use the proper keystonemiddleware module.  Without
# this, multi-domain support in Swift doesn't work properly.
sed -i "s/^paste.filter_factory.*/paste.filter_factory = keystonemiddleware.auth_token:filter_factory/g" \
    /etc/swift/proxy-server.conf

# NGK(TODO) Restart to allow the above Heat and Swift workarounds to
# take effect.  Remove this once the above bugs are fixed.
openstack-service restart

# Add a Cirros image for testing purposes
openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-username cloud_admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name admin_domain \
          --os-domain-name admin_domain \
          image create --disk-format qcow2 --container-format bare --public \
          --copy-from http://download.cirros-cloud.net/0.3.3/cirros-0.3.3-x86_64-disk.img cirros-0.3.3-x86_64

# Wait until the image is active to proceed.  Time out
# after 1 minute.
loops=0
while [  $loops -lt 12 ]; do
    is_active=`openstack --os-identity-api-version 3 \
        --os-auth-url http://$VM_FQDN:35357/v3 \
        --os-username cloud_admin \
        --os-password $RDO_PASSWORD \
        --os-user-domain-name admin_domain \
        --os-domain-name admin_domain \
        image show -f value -c status cirros-0.3.3-x86_64`

    if [ "$is_active" == "active" ]; then
        break
    fi

    sleep 5
    let loops++
done

# Set our demo user up for Swift
openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name $IPA_REALM \
          --os-project-domain-name $IPA_REALM \
          --os-domain-name $IPA_REALM \
          role add --project $demo_project_id --user $demo_user_id SwiftOperator

# Set our demo user up for Heat
openstack --os-identity-api-version 3 \
          --os-auth-url http://$VM_FQDN:35357/v3 \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-user-domain-name $IPA_REALM \
          --os-project-domain-name $IPA_REALM \
          --os-domain-name $IPA_REALM \
          role add --project $demo_project_id --user $demo_user_id heat_stack_owner

# Create a simple Heat template for testing purposes
cat > /home/$VM_USER_ID/test-template.yaml << EOF
heat_template_version: 2013-05-23

description: Test Template

parameters:
  ImageID:
    type: string
    description: Image use to boot a server

resources:
  server1:
    type: OS::Nova::Server
    properties:
      name: "Test server"
      image: { get_param: ImageID }
      flavor: "m1.tiny"

outputs:
  server1_private_ip:
    description: IP address of the server in the private network
    value: { get_attr: [ server1, first_address ] }
EOF

chown $VM_USER_ID:$VM_USER_ID /home/$VM_USER_ID/test-template.yaml

# Create a test stack as the demo user
heat --os-auth-url http://$VM_FQDN:35357/v3 \
     --os-username demo \
     --os-password $RDO_PASSWORD \
     --os-user-domain-name $IPA_REALM \
     --os-project-domain-name $IPA_REALM \
     --os-project-name demo \
     stack-create -f /home/$VM_USER_ID/test-template.yaml \
     -P "ImageID=cirros-0.3.3-x86_64" test-stack

# Add rc files for cloud admin and IPA domain admin
cat > /home/$VM_USER_ID/keystonerc_cloud_admin << EOF
export OS_USERNAME=cloud_admin
export OS_PASSWORD=$RDO_PASSWORD
export OS_DOMAIN_NAME=admin_domain
export OS_PROJECT_NAME=
export OS_USER_DOMAIN_NAME=admin_domain
export OS_PROJECT_DOMAIN_NAME=admin_domain
export OS_AUTH_URL=http://$VM_FQDN:5000/v3/
export OS_IDENTITY_API_VERSION=3
export OS_AUTH_TYPE=
export PS1='[\u@\h \W(keystone_cloud_admin)]\$ '
EOF

cat > /home/$VM_USER_ID/keystonerc_ipa_admin << EOF
export OS_USERNAME=admin
export OS_PASSWORD=$RDO_PASSWORD
export OS_DOMAIN_NAME=$IPA_REALM
export OS_PROJECT_NAME=
export OS_USER_DOMAIN_NAME=$IPA_REALM
export OS_PROJECT_DOMAIN_NAME=$IPA_REALM
export OS_AUTH_URL=http://$VM_FQDN:5000/v3/
export OS_IDENTITY_API_VERSION=3
export OS_AUTH_TYPE=
export PS1='[\u@\h \W(keystone_ipa_admin)]\$ '
EOF

cat > /home/$VM_USER_ID/keystonerc_demo << EOF
export OS_USERNAME=demo
export OS_PASSWORD=$RDO_PASSWORD
export OS_DOMAIN_NAME=
export OS_PROJECT_NAME=demo
export OS_USER_DOMAIN_NAME=$IPA_REALM
export OS_PROJECT_DOMAIN_NAME=$IPA_REALM
export OS_AUTH_URL=http://$VM_FQDN:5000/v3/
export OS_IDENTITY_API_VERSION=3
export OS_AUTH_TYPE=
export PS1='[\u@\h \W(keystone_demo)]\$ '
EOF

chown $VM_USER_ID:$VM_USER_ID /home/$VM_USER_ID/keystonerc_*
