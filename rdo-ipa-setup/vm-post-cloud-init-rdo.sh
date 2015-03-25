#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

set -o errexit

get_mysql_conn_info() {
    # grab the mysql connection parameters
    url=`grep ^connection /etc/keystone/keystone.conf|sed 's/^connection[ ]*=[ ]*//'`
    # url looks like this: mysql://username:password@hostname:port/dbname
    m_userpass=`echo "$url"|sed 's,^.*//\([^@]*\)@.*$,\1,'`
    m_hostport=`echo "$url"|sed 's,^.*@\([^/]*\)/.*$,\1,'`
    m_dbname=`echo "$url"|sed 's,^.*/\([^/]*\)$,\1,'`
    m_user=`echo "$m_userpass"|cut -s -f1 -d:`
    if [ -z "$m_user" ] ; then # no pass
        m_user="$m_userpass"
    fi
    m_pass=`echo "$m_userpass"|cut -s -f2 -d:`
    m_host=`echo "$m_hostport"|cut -s -f1 -d:`
    if [ -z "$m_host" ] ; then # no port
        m_host="$m_hostport"
    fi
    m_port=`echo "$m_hostport"|cut -s -f2 -d:`
}

create_ipa_user() {
    if [ -n "$3" ] ; then
        mail="$3"
    else
        mail="$1@localhost"
    fi
    if [ -n "$PACKSTACK_LDAP" -a -z "$PACKSTACK_SUPPORTS_INVERT" ] ; then
        addtl="--addattr=${KEYSTONE_LDAP_USER_ENABLED_ATTRIBUTE}=${KEYSTONE_LDAP_USER_ENABLED_DEFAULT}"
    fi
    if ipa user-show $1 ; then
        echo using existing user $1
    else
        echo "$2" | ipa user-add $1 --cn="$1 user" --first="$1" --last="user" --homedir=/var/lib/$1 $addtl --password
        dn="uid=$1,$KEYSTONE_LDAP_USER_SUBTREE"
        ldapmodify -Y GSSAPI -H "$KEYSTONE_LDAP_URL" <<EOF
dn: $dn
changetype: modify
replace: mail
mail: $mail
EOF
    fi
}

fix_keystone_tables_for_userid() {
    # new user_id is $1
    # old user_id is $2 (used for renaming users)
    # What are we doing?
    # When switching from sql to ldap, you have to use the ldap userid (the user.name column)
    # as the keystone user id instead of the uuid, since the user table won't be used anymore,
    # and the key in the user table is the uuid - so, use the user name as the user_id
    # in the $asgn_t table
    asgn_t="assignment" # assignment table name
    act_col="actor_id" # actor column name
    id_col="id" # id column name
    user_t="user" # user table name
    name_col="name" # user name column
    proj_t="project" # project/tenant table name
    if [ -n "$2" ] ; then
        mysql ${m_host:+"--host=$m_host"} ${m_port:+"--port=$m_port"} \
            ${m_user:+"--user=$m_user"} ${m_pass:+"--password=$m_pass"} "$m_dbname"  --execute \
            "update $asgn_t set $act_col = '$2' where $act_col = (select $id_col from $user_t where $name_col = '$1');"
    else
        mysql ${m_host:+"--host=$m_host"} ${m_port:+"--port=$m_port"} \
            ${m_user:+"--user=$m_user"} ${m_pass:+"--password=$m_pass"} "$m_dbname"  --execute \
            "update $asgn_t set $act_col = '$1' where $act_col = (select $id_col from $user_t where $name_col = '$1');"
    fi
}

convert_yn_to_tf() {
    case "$1" in
    [yY]*) echo true ;;
    *) echo false ;;
    esac
}

