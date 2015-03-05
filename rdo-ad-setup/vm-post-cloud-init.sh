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

create_ldap_user() {
    USER_PASSWORD=`echo -n "\"$2\"" | iconv -f UTF8 -t UTF16LE | base64 -w 0`
    ldapmodify -x -H ldaps://$VM_FQDN:636 -D "cn=$ADMINNAME,cn=users,$VM_AD_SUFFIX" -w $ADMINPASSWORD <<EOF
dn: cn=$1,cn=users,$VM_AD_SUFFIX
changetype: add
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: user
cn: $1
sn: $1
givenName: $1
sAMAccountName: $1
userAccountControl: 512
userPrincipalName: $1@rdodom.test
unicodePwd:: $USER_PASSWORD
EOF
}

fix_keystone_tables_for_userid() {
    # new user_id is $1
    # What are we doing?
    # When switching from sql to ldap, you have to use the ldap userid (the user.name column)
    # as the keystone user id instead of the uuid, since the user table won't be used anymore,
    # and the key in the user table is the uuid - so, use the user name as the user_id
    # in the $asgn_t table
    mysql ${m_host:+"--host=$m_host"} ${m_port:+"--port=$m_port"} \
        ${m_user:+"--user=$m_user"} ${m_pass:+"--password=$m_pass"} "$m_dbname" <<EOF
update $asgn_t set $act_col = '$1' where $act_col = (select $id_col from $user_t where $name_col = '$1');
EOF
}

use_ldap_in_keystone() {
    cp -p /etc/keystone/keystone.conf /etc/keystone/keystone.conf.orig
    openstack-config --set /etc/keystone/keystone.conf identity driver keystone.identity.backends.ldap.Identity
    openstack-config --set /etc/keystone/keystone.conf assignment driver keystone.assignment.backends.sql.Assignment
    openstack-config --set /etc/keystone/keystone.conf ldap url ldaps://$VM_FQDN:636
    openstack-config --set /etc/keystone/keystone.conf ldap user cn=admin,cn=users,$VM_AD_SUFFIX
    openstack-config --set /etc/keystone/keystone.conf ldap password $RDO_PASSWORD
    openstack-config --set /etc/keystone/keystone.conf ldap suffix $VM_AD_SUFFIX
    openstack-config --set /etc/keystone/keystone.conf ldap user_tree_dn cn=users,$VM_AD_SUFFIX
    openstack-config --set /etc/keystone/keystone.conf ldap user_objectclass user
    openstack-config --set /etc/keystone/keystone.conf ldap user_id_attribute sAMAccountName
    openstack-config --set /etc/keystone/keystone.conf ldap user_name_attribute sAMAccountName
    openstack-config --set /etc/keystone/keystone.conf ldap user_mail_attribute mail
    openstack-config --set /etc/keystone/keystone.conf ldap user_enabled_attribute userAccountControl
    openstack-config --set /etc/keystone/keystone.conf ldap user_enabled_mask 2
    openstack-config --set /etc/keystone/keystone.conf ldap user_enabled_default 512
    openstack-config --set /etc/keystone/keystone.conf ldap user_allow_create false
    openstack-config --set /etc/keystone/keystone.conf ldap user_allow_update false
    openstack-config --set /etc/keystone/keystone.conf ldap user_allow_delete false
    openstack-config --set /etc/keystone/keystone.conf ldap group_tree_dn cn=users,$VM_AD_SUFFIX
    openstack-config --set /etc/keystone/keystone.conf ldap group_objectclass group
    openstack-config --set /etc/keystone/keystone.conf ldap group_id_attribute cn
    openstack-config --set /etc/keystone/keystone.conf ldap group_name_attribute cn
    openstack-config --set /etc/keystone/keystone.conf ldap group_member_attribute member
    openstack-config --set /etc/keystone/keystone.conf ldap group_desc_attribute description
    openstack-config --set /etc/keystone/keystone.conf ldap group_allow_create false
    openstack-config --set /etc/keystone/keystone.conf ldap group_allow_update false
    openstack-config --set /etc/keystone/keystone.conf ldap group_allow_delete false
}

