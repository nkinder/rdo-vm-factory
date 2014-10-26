#!/bin/sh

#### Installation Helpers ####
install_packages() {
    PKGS_REQ=${PKGS_REQ:-"git wget genisoimage qemu-img qemu-kvm libvirt virt-manager virt-install libguestfs-tools openldap-clients"}
    PKGS_TO_INSTALL=${PKGS_TO_INSTALL:-""}

    for pkg in $PKGS_REQ ; do
        if rpm -q $pkg ; then
            echo package $pkg installed
        else
            PKGS_TO_INSTALL="$PKGS_TO_INSTALL $pkg"
        fi
    done

    if [ -n "$PKGS_TO_INSTALL" ] ; then
        $SUDOCMD yum -y install $PKGS_TO_INSTALL
    fi

    # RHEL requires libguestfs-winsupport
    if [ "$OS_NAME" = "RHEL" ] ; then
        pkg=libguestfs-winsupport
        if ! rpm -q $pkg ; then
            $SUDOCMD yum -y install $pkg
        fi

        if ! rpm -q $pkg ; then
            echo "Error:  RHEL requires the $pkg package, which is available in"
            echo "the V2VWIN channel.  You must subscribe to the V2VWIN channel"
            echo "or install this package via other means."
            exit 1
        fi
    fi
}

install_scripts() {
    pushd $FACTORY_DIR

    # Clone richm's script repo
    if [ ! -d "$FACTORY_DIR/scripts" ] ; then
        git clone https://github.com/richm/scripts.git
    fi

    # Clone richm's auto_win_vm repo
    if [ ! -d "$FACTORY_DIR/auto-win-vm-ad" ] ; then
        git clone https://github.com/richm/auto-win-vm-ad.git
    fi

    popd
}

factory_setup() {
    # Determine our OS
    release=`cat /etc/redhat-release`
    case $release in
        'Red Hat Enterprise Linux'*)
            OS_NAME=RHEL
            ;;
        Fedora*)
            OS_NAME=Fedora
            ;;
        *)
    esac

    install_packages
    install_scripts

    # We might have just installed libvirtd, so start
    # it if necessary.
    if ! systemctl status libvirtd.service; then
        $SUDOCMD systemctl start libvirtd.service
    fi
}

#### Image Download Helpers ####
get_image() {
    . $1
    if [ ! -f "$VM_IMG_DIR/$VM_IMG_NAME" ] ; then
        $SUDOCMD wget -O $VM_IMG_DIR/$VM_IMG_NAME $VM_IMG_URL
    fi
}

get_windows_image() {
    destfile=${WIN_VM_DISKFILE_BACKING:-$VM_IMG_DIR/$WIN_IMG_NAME.qcow2}
    if ! $SUDOCMD test -f $destfile ; then
        # Install the unarchive tools.
        $SUDOCMD yum -y install unar unrar
        if rpm -q unar ; then
            UNRAR=unar
        else
            if rpm -q unrar ; then
                UNRAR="unrar x"
            else
                echo "The unar or unrar package is unavailable.  This is required to"
                echo "extract the downloaded Windows images.  Either install the unar"
                echo "of unrar package from somewhere like RPMFusion, or download and"
                echo "convert the Windows image on another system where the proper tools"
                echo "are available and place it in the following expected location:"
                echo ""
                echo "    $destfile"
                echo ""
                echo "Downloading and image conversion can be performed manually with"
                echo "the following steps:"
                echo ""
                echo "  $ mkdir -p /tmp/vhd && cd /tmp/vhd"
                echo "  $ wget $WIN_URL/$WIN_IMG_NAME.part01.exe"
                echo "  $ wget $WIN_URL/$WIN_IMG_NAME.part02.rar"
                echo "  $ wget $WIN_URL/$WIN_IMG_NAME.part03.rar"
                echo "  $ unar $WIN_IMG_NAME.part01.exe"
                echo "  $ cd \"/tmp/vhd/$WIN_IMG_NAME/$WIN_IMG_NAME/Virtual Hard Disks\""
                echo "  $ qemu-img convert -p -f vpc -O qcow2 $WIN_IMG_NAME.vhd $WIN_IMG_NAME.qcow2"
                echo ""
                echo "If unar is unavailable, unrar can be used like this:"
                echo ""
                echo "  $ unrar x $WIN_IMG_NAME.part01.exe"
                echo ""
                exit 1
            fi
        fi

        # Download the partial Windows images
        mkdir -p $WIN_DL_IMG_DIR
        pushd $WIN_DL_IMG_DIR
        for file in $WIN_IMG_NAME.part01.exe $WIN_IMG_NAME.part02.rar $WIN_IMG_NAME.part03.rar ; do
            if [ ! -f $file ] ; then
                wget $WIN_URL/$file
            fi
        done

        # Extract the image
        if [ ! -f "$WIN_DL_IMG_DIR/$WIN_IMG_NAME/$WIN_IMG_NAME/Virtual Hard Disks/$WIN_IMG_NAME.vhd" ] ; then
            $UNRAR $WIN_IMG_NAME.part01.exe
        fi

        # Convert the image to qcow2 format
        cd "$WIN_DL_IMG_DIR/$WIN_IMG_NAME/$WIN_IMG_NAME/Virtual Hard Disks"
        $SUDOCMD qemu-img convert -p -f vpc -O qcow2 $WIN_IMG_NAME.vhd $destfile
        popd
    fi

    # Source our VM conf file to see if a backing file is being used
    #
    # NOTE: On F20, when using a backing file + image, it seems that virt-win-reg somehow
    # corrupts the registry, which is used by other virt tools such as virt-cat and virt-ls,
    # which are used to test for setup/install completion - in this case, we can't use the
    # backing file, we just make a copy of it so we can write to it
    # we keep a copy of it for testing, so we can create other vms from the same source
    . $1
    if [ -z "$WIN_VM_DISKFILE_BACKING" -a -n "$WIN_VM_DISKFILE" ] ; then
        if ! $SUDOCMD test -f $WIN_VM_DISKFILE ; then
            $SUDOCMD cp $destfile $WIN_VM_DISKFILE
        fi
    fi
}

