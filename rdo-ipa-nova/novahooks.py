import os
import time
import pprint
import requests
import uuid
import kerberos
import base64
import six

from oslo_config import cfg
from oslo_config import types
from oslo_log import log as logging
from oslo_serialization import jsonutils as json

from nova.i18n import _
from nova.i18n import _LE
from nova.i18n import _LI
from nova.i18n import _LW

NOVACONF = cfg.CONF
CONF = cfg.ConfigOpts()

CONF.register_opts([
    cfg.StrOpt('url', default=None,
               help='IPA JSON RPC URL (e.g. https://ipa.host.domain/ipa/json)'),
    cfg.StrOpt('keytab', default='/etc/krb5.keytab',
               help='Kerberos client keytab file'),
    cfg.StrOpt('service_name', default=None,
               help='HTTP IPA Kerberos service name (e.g. HTTP@ipa.host.domain)'),
    cfg.StrOpt('cacert', default='/etc/ipa/ca.crt',
               help='CA certificate for use with https to IPA'),
    cfg.StrOpt('domain', default='test',
               help='Domain for new hosts'),
    cfg.IntOpt('connect_retries', default=1,
               help='How many times to attempt to retry '
               'the connection to IPA before giving up'),
    cfg.StrOpt('json_rpc_version', default='2.65',
               help='IPA RPC JSON version'),
    cfg.MultiOpt('inject_files', item_type=types.String(), default=[],
                 help='Files to inject into the new VM.  Specify as /path/to/file/on/host[ /path/to/file/in/vm/if/different]')
])

CONF(['--config-file', '/etc/nova/ipaclient.conf'])

LOG = logging.getLogger(__name__)

class IPABaseError(Exception):
    error_code = 500
    error_type = 'unknown_ipa_error'
    error_message = None
    errors = None

    def __init__(self, *args, **kwargs):
        self.errors = kwargs.pop('errors', None)
        self.object = kwargs.pop('object', None)

        super(IPABaseError, self).__init__(*args, **kwargs)

        if len(args) > 0 and isinstance(args[0], six.string_types):
            self.error_message = args[0]


class IPAAuthError(IPABaseError):
    error_type = 'authentication_error'


IPA_INVALID_DATA = 3009
IPA_NOT_FOUND = 4001
IPA_DUPLICATE = 4002
IPA_NO_DNS_RECORD = 4019
IPA_NO_CHANGES = 4202


class IPAUnknownError(IPABaseError):
    pass


class IPACommunicationFailure(IPABaseError):
    error_type = 'communication_failure'
    pass


class IPAInvalidData(IPABaseError):
    error_type = 'invalid_data'
    pass

class IPADuplicateEntry(IPABaseError):
    error_type = 'duplicate_entry'
    pass


ipaerror2exception = {
    IPA_INVALID_DATA: {
        'host': IPAInvalidData,
        'dnsrecord': IPAInvalidData
    },
    IPA_NO_CHANGES: {
        'host': None,
        'dnsrecord': None
    },
    IPA_NO_DNS_RECORD: {
        'host': None, # ignore - means already added
    },
    IPA_DUPLICATE: {
        'host': IPADuplicateEntry,
        'dnsrecord': IPADuplicateEntry
    }
}

def getvmdomainname():
    rv = NOVACONF.dhcp_domain or CONF.domain
    LOG.debug("getvmdomainname rv = " + rv)
    return rv