get_ad_ca_cert() {
    AD_CA_NAME=`echo $VM_DOMAIN | sed -e 's/\..*$/-AD-CA/g'`
    CA_CERT_DN="cn=$AD_CA_NAME,cn=certification authorities,cn=public key services,cn=services,cn=configuration,$VM_AD_SUFFIX"
    CA_CERT=/etc/openldap/certs/ad-cacert.pem

    echo "-----BEGIN CERTIFICATE-----" > $CA_CERT
    ldapsearch -xLLL -H ldap://$VM_FQDN -D "cn=$ADMINNAME,cn=users,$VM_AD_SUFFIX" -w $ADMINPASSWORD \
        -s base -b "$CA_CERT_DN" "objectclass=*" cACertificate | perl -p0e 's/\n //g' | \
        sed -e '/^cACertificate/ { s/^cACertificate:: //; s/\(.\{1,64\}\)/\1\n/g; p }' -e 'd' | \
        grep -v '^$' >> $CA_CERT
    echo "-----END CERTIFICATE-----" >> $CA_CERT

    echo "TLS_CACERT $CA_CERT" >> /etc/openldap/ldap.conf
}

##### MAIN BEGINS HERE #####

# Source our RDO config for RDO specific settings.
. /mnt/rdo.conf

# Disable SELinux until rules for RDO Juno are in place.
setenforce 0

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

# Install RDO
HOME=/root packstack --debug --answer-file=/root/answerfile.txt

# NGK(TODO) It would be better to use the keystone or OSC CLI to
# update the assignments instead of directly manipulating the
# database.
asgn_t="assignment" # assignment table name
act_col="actor_id" # actor column name
id_col="id" # id column name
user_t="user" # user table name
name_col="name" # user name column
proj_t="project" # project/tenant table name

# set the mysql connection parameters
get_mysql_conn_info

# Get a list of all users defined in Keystone.
KS_USERS=`mysql -B --skip-column-names ${m_host:+"--host=$m_host"} ${m_port:+"--port=$m_port"} \
     ${m_user:+"--user=$m_user"} ${m_pass:+"--password=$m_pass"} "$m_dbname" \
     --execute "select $name_col from $user_t;"`

# Save our RDO system FQDN before it's overwritten
# by the AD VM FQDN.
RDO_VM_FQDN=$VM_FQDN

# Source our AD config in preparation for 
# performing LDAP updates.
. /mnt/ad.conf
suffix=`echo $VM_DOMAIN | sed -e 's/^/dc=/' -e 's/\./,dc=/g'`
VM_AD_SUFFIX=${VM_AD_SUFFIX:-"$suffix"}

# Fetch the AD CA certificate via LDAP and trust it.
get_ad_ca_cert

# Create our users in AD and fix up the assignments table.
for user in $KS_USERS; do
    create_ldap_user $user $RDO_PASSWORD
    fix_keystone_tables_for_userid $user
done

# Configure Keystone to use AD
use_ldap_in_keystone

# Restart the OpenStack services
openstack-service restart

# Copy our keystonerc files to our normal user's home directory.
cp /root/keystonerc_* /home/$VM_USER_ID

# Create a v3 keystonerc file.
cat > /home/$VM_USER_ID/keystonerc_v3_admin <<EOF
export OS_USERNAME=admin
export OS_PASSWORD=$RDO_PASSWORD
export OS_PROJECT_NAME=admin
export OS_AUTH_URL=http://$RDO_VM_FQDN:5000/v3/
export OS_IDENTITY_API_VERSION=3
export PS1='[\u@\h \W(keystone_v3_admin)]\$ '
EOF

chown $VM_USER_ID:$VM_USER_ID /home/$VM_USER_ID/keystonerc_*
