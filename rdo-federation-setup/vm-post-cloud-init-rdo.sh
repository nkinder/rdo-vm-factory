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

# Source our IPA config for IPA settings
. /mnt/ipa.conf

# Save the IPA FQDN and IP for later use
IPA_FQDN=$VM_FQDN
IPA_IP=$VM_IP

# Source our config for RDO settings
. /mnt/rdo.conf

# Use IPA for DNS discovery
sed -i "s/^nameserver .*/nameserver $IPA_IP/g" /etc/resolv.conf

# turn off and permanently disable firewall
systemctl stop firewalld.service
systemctl disable firewalld.service

set -o errexit

# Join IPA
ipa-client-install -U -p admin@$IPA_REALM -w $IPA_PASSWORD --force-join

# RDO requires EPEL
yum install -y epel-release

# Set up the rdo-release repo
yum install -y https://rdo.fedorapeople.org/openstack-juno/rdo-release-juno.rpm
if [ -n "$USE_DELOREAN" ] ; then
    wget -O /etc/yum.repos.d/delorean.repo \
        http://trunk.rdoproject.org/centos70/current/delorean.repo
    wget -O /etc/yum.repos.d/rdo-kilo.repo \
        http://copr.fedoraproject.org/coprs/apevec/RDO-Kilo/repo/epel-7/apevec-RDO-Kilo-epel-7.repo
    wget -O /etc/yum.repos.d/pycrypto.repo \
        http://copr.fedoraproject.org/coprs/npmccallum/python-cryptography/repo/epel-7/npmccallum-python-cryptography-epel-7.repo
fi

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

# Authenticate as IPA admin
echo "$IPA_PASSWORD" | kinit admin

# Add a federation test user
create_ipa_user fedtest $RDO_PASSWORD

# Get rid of the admin Kerberos ticket
kdestroy

# set password
{ echo "$RDO_PASSWORD" ; echo "$RDO_PASSWORD" ; echo "$RDO_PASSWORD" ; } | kinit fedtest
kdestroy

# still need pip
yum -y install python-pip

# Install mod_auth_mellon
wget -O /etc/yum.repos.d/xmlsec1.repo \
    https://copr.fedoraproject.org/coprs/simo/xmlsec1/repo/epel-7/simo-xmlsec1-epel-7.repo
wget -O /etc/yum.repos.d/lasso.repo \
    https://copr.fedoraproject.org/coprs/simo/lasso/repo/epel-7/simo-lasso-epel-7.repo
wget -O /etc/yum.repos.d/mellon.repo \
    https://copr.fedoraproject.org/coprs/nkinder/mod_auth_mellon/repo/epel-7/nkinder-mod_auth_mellon-epel-7.repo
yum install -y mod_auth_mellon
# Install ipsilon-client
wget -O /etc/yum.repos.d/ipsilon.repo \
    https://copr.fedoraproject.org/coprs/nkinder/ipsilon/repo/epel-7/nkinder-ipsilon-epel-7.repo
yum install -y ipsilon-client

if [ -z "$USE_DELOREAN" ]; then
    # Install pysaml2
    # NGK(TODO) This needs to be packaged and installed as a dependency via RPM
    yum install -y python-pip
    pip install pysaml2
fi

if [ "$USE_IPSILON_PUPPET" = 1 ] ; then
    echo using puppet
elif [ "$USE_IPSILON_CLIENT" = 1 ] ; then
    IPSILON_ADMIN_PASSWORD="$IPA_PASSWORD" \
    /share/ipsilon/ipsilon/install/ipsilon-client-install --saml-sp-name keystone --port 5000 \
                           --saml-base /v3 \
                           --saml-auth /v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth \
                           --saml-sp /v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth/mellon \
                           --saml-idp-url https://$IPA_FQDN/idp \
                           --saml-sp-logout /v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth/mellon/logout \
                           --saml-sp-post /v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth/mellon/postResponse \
                           --saml-insecure-setup --http-saml-conf-file /etc/httpd/conf.d/keystone-ipsilon.conf

    # fix up /etc/httpd/conf.d/ipsilon-saml.conf to make it suitable for wsgi virtualhost
    # this should be done by a working --saml-secure-setup False setting
#    sed -i -e '/SSLRequireSSL/d' -e '/MellonsecureCookie/d' -e '/^Rewrite/d' /etc/httpd/conf.d/ipsilon-saml.conf
    cat > /etc/httpd/conf.d/headers.load << EOF
