#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

##### MAIN BEGINS HERE #####

#setenforce 0

# Source our config for IPA settings.
. /mnt/ipa.conf

# Set up entropy source for IPA installer
rngd -r /dev/hwrng

# Install IPA
ipa-server-install -r $IPA_REALM -n $VM_DOMAIN -p "$IPA_PASSWORD" -a "$IPA_PASSWORD" \
    -N --hostname=$VM_FQDN --setup-dns --forwarder=$IPA_FWDR -U

# Enable EPEL (for Ipsilon deps)
yum install -y epel-release

# Set up Copr repos for Ipsilon and it's dependencies
wget -O /etc/yum.repos.d/xmlsec1.repo \
    https://copr.fedoraproject.org/coprs/simo/xmlsec1/repo/epel-7/simo-xmlsec1-epel-7.repo
wget -O /etc/yum.repos.d/lasso.repo \
    https://copr.fedoraproject.org/coprs/simo/lasso/repo/epel-7/simo-lasso-epel-7.repo
wget -O /etc/yum.repos.d/mellon.repo \
    https://copr.fedoraproject.org/coprs/nkinder/mod_auth_mellon/repo/epel-7/nkinder-mod_auth_mellon-epel-7.repo
wget -O /etc/yum.repos.d/mod_authnz_pam.repo \
    https://copr.fedoraproject.org/coprs/nkinder/mod_authnz_pam/repo/epel-7/nkinder-mod_authnz_pam-epel-7.repo
wget -O /etc/yum.repos.d/mod_intercept_form_submit.repo \
    https://copr.fedoraproject.org/coprs/nkinder/mod_intercept_form_submit/repo/epel-7/nkinder-mod_intercept_form_submit-epel-7.repo
wget -O /etc/yum.repos.d/ipsilon.repo \
    https://copr.fedoraproject.org/coprs/nkinder/ipsilon/repo/epel-7/nkinder-ipsilon-epel-7.repo

# NGK(TODO) Just install the open-sans-fonts  package from Fedora 20 for now.  This is a bit of a hack, but it can go away as soon as CentOs 7 is updated to include open-sans-fonts from RHEL 7.1.
yum install -y https://kojipkgs.fedoraproject.org//packages/open-sans-fonts/1.10/1.fc20/noarch/open-sans-fonts-1.10-1.fc20.noarch.rpm

# NGK(TODO) Once CentOS 7 is updated with sssd from RHEL 7.1, we should install ipsilon-infosssd too.
# Install Ipsilon
yum install -y ipsilon ipsilon-tools ipsilon-tools-ipa ipsilon-saml2 ipsilon-authkrb ipsilon-authform
ipsilon-server-install --ipa=yes --krb=yes --form=yes --admin-user=admin

# Ipsilon uses mod_ssl, but IPA uses mod_nss.  We need to switch
# the directive to allow httpd to start properly.
sed -i 's/SSLRequireSSL/NSSRequireSSL/g' /etc/httpd/conf.d/ipsilon-idp.conf
rm -f /etc/httpd/conf.d/ssl.conf

# Enable local mapping to allow Kerberos or form-based admin access
sed -i 's/# KrbLocalUserMapping On/KrbLocalUserMapping On/' /etc/httpd/conf.d/ipsilon-idp.conf

# Restart httpd to start Ipsilon
systemctl restart httpd.service
