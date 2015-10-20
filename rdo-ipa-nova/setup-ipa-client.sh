#!/bin/sh

# get OTP
ii=60
while [ $ii -gt 0 ] ; do
    otp=`cat /tmp/ipaotp`
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

rm -f /tmp/ipaotp
# run ipa-client-install
ipa-client-install -U -w $otp