LoadModule headers_module modules/mod_headers.so
EOF
else
    # Set up our SP metadata and fetch the IdP metadata
    /usr/libexec/mod_auth_mellon/mellon_create_metadata.sh http://$VM_FQDN:5000/keystone http://$VM_FQDN:5000/v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth/mellon
    mkdir /etc/httpd/mellon
    cp ./http_${VM_FQDN}_keystone.* /etc/httpd/mellon/
    wget --ca-certificate=/etc/ipa/ca.crt -O /etc/httpd/mellon/idp-metadata.xml https://$IPA_FQDN/idp/saml2/metadata

    # Add our SP to Ipsilon
    /mnt/add-sp.py --url https://$IPA_FQDN/idp --password $IPA_PASSWORD --metadata /etc/httpd/mellon/http_${VM_FQDN}_keystone.xml keystone
    # echo -n "admin" > /etc/httpd/mellon/idp_username.txt
    # echo -n "$IPA_PASSWORD" > /etc/httpd/mellon/idp_password.txt
    # curl --cacert /etc/ipa/ca.crt \
    #      --data-urlencode login_name@/etc/httpd/mellon/idp_username.txt \
    #      --data-urlencode login_password@/etc/httpd/mellon/idp_password.txt \
    #      -b /etc/httpd/mellon/cookies -c /etc/httpd/mellon/cookies \
    #      https://$IPA_FQDN/idp/login/form
    # curl --cacert /etc/ipa/ca.crt --referer https://$IPA_FQDN/idp/rest/providers/saml2/SPS/keystone \
    #      -b /etc/httpd/mellon/cookies -c /etc/httpd/mellon/cookies \
    #      --data-urlencode metadata@/etc/httpd/mellon/http_${VM_FQDN}_keystone.xml \
    #      https://$IPA_FQDN/idp/rest/providers/saml2/SPS/keystone
    #cleanup secrets
    # rm -f /etc/httpd/mellon/idp_username.txt /etc/httpd/mellon/idp_password.txt /etc/httpd/mellon/cookies
    if [ -z "$USE_WEBSSO" ] ; then
        WEBSSO_COMMENT="#"
    fi
    cat > /etc/httpd/conf.d/keystone-ipsilon.conf <<EOF
  <Location /v3>
    MellonEnable "info"
    MellonSPPrivateKeyFile /etc/httpd/mellon/http_${VM_FQDN}_keystone.key
    MellonSPCertFile /etc/httpd/mellon/http_${VM_FQDN}_keystone.cert
    MellonSPMetadataFile /etc/httpd/mellon/http_${VM_FQDN}_keystone.xml
    MellonIdPMetadataFile /etc/httpd/mellon/idp-metadata.xml
    MellonEndpointPath /v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth/mellon
    MellonIdP "IDP"
  </Location>

  <Location /v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth>
    AuthType "Mellon"
    MellonEnable "auth"
  </Location>

${WEBSSO_COMMENT}  <Location /v3/auth/OS-FEDERATION/websso/saml2>
${WEBSSO_COMMENT}    AuthType "Mellon"
${WEBSSO_COMMENT}    MellonEnable "auth"
${WEBSSO_COMMENT}  </Location>

EOF
fi

if [ "$USE_IPSILON_PUPPET" = 1 ] ; then
    pushd /usr/share/openstack-puppet/modules
    ln -s /share/puppet-apache-auth-mods apache_auth
    popd
    puppet apply --debug --modulepath /usr/share/openstack-puppet/modules /usr/share/openstack-puppet/modules/apache_auth/test.pp
else
    # Set up apache config files (load mellon module, configure wsgi files)
    cat > /etc/httpd/conf.d/auth_mellon.load << EOF
LoadModule auth_mellon_module /usr/lib64/httpd/modules/mod_auth_mellon.so
EOF

    sed -i 's/<\/VirtualHost>//g' /etc/httpd/conf.d/10-keystone_wsgi_main.conf
    cat >> /etc/httpd/conf.d/10-keystone_wsgi_main.conf << EOF
  WSGIScriptAliasMatch ^(/v3/OS-FEDERATION/identity_providers/.*?/protocols/.*?/auth)$ /var/www/cgi-bin/keystone/main/$1

  Include /etc/httpd/conf.d/keystone-ipsilon.conf
