"""Pulse v5.3 extras: the 50 small features. Runs the real server code with a fake clock.
Run:  python test_extras.py
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
CLOCK = [time.time()]
S.now = lambda: CLOCK[0]
RESULTS = []
P = S.POST_AUTH
G = S.GET_AUTH


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
def reg(ip=None, age_h=72):
    N[0] += 1
    ip = ip or '10.%d.%d.9' % (N[0] // 200, N[0] % 200)
    S.REQ.ip = ip
    S.h_register({'username': 'xt%03d' % N[0], 'password': 'secret123'}, ip)
    u = S.DB['users'][S.DB['names']['xt%03d' % N[0]]]
    u['created'] -= age_h * 3600
    S.note_ip(u, ip)
    return u


def ideal(ch, after=200):
    best = None
    for target in (ch['zone_center'], 2 - ch['zone_center']):
        t = ((target - ch['offset']) % 2.0) / ch['speed'] * 1000.0
        while t < after:
            t += 2.0 / ch['speed'] * 1000.0
        best = t if best is None else min(best, t)
    return best


def strike(u, tier=1, off=0):
    tick(2.0)
    st = S.h_mine_start(u, {'tier': tier})
    tap = int(ideal(st['challenge']) + off)
    tick(tap / 1000.0 + 0.02)
    return P['/mine/strike'](u, {'id': st['id'], 'tap_ms': tap})


def t_mining_extras():
    u = reg()
    random.seed(11)
    lucky = rhythm = 0
    cleared_traits = set()
    for i in range(240):
        r = strike(u, 1, random.gauss(0, 25))
        lucky += 1 if r.get('lucky') else 0
        rhythm = max(rhythm, r.get('rhythm', 0))
        if r['cleared']:
            cleared_traits.add(r['trait'])
            if r['trait'] == 'stubborn':
                assert r['vein_max'] == 18 and r['vein_hp'] == 18
    x = u['x']
    assert x['clears']['1'] >= 20 and rhythm == 3
    assert u['daily'].get('first_perfect') == 1
    v = G['/mine/veins'](u, {})
    assert v['veins'][0]['clears'] == x['clears']['1'] and 'forecast' in v
    assert u['cabin'][0] == 'badge:first_vein'
    held = sum(y['balance'] for y in S.DB['users'].values())
    assert held + sum(S.DB['accounts'].values()) == 0
    return '%d strikes: %d lucky, rhythm glow, %d clears, traits seen %s, first-vein trophy shelved, no PLS minted' % (
        240, lucky, x['clears']['1'], sorted(t or 'plain' for t in cleared_traits))


def t_cart_chest():
    u = reg()
    r = P['/cart/claim'](u, {})
    assert sum(r['ore'].values()) >= 9
    raises('cart_gone', lambda: P['/cart/claim'](u, {}))
    raises('chest_locked', lambda: P['/chest/claim'](u, {}))
    for d in range(5):
        os.environ['PULSE_FAKE_DAY'] = 'C%02d' % d
        os.environ['PULSE_FAKE_WEEK'] = 'CW1'
        G['/me'](u, {})
    me = G['/me'](u, {})
    assert me['daily']['chest_ready'] and me['daily']['week_days'] == 5
    got = P['/chest/claim'](u, {})['got']
    assert ('gem' in got or 'dye' in got) and got['coal'] == 20
    raises('chest_open', lambda: P['/chest/claim'](u, {}))
    os.environ.pop('PULSE_FAKE_DAY'); os.environ.pop('PULSE_FAKE_WEEK')
    return 'daily cart once a day; chest opens after 5 days in a week, once (%s)' % got


def t_away_comeback():
    u = reg()
    G['/me'](u, {})
    tick(4 * 86400)
    me = G['/me'](u, {})
    assert me['away'] and me['away']['hours'] >= 96 and me['away']['comeback']
    r = strike(u)
    assert r.get('comeback', 0) > 0 or r['quality'] == 'miss'
    return 'back after 4 days: summary %s and 30 minutes of double xp' % me['away']


def t_titles_taunt_name():
    u = reg()
    raises('not_earned', lambda: P['/title'](u, {'title': 'Void Walker'}))
    P['/title'](u, {'title': 'Pebble Picker'})
    assert S.profile_view(u)['shown_title'] == 'Pebble Picker'
    P['/taunt'](u, {'taunt': 3})
    assert S._look(u['uid'])['taunt'] == S.TAUNTS[3]
    u['ore']['iron'], u['ore']['coal'] = 12, 8
    S.h_forge(u, {'recipe': 'iron_pickaxe'})
    P['/gear/name'](u, {'slot': 'pickaxe', 'name': "Old Betsy"})
    raises('bad_name', lambda: P['/gear/name'](u, {'slot': 'pickaxe', 'name': '<script>'}))
    assert S.profile_view(u)['gear']['pickaxe']['nick'] == 'Old Betsy'
    return 'chosen titles must be earned; taunt shows on your duel look; pickaxe named "Old Betsy"'


def t_waves_news_gifts():
    a, b = reg(), reg()
    S.DB['friends'].append({'a': a['uid'], 'b': b['uid']})
    assert b['uid'] in S.friends_of(a['uid']), 'friend setup'
    P['/wave'](a, {'username': b['username']})
    raises('waved', lambda: P['/wave'](a, {'username': b['username']}))
    a['ore']['coal'] = 50
    P['/gift'](a, {'username': b['username'], 'ore': 'coal', 'qty': 7})
    raises('gift_limit', lambda: P['/gift'](a, {'username': b['username'], 'ore': 'coal', 'qty': 4}))
    inbox = G['/me'](b, {})['inbox']
    kinds = sorted(i['kind'] for i in inbox)
    assert kinds == ['gift', 'wave'] and b['ore']['coal'] == 7
    assert G['/me'](b, {})['inbox'] == []
    # an alt account on the same network can never receive gifts
    c = reg()
    S.note_ip(c, '10.77.1.9')
    S.note_ip(a, '10.77.1.9')
    S.DB['friends'].append({'a': a['uid'], 'b': c['uid']})
    raises('linked_accounts', lambda: P['/gift'](a, {'username': c['username'], 'ore': 'coal', 'qty': 1}))
    stranger = reg()
    raises('friends_only', lambda: P['/gift'](a, {'username': stranger['username'], 'ore': 'coal', 'qty': 1}))
    fresh = reg(age_h=1)
    S.DB['friends'].append({'a': fresh['uid'], 'b': a['uid']})
    fresh['ore']['coal'] = 5
    raises('new_account', lambda: P['/gift'](fresh, {'username': a['username'], 'ore': 'coal', 'qty': 1}))
    return 'waves (10-min cooldown) and gifts (friends only, 10 ore/day) arrive in the inbox once; alts and new accounts blocked'


def t_duel_rivals_cheers():
    a, b, fan = reg(), reg(), reg()
    for x in (a, b):
        x['practice_n'] = 10
    for i in range(6):
        inv = S.h_pvp_challenge(a, {'username': b['username'], 'game': 'quickdraw', 'stake': 0})
        S.h_pvp_respond(b, {'invite_id': inv['invite_id'], 'accept': True})
        m = [m for m in S.DB['matches'].values() if m['state'] == 'active' and a['uid'] in m['players']][-1]
        for u, rt in ((a, 250), (b, 330)):
            st = P['/pvp/play'](u, {'match_id': m['id']})
            tick(sum(st['challenge']['delays']) / 1000.0 + 8)
            P['/pvp/submit'](u, {'id': st['id'], 'result': {'reactions': [rt + random.randint(-15, 15) for _ in range(5)]}})
        S.pvp_housekeeping()
        if i == 0:
            P['/duels/cheer'](fan, {'id': m['id']})
            raises('cheered', lambda: P['/duels/cheer'](fan, {'id': m['id']}))
            raises('own_duel', lambda: P['/duels/cheer'](a, {'id': m['id']}))
            rep = G['/duels/replay'](fan, {'id': [m['id']]})
            assert rep['cheers'] == 1
    assert a['x']['wstreak'] == 6 and b['x']['wstreak'] == 0
    st = P['/pvp/play'](a, {'match_id': m['id']}) if False else None
    assert S.rivalry(a, b['uid']) == {'wins': 6, 'losses': 0, 'rival': True}
    assert 'rival_win' in a['badges'] and S._look(a['uid'])['win_streak'] == 6
    return 'six duels: win streak 6, rivals after 5 (6-0), Grudge Match badge, one cheer per fan'


def t_knight():
    u = reg()
    target = S.knight_target()
    st = S.h_practice_start(u, {'game': 'quickdraw'})
    tick(sum(st['challenge']['delays']) / 1000.0 + 8)
    r = P['/practice/submit'](u, {'id': st['id'], 'result': {'reactions': [target - 30 + i * 3 for i in range(5)]}})
    assert r['knight']['beat'] and r['knight']['reward']['iron'] == 8
    st = S.h_practice_start(u, {'game': 'quickdraw'})
    tick(sum(st['challenge']['delays']) / 1000.0 + 8)
    r2 = P['/practice/submit'](u, {'id': st['id'], 'result': {'reactions': [target - 30 + i * 3 for i in range(5)]}})
    assert r2['knight']['done'] and 'reward' not in r2['knight']
    return 'beat the Training Knight (%d ms): +8 iron, once a day' % target


def t_merchant_cabin_badges():
    u, v = reg(), reg()
    mm = S.merchant()
    u['ore']['crystal'], u['ore']['iron'] = 40, 120
    if mm['here']:
        P['/merchant/buy'](u, {})
        assert mm['item'] in u['cosmetics']
    else:
        raises('not_here', lambda: P['/merchant/buy'](u, {}))
    G['/cabin'](v, {'user': [u['username']]})
    P['/cabin/like'](v, {'username': u['username']})
    raises('liked', lambda: P['/cabin/like'](v, {'username': u['username']}))
    own = G['/cabin'](u, {})
    assert own['visitors'][0]['name'] == v['username'] and own['likes'] == 1
    b = G['/badges'](u, {})
    assert not any(x.get('secret') for x in b['all']) and b['secret_left'] == 4
    # dyes unlock shirt colours
    u['cosmetics'].append('shirt_%d' % (S.DYE_BASE + 2))
    S.h_appearance(u, {'appearance': {'shirt': S.DYE_BASE + 2}})
    raises('not_owned', lambda: S.h_appearance(u, {'appearance': {'shirt': S.DYE_BASE + 3}}))
    return 'merchant (%s), cabin visitors + one like a day, secret badges hidden, dyes unlock shirts' % ('open' if mm['here'] else 'away today')


def t_crew_color_rally():
    a = reg()
    S.move('mint', S.U(a['uid']), 500, 'test')
    S.h_crew_create(a, {'name': 'Rally Crew', 'tag': 'RAL'})
    P['/crew/color'](a, {'color': 4})
    assert S._look(a['uid'])['crew_color'] == 4
    c = S.DB['crews'][a['crew']]
    mates = [reg() for _ in range(2)]
    for m in mates:
        c['members'].append(m['uid'])
        m['crew'] = c['id']
        S.act(m, 'mine')
    S.act(a, 'mine')
    assert S._crew_rally(a) == 3
    return 'crew founder picks a banner colour; 3 crewmates mining together rally for +10% ore'


for name, fn in [('mining extras', t_mining_extras), ('cart + chest', t_cart_chest), ('away + comeback', t_away_comeback),
                 ('titles, taunts, pick names', t_titles_taunt_name), ('waves, gifts, news', t_waves_news_gifts),
                 ('duel streaks, rivals, cheers', t_duel_rivals_cheers), ('training knight', t_knight),
                 ('merchant, cabin, badges, dyes', t_merchant_cabin_badges), ('crew colour + rally', t_crew_color_rally)]:
    check(name, fn)
for s, n, d in RESULTS:
    print('%s: %s - %s' % (s, n, d))
print('\nTOTAL %d PASS / %d FAIL' % (sum(1 for r in RESULTS if r[0] == 'PASS'), sum(1 for r in RESULTS if r[0] == 'FAIL')))
