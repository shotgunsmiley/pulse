#!/usr/bin/env python3
"""Devnet PULSE test against a stand-in Solana RPC that decodes every transaction with solders
(Solana's Rust library), checks its signatures, and applies System / Token-2022 / ATA rules.
Proves: the server creates the mint once, mints ONLY node rewards to linked wallets, never twice,
waits for a wallet before minting, and reuses the same mint after a restart."""
import json, os, sys, time, socket, tempfile, threading, subprocess, urllib.request, traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64, hashlib
from solders.transaction import Transaction
from solders.keypair import Keypair
from solders.pubkey import Pubkey

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN22 = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb'
ATA = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL'
SYSTEM = '11111111111111111111111111111111'

class Chain:
    def __init__(self):
        self.accounts = {}        # addr -> {'owner', 'lamports', 'mint'?, 'auth'?, 'supply'?, 'token_owner'?, 'amount'?}
        self.sigs = {}
        self.lock = threading.Lock()
        self.blockhash = str(__import__('solders.hash', fromlist=['Hash']).Hash.new_unique())
        self.minted_txs = 0

    def apply(self, raw):
        tx = Transaction.from_bytes(raw)
        tx.verify()                                  # every signature must check out
        m = tx.message
        keys = [str(k) for k in m.account_keys]
        h = m.header
        nsig = h.num_required_signatures
        writable = lambda i: (i < nsig - h.num_readonly_signed_accounts) or (nsig <= i < len(keys) - h.num_readonly_unsigned_accounts)
        signer = lambda i: i < nsig
        with self.lock:
            snap = json.loads(json.dumps(self.accounts))
            try:
                for ix in m.instructions:
                    prog = keys[ix.program_id_index]
                    acc = list(ix.accounts)
                    d = bytes(ix.data)
                    if prog == SYSTEM:
                        assert int.from_bytes(d[:4], 'little') == 0
                        lam = int.from_bytes(d[4:12], 'little'); owner = str(Pubkey(d[20:52]))
                        payer, new = keys[acc[0]], keys[acc[1]]
                        assert signer(acc[0]) and signer(acc[1]) and writable(acc[0]) and writable(acc[1]), 'create needs signers'
                        assert new not in self.accounts, 'account exists'
                        assert self.accounts.get(payer, {}).get('lamports', 0) >= lam, 'payer has no SOL'
                        self.accounts[payer]['lamports'] -= lam
                        self.accounts[new] = {'owner': owner, 'lamports': lam, 'raw': True}
                    elif prog == TOKEN22 and d[0] == 20:
                        mint = keys[acc[0]]
                        assert self.accounts[mint]['owner'] == TOKEN22 and self.accounts[mint].get('raw'), 'mint not created'
                        self.accounts[mint].update(raw=False, mint=True, decimals=d[1], auth=str(Pubkey(d[2:34])), supply=0, freeze=d[34])
                    elif prog == ATA and d == bytes([1]):
                        payer, ata, owner, mint = keys[acc[0]], keys[acc[1]], keys[acc[2]], keys[acc[3]]
                        want = str(Pubkey.find_program_address([bytes(Pubkey.from_string(owner)), bytes(Pubkey.from_string(TOKEN22)), bytes(Pubkey.from_string(mint))], Pubkey.from_string(ATA))[0])
                        assert ata == want, 'wrong associated token address'
                        assert keys[acc[5]] == TOKEN22 and keys[acc[4]] == SYSTEM
                        if ata not in self.accounts:
                            self.accounts[payer]['lamports'] -= 2074080
                            self.accounts[ata] = {'owner': TOKEN22, 'lamports': 2074080, 'token_owner': owner, 'mint': mint, 'amount': 0}
                    elif prog == TOKEN22 and d[0] == 14:
                        mint, dest, auth = keys[acc[0]], keys[acc[1]], keys[acc[2]]
                        amt = int.from_bytes(d[1:9], 'little')
                        mi = self.accounts[mint]
                        assert signer(acc[2]) and auth == mi['auth'], 'wrong mint authority'
                        assert writable(acc[0]) and writable(acc[1])
                        assert d[9] == mi['decimals'], 'decimals mismatch'
                        assert self.accounts[dest]['mint'] == mint
                        mi['supply'] += amt
                        self.accounts[dest]['amount'] += amt
                        self.minted_txs += 1
                    else:
                        raise AssertionError('unexpected instruction %s %s' % (prog, d[:1].hex()))
                fee = 5000 * nsig
                self.accounts[keys[0]]['lamports'] -= fee
            except Exception:
                self.accounts = snap
                raise
        return str(tx.signatures[0])

