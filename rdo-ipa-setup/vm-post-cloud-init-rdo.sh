#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

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
    suffix=`echo $VM_DOMAIN | sed -e 's/^/dc=/' -e 's/\./,dc=/g'`
    echo "$2" | ipa user-add $1 --cn="$1 user" --first="$1" --last="user" --password
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

use_ldap_in_keystone() {
    suffix=`echo $VM_DOMAIN | sed -e 's/^/dc=/' -e 's/\./,dc=/g'`
    cp -p /etc/keystone/keystone.conf /etc/keystone/keystone.conf.orig
    openstack-config --set /etc/keystone/keystone.conf identity driver keystone.identity.backends.ldap.Identity
    openstack-config --set /etc/keystone/keystone.conf assignment driver keystone.assignment.backends.sql.Assignment
    openstack-config --set /etc/keystone/keystone.conf ldap url ldaps://$IPA_FQDN
    openstack-config --set /etc/keystone/keystone.conf ldap user uid=keystone,cn=users,cn=accounts,$suffix
    openstack-config --set /etc/keystone/keystone.conf ldap password $RDO_PASSWORD
    openstack-config --set /etc/keystone/keystone.conf ldap suffix $suffix
    openstack-config --set /etc/keystone/keystone.conf ldap user_tree_dn cn=users,cn=accounts,$suffix
    openstack-config --set /etc/keystone/keystone.conf ldap user_objectclass person
    openstack-config --set /etc/keystone/keystone.conf ldap user_id_attribute uid
    openstack-config --set /etc/keystone/keystone.conf ldap user_name_attribute uid
    openstack-config --set /etc/keystone/keystone.conf ldap user_mail_attribute mail
    openstack-config --set /etc/keystone/keystone.conf ldap user_allow_create false
    openstack-config --set /etc/keystone/keystone.conf ldap user_allow_update false
    openstack-config --set /etc/keystone/keystone.conf ldap user_allow_delete false
    openstack-config --set /etc/keystone/keystone.conf ldap group_tree_dn cn=groups,cn=accounts,$suffix
    openstack-config --set /etc/keystone/keystone.conf ldap group_objectclass groupOfNames
    openstack-config --set /etc/keystone/keystone.conf ldap group_id_attribute cn
    openstack-config --set /etc/keystone/keystone.conf ldap group_name_attribute cn
    openstack-config --set /etc/keystone/keystone.conf ldap group_member_attribute member
    openstack-config --set /etc/keystone/keystone.conf ldap group_desc_attribute description
    openstack-config --set /etc/keystone/keystone.conf ldap group_allow_create false
    openstack-config --set /etc/keystone/keystone.conf ldap group_allow_update false
    openstack-config --set /etc/keystone/keystone.conf ldap group_allow_delete false
    openstack-config --set /etc/keystone/keystone.conf ldap user_enabled_attribute nsAccountLock
    openstack-config --set /etc/keystone/keystone.conf ldap user_enabled_default False
    openstack-config --set /etc/keystone/keystone.conf ldap user_enabled_invert true
}

##### MAIN BEGINS HERE #####

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

# Set up SSH
ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

# Set up our answerfile
HOME=/root packstack --gen-answer-file=/root/answerfile.txt
sed -i 's/CONFIG_NEUTRON_INSTALL=y/CONFIG_NEUTRON_INSTALL=n/g' /root/answerfile.txt
sed -i "s/CONFIG_\(.*\)_PW=.*/CONFIG_\1_PW=$RDO_PASSWORD/g" /root/answerfile.txt
sed -i 's/CONFIG_KEYSTONE_SERVICE_NAME=keystone/CONFIG_KEYSTONE_SERVICE_NAME=httpd/g' /root/answerfile.txt

# Install RDO
HOME=/root packstack --debug --answer-file=/root/answerfile.txt

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
use_ldap_in_keystone

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
