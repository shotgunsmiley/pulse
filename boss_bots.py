"""Pulse v5.5 tour helper: a few other players who come to fight the monster.
Registers N players on a running local server, brings a monster with the admin
route, then swings at whatever monster is live (human-like timing) until time runs out.
Usage:  python boss_bots.py <server> <admin_token> <monster> <lead_s> <minutes> [n_bots]
"""
import json, random, sys, threading, time, urllib.request

BASE, ADMIN, MON = sys.argv[1], sys.argv[2], sys.argv[3]
LEAD, MINUTES = int(sys.argv[4]), float(sys.argv[5])
N = int(sys.argv[6]) if len(sys.argv) > 6 else 4
END = time.time() + MINUTES * 60
NAMES = ['Brakka', 'Tilda', 'Osric', 'Mae', 'Juno', 'Fenwick']


def call(path, body=None, token=None):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Content-Type': 'application/json'})
    if token:
        req.add_header('Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b'{}')


def ideal(ch, after=220):
    best = None
    for target in (ch['zone_center'], 2 - ch['zone_center']):
        t = ((target - ch['offset']) % 2.0) / ch['speed'] * 1000.0
        while t < after:
            t += 2.0 / ch['speed'] * 1000.0
        best = t if best is None else min(best, t)
    return best


def fighter(tok, skill, seed):
    rng = random.Random(seed)
    while time.time() < END:
        v = call('/boss', token=tok)
        if v.get('state') != 'live':
            time.sleep(1.0)
            continue
        st = call('/boss/start', {}, tok)
        if not st.get('ok'):
            time.sleep(0.8)
            continue
        t0 = time.time()
        tap = max(200, int(ideal(st['challenge']) + rng.gauss(0, 75 - 50 * skill)))
        time.sleep(max(0.0, tap / 1000.0 - (time.time() - t0)) + 0.02)
        call('/boss/strike', {'id': st['id'], 'tap_ms': tap}, tok)
        time.sleep(rng.uniform(0.7, 1.4))


toks = []
for i in range(N):
    nm = '%s%d' % (NAMES[i % len(NAMES)], random.randint(10, 99))
    r = call('/auth/register', {'username': nm, 'password': 'secret123'})
    tok = r.get('token')
    if tok:
        look = {'skin': (i * 2 + 1) % 5, 'hair_style': i % 2, 'hair_color': i % 3, 'shirt': i % 2, 'pants': (i + 1) % 2}
        call('/profile/appearance', {'appearance': look}, tok)
        toks.append(tok)
print('bots:', len(toks), flush=True)
if MON != '-':
    req = urllib.request.Request('%s/admin/boss?spawn=%s&lead=%d' % (BASE, MON, LEAD), headers={'Authorization': 'Bearer ' + ADMIN})
    print(urllib.request.urlopen(req).read().decode()[:200], flush=True)
ths = [threading.Thread(target=fighter, args=(t, 0.4 + 0.15 * i, i), daemon=True) for i, t in enumerate(toks)]
for th in ths:
    th.start()
for th in ths:
    th.join()
print('bots done', flush=True)
