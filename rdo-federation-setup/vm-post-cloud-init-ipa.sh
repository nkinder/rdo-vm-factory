#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

##### MAIN BEGINS HERE #####

setenforce 0

# Source our config for IPA settings.
. /mnt/ipa.conf

# Set up entropy source for IPA installer
rngd -r /dev/hwrng

# Install IPA
ipa-server-install -r $IPA_REALM -n $VM_DOMAIN -p "$IPA_PASSWORD" -a "$IPA_PASSWORD" \
    -N --hostname=$VM_FQDN --setup-dns --forwarder=$IPA_FWDR -U

# Enable EPEL for python-cherrypy and python-sqlalchemy
yum install -y epel-release

# Set up Copr repos for Ipsilon and it's dependencies
wget -O /etc/yum.repos.d/ipsilon.repo \
    https://copr.fedoraproject.org/coprs/nkinder/ipsilon/repo/epel-7/nkinder-ipsilon-epel-7.repo
wget -O /etc/yum.repos.d/sssd.repo \
    https://copr.fedoraproject.org/coprs/nkinder/sssd/repo/epel-7/nkinder-sssd-epel-7.repo

# Install Ipsilon
yum install -y ipsilon ipsilon-tools ipsilon-tools-ipa ipsilon-saml2 \
               ipsilon-authkrb ipsilon-authform ipsilon-infosssd
ipsilon-server-install --ipa=yes --krb=yes --form=yes --info-sssd=yes \
                       --admin-user=admin

# Ipsilon uses mod_ssl, but IPA uses mod_nss.  We need to switch
# the directive to allow httpd to start properly.
sed -i 's/SSLRequireSSL/NSSRequireSSL/g' /etc/httpd/conf.d/ipsilon-idp.conf
rm -f /etc/httpd/conf.d/ssl.conf

# Enable local mapping to allow Kerberos or form-based admin access
sed -i 's/# KrbLocalUserMapping On/KrbLocalUserMapping On/' /etc/httpd/conf.d/ipsilon-idp.conf

# Restart httpd to start Ipsilon
systemctl restart httpd.service
