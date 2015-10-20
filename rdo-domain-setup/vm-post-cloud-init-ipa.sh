#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

##### MAIN BEGINS HERE #####

#setenforce 0

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

# Install IPA
ipa-server-install -r $IPA_REALM -n $VM_DOMAIN -p "$IPA_PASSWORD" -a "$IPA_PASSWORD" \
    -N --hostname=$VM_FQDN --setup-dns --forwarder=$IPA_FWDR -U
