#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

##### MAIN BEGINS HERE #####

setenforce 0

# Source our config for IPA settings.
. /mnt/ipa.conf

# Set up entropy source for IPA installer
rngd -r /dev/hwrng

# I dunno - maybe something needs more time?
sleep 60
# getcert fails - certmonger not running?

# turn off and permanently disable firewall
systemctl stop firewalld.service
systemctl disable firewalld.service

set -o errexit

# Install IPA
ipa-server-install -r $IPA_REALM -n $VM_DOMAIN -p "$IPA_PASSWORD" -a "$IPA_PASSWORD" \
    --no-ntp --hostname=$VM_FQDN --setup-dns --forwarder=$IPA_FWDR -U

if [ -n "$USE_IPSILON" ] ; then
    # Enable EPEL for python-cherrypy and python-sqlalchemy
    yum install -y epel-release

    # Set up Copr repos for Ipsilon and it's dependencies
    wget -O /etc/yum.repos.d/ipsilon.repo \
         https://copr.fedoraproject.org/coprs/nkinder/ipsilon/repo/epel-7/nkinder-ipsilon-epel-7.repo
    wget -O /etc/yum.repos.d/sssd.repo \
         https://copr.fedoraproject.org/coprs/nkinder/sssd/repo/epel-7/nkinder-sssd-epel-7.repo
    wget -O /etc/yum.repos.d/mod_auth_gssapi.repo \
         https://copr.fedoraproject.org/coprs/simo/mod_auth_gssapi/repo/epel-7/simo-mod_auth_gssapi-epel-7.repo

    # Install Ipsilon from Copr
    wget -O /etc/yum.repos.d/nkinder-ipsilon-epel-7.repo \
         https://copr.fedoraproject.org/coprs/nkinder/ipsilon/repo/epel-7/nkinder-ipsilon-epel-7.repo
    yum install -y ipsilon ipsilon-saml2 ipsilon-authform ipsilon-authgssapi ipsilon-infosssd ipsilon-tools-ipa
    ipsilon-server-install --ipa=yes --gssapi=yes --form=yes --info-sssd=yes \
                           --admin-user=admin


    # Ipsilon uses mod_ssl, but IPA uses mod_nss.  We need to switch
    # the directive to allow httpd to start properly.
    sed -i 's/SSLRequireSSL/NSSRequireSSL/g' /etc/httpd/conf.d/ipsilon-idp.conf
    rm -f /etc/httpd/conf.d/ssl.conf

    # Enable local mapping to allow Kerberos or form-based admin access
    sed -i 's/# KrbLocalUserMapping On/KrbLocalUserMapping On/' /etc/httpd/conf.d/ipsilon-idp.conf

    # Restart httpd to start Ipsilon
    systemctl restart httpd.service
fi