</VirtualHost>
EOF

    sed -i 's/<\/VirtualHost>//g' /etc/httpd/conf.d/10-keystone_wsgi_admin.conf
    cat >> /etc/httpd/conf.d/10-keystone_wsgi_admin.conf << EOF
  WSGIScriptAliasMatch ^(/v3/OS-FEDERATION/identity_providers/.*?/protocols/.*?/auth)$ /var/www/cgi-bin/keystone/main/$1

  Include /etc/httpd/conf.d/keystone-ipsilon.conf
</VirtualHost>
EOF

    # Set up Keystone for OS-FEDERATION extension
    openstack-config --set /etc/keystone/keystone.conf federation driver keystone.contrib.federation.backends.sql.Federation
    openstack-config --set /etc/keystone/keystone.conf auth methods external,password,token,saml2
    openstack-config --set /etc/keystone/keystone.conf auth saml2 keystone.auth.plugins.mapped.Mapped
    openstack-config --set /etc/keystone/keystone.conf paste_deploy config_file /etc/keystone/keystone-paste.ini
    cp /usr/share/keystone/keystone-dist-paste.ini /etc/keystone/keystone-paste.ini
    chown keystone:keystone /etc/keystone/keystone-paste.ini

    v3_pipeline=`openstack-config --get /etc/keystone/keystone-paste.ini pipeline:api_v3 pipeline`
    if [[ "$v3_pipeline" !=  *'federation_extension'* ]] ; then
        new_v3_pipeline=`echo $v3_pipeline | sed -e 's/service_v3/federation_extension service_v3/g'`
        openstack-config --set /etc/keystone/keystone-paste.ini pipeline:api_v3 pipeline "$new_v3_pipeline"
    fi

    keystone-manage db_sync --extension federation
fi

if [ -n "$USE_WEBSSO" ] ; then
    openstack-config --set /etc/keystone/keystone.conf federation remote_id_attribute MELLON_IDP
    openstack-config --set /etc/keystone/keystone.conf federation trusted_dashboard http://${VM_FQDN}/auth/websso/

    # Configure Horizon for WebSSO
    sed -i "s/^OPENSTACK_KEYSTONE_URL = .*/OPENSTACK_KEYSTONE_URL = \"http:\/\/$VM_FQDN:5000\/v3\"/g" \
        /etc/openstack-dashboard/local_settings

    cat >> /etc/openstack-dashboard/local_settings << EOF
OPENSTACK_API_VERSIONS = {
     "identity": 3
}

WEBSSO_ENABLED = True
WEBSSO_CHOICES = (
  ("credentials", _("Keystone Credentials")),
  ("saml2", _("Security Assertion Markup Language"))
)

WEBSSO_INITIAL_CHOICE = "saml2"
EOF
fi

# get DOA patch
doachange=20
git clone https://review.openstack.org/openstack/django_openstack_auth && cd django_openstack_auth && git fetch origin refs/changes/78/136178/$doachange && git checkout FETCH_HEAD && python setup.py install && cd ..
# get Horizon patch
horizonchange=34
git clone https://review.openstack.org/openstack/horizon && cd horizon && git fetch origin refs/changes/42/151842/$horizonchange && git checkout FETCH_HEAD && cd ..

# Restart keystone
systemctl restart httpd.service

# Set up our group, assignment, IdP, mapping, and protocol in Keystone
openstack --os-auth-url http://$VM_FQDN:5000/v3 \
          --os-user-domain-name default \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-project-domain-name default \
          --os-project-name admin \
          --os-identity-api-version 3 \
          group create admins

FED_GROUP_ID=`openstack --os-auth-url http://$VM_FQDN:5000/v3 \
                        --os-user-domain-name default \
                        --os-username admin --os-password $RDO_PASSWORD \
                        --os-project-domain-name default \
                        --os-project-name admin --os-identity-api-version 3 \
                        group show admins -f value -c id`

openstack --os-auth-url http://$VM_FQDN:5000/v3 \
          --os-user-domain-name default \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-project-domain-name default \
          --os-project-name admin \
          --os-identity-api-version 3 \
          role add --group admins --project admin admin

if [ -n "$USE_DELOREAN" ]; then
    openstack --os-auth-url http://$VM_FQDN:5000/v3 \
              --os-user-domain-name default \
              --os-username admin \
              --os-password $RDO_PASSWORD \
              --os-project-domain-name default \
              --os-project-name admin \
              --os-identity-api-version 3 \
              identity provider create --enable ipsilon --remote-id https://$IPA_FQDN/idp/saml2/metadata