configure_keystone_for_ldap() {
    cp -p /etc/keystone/keystone.conf /etc/keystone/keystone.conf.orig
    openstack-config --set /etc/keystone/keystone.conf identity driver keystone.identity.backends.ldap.Identity
    openstack-config --set /etc/keystone/keystone.conf assignment driver keystone.assignment.backends.sql.Assignment
    openstack-config --set /etc/keystone/keystone.conf ldap url "$KEYSTONE_LDAP_URL"
    openstack-config --set /etc/keystone/keystone.conf ldap user "$KEYSTONE_LDAP_USER_DN"
    openstack-config --set /etc/keystone/keystone.conf ldap password "$KEYSTONE_LDAP_USER_PASSWORD"
    openstack-config --set /etc/keystone/keystone.conf ldap suffix "$KEYSTONE_LDAP_SUFFIX"
    openstack-config --set /etc/keystone/keystone.conf ldap user_tree_dn "$KEYSTONE_LDAP_USER_SUBTREE"
    openstack-config --set /etc/keystone/keystone.conf ldap user_objectclass $KEYSTONE_LDAP_USER_OBJECTCLASS
    openstack-config --set /etc/keystone/keystone.conf ldap user_id_attribute $KEYSTONE_LDAP_USER_ID_ATTRIBUTE
    openstack-config --set /etc/keystone/keystone.conf ldap user_name_attribute $KEYSTONE_LDAP_USER_NAME_ATTRIBUTE
    openstack-config --set /etc/keystone/keystone.conf ldap user_mail_attribute $KEYSTONE_LDAP_USER_MAIL_ATTRIBUTE
    openstack-config --set /etc/keystone/keystone.conf ldap user_allow_create `convert_yn_to_tf $KEYSTONE_LDAP_USER_ALLOW_CREATE`
    openstack-config --set /etc/keystone/keystone.conf ldap user_allow_update `convert_yn_to_tf $KEYSTONE_LDAP_USER_ALLOW_UPDATE`
    openstack-config --set /etc/keystone/keystone.conf ldap user_allow_delete `convert_yn_to_tf $KEYSTONE_LDAP_USER_ALLOW_DELETE`
    openstack-config --set /etc/keystone/keystone.conf ldap group_tree_dn "$KEYSTONE_LDAP_GROUP_SUBTREE"
    openstack-config --set /etc/keystone/keystone.conf ldap group_objectclass $KEYSTONE_LDAP_GROUP_OBJECTCLASS
    openstack-config --set /etc/keystone/keystone.conf ldap group_id_attribute $KEYSTONE_LDAP_GROUP_ID_ATTRIBUTE
    openstack-config --set /etc/keystone/keystone.conf ldap group_name_attribute $KEYSTONE_LDAP_GROUP_NAME_ATTRIBUTE
    openstack-config --set /etc/keystone/keystone.conf ldap group_member_attribute $KEYSTONE_LDAP_GROUP_MEMBER_ATTRIBUTE
    openstack-config --set /etc/keystone/keystone.conf ldap group_desc_attribute $KEYSTONE_LDAP_GROUP_DESC_ATTRIBUTE
    openstack-config --set /etc/keystone/keystone.conf ldap group_allow_create `convert_yn_to_tf $KEYSTONE_LDAP_GROUP_ALLOW_CREATE`
    openstack-config --set /etc/keystone/keystone.conf ldap group_allow_update `convert_yn_to_tf $KEYSTONE_LDAP_GROUP_ALLOW_UPDATE`
    openstack-config --set /etc/keystone/keystone.conf ldap group_allow_delete `convert_yn_to_tf $KEYSTONE_LDAP_GROUP_ALLOW_DELETE`
    openstack-config --set /etc/keystone/keystone.conf ldap user_enabled_attribute $KEYSTONE_LDAP_USER_ENABLED_ATTRIBUTE
    openstack-config --set /etc/keystone/keystone.conf ldap user_enabled_default $KEYSTONE_LDAP_USER_ENABLED_DEFAULT
    openstack-config --set /etc/keystone/keystone.conf ldap user_enabled_invert $KEYSTONE_LDAP_USER_ENABLED_INVERT
}

##### MAIN BEGINS HERE #####

# I dunno - maybe something needs more time?
sleep 60
# getcert fails - certmonger not running?

# turn off and permanently disable firewall
systemctl stop firewalld.service
systemctl disable firewalld.service

# NGK(TODO) - Disable SELinux policy to allow Keystone to run in httpd.  This
# is a temporary workaround until BZ#1138424 is fixed and available in the base
# SELinux policy in RHEL/CentOS.
setenforce 0