CH = Chain()

class RPC(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        m, p = req['method'], req.get('params', [])
        res, err = None, None
        try:
            if m == 'getLatestBlockhash':
                res = {'value': {'blockhash': CH.blockhash, 'lastValidBlockHeight': 100}}
            elif m == 'getAccountInfo':
                a = CH.accounts.get(p[0])
                res = {'value': None if a is None else {'owner': a['owner'], 'lamports': a['lamports'], 'data': ['', 'base64']}}
            elif m == 'getMinimumBalanceForRentExemption':
                res = 1461600
            elif m == 'getBalance':
                res = {'value': CH.accounts.get(p[0], {}).get('lamports', 0)}
            elif m == 'sendTransaction':
                sig = CH.apply(base64.b64decode(p[0]))
                CH.sigs[sig] = 'confirmed'
                res = sig
            elif m == 'getSignatureStatuses':
                res = {'value': [{'confirmationStatus': CH.sigs[s], 'err': None} if s in CH.sigs else None for s in p[0]]}
        except Exception as e:
            err = {'code': -32002, 'message': 'Transaction simulation failed: %s' % e}
        out = json.dumps({'jsonrpc': '2.0', 'id': req['id'], **({'error': err} if err else {'result': res})}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)

def port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

RPORT, SPORT = port(), port()
threading.Thread(target=ThreadingHTTPServer(('127.0.0.1', RPORT), RPC).serve_forever, daemon=True).start()
AUTH = Keypair()
CH.accounts[str(AUTH.pubkey())] = {'owner': SYSTEM, 'lamports': 2 * 10 ** 9}     # "faucet" SOL
DATA = tempfile.mktemp(suffix='.json')
ENV = dict(os.environ, PORT=str(SPORT), PULSE_DATA_FILE=DATA, PULSE_AUTH_LIMIT='1000', PULSE_SOL_SECRET=str(AUTH),
           PULSE_SOL_RPC='http://127.0.0.1:%d' % RPORT, PULSE_SOL_EVERY='0.5', PULSE_SETTLE_EVERY='0.5', PULSE_EPOCH_SECONDS='3',
           PULSE_UNITS_PER_PLS='1', PULSE_HB_MIN_GAP='0', PULSE_EPOCH_CAP_PLS='10000000')
ENV.pop('DATABASE_URL', None)
BASE = 'http://127.0.0.1:%d' % SPORT

def req(method, path, body=None, tok=None):
    h = {'Content-Type': 'application/json'}
    if tok:
        h['Authorization'] = 'Bearer ' + tok
    r = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body is not None else None, headers=h, method=method)
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
    raise RuntimeError('no server')

import math, secrets
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


RESULTS = []
def check(name, fn):
    try:
        d = fn(); RESULTS.append(True); print('PASS:', name, '-', d or '')
    except Exception as e:
        traceback.print_exc(); RESULTS.append(False); print('FAIL:', name, '-', repr(e))

def wait_for(fn, t=20):
    t0 = time.time()
    while time.time() - t0 < t:
        v = fn()
        if v:
            return v
        time.sleep(0.25)
    return fn()

proc = start()
U = req('POST', '/auth/register', {'username': 'Solana1', 'password': 'secret123'})
TOK, UID = U['token'], U['profile']['uid']
WALLET = str(Keypair().pubkey())
PH = Phone()
ST = {}

