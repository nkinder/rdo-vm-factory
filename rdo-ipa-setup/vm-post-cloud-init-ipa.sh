#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

##### MAIN BEGINS HERE #####

set -o errexit

setenforce 0

# Source our config for IPA settings.
. /mnt/ipa.conf

if [ -z "$NO_RNGD" ] ; then
    # Set up entropy source for IPA installer
    rngd -r /dev/hwrng
fi

# I dunno - maybe something needs more time?
dig @192.168.128.1 . -t NS || echo failed
sleep 120
dig @192.168.128.1 . -t NS || echo failed

# getcert fails - certmonger not running?

# turn off and permanently disable firewall
systemctl stop firewalld.service
systemctl disable firewalld.service

# Install IPA
if [ -z "$NO_IPA_DNS" ] ; then
    IPA_DNS="--setup-dns --forwarder=$IPA_FWDR"
fi
ipa-server-install -r $IPA_REALM -n $VM_DOMAIN -p "$IPA_PASSWORD" -a "$IPA_PASSWORD" \
    -N --hostname=$VM_FQDN $IPA_DNS -U
