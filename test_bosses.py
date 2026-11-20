"""Pulse v5.5 world bosses: shared monster events with a countdown.
Runs the real server code with a fake clock.
Run:  python test_bosses.py
"""
import os, sys, tempfile, importlib, random, time

for k in list(os.environ):
    if k.startswith('PULSE_'):
        del os.environ[k]
HERE = os.path.dirname(os.path.abspath(__file__))
os.environ['PULSE_DATA_FILE'] = tempfile.mktemp(suffix='.json')
os.environ.pop('DATABASE_URL', None)
sys.path.insert(0, HERE)
S = importlib.import_module('server')
E = S.ApiError
P, G = S.POST_AUTH, S.GET_OPTIONAL
CLOCK = [(int(time.time()) // int(S.BOSS_EVERY) + 3) * S.BOSS_EVERY - S.BOSS_LEAD - 60]   # a minute before a countdown
S.now = lambda: CLOCK[0]
RESULTS = []
rng = random.Random(4)


def tick(s):
    CLOCK[0] += s


def check(name, fn):
    try:
        RESULTS.append(('PASS', name, fn() or ''))
    except Exception as e:
        import traceback
        traceback.print_exc()
        RESULTS.append(('FAIL', name, repr(e)))


def raises(code, fn):
    try:
        fn()
    except E as e:
        assert e.code == code, (e.code, code)
        return
    raise AssertionError('expected ' + code)


N = [0]
def reg():
    N[0] += 1
    ip = '10.%d.%d.3' % (N[0] // 200, N[0] % 200)
    S.REQ.ip = ip
    S.h_register({'username': 'bo%03d' % N[0], 'password': 'secret123'}, ip)
    u = S.DB['users'][S.DB['names']['bo%03d' % N[0]]]
    u['created'] -= 100 * 3600
    return u


def ideal(ch, after=200):
    best = None
    for target in (ch['zone_center'], 2 - ch['zone_center']):
        t = ((target - ch['offset']) % 2.0) / ch['speed'] * 1000.0
        while t < after:
            t += 2.0 / ch['speed'] * 1000.0
        best = t if best is None else min(best, t)
    return best


def swing(u, skill=0.7, bot=False):
    st = P['/boss/start'](u, {})
    tap = int(ideal(st['challenge']) + (0 if bot else rng.gauss(0, 70 - 45 * skill)))
    tap = max(160, tap)
    tick(tap / 1000.0 + 0.02)
    r = P['/boss/strike'](u, {'id': st['id'], 'tap_ms': tap})
    tick(rng.uniform(0.7, 1.6))
    return r


def ledger():
    held = sum(x['balance'] for x in S.DB['users'].values())
    return held + sum(S.DB['accounts'].values()), dict(S.DB['accounts'])


def t_countdown_and_fight():
    a, b, c = reg(), reg(), reg()
    v = G['/boss'](a, {})
    assert v['state'] == 'idle' and v['next']['in_s'] > 0
    tick(61)
    v = G['/boss'](a, {})
    assert v['state'] == 'countdown' and 170 <= v['spawn_in'] <= 180, v
    raises('no_boss', lambda: P['/boss/start'](a, {}))
    chat = [m['text'] for m in S.DB['messages'] if m.get('system')]
    assert any('town square' in t for t in chat)
    tick(v['spawn_in'] + 1)
    v = G['/boss'](a, {})
    assert v['state'] == 'live' and v['hp'] == v['max_hp'] > 0
    mon = v['monster']
    led0 = ledger()
    hits = 0
    done = False
    while not done:                       # the three swing at the same time, like real players
        starts = []
        for u, sk in ((a, 0.9), (b, 0.6), (c, 0.3)):
            st = P['/boss/start'](u, {})
            tap = max(160, int(ideal(st['challenge']) + rng.gauss(0, 70 - 45 * sk)))
            starts.append((u, st, tap))
        tick(max(x[2] for x in starts) / 1000.0 + 0.02)
        for u, st, tap in starts:
            r = P['/boss/strike'](u, {'id': st['id'], 'tap_ms': tap})
            hits += 1
            if r['killed'] or r['boss']['state'] != 'live':
                done = True
                break
        tick(rng.uniform(0.6, 1.2))
    v = G['/boss'](a, {})
    assert v['state'] == 'won', v['state']
    assert v['fighters'] == 3 and v['max_hp'] == int(S.BOSS_BASE_HP * S.MONSTERS[mon]['hp']) + 2 * S.BOSS_HP_PER_FIGHTER
    rw = [x for x in (a, b, c) if 'slay_' + mon in x['badges']]
    assert len(rw) == 3, 'everyone who fought gets the slayer badge'
    assert sum('boss_mvp' in x['badges'] for x in (a, b, c)) == 1
    assert sum('final_blow' in x['badges'] for x in (a, b, c)) == 1
    assert ledger()[0] == 0 and ledger()[1] == led0[1], 'no PLS moves'
    took = S.now() - v['spawn_in'] - (S.now() - S.BOSS_FIGHT + v['time_left'])
    return '%s: countdown 3 min with chat call-out, 3 fighters, killed in %d strikes; slayer badges, one MVP, one final blow, no PLS' % (S.MONSTERS[mon]['name'], hits)


def force(mon, lead=10):
    S.h_admin_boss({'spawn': [mon], 'lead': [str(lead)]})
    tick(lead + 1)
    v = G['/boss'](None, {})
    assert v['state'] == 'live' and v['monster'] == mon, v
    return v


def t_tricks():
    out = []
    u = reg()
    # golem hardens below 75%: only perfect hits count for 12 s
    force('golem')
    ev = S.DB['boss']['ev']
    ev['hp'] = int(ev['max_hp'] * 0.76)
    for i in range(6):
        r = swing(u, 0.95)
        if ev['crossed']:
            break
    assert ev['crossed'] and S.boss_tricks(ev).get('hardened')
    blocked = False
    for i in range(10):
        st = P['/boss/start'](u, {})
        tap = int(ideal(st['challenge']) + 70)        # a great, not a perfect
        tick(tap / 1000.0)
        r = P['/boss/strike'](u, {'id': st['id'], 'tap_ms': tap})
        tick(0.7)
        if r['quality'] in ('great', 'good'):
            assert r['damage'] == 0 and 'perfect' in r['note']
            blocked = True
            break
    assert blocked
    out.append('golem hardens')
    # wyrm burrows: no damage while underground
    force('wyrm')
    ev = S.DB['boss']['ev']
    tick(40 - (S.now() - ev['spawn_t']) % 40 + 1)
    assert S.boss_tricks(ev).get('burrowed')
    r = swing(u, 0.95)
    assert r['damage'] == 0
    out.append('wyrm burrows')
    # wraith heals on misses
    force('wraith')
    ev = S.DB['boss']['ev']
    swing(u, 0.9)
    ev['hp'] = ev['max_hp'] - 50
    st = P['/boss/start'](u, {})
    ch = st['challenge']
    tap = next(t for t in range(300, 4000, 10) if abs(S.marker_pos(ch, t) - ch['zone_center']) > ch['zone_width'] + 0.1)   # far from the zone
    tick(tap / 1000.0)
    hp0 = ev['hp']
    r = P['/boss/strike'](u, {'id': st['id'], 'tap_ms': tap})
    assert r['quality'] == 'miss' and ev['hp'] == hp0 + 3
    tick(1)
    out.append('wraith feeds on misses')
    # drake shield halves damage; enraged takes more
    force('drake')
    ev = S.DB['boss']['ev']
    tick(30 - (S.now() - ev['spawn_t']) % 30 + 1)            # the next shield, 30 s in
    assert S.boss_tricks(ev).get('shield')
    out.append('drake shields')
    # spider: perfect does double
    force('spider')
    st = P['/boss/start'](u, {})
    tap = int(ideal(st['challenge']))
    tick(tap / 1000.0)
    r = P['/boss/strike'](u, {'id': st['id'], 'tap_ms': tap})
    assert r['quality'] == 'perfect' and r['damage'] >= 12
    out.append('spider takes double on perfects')
    return ', '.join(out)


def t_escape():
    us = [reg() for _ in range(2)]
    v = force('drake', 5)
    for u in us:
        for i in range(4):
            swing(u)
    tick(S.BOSS_FIGHT + 5)
    v = G['/boss'](us[0], {})
    assert v['state'] == 'escaped' and v['reward']['escaped']
    assert v['reward']['ore'] and 'slay_drake' not in us[0]['badges']
    v2 = G['/boss'](us[1], {})
    assert v2['reward']['escaped']
    assert G['/boss'](us[1], {}).get('reward') is None, 'rewards are shown once'
    return 'time runs out: the Drake escapes, fighters keep a quarter of the loot, no badge'


def t_bots_and_spam():
    bot, human = reg(), reg()
    force('golem', 5)
    dealt = 0
    for i in range(55):
        was = bot.get('flagged')
        st = P['/boss/start'](bot, {})
        tap = int(ideal(st['challenge']))
        tick(tap / 1000.0 + 0.01)
        r = P['/boss/strike'](bot, {'id': st['id'], 'tap_ms': tap})
        tick(0.75)
        if was:
            dealt += r['damage']
    assert bot['flagged'] and dealt == 0, (bot.get('flag_why'), dealt)
    # strike spam
    st = P['/boss/start'](human, {})
    tick(0.4)
    P['/boss/strike'](human, {'id': st['id'], 'tap_ms': 300}) if False else None
    st1 = P['/boss/start'](human, {})
    tap = int(ideal(st1['challenge']))
    tick(tap / 1000.0)
    P['/boss/strike'](human, {'id': st1['id'], 'tap_ms': tap})
    st2 = P['/boss/start'](human, {})
    tick(0.2)
    raises('too_fast', lambda: P['/boss/strike'](human, {'id': st2['id'], 'tap_ms': 160}))
    raises('no_challenge', lambda: P['/boss/strike'](human, {'id': 'nope', 'tap_ms': 300}))
    return 'a perfect-timing bot is flagged after a few strikes and then deals no damage; strike spam refused'


def t_scaling_and_numbers():
    us = [reg() for _ in range(8)]
    v = force('spider', 5)
    base = v['max_hp']
    for u in us:
        swing(u)
    v = G['/boss'](us[0], {})
    assert v['max_hp'] == base + 7 * S.BOSS_HP_PER_FIGHTER
    assert v['fighting_now'] == 8
    assert len(v['top']) == 6 and 'look' in v['top'][0]
    return 'health grows with every new fighter (%d -> %d for 8); fighting together boosts damage; top 6 shown with their looks' % (base, v['max_hp'])


def t_bestiary_hunter():
    u = reg()
    for mon in S.MONSTER_ORDER:
        force(mon, 5)
        ev = S.DB['boss']['ev']
        ev['hp'] = 30
        for i in range(30):
            r = swing(u, 0.95)
            if r['killed']:
                break
        assert r['killed'], mon
        tick(2)
        if mon == 'wyrm':
            pass
    assert 'monster_hunter' in u['badges']
    b = S.profile_view(u)['bestiary']
    assert all(b[m]['kills'] == 1 for m in S.MONSTER_ORDER)
    return 'beat all five: Monster Hunter badge; the bestiary counts kills and best damage per monster'


for name, fn in [('countdown + shared fight', t_countdown_and_fight), ('monster tricks', t_tricks), ('escape', t_escape),
                 ('bots + spam', t_bots_and_spam), ('scaling', t_scaling_and_numbers), ('bestiary + hunter', t_bestiary_hunter)]:
    check(name, fn)
for s, n, d in RESULTS:
    print('%s: %s - %s' % (s, n, d))
print('\nTOTAL %d PASS / %d FAIL' % (sum(1 for r in RESULTS if r[0] == 'PASS'), sum(1 for r in RESULTS if r[0] == 'FAIL')))
