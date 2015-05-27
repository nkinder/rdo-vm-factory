#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

##### MAIN BEGINS HERE #####

setenforce 0

# Source IPA config for IPA settings
. /mnt/ipa.conf

# Save the IPA FQDN and IP for later use
IPA_FQDN=$VM_FQDN
IPA_IP=$VM_IP

# Source our config for our settings
. /mnt/foreman.conf

# Enable EPEL
yum install -y epel-release

# Use IPA for DNS discovery
sed -i "s/^nameserver .*/nameserver $IPA_IP/g" /etc/resolv.conf

# Join IPA
ipa-client-install -U -p admin@$IPA_REALM -w $IPA_PASSWORD

# Add a service for Foreman
echo $IPA_PASSWORD | kinit admin
ipa service-add HTTP/$VM_FQDN@$IPA_REALM
kdestroy

# Install Foreman
yum -y install http://yum.theforeman.org/releases/1.7/el7/x86_64/foreman-release.rpm
yum -y install foreman-installer
foreman-installer --foreman-ipa-authentication=true

# Install a newer mod_auth_mellon from Copr
wget -O /etc/yum.repos.d/nkinder-mod_auth_mellon-epel-7.repo \
    https://copr.fedoraproject.org/coprs/nkinder/mod_auth_mellon/repo/epel-7/nkinder-mod_auth_mellon-epel-7.repo
yum update -y mod_auth_mellon

# Fetch IdP metadata and generate SP metadata
mkdir /etc/httpd/saml2
wget --ca-certificate=/etc/ipa/ca.crt -O /etc/httpd/saml2/idp-metadata.xml https://$IPA_FQDN/idp/saml2/metadata
pushd /etc/httpd/saml2
# NGK(TODO) This is something we should handle with ipsilon-client-install
# in the future.
/usr/libexec/mod_auth_mellon/mellon_create_metadata.sh https://$(hostname) https://$(hostname)/saml2

# Add 'unspecified' nameid to metadata
sed -i 's/<\/SPSSODescriptor>/  <NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified<\/NameIDFormat>\n  <\/SPSSODescriptor>/g' \
    ./https_$(hostname).xml
popd

# Register SP
/mnt/add-sp.py --url https://$IPA_FQDN/idp --password $IPA_PASSWORD \
          --metadata /etc/httpd/saml2/https_$(hostname).xml $(hostname | sed -e 's/\.//g')

# Comment out the mod_auth_kerb external auth setup
sed -i 's/^\(.*\)$/#\1/g' /etc/httpd/conf.d/05-foreman-ssl.d/auth_kerb.conf

# Update httpd config to use mod_auth_mellon
cat /mnt/auth_mellon.conf.template | sed -e "s/\${HOSTNAME}/$(hostname)/g" > \
    /etc/httpd/conf.d/05-foreman-ssl.d/auth_mellon.conf

# Disable mod_lookup_identity for external login since
# mod_auth_mellon will provide all of the user attributes
sed -i 's/(ext)?//g' /etc/httpd/conf.d/05-foreman-ssl.d/lookup_identity.conf

# Set our SSO logout URL
echo ":login_delegation_logout_url: https://$(hostname)/saml2/logout?ReturnTo=https://$(hostname)/users/extlogout" \
    >> /etc/foreman/settings.yaml

# Restart httpd and foreman to allow changes to take effect
systemctl restart httpd.service
systemctl restart foreman.service
systemctl restart foreman-proxy.service
