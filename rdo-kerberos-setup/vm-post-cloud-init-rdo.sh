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

# Join IPA
ipa-client-install -U -p admin@$IPA_REALM -w $IPA_PASSWORD

# RDO requires EPEL
yum install -y http://download.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-2.noarch.rpm
yum-config-manager --enable epel

# Set up the rdo-release repo
yum install -y https://rdo.fedorapeople.org/openstack-juno/rdo-release-juno.rpm

# Install packstack
yum install -y openstack-packstack

# Set up SSH
ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

# Set up our answerfile
HOME=/root packstack --gen-answer-file=/root/answerfile.txt
sed -i 's/CONFIG_NEUTRON_INSTALL=y/CONFIG_NEUTRON_INSTALL=n/g' /root/answerfile.txt
sed -i "s/CONFIG_\(.*\)_PW=.*/CONFIG_\1_PW=$RDO_PASSWORD/g" /root/answerfile.txt

# NGK(TODO) This is a tempory workaround until LP#1382160 is addressed.
sed -i 's/CONFIG_KEYSTONE_TOKEN_FORMAT=PKI/CONFIG_KEYSTONE_TOKEN_FORMAT=UUID/g' /root/answerfile.txt

# Patch packstack to support deplyment of Keystone in httpd
patch -p1 -d /usr/lib/python2.7/site-packages < /mnt/0001-support-other-components-using-apache-mod_wsgi.patch
mv /usr/lib/python2.7/site-packages/packstack/puppet/modules/packstack/manifests/apache_common.pp \
    /usr/share/openstack-puppet/modules/packstack/manifests

# Configure Keystone to be deployed in httpd
echo 'CONFIG_KEYSTONE_SERVICE_NAME=httpd' >> /root/answerfile.txt

# Install RDO
HOME=/root packstack --debug --answer-file=/root/answerfile.txt

# Install OSC
yum install -y python-openstackclient

# NGK(TODO) This is a temporary workaround until a new version of OSC is
# released that contains the fixes for LP#1378565 and Gerrit#108325.
rpm -e python-openstackclient
pushd /opt
git clone git://git.openstack.org/openstack/python-openstackclient
pushd /opt/python-openstackclient
python setup.py install
popd
popd

# Authenticate as IPA admin
echo "$IPA_PASSWORD" | kinit admin

# Add a keystone user that Keystone will bind as
create_ipa_user keystone $RDO_PASSWORD

# Create a service in IPA and get a keytab
ipa service-add HTTP/$VM_FQDN@$IPA_REALM
ipa-getkeytab -s $IPA_FQDN -p HTTP/$VM_FQDN -k /etc/httpd/conf/httpd.keytab
chown apache:apache /etc/httpd/conf/httpd.keytab

# Get rid of the admin Kerberos ticket
kdestroy

# Load mod_auth_kerb
cp /etc/httpd/conf.modules.d/10-auth_kerb.conf /etc/httpd/conf.d/auth_kerb.load

# Set up mod_auth_kerb for Keystone
sed -i 's/<\/VirtualHost>//g' /etc/httpd/conf.d/10-keystone_wsgi_main.conf
sed -i 's/  WSGIScriptAlias \/ "\/var\/www\/cgi-bin\/keystone\/main"//g' /etc/httpd/conf.d/10-keystone_wsgi_main.conf
cat >> /etc/httpd/conf.d/10-keystone_wsgi_main.conf << EOF
  WSGIScriptAlias /krb /var/www/cgi-bin/keystone/main
  WSGIScriptAlias /    /var/www/cgi-bin/keystone/main

  <Location "/krb">
    LogLevel debug
    AuthType Kerberos
    AuthName "Kerberos Login"
    KrbMethodNegotiate on
    KrbMethodK5Passwd off
    KrbServiceName HTTP
    KrbAuthRealms $IPA_REALM
    Krb5KeyTab /etc/httpd/conf/httpd.keytab
    KrbSaveCredentials on
    KrbLocalUserMapping on
    SetEnv REMOTE_DOMAIN $IPA_REALM
    Require valid-user
  </Location>

</VirtualHost>
EOF

sed -i 's/<\/VirtualHost>//g' /etc/httpd/conf.d/10-keystone_wsgi_admin.conf
sed -i 's/  WSGIScriptAlias \/ "\/var\/www\/cgi-bin\/keystone\/admin"//g' /etc/httpd/conf.d/10-keystone_wsgi_admin.conf
cat >> /etc/httpd/conf.d/10-keystone_wsgi_admin.conf << EOF
  WSGIScriptAlias /krb /var/www/cgi-bin/keystone/admin
  WSGIScriptAlias /    /var/www/cgi-bin/keystone/admin

  <Location "/krb">
    LogLevel debug
    AuthType Kerberos
    AuthName "Kerberos Login"
    KrbMethodNegotiate on
    KrbMethodK5Passwd off
    KrbServiceName HTTP
    KrbAuthRealms $IPA_REALM
    Krb5KeyTab /etc/httpd/conf/httpd.keytab
    KrbSaveCredentials on
    KrbLocalUserMapping on
    SetEnv REMOTE_DOMAIN $IPA_REALM
    Require valid-user
  </Location>

</VirtualHost>
EOF

# Configure kerberos auth method and plugin
openstack-config --set /etc/keystone/keystone.conf auth methods "kerberos,password,token"
openstack-config --set /etc/keystone/keystone.conf auth kerberos keystone.auth.plugins.external.KerberosDomain

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
wget -O /etc/keystone/policy.v3cloudsample.json http://git.openstack.org/cgit/openstack/keystone/plain/etc/policy.v3cloudsample.json
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

# Add a project to our domain and grant the admin role to  a user
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

# NGK(TODO) Install Kerberos plugin from git.  This can be replaced
# when it is available via RPM from yum.
pushd /opt
git clone git://git.openstack.org/openstack/python-keystoneclient-kerberos
pushd /opt/python-keystoneclient-kerberos
git pull https://review.openstack.org/openstack/python-keystoneclient-kerberos refs/changes/14/123614/14
python setup.py install
popd
popd

# Add rc files for cloud admin and IPA domain admin
cat > /home/$VM_USER_ID/keystonerc_cloud_admin << EOF
export OS_USERNAME=cloud_admin
export OS_PASSWORD=$RDO_PASSWORD
export OS_DOMAIN_NAME=admin_domain
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
export OS_USER_DOMAIN_NAME=$IPA_REALM
export OS_PROJECT_DOMAIN_NAME=$IPA_REALM
export OS_AUTH_URL=http://$VM_FQDN:5000/v3/
export OS_IDENTITY_API_VERSION=3
export OS_AUTH_TYPE=
export PS1='[\u@\h \W(keystone_ipa_admin)]\$ '
EOF

cat > /home/$VM_USER_ID/keystonerc_kerberos <<EOF
export OS_USERNAME=unused
export OS_PASSWORD=unused
export OS_USER_DOMAIN_NAME=unused
export OS_DOMAIN_NAME=$IPA_REALM
export OS_PROJECT_DOMAIN_NAME=$IPA_REALM
export OS_AUTH_URL=http://$VM_FQDN:5000/krb/v3/
export OS_IDENTITY_API_VERSION=3
export OS_AUTH_TYPE=v3kerberos
export PS1='[\u@\h \W(keystone_kerberos)]\$ '
EOF

chown $VM_USER_ID:$VM_USER_ID /home/$VM_USER_ID/keystonerc_*