# Source our IPA config for IPA settings
. /mnt/ipa.conf

# Save the IPA FQDN and IP for later use
IPA_FQDN=$VM_FQDN
IPA_IP=$VM_IP

# Source our config for RDO settings
. /mnt/rdo.conf

suffix=`echo $VM_DOMAIN | sed -e 's/^/dc=/' -e 's/\./,dc=/g'`
KEYSTONE_LDAP_SUFFIX=${KEYSTONE_LDAP_SUFFIX:-$suffix}
KEYSTONE_LDAP_URL=${KEYSTONE_LDAP_URL:-"ldap://$IPA_FQDN"}
KEYSTONE_LDAP_USER_DN=${KEYSTONE_LDAP_USER_DN:-"uid=keystone,cn=users,cn=accounts,$KEYSTONE_LDAP_SUFFIX"}
KEYSTONE_LDAP_USER_PASSWORD=${KEYSTONE_LDAP_USER_PASSWORD:-"$RDO_PASSWORD"}
KEYSTONE_LDAP_USER_SUBTREE=${KEYSTONE_LDAP_USER_SUBTREE:-"cn=users,cn=accounts,$KEYSTONE_LDAP_SUFFIX"}
if [ -n "$LDAP_USE_POSIX" ] ; then
    KEYSTONE_LDAP_USER_OBJECTCLASS=${KEYSTONE_LDAP_USER_OBJECTCLASS:-posixAccount}
    KEYSTONE_LDAP_USER_ID_ATTRIBUTE=${KEYSTONE_LDAP_USER_ID_ATTRIBUTE:-uidNumber}
    KEYSTONE_LDAP_USER_NAME_ATTRIBUTE=${KEYSTONE_LDAP_USER_NAME_ATTRIBUTE:-uid}
else
    KEYSTONE_LDAP_USER_OBJECTCLASS=${KEYSTONE_LDAP_USER_OBJECTCLASS:-person}
    KEYSTONE_LDAP_USER_ID_ATTRIBUTE=${KEYSTONE_LDAP_USER_ID_ATTRIBUTE:-uid}
    KEYSTONE_LDAP_USER_NAME_ATTRIBUTE=${KEYSTONE_LDAP_USER_NAME_ATTRIBUTE:-uid}
fi
KEYSTONE_LDAP_USER_MAIL_ATTRIBUTE=${KEYSTONE_LDAP_USER_MAIL_ATTRIBUTE:-mail}
if [ -n "$PACKSTACK_LDAP" -a -z "$PACKSTACK_SUPPORTS_INVERT" ] ; then
    KEYSTONE_LDAP_USER_ENABLED_ATTRIBUTE=${KEYSTONE_LDAP_USER_ENABLED_ATTRIBUTE:-description}
    KEYSTONE_LDAP_USER_ENABLED_DEFAULT=${KEYSTONE_LDAP_USER_ENABLED_DEFAULT:-TRUE}
else
    KEYSTONE_LDAP_USER_ENABLED_ATTRIBUTE=${KEYSTONE_LDAP_USER_ENABLED_ATTRIBUTE:-nsAccountLock}
    KEYSTONE_LDAP_USER_ENABLED_DEFAULT=${KEYSTONE_LDAP_USER_ENABLED_DEFAULT:-FALSE}
    KEYSTONE_LDAP_USER_ENABLED_INVERT=${KEYSTONE_LDAP_USER_ENABLED_INVERT:-true}
fi
KEYSTONE_LDAP_USER_ALLOW_CREATE=n
KEYSTONE_LDAP_USER_ALLOW_UPDATE=n
KEYSTONE_LDAP_USER_ALLOW_DELETE=n