else
    openstack --os-auth-url http://$VM_FQDN:5000/v3 \
              --os-user-domain-name default \
              --os-username admin \
              --os-password $RDO_PASSWORD \
              --os-project-domain-name default \
              --os-project-name admin \
              --os-identity-api-version 3 \
              identity provider create --enable ipsilon

    # NGK(TODO) Add a remote_id to our newly created identity provider. OSC doesn't support this
    # currently, but patches are proposed to allow us to specify the remote_id during creation of
    # the identity provider.
    if [ -n "$USE_WEBSSO" ] ; then
        ADMIN_TOKEN=`openstack-config --get /etc/keystone/keystone.conf DEFAULT admin_token`
        curl -si -X PATCH -d @- -H "X-Auth-Token:$ADMIN_TOKEN" -H "Content-type: application/json" \
            http://$VM_FQDN:5000/v3/OS-FEDERATION/identity_providers/ipsilon << EOF
{
    "identity_provider": {
        "remote_id": "https://$IPA_FQDN/idp/saml2/metadata"
    }
}
EOF
    fi
fi

cat > /tmp/ipsilon_mapping.json << EOF
[
    {
        "local": [
            {
                "user": {
                    "name": "{0}"
                },
                "group": {
                    "id": "$FED_GROUP_ID"
                }
            }
        ],
        "remote": [
            {
                "type": "MELLON_NAME_ID"
            }
        ]
    }
]
EOF

openstack --os-auth-url http://$VM_FQDN:5000/v3 \
          --os-user-domain-name default \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-project-domain-name default \
          --os-project-name admin \
          --os-identity-api-version 3 \
          mapping create --rules /tmp/ipsilon_mapping.json ipsilon_mapping

openstack --os-auth-url http://$VM_FQDN:5000/v3 \
          --os-user-domain-name default \
          --os-username admin \
          --os-password $RDO_PASSWORD \
          --os-project-domain-name default \
          --os-project-name admin \
          --os-identity-api-version 3 \
          federation protocol create --identity-provider ipsilon \
          --mapping ipsilon_mapping saml2

# Copy our keystonerc files to our normal user's home directory.
cp /root/keystonerc_* /home/$VM_USER_ID

# Create a v3 keystonerc file.
cat > /home/$VM_USER_ID/keystonerc_v3_admin <<EOF
export OS_USERNAME=admin
export OS_PASSWORD=$RDO_PASSWORD
export OS_PROJECT_NAME=admin
export OS_AUTH_URL=http://$VM_FQDN:5000/v3/
export OS_IDENTITY_API_VERSION=3
export PS1='[\u@\h \W(keystone_v3_admin)]\$ '
EOF

chown $VM_USER_ID:$VM_USER_ID /home/$VM_USER_ID/keystonerc_*

############### test federated auth to http://$VM_FQDN:5000/v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth
# this will do the federated auth and get an unscoped keystone token
test_federated_auth() {
    login_name=fedtest
    login_password=Secret12
    osfurl=http://$VM_FQDN:5000/v3/OS-FEDERATION/identity_providers/ipsilon/protocols/saml2/auth
    HOME=${HOME:-/root}
    log=$HOME/curltest.log
    hdrs=$HOME/hdrs.txt
    cookies=$HOME/.cookies
    rm -f $cookies
    #trace="--trace -"
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt $osfurl > $log 2>&1
    url2=`awk '/^Location:/ {print $2}' $hdrs`
    echo $url2
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt $url2 >> $log 2>&1
    url3=`awk '/^Location:/ {print $2}' $hdrs`
    echo $url3
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt $url3 >> $log 2>&1
    url4=`awk '/^Location:/ {print $2}' $hdrs`
    echo $url4
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt $url4 >> $log 2>&1
    url5=`awk '/^Location:/ {print $2}' $hdrs`
    echo $url5
    curl -s -o $HOME/form.html $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt $url5 >> $log 2>&1
    postpath=`xmllint --html --xpath 'string(//@action)' $HOME/form.html`
    posturl=`echo "$url5" | sed -e "s,/idp/login/gssapi/negotiate,$postpath,"`
    echo $posturl
    ip_trans_id=`xmllint --html --xpath 'string(//input[@name="ipsilon_transaction_id"]/@value)' $HOME/form.html`
    postdata="login_name=${login_name}&login_password=${login_password}&ipsilon_transaction_id=${ip_trans_id}"
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt -d "$postdata" $posturl >> $log 2>&1
    url6=`awk '/^Location:/ {print $2}' $hdrs`
    echo $url6
    curl -s -o $HOME/form.html $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt $url6 >> $log 2>&1
    url7=`xmllint --html --xpath 'string(//@action)' $HOME/form.html`
    {
        echo -n "SAMLResponse="
        xmllint --html --xpath 'string(//input[@name="SAMLResponse"]/@value)' $HOME/form.html | \
            hexdump -v -e '/1 "%02x"' | sed 's/\(..\)/%\1/g' ;
        echo -n "&RelayState="
        xmllint --html --xpath 'string(//input[@name="RelayState"]/@value)' $HOME/form.html | \
            hexdump -v -e '/1 "%02x"' | sed 's/\(..\)/%\1/g' ;
    } > $HOME/form.dat
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt -d@$HOME/form.dat $url7 >> $log 2>&1
    url7=`awk '/^Location:/ {print $2}' $hdrs`
    echo $url7
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt $url7 >> $log 2>&1
    token=`awk '/^X-Subject-Token:/ {print $2}' $hdrs`
    echo token=$token
}

