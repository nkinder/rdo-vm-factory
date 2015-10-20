#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

create_ipa_user() {
    if ipa user-find $1 ; then
        echo using existing user $1
    else
        echo "$2" | ipa user-add $1 --cn="$1 user" --first="$1" --last="user" --password
    fi
}

##### MAIN BEGINS HERE #####

# NGK(TODO) - Disable SELinux policy to allow Keystone to run in httpd.  This
# is a temporary workaround until BZ#1138424 is fixed and available in the base
# SELinux policy in RHEL/CentOS.
setenforce 0

# global network config
. /mnt/global.conf

# Source our IPA config for IPA settings
. /mnt/ipa.conf

# Save the IPA FQDN and IP for later use
IPA_FQDN=$VM_FQDN
IPA_IP=$VM_IP

# Source our config for RDO settings
. /mnt/rdo.conf

if [ -n "$VM_NODHCP" ] ; then
    # configure static networking
    cp /mnt/rdo-network /etc/sysconfig/network
    cp /mnt/rdo-ifcfg-eth0 /etc/sysconfig/network-scripts/ifcfg-eth0
    service network restart
else
    # Use IPA for DNS discovery
    sed -i "s/^nameserver .*/nameserver $IPA_IP/g" /etc/resolv.conf
fi

# turn off and permanently disable firewall
systemctl stop firewalld.service
systemctl disable firewalld.service

set -o errexit

sleep 60

# Join IPA
ipa-client-install -U -p admin@$IPA_REALM -w $IPA_PASSWORD --force-join

# RDO requires EPEL
if [ -n "$USE_RDO" ] ; then
    yum install -y epel-release

    # Set up the rdo-release repo
    yum install -y https://repos.fedorapeople.org/repos/openstack/openstack-kilo/rdo-release-kilo-1.noarch.rpm
    #yum install -y https://rdo.fedorapeople.org/openstack-juno/rdo-release-juno.rpm
    if [ -n "$USE_DELOREAN" ] ; then
        wget -O /etc/yum.repos.d/delorean.repo \
             http://trunk.rdoproject.org/centos70/current/delorean.repo
        wget -O /etc/yum.repos.d/rdo-kilo.repo \
             http://copr.fedoraproject.org/coprs/apevec/RDO-Kilo/repo/epel-7/apevec-RDO-Kilo-epel-7.repo
        wget -O /etc/yum.repos.d/pycrypto.repo \
             http://copr.fedoraproject.org/coprs/npmccallum/python-cryptography/repo/epel-7/npmccallum-python-cryptography-epel-7.repo
    fi
fi

# Install packstack
yum install -y openstack-packstack

# Set up SSH
ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

# Set up our answerfile
HOME=/root packstack --gen-answer-file=/root/answerfile.txt
if [ -n "$USE_NOVA_NETWORK" ] ; then
    sed -i 's/CONFIG_NEUTRON_INSTALL=y/CONFIG_NEUTRON_INSTALL=n/g' /root/answerfile.txt
else
    sed -i 's/CONFIG_NEUTRON_INSTALL=n/CONFIG_NEUTRON_INSTALL=y/g' /root/answerfile.txt
    if [ -n "$USE_PROVIDER_NETWORK" ] ; then
        sed -i 's,CONFIG_PROVISION_DEMO=y,CONFIG_PROVISION_DEMO=n,g' /root/answerfile.txt
    else
        sed -i "s,CONFIG_PROVISION_DEMO_FLOATRANGE=.*\$,CONFIG_PROVISION_DEMO_FLOATRANGE=${VM_EXT_NETWORK},g" /root/answerfile.txt
        sed -i 's/PROVISION_ALL_IN_ONE_OVS_BRIDGE=n/PROVISION_ALL_IN_ONE_OVS_BRIDGE=y/g' /root/answerfile.txt
        sed -i 's/CONFIG_NEUTRON_OVS_TUNNELING=n/CONFIG_NEUTRON_OVS_TUNNELING=y/g' /root/answerfile.txt
        sed -i 's/CONFIG_NEUTRON_OVS_TUNNEL_TYPES=.*$/CONFIG_NEUTRON_OVS_TUNNEL_TYPES=vxlan/g' /root/answerfile.txt
    fi
    # neutron doesn't like NetworkManager
    systemctl stop NetworkManager.service
    systemctl disable NetworkManager.service
fi
sed -i "s/CONFIG_\(.*\)_PW=.*/CONFIG_\1_PW=$RDO_PASSWORD/g" /root/answerfile.txt
sed -i 's/CONFIG_KEYSTONE_SERVICE_NAME=keystone/CONFIG_KEYSTONE_SERVICE_NAME=httpd/g' /root/answerfile.txt

# Install RDO
HOME=/root packstack --debug --answer-file=/root/answerfile.txt
if [ -n "$USE_PROVIDER_NETWORK" ] ; then
    . /root/keystonerc_admin
    openstack project create demo --description "demo project" --enable
    openstack user create demo --project demo --password "$RDO_PASSWORD" --email demo@$VM_DOMAIN --enable
fi

sh -x /mnt/nova-setup.sh