KEYSTONE_LDAP_GROUP_SUBTREE=${KEYSTONE_LDAP_GROUP_SUBTREE:-"cn=groups,cn=accounts,$KEYSTONE_LDAP_SUFFIX"}
KEYSTONE_LDAP_GROUP_OBJECTCLASS=${KEYSTONE_LDAP_GROUP_OBJECTCLASS:-groupOfNames}
KEYSTONE_LDAP_GROUP_ID_ATTRIBUTE=${KEYSTONE_LDAP_GROUP_ID_ATTRIBUTE:-cn}
KEYSTONE_LDAP_GROUP_NAME_ATTRIBUTE=${KEYSTONE_LDAP_GROUP_NAME_ATTRIBUTE:-cn}
KEYSTONE_LDAP_GROUP_MEMBER_ATTRIBUTE=${KEYSTONE_LDAP_GROUP_MEMBER_ATTRIBUTE:-member}
KEYSTONE_LDAP_GROUP_DESC_ATTRIBUTE=${KEYSTONE_LDAP_GROUP_DESC_ATTRIBUTE:-description}
KEYSTONE_LDAP_GROUP_ALLOW_CREATE=n
KEYSTONE_LDAP_GROUP_ALLOW_UPDATE=n
KEYSTONE_LDAP_GROUP_ALLOW_DELETE=n

# Use IPA for DNS discovery
sed -i "s/^nameserver .*/nameserver $IPA_IP/g" /etc/resolv.conf

# Join IPA
ipa-client-install -U -p admin@$IPA_REALM -w $IPA_PASSWORD

# RDO requires EPEL
yum install -y epel-release

# Set up the rdo-release repo
yum install -y https://rdo.fedorapeople.org/openstack-juno/rdo-release-juno.rpm

# Install packstack
yum install -y openstack-packstack

if [ -n "$PACKSTACK_LDAP" -a -n "$IPA_IS_READ_ONLY" ] ; then
    CEILOMETER_USER=ceilometer
    CEILOMETER_KS_PW=`uuidgen`
    KEYSTONE_USER=keystone
    KEYSTONE_ADMIN_EMAIL=${KEYSTONE_USER}@localhost
    KEYSTONE_ADMIN_PW="$RDO_PASSWORD"
    DEMO_USER=demo
    DEMO_PW=`uuidgen`
    CINDER_USER=cinder
    CINDER_KS_PW=`uuidgen`
    GLANCE_USER=glance
    GLANCE_KS_PW=`uuidgen`
    HEAT_USER=heat
    HEAT_KS_PW=`uuidgen`
    NEUTRON_USER=neutron
    NEUTRON_KS_PW=`uuidgen`
    NOVA_USER=nova
    NOVA_KS_PW=`uuidgen`
    SWIFT_USER=swift
    SWIFT_KS_PW=`uuidgen`
    TEMPEST_USER=tempest
    TEMPEST_USER_PW=`uuidgen`
    # Authenticate as IPA admin
    echo "$IPA_PASSWORD" | kinit admin

    create_ipa_user $CEILOMETER_USER "$CEILOMETER_KS_PW"
    create_ipa_user $KEYSTONE_USER "$KEYSTONE_ADMIN_PW" $KEYSTONE_ADMIN_EMAIL
    create_ipa_user $DEMO_USER "$DEMO_PW"
    create_ipa_user $CINDER_USER "$CINDER_KS_PW"
    create_ipa_user $GLANCE_USER "$GLANCE_KS_PW"
    create_ipa_user $HEAT_USER "$HEAT_KS_PW"
    create_ipa_user $NEUTRON_USER "$NEUTRON_KS_PW"
    create_ipa_user $NOVA_USER "$NOVA_KS_PW"
    create_ipa_user $SWIFT_USER "$SWIFT_KS_PW"
    create_ipa_user $TEMPEST_USER "$TEMPEST_USER_PW"
    if [ "$KEYSTONE_USER" != keystone ] ; then
        create_ipa_user keystone "$RDO_PASSWORD"
    fi

    kdestroy
fi

# Set up SSH
ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

# need packstack patch
if [ -f /share/packstack/0001-allow-to-specify-admin-name-and-email.patch ] ; then
    pushd /usr/lib/python2.7/site-packages/packstack
    yum -y install patch
    patch -p2 < /share/packstack/0001-allow-to-specify-admin-name-and-email.patch
    popd
fi