class IPAAuth(requests.auth.AuthBase):
    def __init__(self, keytab, service):
        # store the kerberos credentials in memory rather than on disk
        os.environ['KRB5CCNAME'] = "MEMORY:" + str(uuid.uuid4())
        self.token = None
        self.keytab = keytab
        self.service = service
        if self.keytab:
            os.environ['KRB5_CLIENT_KTNAME'] = self.keytab
        else:
            LOG.warn(_LW('No IPA client kerberos keytab file given'))

    def __call__(self, request):
        if not self.token:
            self.refresh_auth()
        request.headers['Authorization'] = 'negotiate ' + self.token
        return request

    def refresh_auth(self):
        flags = kerberos.GSS_C_MUTUAL_FLAG | kerberos.GSS_C_SEQUENCE_FLAG
        try:
            (unused, vc) = kerberos.authGSSClientInit(self.service, flags)
        except kerberos.GSSError as e:
            LOG.error(_LE("caught kerberos exception %r") % e)
            raise IPAAuthError(str(e))
        try:
            kerberos.authGSSClientStep(vc, "")
        except kerberos.GSSError as e:
            LOG.error(_LE("caught kerberos exception %r") % e)
            raise IPAAuthError(str(e))
        self.token = kerberos.authGSSClientResponse(vc)


class IPANovaHookBase(object):

    session = None
    inject_files = []

    @classmethod
    def start(cls):
        if not cls.session:
            # set up session to share among all instances
            cls.session = requests.Session()
            cls.session.auth = IPAAuth(CONF.keytab, CONF.service_name)
            xtra_hdrs = {'Content-Type': 'application/json',
                         'Referer': CONF.url}
            cls.session.headers.update(xtra_hdrs)
            cls.session.verify = False
            # verify is not working - ssl.py self.sock.getpeercert() fails
#            cls.session.verify = CONF.cacert
        if not cls.inject_files:
            for fn in CONF.inject_files:
                hostvm = fn.split(' ')
                hostfile = hostvm[0]
                if len(hostvm) > 1:
                    vmfile = hostvm[1]
                else:
                    vmfile = hostfile
                with file(hostfile, 'r') as f:
                    cls.inject_files.append([vmfile, base64.b64encode(f.read())])

    def __init__(self):
        IPANovaHookBase.start()
        self.session = IPANovaHookBase.session
        self.ntries = CONF.connect_retries
        self.inject_files = IPANovaHookBase.inject_files

    def _ipa_error_to_exception(self, resp, ipareq):
        exc = None
        if resp['error'] is None:
            return exc
        errcode = resp['error']['code']
        method = ipareq['method']
        methtype = method.split('_')[0]
        exclass = ipaerror2exception.get(errcode, {}).get(methtype,
                                                          IPAUnknownError)
        if exclass:
            LOG.debug("Error: ipa command [%s] returned error [%s]" %
                      (pprint.pformat(ipareq), pprint.pformat(resp)))
        elif errcode:  # not mapped
            LOG.debug("Ignoring IPA error code %d: %s" %
                      (errcode, pprint.pformat(resp)))
        return exclass

    def _call_and_handle_error(self, ipareq):
        if 'version' not in ipareq['params'][1]:
            ipareq['params'][1]['version'] = CONF.json_rpc_version
        need_reauth = False
        while True:
            status_code = 200
            try:
                if need_reauth:
                    self.session.auth.refresh_auth()
#                import rpdb; rpdb.set_trace()
                rawresp = self.session.post(CONF.url,
                                            data=json.dumps(ipareq))
                status_code = rawresp.status_code
            except IPAAuthError:
                status_code = 401
            if status_code == 401:
                if self.ntries == 0:
                    # persistent inability to auth
                    LOG.error(_LE("Error: could not authenticate to IPA - "
                              "please check for correct keytab file"))
                    # reset for next time
                    self.ntries = CONF.connect_retries
                    raise IPACommunicationFailure()
                else:
                    LOG.debug("Refresh authentication")
                    need_reauth = True
                    self.ntries -= 1
                    time.sleep(1)
            else:
                # successful - reset
                self.ntries = CONF.connect_retries
                break
        try:
            resp = json.loads(rawresp.text)
        except ValueError:
            # response was not json - some sort of error response
            LOG.debug("Error: unknown error from IPA [%s]" % rawresp.text)
            raise IPAUnknownError("unable to process response from IPA")
        # raise the appropriate exception, if error
        exclass = self._ipa_error_to_exception(resp, ipareq)
        if exclass:
            # could add additional info/message to exception here
            raise exclass()
        return resp