test_websso_auth() {
    login_name=fedtest
    login_password=Secret12
    osfurl="http://$VM_FQDN:5000/v3/auth/OS-FEDERATION/websso/saml2?origin=http%3A//$VM_FQDN"
    HOME=${HOME:-/root}
    log=$HOME/webssotest.log
    hdrs=$HOME/hdrs.txt
    cookies=$HOME/.cookies
    rm -f $cookies
    #trace="--trace -"
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt "$osfurl" > $log 2>&1
    url2=`awk '/^Location:/ {print $2}' $hdrs`
    echo $url2
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt "$url2" >> $log 2>&1
    url3=`awk '/^Location:/ {print $2}' $hdrs`
    echo "$url3"
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt "$url3" >> $log 2>&1
    url4=`awk '/^Location:/ {print $2}' $hdrs`
    echo "$url4"
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt "$url4" >> $log 2>&1
    url5=`awk '/^Location:/ {print $2}' $hdrs`
    echo "$url5"
    curl -s -o form.html $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt "$url5" >> $log 2>&1
    postpath=`xmllint --html --xpath 'string(//@action)' form.html`
    posturl=`echo "$url5" | sed -e "s,/idp/login/gssapi/negotiate,$postpath,"`
    echo $posturl
    ip_trans_id=`xmllint --html --xpath 'string(//input[@name="ipsilon_transaction_id"]/@value)' form.html`
    postdata="login_name=${login_name}&login_password=${login_password}&ipsilon_transaction_id=${ip_trans_id}"
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt -d "$postdata" $posturl >> $log 2>&1
    url6=`awk '/^Location:/ {print $2}' $hdrs`
    echo $url6
    curl -s -o form.html $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt "$url6" >> $log 2>&1
    url7=`xmllint --html --xpath 'string(//@action)' form.html`
    {
        echo -n "SAMLResponse="
        xmllint --html --xpath 'string(//input[@name="SAMLResponse"]/@value)' form.html | \
            hexdump -v -e '/1 "%02x"' | sed 's/\(..\)/%\1/g' ;
        echo -n "&RelayState="
        xmllint --html --xpath 'string(//input[@name="RelayState"]/@value)' form.html | \
            hexdump -v -e '/1 "%02x"' | sed 's/\(..\)/%\1/g' ;
    } > form.dat
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt -d@form.dat "$url7" >> $log 2>&1
    url8=`awk '/^Location:/ {print $2}' $hdrs`
    echo $url8
    curl -s -o form.html $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt "$url8" >> $log 2>&1
    url9=`xmllint --html --xpath 'string(//@action)' form.html`
    token=`xmllint --html --xpath 'string(//input[@name="token"]/@value)' form.html`
    postdata="token=$token"
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt -d "$postdata" "$url9" >> $log 2>&1
    # token=`awk '/^X-Subject-Token:/ {print $2}' $hdrs`
    # echo token=$token
    url10=`awk '/^Location:/ {print $2}' $hdrs`
    echo "$url10"
    curl -s $trace -w '\n' -D $hdrs -b $cookies -c $cookies --cacert /etc/ipa/ca.crt "$url10" >> $log 2>&1
}

test_federated_auth

if [ -n "$USE_WEBSSO" ] ; then
    test_websso_auth
fi