# Set up our answerfile
HOME=/root packstack --gen-answer-file=/root/answerfile.txt
sed -i 's/CONFIG_NEUTRON_INSTALL=y/CONFIG_NEUTRON_INSTALL=n/g' /root/answerfile.txt
sed -i "s/CONFIG_\(.*\)_PW=.*/CONFIG_\1_PW=$RDO_PASSWORD/g" /root/answerfile.txt
sed -i 's/CONFIG_KEYSTONE_SERVICE_NAME=keystone/CONFIG_KEYSTONE_SERVICE_NAME=httpd/g' /root/answerfile.txt
if [ -n "$PACKSTACK_LDAP" ] ; then
    sed -i 's/CONFIG_KEYSTONE_IDENTITY_BACKEND=sql/CONFIG_KEYSTONE_IDENTITY_BACKEND=ldap/' /root/answerfile.txt
    sed -i "s,CONFIG_KEYSTONE_LDAP_URL=.*$,CONFIG_KEYSTONE_LDAP_URL=$KEYSTONE_LDAP_URL," /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_SUFFIX=.*$/CONFIG_KEYSTONE_LDAP_SUFFIX=$KEYSTONE_LDAP_SUFFIX/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_USER_DN=.*$/CONFIG_KEYSTONE_LDAP_USER_DN=$KEYSTONE_LDAP_USER_DN/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_USER_PASSWORD=.*$/CONFIG_KEYSTONE_LDAP_USER_PASSWORD=$KEYSTONE_LDAP_USER_PASSWORD/" /root/answerfile.txt
    if [ -n "$KEYSTONE_LDAP_USER_FILTER" ] ; then
        sed -i "s/CONFIG_KEYSTONE_LDAP_USER_FILTER=.*$/CONFIG_KEYSTONE_LDAP_USER_FILTER=$KEYSTONE_LDAP_USER_FILTER/" /root/answerfile.txt
    fi
    sed -i "s/CONFIG_KEYSTONE_LDAP_USER_SUBTREE=.*$/CONFIG_KEYSTONE_LDAP_USER_SUBTREE=$KEYSTONE_LDAP_USER_SUBTREE/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_GROUP_SUBTREE=.*$/CONFIG_KEYSTONE_LDAP_GROUP_SUBTREE=$KEYSTONE_LDAP_GROUP_SUBTREE/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_USER_OBJECTCLASS=.*$/CONFIG_KEYSTONE_LDAP_USER_OBJECTCLASS=$KEYSTONE_LDAP_USER_OBJECTCLASS/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_USER_ID_ATTRIBUTE=.*$/CONFIG_KEYSTONE_LDAP_USER_ID_ATTRIBUTE=$KEYSTONE_LDAP_USER_ID_ATTRIBUTE/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_USER_NAME_ATTRIBUTE=.*$/CONFIG_KEYSTONE_LDAP_USER_NAME_ATTRIBUTE=$KEYSTONE_LDAP_USER_NAME_ATTRIBUTE/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_USER_MAIL_ATTRIBUTE=.*$/CONFIG_KEYSTONE_LDAP_USER_MAIL_ATTRIBUTE=$KEYSTONE_LDAP_USER_MAIL_ATTRIBUTE/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_USER_ENABLED_ATTRIBUTE=.*$/CONFIG_KEYSTONE_LDAP_USER_ENABLED_ATTRIBUTE=$KEYSTONE_LDAP_USER_ENABLED_ATTRIBUTE/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_USER_ENABLED_DEFAULT=.*$/CONFIG_KEYSTONE_LDAP_USER_ENABLED_DEFAULT=$KEYSTONE_LDAP_USER_ENABLED_DEFAULT/" /root/answerfile.txt
    if [ -n "$KEYSTONE_LDAP_USER_ENABLED_INVERT" ] ; then
        sed -i "s/CONFIG_KEYSTONE_LDAP_USER_ENABLED_INVERT=.*$/CONFIG_KEYSTONE_LDAP_USER_ENABLED_INVERT=$KEYSTONE_LDAP_USER_ENABLED_INVERT/" /root/answerfile.txt
    fi
    sed -i "s/CONFIG_KEYSTONE_LDAP_GROUP_OBJECTCLASS=.*$/CONFIG_KEYSTONE_LDAP_GROUP_OBJECTCLASS=$KEYSTONE_LDAP_GROUP_OBJECTCLASS/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_GROUP_ID_ATTRIBUTE=.*$/CONFIG_KEYSTONE_LDAP_GROUP_ID_ATTRIBUTE=$KEYSTONE_LDAP_GROUP_ID_ATTRIBUTE/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_GROUP_NAME_ATTRIBUTE=.*$/CONFIG_KEYSTONE_LDAP_GROUP_NAME_ATTRIBUTE=$KEYSTONE_LDAP_GROUP_NAME_ATTRIBUTE/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_GROUP_MEMBER_ATTRIBUTE=.*$/CONFIG_KEYSTONE_LDAP_GROUP_MEMBER_ATTRIBUTE=$KEYSTONE_LDAP_GROUP_MEMBER_ATTRIBUTE/" /root/answerfile.txt
    sed -i "s/CONFIG_KEYSTONE_LDAP_GROUP_DESC_ATTRIBUTE=.*$/CONFIG_KEYSTONE_LDAP_GROUP_DESC_ATTRIBUTE=$KEYSTONE_LDAP_GROUP_DESC_ATTRIBUTE/" /root/answerfile.txt
    if [ -n "$KEYSTONE_LDAP_USER_ALLOW_CREATE" ] ; then
        sed -i "s/CONFIG_KEYSTONE_LDAP_USER_ALLOW_CREATE=.*$/CONFIG_KEYSTONE_LDAP_USER_ALLOW_CREATE=$KEYSTONE_LDAP_USER_ALLOW_CREATE/" /root/answerfile.txt
    fi
    if [ -n "$KEYSTONE_LDAP_GROUP_ALLOW_CREATE" ] ; then
        sed -i "s/CONFIG_KEYSTONE_LDAP_GROUP_ALLOW_CREATE=.*$/CONFIG_KEYSTONE_LDAP_GROUP_ALLOW_CREATE=$KEYSTONE_LDAP_GROUP_ALLOW_CREATE/" /root/answerfile.txt
    fi
    if [ -n "$KEYSTONE_LDAP_USER_ALLOW_UPDATE" ] ; then
        sed -i "s/CONFIG_KEYSTONE_LDAP_USER_ALLOW_UPDATE=.*$/CONFIG_KEYSTONE_LDAP_USER_ALLOW_UPDATE=$KEYSTONE_LDAP_USER_ALLOW_UPDATE/" /root/answerfile.txt
    fi
    if [ -n "$KEYSTONE_LDAP_GROUP_ALLOW_UPDATE" ] ; then
        sed -i "s/CONFIG_KEYSTONE_LDAP_GROUP_ALLOW_UPDATE=.*$/CONFIG_KEYSTONE_LDAP_GROUP_ALLOW_UPDATE=$KEYSTONE_LDAP_GROUP_ALLOW_UPDATE/" /root/answerfile.txt
    fi
    if [ -n "$KEYSTONE_LDAP_USER_ALLOW_DELETE" ] ; then
        sed -i "s/CONFIG_KEYSTONE_LDAP_USER_ALLOW_DELETE=.*$/CONFIG_KEYSTONE_LDAP_USER_ALLOW_DELETE=$KEYSTONE_LDAP_USER_ALLOW_DELETE/" /root/answerfile.txt
    fi
    if [ -n "$KEYSTONE_LDAP_GROUP_ALLOW_DELETE" ] ; then
        sed -i "s/CONFIG_KEYSTONE_LDAP_GROUP_ALLOW_DELETE=.*$/CONFIG_KEYSTONE_LDAP_GROUP_ALLOW_DELETE=$KEYSTONE_LDAP_GROUP_ALLOW_DELETE/" /root/answerfile.txt
    fi
