#!/bin/sh
# Source our IPA config for IPA settings
. /mnt/ipa.conf

# Save the IPA FQDN and IP for later use
IPA_FQDN=$VM_FQDN
IPA_IP=$VM_IP
IPA_DOMAIN=$VM_DOMAIN

# Source our config for RDO settings
. /mnt/rdo.conf

# add python plugin code for ipa
cp /mnt/novahooks.py /usr/lib/python2.7/site-packages/ipaclient

# add ipa plugin config
cp /mnt/ipaclient.conf /etc/nova

# this script does the ipa client setup
cp /mnt/setup-ipa-client.sh /etc/nova

# cloud-config data
cp /mnt/cloud-config.json /etc/nova
openstack-config --set /etc/nova/nova.conf DEFAULT vendordata_jsonfile_path /etc/nova/cloud-config.json

# put nova in debug mode
openstack-config --set /etc/nova/nova.conf DEFAULT debug True
# use kvm
openstack-config --set /etc/nova/nova.conf DEFAULT virt_type kvm
# set the default domain to the IPA domain
openstack-config --set /etc/nova/nova.conf DEFAULT dhcp_domain $IPA_DOMAIN

# add keytab, url, ca cert
rm -f /etc/nova/ipauser.keytab
ipa-getkeytab -r -s $IPA_FQDN -D "cn=directory manager" -w "$IPA_PASSWORD" -p admin@$IPA_REALM -k /etc/nova/ipauser.keytab
chown nova:nova /etc/nova/ipauser.keytab
chmod 0600 /etc/nova/ipauser.keytab

# add python plugin to nova entry points
openstack-config --set /usr/lib/python2.7/site-packages/nova-*.egg-info/entry_points.txt nova.hooks build_instance ipaclient.novahooks:IPABuildInstanceHook
openstack-config --set /usr/lib/python2.7/site-packages/nova-*.egg-info/entry_points.txt nova.hooks delete_instance ipaclient.novahooks:IPADeleteInstanceHook
openstack-config --set /usr/lib/python2.7/site-packages/nova-*.egg-info/entry_points.txt nova.hooks instance_network_info ipaclient.novahooks:IPANetworkInfoHook

# need a real el7 image in order to run ipa-client-install
. /root/keystonerc_admin
openstack image create rhel7 --file /mnt/rhel-guest-image-7.1-20150224.0.x86_64.qcow2

# route private network through public network
ip route replace 10.0.0.0/24 via 172.24.4.2
# tell dhcp agent which DNS servers to use - use IPA first
openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT dnsmasq_dns_servers $IPA_IP,$VM_IP

# set up ip forwarding and NATing so the new server can access the outside network
echo set up ipv4 forwarding
sysctl -w net.ipv4.ip_forward=1
sed -i "/net.ipv4.ip_forward = 0/s//net.ipv4.ip_forward = 1/" /etc/sysctl.conf && sysctl -p || echo problem
if [ -n "$VM_NODHCP" ] ; then
    echo set up NATing
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    iptables -I FORWARD 1 -j ACCEPT
    iptables-save > /etc/sysconfig/iptables
fi

# restart nova and neutron
openstack-service restart nova
openstack-service restart neutron

SEC_GRP_IDS=$(neutron security-group-list | awk '/ default / {print $2}')
PUB_NET=$(neutron net-list | awk '/ public / {print $2}')
PRIV_NET=$(neutron net-list | awk '/ private / {print $2}')
ROUTER_ID=$(neutron router-list | awk ' /router1/ {print $2}')
# Set the Neutron gateway for router
neutron router-gateway-set $ROUTER_ID $PUB_NET
#Add security group rules to enable ping and ssh:
for secgrpid in $SEC_GRP_IDS ; do
    neutron security-group-rule-create --protocol icmp \
            --direction ingress --remote-ip-prefix 0.0.0.0/0 $secgrpid
    neutron security-group-rule-create --protocol tcp  \
            --port-range-min 22 --port-range-max 22 --direction ingress $secgrpid
done

BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}

myping() {
    ii=$2
    while [ $ii -gt 0 ] ; do
        if ping -q -W1 -c1 -n $1 ; then
            break
        fi
        ii=`expr $ii - 1`
        sleep 1
    done
    if [ $ii = 0 ] ; then
        echo $LINENO "server did not respond to ping $1"
        return 1
    fi
    return 0
}

# get private network id
netid=`openstack network list|awk '/ private / {print $2}'`
if [ -z "$netid" ] ; then
    netid=`nova net-list|awk '/ novanetwork / {print $2}'`
fi
if [ -z "$netid" ] ; then
    echo Error: could not find private network
    openstack network list --long
    nova net-list
    neutron subnet-list
    exit 1
fi
VM_UUID=$(openstack server create rhel7 --flavor m1.small --image rhel7 --security-group default --nic net-id=$netid | awk '/ id / {print $4}')

ii=$BOOT_TIMEOUT
while [ $ii -gt 0 ] ; do
    if openstack server show rhel7|grep ACTIVE ; then
        break
    fi
    ii=`expr $ii - 1`
done

if [ $ii = 0 ] ; then
    echo $LINENO server was not active after $BOOT_TIMEOUT seconds
    openstack server show rhel7
    exit 1
fi

VM_IP=$(openstack server show rhel7 | sed -n '/ addresses / { s/^.*addresses.*private=\([0-9.][0-9.]*\).*$/\1/; p; q }')
if ! myping $VM_IP $BOOT_TIMEOUT ; then
    echo $LINENO "server did not respond to ping $VM_IP"
    exit 1
fi

PORTID=$(neutron port-list --device-id $VM_UUID | awk "/$VM_IP/ {print \$2}")
FIPID=$(neutron floatingip-create public | awk '/ id / {print $4}')
neutron floatingip-associate $FIPID $PORTID
FLOATING_IP=$(neutron floatingip-list | awk "/$VM_IP/ {print \$6}")
FLOATID=$(neutron floatingip-list | awk "/$VM_IP/ {print \$2}")

sleep 10 # give external network a chance to become active
if ! myping $FLOATING_IP $BOOT_TIMEOUT ; then
    echo $LINENO "server did not respond to ping $FLOATING_IP"
    exit 1
fi
