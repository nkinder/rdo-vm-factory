#!/bin/sh

# get OTP
ii=60
while [ $ii -gt 0 ] ; do
    otp=`curl -s http://169.254.169.254/openstack/latest/meta_data.json | python -c 'import json; import sys; obj = json.load(sys.stdin); print "%s\n" % obj["meta"]["ipaotp"]'`
    if [ -n "$otp" ] ; then
        break
    fi
    sleep 1
    ii=`expr $ii - 1`
done

if [ -z "$otp" ] ; then
    echo Error: could not get IPA OTP after 60 seconds - exiting
    exit 1
fi

# run ipa-client-install
ipa-client-install -U -w $otp