fi
if [ -n "$PACKSTACK_LDAP" -a -n "$IPA_IS_READ_ONLY" ] ; then
    sed -i "s/^CONFIG_CEILOMETER_KS_PW=.*$/CONFIG_CEILOMETER_KS_PW=$CEILOMETER_KS_PW/" /root/answerfile.txt
    sed -i "s/^CONFIG_KEYSTONE_ADMIN_PW=.*$/CONFIG_KEYSTONE_ADMIN_PW=$KEYSTONE_ADMIN_PW/" /root/answerfile.txt
    sed -i "s/^CONFIG_KEYSTONE_DEMO_PW=.*$/CONFIG_KEYSTONE_DEMO_PW=$DEMO_PW/" /root/answerfile.txt
    sed -i "s/^CONFIG_CINDER_KS_PW=.*$/CONFIG_CINDER_KS_PW=$CINDER_KS_PW/" /root/answerfile.txt
    sed -i "s/^CONFIG_GLANCE_KS_PW=.*$/CONFIG_GLANCE_KS_PW=$GLANCE_KS_PW/" /root/answerfile.txt
    sed -i "s/^CONFIG_HEAT_KS_PW=.*$/CONFIG_HEAT_KS_PW=$HEAT_KS_PW/" /root/answerfile.txt
    sed -i "s/^CONFIG_NEUTRON_KS_PW=.*$/CONFIG_NEUTRON_KS_PW=$NEUTRON_KS_PW/" /root/answerfile.txt
    sed -i "s/^CONFIG_NOVA_KS_PW=.*$/CONFIG_NOVA_KS_PW=$NOVA_KS_PW/" /root/answerfile.txt
    sed -i "s/^CONFIG_SWIFT_KS_PW=.*$/CONFIG_SWIFT_KS_PW=$SWIFT_KS_PW/" /root/answerfile.txt
    sed -i "s/^CONFIG_PROVISION_TEMPEST_USER_PW=.*$/CONFIG_PROVISION_TEMPEST_USER_PW=$TEMPEST_USER_PW/" /root/answerfile.txt
    sed -i "s/^CONFIG_KEYSTONE_ADMIN_USERNAME=.*$/CONFIG_KEYSTONE_ADMIN_USERNAME=$KEYSTONE_USER/" /root/answerfile.txt
    sed -i "s/^CONFIG_KEYSTONE_ADMIN_EMAIL=.*$/CONFIG_KEYSTONE_ADMIN_EMAIL=$KEYSTONE_ADMIN_EMAIL/" /root/answerfile.txt
