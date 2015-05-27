#!/bin/sh

IPSILON_FQDN=ipa.example.test
IPSILON_PASSWORD=Secret12

# Install mod_auth_mellon
wget -O /etc/yum.repos.d/nkinder-mod_auth_mellon-epel-6.repo \
    https://copr.fedoraproject.org/coprs/nkinder/mod_auth_mellon/repo/epel-6/nkinder-mod_auth_mellon-epel-6.repo
yum install -y mod_auth_mellon

# Fetch IdP metadata and generate SP metadata
mkdir /etc/httpd/saml2
wget --ca-certificate=/etc/ipa/ca.crt -O /etc/httpd/saml2/idp-metadata.xml https://$IPSILON_FQDN/idp/saml2/metadata
pushd /etc/httpd/saml2
# NGK(TODO) This is something we should handle with ipsilon-client-install
# in the future.
/usr/libexec/mod_auth_mellon/mellon_create_metadata.sh https://$(hostname) https://$(hostname)/saml2

# Add 'unspecified' nameid to metadata
sed -i 's/<\/SPSSODescriptor>/  <NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified<\/NameIDFormat>\n  <\/SPSSODescriptor>/g' \
    ./https_$(hostname).xml
popd

# Register SP
yum install -y python-argparse python-requests
./add-sp.py --url https://$IPSILON_FQDN/idp --password $IPSILON_PASSWORD \
          --metadata /etc/httpd/saml2/https_$(hostname).xml $(hostname | sed -e 's/\.//g') 

# Update httpd config to use mod_auth_mellon
cp /etc/httpd/conf.d/cfme-external-auth ./cfme-external-auth.backup
cp ./cfme-external-auth.template /etc/httpd/conf.d/cfme-external-auth
sed -i "s/\${HOSTNAME}/$(hostname)/g" /etc/httpd/conf.d/cfme-external-auth

# Add mod_proxy rule to exclude /saml2
proxy_conf=$(cat /etc/httpd/conf.d/cfme-redirects-ui)
echo -e "ProxyPass /saml2 !\n$proxy_conf" > /etc/httpd/conf.d/cfme-redirects-ui

# Restart httpd to allow changes to take effect
service httpd restart
