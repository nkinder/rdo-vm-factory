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
yum install -y epel-release

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
sed -i 's/CONFIG_KEYSTONE_SERVICE_NAME=keystone/CONFIG_KEYSTONE_SERVICE_NAME=httpd/g' /root/answerfile.txt

# Install RDO
HOME=/root packstack --debug --answer-file=/root/answerfile.txt

# Install mod_auth_mellon
wget -O /etc/yum.repos.d/xmlsec1.repo \
    https://copr.fedoraproject.org/coprs/simo/xmlsec1/repo/epel-7/simo-xmlsec1-epel-7.repo
wget -O /etc/yum.repos.d/lasso.repo \
    https://copr.fedoraproject.org/coprs/simo/lasso/repo/epel-7/simo-lasso-epel-7.repo
wget -O /etc/yum.repos.d/mellon.repo \
    https://copr.fedoraproject.org/coprs/nkinder/mod_auth_mellon/repo/epel-7/nkinder-mod_auth_mellon-epel-7.repo
yum install -y mod_auth_mellon

# Set up our SP metadata and fetch the IdP metadata
/usr/libexec/mod_auth_mellon/mellon_create_metadata.sh http://$VM_FQDN:5000/keystone http://$VM_FQDN:5000/v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth/mellon
mkdir /etc/httpd/mellon
cp ./http_${VM_FQDN}_keystone.* /etc/httpd/mellon/
wget --ca-certificate=/etc/ipa/ca.crt -O /etc/httpd/mellon/idp-metadata.xml https://$IPA_FQDN/idp/saml2/metadata

# NGK(TODO) - The SP data needs to be installed in Ipsilon.  CLI tools for this
# have not been implemented yet.  It might be possible to steal the test code
# from the ipsilon repo to automate this in the meantime.  For now, it needs to
# be done manually by accessing Ipsilon in a brower and setting up a SP using
# /etc/httpd/mellon/http_${VM_FQDN}_keystone.xml as the metadata.

# Set up apache config files (load mellon module, configure wsgi files)
cat > /etc/httpd/conf.d/auth_mellon.load << EOF
LoadModule auth_mellon_module /usr/lib64/httpd/modules/mod_auth_mellon.so
EOF

sed -i 's/<\/VirtualHost>//g' /etc/httpd/conf.d/10-keystone_wsgi_main.conf
cat >> /etc/httpd/conf.d/10-keystone_wsgi_main.conf << EOF
  WSGIScriptAliasMatch ^(/v3/OS-FEDERATION/identity_providers/.*?/protocols/.*?/auth)$ /var/www/cgi-bin/keystone/main/$1

  <Location /v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth>
    AuthType "Mellon"
    MellonEnable "auth"
    MellonSPPrivateKeyFile /etc/httpd/mellon/http_${VM_FQDN}_keystone.key
    MellonSPCertFile /etc/httpd/mellon/http_${VM_FQDN}_keystone.cert
    MellonSPMetadataFile /etc/httpd/mellon/http_${VM_FQDN}_keystone.xml
    MellonIdPMetadataFile /etc/httpd/mellon/idp-metadata.xml
    MellonEndpointPath /v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth/mellon
  </Location>

</VirtualHost>
EOF

sed -i 's/<\/VirtualHost>//g' /etc/httpd/conf.d/10-keystone_wsgi_admin.conf
cat >> /etc/httpd/conf.d/10-keystone_wsgi_admin.conf << EOF
  WSGIScriptAliasMatch ^(/v3/OS-FEDERATION/identity_providers/.*?/protocols/.*?/auth)$ /var/www/cgi-bin/keystone/main/$1

  <Location /v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth>
    AuthType "Mellon"
    MellonEnable "auth"
    MellonSPPrivateKeyFile /etc/httpd/mellon/http_${VM_FQDN}_keystone.key
    MellonSPCertFile /etc/httpd/mellon/http_${VM_FQDN}_keystone.cert
    MellonSPMetadataFile /etc/httpd/mellon/http_${VM_FQDN}_keystone.xml
    MellonIdPMetadataFile /etc/httpd/mellon/idp-metadata.xml
    MellonEndpointPath /v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth/mellon
  </Location>

</VirtualHost>
EOF