fi

# Install RDO
HOME=/root packstack --debug --answer-file=/root/answerfile.txt

if [ -z "$PACKSTACK_LDAP" ] ; then
    # set the mysql connection parameters
    get_mysql_conn_info

    # Get a list of all users defined in Keystone.
    KS_USERS=`mysql -B --skip-column-names ${m_host:+"--host=$m_host"} ${m_port:+"--port=$m_port"} \
     ${m_user:+"--user=$m_user"} ${m_pass:+"--password=$m_pass"} "$m_dbname" \
     --execute "select $name_col from $user_t;"`

    # Authenticate as IPA admin
    echo "$IPA_PASSWORD" | kinit admin

    # Create our users in IPA and fix up the assignments table.
    for user in $KS_USERS; do
        # Rename the "admin" user to "keystone"
        if [ "$user" = "admin" ] ; then
            create_ipa_user keystone $RDO_PASSWORD
            fix_keystone_tables_for_userid $user keystone
        else
            create_ipa_user $user $RDO_PASSWORD
            fix_keystone_tables_for_userid $user
        fi
    done

    # Get rid of the admin Kerberos ticket
    kdestroy

    # Configure Keystone to use IPA
    configure_keystone_for_ldap

    # Fix up the keystonerc for our new admin username
    sed -i 's/export OS_USERNAME=admin/export OS_USERNAME=keystone/g' /root/keystonerc_admin

    # Copy our keystonerc files to our normal user's home directory.
    cp /root/keystonerc_* /home/$VM_USER_ID

    # Create a v3 specific keystonerc file.
    cat > /home/$VM_USER_ID/keystonerc_admin_v3 << EOF
export OS_USERNAME=keystone
export OS_PASSWORD=$RDO_PASSWORD
export OS_PROJECT_NAME=admin
export OS_AUTH_URL=http://127.0.0.1:5000/v3/
export OS_IDENTITY_API_VERSION=3
export PS1='[\u@\h \W(keystone_admin_v3)]\$ '
EOF

    chown $VM_USER_ID:$VM_USER_ID /home/$VM_USER_ID/keystonerc_*

    # Restart the OpenStack services
    openstack-service restart
fi