#### Network Helpers ####
# do this in a sub-shell so we don't pollute the caller's environment
add_host_info() {
(
    . $1
    VM_MAC=${VM_MAC:-`gen_virt_mac`}
    cat >> $ipxml <<EOF
      <host mac='$VM_MAC' name='$VM_NAME' ip='$VM_IP'/>
EOF
    cat >> $dnsxml <<EOF
    <host ip='$VM_IP'>
      <hostname>$VM_NAME.$VM_DOMAIN</hostname>
      <hostname>$VM_NAME</hostname>
    </host>
EOF
)
}

create_virt_network() {
    # create virtual networks before creating hosts
    # each host is in two sections - the ip/dhcp section and the dns section
    VM_NETWORK_NAME=${VM_NETWORK_NAME:-rhostest}
    VM_NETWORK_IP=${VM_NETWORK_IP:-192.168.128.1}
    VM_NETWORK_MASK=${VM_NETWORK_MASK:-255.255.255.0}
    VM_NETWORK_RANGE=${VM_NETWORK_RANGE:-"start='192.168.128.2' end='192.168.128.100'"}
    if $SUDOCMD virsh net-info $VM_NETWORK_NAME > /dev/null 2>&1 ; then
        echo virtual network $VM_NETWORK_NAME already exists
        echo if you want to recreate it, run the following commands
        echo $SUDOCMD virsh net-destroy $VM_NETWORK_NAME
        echo $SUDOCMD virsh net-undefine $VM_NETWORK_NAME
        echo then run $0 again
        echo if you need to add VMs to the network, use $SUDOCMD virsh net-edit $VM_NETWORK_NAME
        echo "and add the <ip><dhcp><host> information, and the <dns><host> information"
        $SUDOCMD virsh net-start $VM_NETWORK_NAME || echo $VM_NETWORK_NAME is running
        return 0
    fi
    netxml=`mktemp`
    cat > $netxml <<EOF
<network>
  <name>$VM_NETWORK_NAME</name>
  <forward mode='nat'/>
  <bridge name='vir$VM_NETWORK_NAME'/>
EOF
    ipxml=`mktemp`
    cat > $ipxml <<EOF
  <ip address='$VM_NETWORK_IP' netmask='$VM_NETWORK_MASK'>
    <dhcp>
      <range $VM_NETWORK_RANGE/>
EOF
    dnsxml=`mktemp`
    cat > $dnsxml <<EOF
  <dns>
EOF
    for cf in "$@" ; do
        add_host_info "$cf"
    done
    cat $dnsxml >> $netxml
    echo '  </dns>' >> $netxml
    cat $ipxml >> $netxml
    echo '    </dhcp>' >> $netxml
    echo '  </ip>' >> $netxml
    echo '</network>' >> $netxml

    $SUDOCMD virsh net-define --file $netxml
    $SUDOCMD virsh net-start $VM_NETWORK_NAME
    rm -f $netxml $ipxml $dnsxml
}

create_virt_private_network() {
    # create virtual networks before creating hosts
    # each host is in two sections - the ip/dhcp section and the dns section
    VM_NETWORK_NAME_2=${VM_NETWORK_NAME_2:-rhosprivate}
    VM_NETWORK_IP_2=${VM_NETWORK_IP_2:-192.168.129.1}
    VM_NETWORK_MASK_2=${VM_NETWORK_MASK_2:-255.255.255.0}
    if $SUDOCMD virsh net-info $VM_NETWORK_NAME_2 > /dev/null 2>&1 ; then
        echo virtual network $VM_NETWORK_NAME_2 already exists
        echo if you want to recreate it, run the following commands
        echo $SUDOCMD virsh net-destroy $VM_NETWORK_NAME_2
        echo $SUDOCMD virsh net-undefine $VM_NETWORK_NAME_2
        echo then run $0 again
        echo if you need to add VMs to the network, use $SUDOCMD virsh net-edit $VM_NETWORK_NAME_2
        echo "and add the <ip><dhcp><host> information, and the <dns><host> information"
        $SUDOCMD virsh net-start $VM_NETWORK_NAME_2 || echo $VM_NETWORK_NAME_2 is running
        return 0
    fi
    netxml=`mktemp`
    cat > $netxml <<EOF
<network>
  <name>$VM_NETWORK_NAME_2</name>
  <forward mode='nat'/>
  <bridge name='vir$VM_NETWORK_NAME_2'/>
  <ip address='$VM_NETWORK_IP_2' netmask='$VM_NETWORK_MASK_2'/>
</network>
EOF
    $SUDOCMD virsh net-define --file $netxml
    $SUDOCMD virsh net-start $VM_NETWORK_NAME_2
    rm -f $netxml
}