# Install pysaml2
# NGK(TODO) This needs to be packaged and installed as a dependency via RPM
yum install -y python-pip
pip install pysaml2

# Set up Keystone for OS-FEDERATION extension
openstack-config --set /etc/keystone/keystone.conf federation driver keystone.contrib.federation.backends.sql.Federation
openstack-config --set /etc/keystone/keystone.conf auth methods external,password,token,saml2
openstack-config --set /etc/keystone/keystone.conf auth saml2 keystone.auth.plugins.mapped.Mapped
openstack-config --set /etc/keystone/keystone.conf paste_deploy config_file /etc/keystone/keystone-paste.ini
cp /usr/share/keystone/keystone-dist-paste.ini /etc/keystone/keystone-paste.ini
chown keystone:keystone /etc/keystone/keystone-paste.ini
openstack-config --set /etc/keystone/keystone-paste.ini pipeline:api_v3 pipeline "sizelimit url_normalize build_auth_context token_auth admin_token_auth xml_body_v3 json_body ec2_extension_v3 s3_extension simple_cert_extension revoke_extension federation_extension service_v3"
keystone-manage db_sync --extension federation

# Restart keystone
systemctl restart httpd.service

# Set up our group, assignment, IdP, mapping, and protocol in Keystone
openstack --os-auth-url http://$VM_FQDN:5000/v3 \
          --os-user-domain-name default \
          --os-username admin \
          --os-password Secret12 \
          --os-project-domain-name default \
          --os-project-name admin \
          --os-identity-api-version 3 \
          group create admins
openstack --os-auth-url http://$VM_FQDN:5000/v3 \
          --os-user-domain-name default \
          --os-username admin \
          --os-password Secret12 \
          --os-project-domain-name default \
          --os-project-name admin \
          --os-identity-api-version 3 \
          role add --group admins --project admin admin
openstack --os-auth-url http://$VM_FQDN:5000/v3 \
          --os-user-domain-name default \
          --os-username admin \
          --os-password Secret12 \
          --os-project-domain-name default \
          --os-project-name admin \
          --os-identity-api-version 3 \
          identity provider create --enable ipsilon

# NGK(TODO) This should be possible with OSC now.  Also, we should enable the info plugin for Ipsilon
# to allow us to use a better mapping based on remote groups.
# Create mapping and IdP protocol in Keystone.
ADMIN_TOKEN=`grep ^admin_token /etc/keystone/keystone.conf | sed -e 's/admin_token=//g'`
FED_GROUP_ID=`openstack --os-auth-url http://$VM_FQDN:5000/v3 --os-user-domain-name default --os-username admin --os-password Secret12 \
    --os-project-domain-name default --os-project-name admin --os-identity-api-version 3 group show admins -f value -c id`
curl -si -X PUT -d @- -H "X-Auth-Token:$ADMIN_TOKEN" -H "Content-type: application/json" http://$VM_FQDN:5000/v3/OS-FEDERATION/mappings/ipsilon_mapping << EOF
    {
        "mapping": {
            "rules": [
                {
                    "local": [
                        {
                            "user": {
                                "name": "{0}"
                            },
                            "group": {
                                "id": "$FED_GROUP_ID"
                            }
                        }
                    ],
                    "remote": [
                        {
                            "type": "MELLON_NAME_ID"
                        }
                    ]
                }
            ]
        }
    }
EOF

curl -si -X PUT -d @- -H "X-Auth-Token:$ADMIN_TOKEN" -H "Content-type: application/json" http://$VM_FQDN:5000/v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2 << EOF
    {
        "protocol": {
            "mapping_id": "ipsilon_mapping"
        }
    }
EOF

# Copy our keystonerc files to our normal user's home directory.
cp /root/keystonerc_* /home/$VM_USER_ID

# Create a v3 keystonerc file.
cat > /home/$VM_USER_ID/keystonerc_v3_admin <<EOF
export OS_USERNAME=admin
export OS_PASSWORD=$RDO_PASSWORD
export OS_PROJECT_NAME=admin
export OS_AUTH_URL=http://$RDO_VM_FQDN:5000/v3/
export OS_IDENTITY_API_VERSION=3
export PS1='[\u@\h \W(keystone_v3_admin)]\$ '
EOF

chown $VM_USER_ID:$VM_USER_ID /home/$VM_USER_ID/keystonerc_*