class IPABuildInstanceHook(IPANovaHookBase):

    def pre(self, *args, **kwargs):
        LOG.debug('In IPABuildInstanceHook.pre: args [%s] kwargs [%s]',
                  pprint.pformat(args), pprint.pformat(kwargs))
        # args[8] is the NetworkRequestList of NetworkRequest objects
        for nr in args[8].objects:
            LOG.debug("nr = %s %s" % (pprint.pformat(nr.network_id), pprint.pformat(nr.address)))
        # args[7] is the injected_files parameter array
        # the value is ('filename', 'base64 encoded contents')
        args[7].extend(self.inject_files)
        # args[3] is the Instance object
        inst = args[2]
        ipaotp = str(uuid.uuid4())
        inst.metadata['ipaotp'] = ipaotp
        # call ipa host add to add the new host
        ipareq = {'method': 'host_add', 'id': 0}
        hostname = '%s.%s' % (inst.hostname, getvmdomainname())
        params = [hostname]
        args = {
            'description': 'IPA host for %s' % inst.display_description,
            'l': 'Mountain View, CA',
            'nshostlocation': 'lab 3, 2nd floor',
            'nshardwareplatform': 'VM',
            'nsosversion': 'RHEL 7.2',
            'userpassword': ipaotp,
            'force': True # we don't have an ip addr yet - use force to add anyway
        }
        # # userpassword, random, usercertificate, macaddress
        # # ipasshpubkey, userclass, ipakrbrequirespreauth,
        # # ipakrbokasdelegate, force, no_reverse, ip_address
        # # no_members
        ipareq['params'] = [params, args]
        self._call_and_handle_error(ipareq)

    def post(self, *args, **kwargs):
        LOG.debug('In IPABuildInstanceHook.post: args [%s] kwargs [%s]',
                  pprint.pformat(args), pprint.pformat(kwargs))
        # in post, there is an additional args[0] not in pre which is the
        # state of the instance - so shift everything else down one
        # args[9] is the NetworkRequestList of NetworkRequest objects
        for nr in args[9].objects:
            LOG.debug("nr = %s %s" % (pprint.pformat(nr.network_id), pprint.pformat(nr.address)))

class IPADeleteInstanceHook(IPANovaHookBase):

    def pre(self, *args, **kwargs):
        LOG.debug('In IPADeleteInstanceHook.pre: args [%s] kwargs [%s]',
                  pprint.pformat(args), pprint.pformat(kwargs))

    def post(self, *args, **kwargs):
        LOG.debug('In IPADeleteInstanceHook.post: args [%s] kwargs [%s]',
                  pprint.pformat(args), pprint.pformat(kwargs))

class IPANetworkInfoHook(IPANovaHookBase):

    def pre(self, *args, **kwargs):
        LOG.debug('In IPANetworkInfoHook.pre: args [%s] kwargs [%s]',
                  pprint.pformat(args), pprint.pformat(kwargs))

    def post(self, *args, **kwargs):
        LOG.debug('In IPANetworkInfoHook.post: args [%s] kwargs [%s]',
                  pprint.pformat(args), pprint.pformat(kwargs))
        if 'nw_info' not in kwargs:
            return
        inst = args[3]
        for fip in kwargs['nw_info'].floating_ips():
            LOG.debug("IPANetworkInfoHook.post fip is [%s] [%s]",
                      fip, pprint.pformat(fip.__dict__))
            ipareq = {'method': 'dnsrecord_add', 'id': 0}
            params = [{"__dns_name__": getvmdomainname() + "."},
                      {"__dns_name__": inst.hostname}]
            args = {'a_part_ip_address': fip['address']}
            ipareq['params'] = [params, args]
            self._call_and_handle_error(ipareq)