def earn(units):
    """The real node flow: register, handshake, then strike + signed heartbeat per unit."""
    if 'nid' not in ST:
        ST['nid'] = req('POST', '/node/register', {'pub': PH.pem()}, TOK)['node_id']
        c = req('POST', '/node/challenge', {'node_id': ST['nid']}, TOK)
        ST['nt'] = req('POST', '/node/handshake', {'node_id': ST['nid'], 'nonce': c['nonce'], 'sig': PH.sign(c['message'])}, TOK)['node_token']
    got = 0
    for _ in range(units):
        r = req('POST', '/mine/start', {'tier': 1}, TOK)
        time.sleep(0.5)
        req('POST', '/mine/strike', {'id': r['id'], 'tap_ms': 450}, TOK)
        PH.seq += 1
        ts = int(time.time())
        msg = 'pulse-heartbeat:%s:%d:%d:1' % (ST['nid'], PH.seq, ts)
        h = req('POST', '/node/heartbeat', {'node_token': ST['nt'], 'seq': PH.seq, 'ts': ts, 'mining': True, 'sig': PH.sign(msg)}, TOK)
        got += 1 if h.get('counted') else 0
    return got

def t_mint_created():
    s = req('GET', '/solana/status')
    assert s['enabled'] and s['cluster'] == 'devnet', s
    ST['mint'] = s['mint']
    return 'devnet mode on; mint address %s... decided by the server key' % s['mint'][:10]

def t_wait_for_wallet():
    n = earn(3)
    assert n == 3
    time.sleep(5)                       # epoch (3 s) ends, settles into the game ledger
    me = req('GET', '/solana/mine', None, TOK)
    assert me['pending_pulse'] == 3 and me['confirmed_pulse'] == 0 and me['sol_wallet'] is None, me
    assert CH.minted_txs == 0
    assert CH.accounts.get(ST['mint'], {}).get('mint'), 'mint not created on first need'
    return '3 PLS of node rewards waiting; nothing minted until a wallet is linked; mint created on chain'

def t_link_and_mint():
    bad = req('POST', '/solana/wallet', {'address': 'not-an-address'}, TOK)
    assert not bad['ok']
    r = req('POST', '/solana/wallet', {'address': WALLET}, TOK)
    assert r['ok']
    me = wait_for(lambda: (lambda m: m if m['confirmed_pulse'] == 3 else None)(req('GET', '/solana/mine', None, TOK)), 15)
    assert me and me['confirmed_pulse'] == 3, me
    ata = str(Pubkey.find_program_address([bytes(Pubkey.from_string(WALLET)), bytes(Pubkey.from_string(TOKEN22)), bytes(Pubkey.from_string(ST['mint']))], Pubkey.from_string(ATA))[0])
    assert CH.accounts[ata]['amount'] == 3 * 10 ** 9 and CH.accounts[ST['mint']]['supply'] == 3 * 10 ** 9
    return 'wallet linked -> 3 PULSE minted on chain to its token account (supply 3)'

def t_only_nodes():
    before = CH.accounts[ST['mint']]['supply']
    r = req('POST', '/mine/start', {'tier': 1}, TOK)       # mining alone, quests, etc. never touch the chain
    time.sleep(3)
    assert CH.accounts[ST['mint']]['supply'] == before
    n = earn(2)
    me = wait_for(lambda: (lambda m: m if m['confirmed_pulse'] == 5 else None)(req('GET', '/solana/mine', None, TOK)), 20)
    assert me and CH.accounts[ST['mint']]['supply'] == 5 * 10 ** 9, (me, CH.accounts[ST['mint']])
    m = CH.accounts[ST['mint']]
    assert m['auth'] == str(AUTH.pubkey()) and m['freeze'] == 0 and m['decimals'] == 9
    return 'supply only moves with node rewards: now 5 PULSE; no freeze authority; 9 decimals'

def t_restart_same_mint():
    global proc
    txs = CH.minted_txs
    proc.terminate(); proc.wait(timeout=10)
    os.remove(DATA)                                   # like a Render free-plan wipe
    proc = start()
    s = req('GET', '/solana/status')
    assert s['mint'] == ST['mint']
    time.sleep(3)
    assert CH.minted_txs == txs, 'minted again after restart'
    return 'after a full data wipe the server finds the same mint and mints nothing twice'

try:
    check('devnet mode + mint address', t_mint_created)
    check('rewards wait for a wallet', t_wait_for_wallet)
    check('link wallet -> PULSE minted', t_link_and_mint)
    check('only node rewards mint PULSE', t_only_nodes)
    check('restart / wipe reuses the same mint', t_restart_same_mint)
finally:
    proc.terminate()
ok = sum(RESULTS)
print('\nTOTAL %d PASS / %d FAIL' % (ok, len(RESULTS) - ok))
sys.exit(0 if ok == len(RESULTS) else 1)
