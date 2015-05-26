#!/usr/bin/python

import argparse
import os
import requests
import sys
from urllib import urlencode


def add_sp(url, user, password, sp_name, sp_metadata):
    s = requests.Session()

    print ('Adding service provider "%s"...' % sp_name)

    # Authenticate to the IdP
    auth_url = '%s/login/form' % url.rstrip('/')
    auth_data = {'login_name': user,
                 'login_password': password}

    r = s.post(auth_url, data=auth_data)
    if r.status_code != 200:
        raise Exception('Unable to authenticate to IdP (%d)' % r.status_code)

    # Add the SP
    sp_url = '%s/rest/providers/saml2/SPS/%s' % (url.rstrip('/'), sp_name)
    sp_headers = {'Content-type': 'application/x-www-form-urlencoded',
                  'Referer': sp_url}
    sp_data = urlencode({'metadata': sp_metadata})

    r = s.post(sp_url, headers=sp_headers, data=sp_data)
    if r.status_code != 201:
        raise Exception('Unable to add Service Provider (%d)' % r.status_code)

    print ('Success')


if __name__ == '__main__':
    # Parse our arguments
    parser = argparse.ArgumentParser()
    parser.add_argument('--cacert', help='Path to CA cert (default: '
                        '/etc/ipa/ca.crt)', default='/etc/ipa/ca.crt')
    parser.add_argument('--url', help='Ipsilon url',
                        required=True)
    parser.add_argument('--user', help='Admin username (default: admin)',
                        default='admin')
    parser.add_argument('--password', help='Admin password',
                        required=True)
    parser.add_argument('--metadata', help='Path to SP metadata file',
                        required=True)
    parser.add_argument('sp_name', help='Service provider name')
    args = parser.parse_args()

    os.environ['REQUESTS_CA_BUNDLE'] = args.cacert

    # Read our metadata
    sp_metadata = ''
    try:
        with open(args.metadata) as f:
            for line in f:
                sp_metadata += line.strip()
    except Exception as e:
        print ('Error accessing metadata file %s (%s)' % (args.metadata, e))
        sys.exit(1)

    try:
        add_sp(args.url, args.user, args.password,
               args.sp_name, sp_metadata)
    except Exception as e:
        print("Error - %s" % e)
        sys.exit(1)

    sys.exit(0)
