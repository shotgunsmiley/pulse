#!/usr/bin/env python3
"""Phone-node tests - runs the real server.py over HTTP with short test timings.
Covers registration, handshake, signed heartbeats, the while-mining policy, replay and forgery
rejection, one-active-phone-per-player, the daily cap, hourly settlement into the ledger
(exactly once), the per-epoch emission cap, node removal, the admin audit, and restart."""
import json, os, sys, time, subprocess, tempfile, socket, traceback, hashlib, hmac, secrets, math, urllib.request, urllib.error, base64

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = []

def check(name, fn):
    try:
        detail = fn()
        RESULTS.append((True, name))
        print('PASS:', name, '-', detail or '')
    except Exception as e:
        traceback.print_exc()
        RESULTS.append((False, name))
        print('FAIL:', name, '-', repr(e))

# --- a phone's key (what Godot's Crypto.generate_rsa + sign produce: RSA-2048, PKCS#1 v1.5, SHA-256)
def _prime(bits):
    while True:
        c = secrets.randbits(bits) | (1 << (bits - 1)) | (1 << (bits - 2)) | 1
        if all(pow(a, c - 1, c) == 1 for a in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37)):
            return c

class Phone:
    PREFIX = bytes.fromhex('3031300d060960864801650304020105000420')

    def __init__(self):
        e = 65537
        while True:
            p, q = _prime(1024), _prime(1024)
            phi = (p - 1) * (q - 1)
            if p != q and math.gcd(e, phi) == 1 and (p * q).bit_length() == 2048:
                break
        self.n, self.e, self.d = p * q, e, pow(e, -1, phi)
        self.seq = 0

    def pem(self):
        def ln(n):
            if n < 128:
                return bytes([n])
            b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
            return bytes([0x80 | len(b)]) + b
        def i(v):
            b = v.to_bytes((v.bit_length() + 8) // 8, 'big')
            return b'\x02' + ln(len(b)) + b
        def seq(b):
            return b'\x30' + ln(len(b)) + b
        rsa = seq(i(self.n) + i(self.e))
        der = seq(seq(bytes.fromhex('06092a864886f70d0101010500')) + b'\x03' + ln(len(rsa) + 1) + b'\x00' + rsa)
        b = base64.b64encode(der).decode()
        return '-----BEGIN PUBLIC KEY-----\n' + '\n'.join(b[k:k + 64] for k in range(0, len(b), 64)) + '\n-----END PUBLIC KEY-----\n'

    def sign(self, msg):
        k = 256
        t = self.PREFIX + hashlib.sha256(msg.encode()).digest()
        em = b'\x00\x01' + b'\xff' * (k - len(t) - 3) + b'\x00' + t
        return base64.b64encode(pow(int.from_bytes(em, 'big'), self.d, self.n).to_bytes(k, 'big')).decode()

def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p

DATA = tempfile.mktemp(suffix='.json')
PORT = free_port()
ADMIN = secrets.token_urlsafe(16)
ENV = dict(os.environ, PORT=str(PORT), PULSE_DATA_FILE=DATA, PULSE_AUTH_LIMIT='1000', PULSE_ADMIN_TOKEN=ADMIN,
           PULSE_HB_MIN_GAP='1', PULSE_EPOCH_SECONDS='6', PULSE_SETTLE_EVERY='1', PULSE_UNITS_PER_PLS='2',
           PULSE_DAILY_UNIT_CAP='8', PULSE_EPOCH_CAP_PLS='1000')
ENV.pop('DATABASE_URL', None)
BASE = 'http://127.0.0.1:%d' % PORT

def req(method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    h = {'Content-Type': 'application/json'}
    if token:
        h['Authorization'] = 'Bearer ' + token
    r = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=10) as x:
            return json.loads(x.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())

def start():
    p = subprocess.Popen([sys.executable, os.path.join(HERE, 'server.py')], env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for _ in range(200):
        try:
            if req('GET', '/health').get('ok'):
                return p
        except Exception:
            time.sleep(0.05)
    raise RuntimeError('server did not start')

proc = start()
U1 = req('POST', '/auth/register', {'username': 'NodeOne', 'password': 'secret123'})
T1, UID1 = U1['token'], U1['profile']['uid']
U2 = req('POST', '/auth/register', {'username': 'NodeTwo', 'password': 'secret123'})
T2, UID2 = U2['token'], U2['profile']['uid']
PH1, PH1B, PH2 = Phone(), Phone(), Phone()
STATE = {}

def strike(tok):
    r = req('POST', '/mine/start', {'tier': 1}, tok)
    time.sleep(0.5)
    s = req('POST', '/mine/strike', {'id': r['id'], 'tap_ms': 450}, tok)
    assert s.get('ok'), s
    time.sleep(0.5)

def handshake(tok, uid, phone, nid):
    c = req('POST', '/node/challenge', {'node_id': nid}, tok)
    assert c['ok'] and c['message'] == 'pulse-handshake:%s:%s:%s' % (nid, uid, c['nonce'])
    h = req('POST', '/node/handshake', {'node_id': nid, 'nonce': c['nonce'], 'sig': phone.sign(c['message'])}, tok)
    assert h['ok'], h
    return h['node_token']

def beat(tok, phone, nid, ntok, mining=True, seq=None, ts=None, sig=None):
    phone.seq = phone.seq + 1 if seq is None else seq
    ts = int(time.time()) if ts is None else ts
    msg = 'pulse-heartbeat:%s:%d:%d:%d' % (nid, phone.seq, ts, 1 if mining else 0)
    return req('POST', '/node/heartbeat', {'node_token': ntok, 'seq': phone.seq, 'ts': ts, 'mining': mining,
                                           'sig': sig or phone.sign(msg)}, tok)

def t_register():
    r = req('POST', '/node/register', {'pub': PH1.pem(), 'label': 'Test phone'}, T1)
    assert r['ok'] and r['new'], r
    STATE['n1'] = r['node_id']
    again = req('POST', '/node/register', {'pub': PH1.pem()}, T1)
    assert again['ok'] and not again['new'] and again['node_id'] == r['node_id']
    stolen = req('POST', '/node/register', {'pub': PH1.pem()}, T2)
    assert not stolen['ok'] and stolen['error'] == 'node_taken'
    bad = req('POST', '/node/register', {'pub': 'not a key'}, T1)
    assert not bad['ok']
    anon = req('POST', '/node/register', {'pub': PH2.pem()})
    assert not anon['ok'] and anon['error'] == 'login_required'
    return 'node id %s... from the public key only; same key can\'t join a second account' % r['node_id'][:10]

def t_handshake():
    n1 = STATE['n1']
    c = req('POST', '/node/challenge', {'node_id': n1}, T1)
    wrong = req('POST', '/node/handshake', {'node_id': n1, 'nonce': c['nonce'], 'sig': PH2.sign(c['message'])}, T1)
    assert not wrong['ok'] and wrong['error'] == 'bad_signature'
    reuse = req('POST', '/node/handshake', {'node_id': n1, 'nonce': c['nonce'], 'sig': PH1.sign(c['message'])}, T1)
    assert not reuse['ok'] and reuse['error'] == 'challenge_expired', reuse     # nonce is single-use
    other = req('POST', '/node/challenge', {'node_id': n1}, T2)
    assert not other['ok']
    STATE['nt1'] = handshake(T1, UID1, PH1, n1)
    return 'wrong key refused, nonce single-use, other players cannot challenge your node'

def t_policy():
    n1, nt = STATE['n1'], STATE['nt1']
    r = beat(T1, PH1, n1, nt, mining=False)
    assert r['ok'] and not r['counted'] and r['reason'] == 'not mining', r
    r = beat(T1, PH1, n1, nt, mining=True)
    assert r['ok'] and not r['counted'] and 'no recent mining' in r['reason'], r      # claims mining, server disagrees
    strike(T1)
    r = beat(T1, PH1, n1, nt, mining=True)
    assert r['ok'] and r['counted'], r
    time.sleep(1.1)
    strike(T1)
    r = beat(T1, PH1, n1, nt, mining=True)
    assert r['counted'] and r['units_today'] == 2, r
    return 'only counts while the server sees real mining strikes'

def t_tamper():
    n1, nt = STATE['n1'], STATE['nt1']
    old = PH1.seq
    r = beat(T1, PH1, n1, nt, seq=old)
    assert not r['ok'] and r['error'] == 'replayed', r
    r = beat(T1, PH1, n1, nt, sig=PH2.sign('pulse-heartbeat:%s:%d:%d:1' % (n1, old + 5, int(time.time()))), seq=old + 5)
    assert not r['ok'] and r['error'] == 'bad_signature', r
    r = beat(T1, PH1, n1, nt, seq=old + 6, ts=int(time.time()) - 3600)
    assert not r['ok'] and r['error'] == 'clock', r
    r = beat(T1, PH1, n1, 'made-up-token')
    assert not r['ok'] and r['error'] == 'node_session_expired'
    r = beat(T2, PH1, n1, nt)
    assert not r['ok']
    return 'replayed, forged, stale-clock, fake-session and wrong-player heartbeats refused'

def t_one_phone():
    r = req('POST', '/node/register', {'pub': PH1B.pem(), 'label': 'Second phone'}, T1)
    assert r['ok']
    STATE['n1b'] = r['node_id']
    ntb = handshake(T1, UID1, PH1B, r['node_id'])
    time.sleep(1.1)
    strike(T1)
    a = beat(T1, PH1, STATE['n1'], STATE['nt1'])
    b = beat(T1, PH1B, STATE['n1b'], ntb)
    assert a['counted'] and not b['counted'] and 'another of your phones' in b['reason'], (a, b)
    STATE['ntb'] = ntb
    return 'two phones on one account: only one earns at a time'

def t_cap():
    n = 0
    for _ in range(12):
        time.sleep(1.05)
        strike(T1)
        r = beat(T1, PH1, STATE['n1'], STATE['nt1'])
        if r['counted']:
            n += 1
    assert r['units_today'] == 8 and not r['counted'] and r['reason'] == 'daily node limit reached', r
    return 'daily cap of 8 test units enforced'

def t_settle():
    time.sleep(8)          # let the 6-second test epochs finish and settle
    s = req('GET', '/node/status', None, T1)
    assert s['ok'] and s['total_earned'] == 4, s          # 8 units / 2 units per PLS
    me = req('GET', '/me', None, T1)['profile']
    led = req('GET', '/ledger', None, T1)
    entries = [e for e in led.get('entries', led.get('ledger', [])) if 'node reward' in json.dumps(e)]
    assert entries, led
    time.sleep(2.5)
    s2 = req('GET', '/node/status', None, T1)
    assert s2['total_earned'] == 4                         # settling again pays nothing twice
    return 'units became %d PLS in the ledger once; balance now %d PLS' % (s['total_earned'], me['balance'])

def t_admin():
    assert req('GET', '/admin/audit').get('error') == 'not_found'
    assert req('GET', '/admin/audit', None, 'wrong').get('error') == 'not_found'
    a = req('GET', '/admin/audit', None, ADMIN)
    assert a['ok'] and a['ledger_balanced'] and a['duplicate_reward_records'] == 0 and a['duplicate_ledger_rewards'] == 0, a
    assert a['node_rewards_issued'] == 4 and a['reward_records_match_ledger'] and a['rejected_signatures_or_replays'] >= 3, a
    return 'hidden without the admin token; ledger balanced, no duplicate rewards, %d rejected attempts logged' % a['rejected_signatures_or_replays']

def t_remove_restart():
    global proc
    r = req('POST', '/node/remove', {'node_id': STATE['n1b']}, T1)
    assert r['ok']
    b = beat(T1, PH1B, STATE['n1b'], STATE['ntb'])
    assert not b['ok']
    time.sleep(1.5)
    proc.terminate()
    proc.wait(timeout=10)
    proc = start()
    s = req('GET', '/node/status', None, T1)
    assert s['total_earned'] == 4 and len(s['nodes']) == 2
    nt = handshake(T1, UID1, PH1, STATE['n1'])
    r = beat(T1, PH1, STATE['n1'], nt)
    assert r['ok']
    r = beat(T1, PH1, STATE['n1'], nt, seq=1)
    assert r['error'] == 'replayed'                         # sequence numbers survive a restart
    a = req('GET', '/admin/audit', None, ADMIN)
    assert a['ledger_balanced'] and a['duplicate_ledger_rewards'] == 0
    return 'removed phone stops at once; after restart rewards, nodes and replay protection are intact'

try:
    check('register a phone as a node', t_register)
    check('signed handshake', t_handshake)
    check('heartbeats count only while mining', t_policy)
    check('tampered heartbeats refused', t_tamper)
    check('one earning phone per player', t_one_phone)
    check('daily cap', t_cap)
    check('hourly settlement into the ledger, exactly once', t_settle)
    check('admin audit', t_admin)
    check('remove node + restart', t_remove_restart)
finally:
    proc.terminate()
ok = sum(1 for r in RESULTS if r[0])
print('\nTOTAL %d PASS / %d FAIL' % (ok, len(RESULTS) - ok))
sys.exit(0 if ok == len(RESULTS) else 1)
