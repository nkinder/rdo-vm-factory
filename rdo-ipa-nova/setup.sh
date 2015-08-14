#!/bin/bash

set -o errexit

# Define our paths
FACTORY_DIR=`pwd`/..
PATH="$PATH:$FACTORY_DIR:$FACTORY_DIR/scripts:$FACTORY_DIR/auto-win-vm-ad"

# Setup the vm-factory environment before anything else
. factory.sh
factory_setup || echo error setting up vm-factory

# Source scripts to use their helper functions.
. setupvm.sh

# Source our global configuration
. ../global.conf

# Create our networks
create_virt_network ./ipa.conf ./rdo.conf
#create_virt_private_network

# Set up IPA VM
get_image ./ipa.conf
setupvm.sh ../global.conf ./ipa.conf

# Set up RDO VM
get_image ./rdo.conf
setupvm.sh ../global.conf ./rdo.conf
