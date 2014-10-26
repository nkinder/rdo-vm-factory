#!/bin/bash

. ../global.conf
. ../scripts/setupvm.sh

# Remove the VMs
remove_vm "rdo"
remove_vm "ipa"

# Remove the virtual networks
remove_virt_network "$VM_NETWORK_NAME"
remove_virt_network "$VM_NETWORK_NAME_2"
