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
yum install -y http://download.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-2.noarch.rpm
yum-config-manager --enable epel

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

# Install Ipsilon
yum install -y ipsilon
ipsilon-server-install --ipa=yes --krb=yes --pam=yes --admin-user=admin@$IPA_REALM

# NGK(TODO) Ipsilon uses mod_ssl, but IPA uses mod_nss.  We need to switch
# the directive to allow httpd to start properly.  Ideally, Ipsilon should
# be capable of using either module for TLS.
sed -i 's/SSLRequireSSL/NSSRequireSSL/g' /etc/httpd/conf.d/ipsilon-idp.conf

# Restart httpd to start Ipsilon
systemctl restart httpd.service
