"""Pulse v5.1 attack suite: tries to break, cheat, farm and flood the server.
Every attack must FAIL, and honest players (the controls) must keep working.
Runs with the real security settings (no relaxed environment).
Run:  python test_attacks.py
"""
import os, sys, json, time, tempfile, importlib, socket, subprocess, urllib.request, urllib.error, random, threading

for k in list(os.environ):
    if k.startswith('PULSE_') and k not in ('PULSE_DATA_FILE',):
        del os.environ[k]
HERE = os.path.dirname(os.path.abspath(__file__))
os.environ['PULSE_DATA_FILE'] = tempfile.mktemp(suffix='.json')
os.environ.pop('DATABASE_URL', None)
sys.path.insert(0, HERE)
S = importlib.import_module('server')
E = S.ApiError
RESULTS = []
CLOCK = [time.time()]
S.now = lambda: CLOCK[0]
rng = random.Random(5)

def check(name, fn):
    try:
        RESULTS.append(('BLOCKED' if True else '', name, fn() or ''))
    except Exception as e:
        import traceback
        traceback.print_exc()
        RESULTS.append(('FAIL', name, repr(e)))

def tick(sec):
    CLOCK[0] += sec

def raises(code, fn):
    try:
        fn()
    except E as e:
        assert e.code == code, (e.code, 'expected', code)
        return
    raise AssertionError('not blocked: expected ' + code)

N = [0]
def reg(ip='10.0.0.%d', age_h=48, practice=0):
    N[0] += 1
    ip = ip % N[0] if '%d' in ip else ip
    S.REQ.ip = ip
    out = S.h_register({'username': 'u%04d' % N[0], 'password': 'secret123'}, ip)
    u = S.DB['users'][S.DB['names']['u%04d' % N[0]]]
    u['created'] -= age_h * 3600
    u['practice_n'] = practice
    S.note_ip(u, ip)
    return u

def give(u, n):
    S.move('mint', S.U(u['uid']), n, 'test_grant')

def as_ip(u, ip):
    S.REQ.ip = ip
    S.note_ip(u, ip)

def ideal_tap(ch, after=200):
    best = None
    for target in (ch['zone_center'], 2 - ch['zone_center']):
        t = ((target - ch['offset']) % 2.0) / ch['speed'] * 1000.0
        while t < after:
            t += 2.0 / ch['speed'] * 1000.0
        best = t if best is None else min(best, t)
    return best

def mine_once(u, tap_fn, gap):
    """One strike: tap_fn(challenge) -> tap ms; gap = seconds since the last strike."""
    tick(gap)
    st = S.h_mine_start(u, {'tier': 1})
    tap = max(160, int(tap_fn(st['challenge'])))
    tick(tap / 1000.0 + 0.02)
    u['last_strike'] = 0
    return S.h_mine_strike(u, {'id': st['id'], 'tap_ms': tap})

def human_tap(ch):
    return ideal_tap(ch) + rng.gauss(0, 45)

def node_counts(u, ip):
    S.REQ.ip = ip
    n = S.DB['nodes'].setdefault('n' + u['uid'], {'id': 'n' + u['uid'], 'uid': u['uid'], 'status': 'active', 'last_counted': 0,
                                                  'units_epoch': {}, 'day': '', 'day_units': 0, 'units_total': 0})
    ok, why = S.node_eligibility(u, n, True)
    return ok, why

def ledger_ok():
    held = sum(x['balance'] for x in S.DB['users'].values())
    assert held + sum(S.DB['accounts'].values()) == 0

# ===========================================================================
# NETWORK + DENIAL OF SERVICE
# ===========================================================================
def a_xff_spoof():
    class H:
        client_address = ('203.0.113.9', 5555)
        headers = {'X-Forwarded-For': '1.2.3.4, 5.6.7.8, 198.51.100.7'}
    h = H()
    assert S.Handler.ip(h) == '198.51.100.7'
    H.headers = {'X-Forwarded-For': 'evil-fake'}
    assert S.Handler.ip(H()) == 'evil-fake'          # a single hop: what the proxy wrote
    H.headers = {}
    assert S.Handler.ip(H()) == '203.0.113.9'
    return 'faked X-Forwarded-For entries are ignored; only the hop our proxy added counts (rate limits and account limits cannot be dodged)'

def a_rate_limit():
    ip = '192.0.2.50'
    ok = sum(1 for _ in range(200) if S.rate_ok(ip))
    assert ok <= S.RATE_BURST + 2, ok
    assert S.rate_ok('192.0.2.51')
    return 'a flood of 200 instant requests from one address: only %d get through, other addresses unaffected' % ok

def a_challenge_spam():
    u = reg()
    for i in range(500):
        S.h_practice_start(u, {'game': 'quickdraw'})
    mine = sum(1 for v in S.CHALLENGES.values() if v['uid'] == u['uid'])
    assert mine <= S.MAX_CHALLENGES_PER_USER, mine
    return '500 game starts in a row: the server keeps only %d open per player (memory stays bounded)' % mine

def a_session_spam():
    u = reg()
    for i in range(60):
        S.create_session(u['uid'])
    n = sum(1 for v in S.DB['sessions'].values() if v['uid'] == u['uid'])
    assert n <= S.MAX_SESSIONS_PER_USER
    return '60 logins: only the newest %d sessions are kept' % n

def a_result_bloat():
    u = reg()
    p = S.h_practice_start(u, {'game': 'quickdraw'})
    S.CHALLENGES[p['id']]['issued'] -= 60
    junk = {'reactions': [300, 280, 320, 290, 310], 'junk': 'x' * 150000}
    S.h_practice_submit(u, {'id': p['id'], 'result': junk})
    assert 'junk' not in json.dumps(u['best_runs'])
    return 'a 150 KB junk field hidden in a game result is stripped before anything is saved'

def a_pruning_keeps_escrow():
    seller = reg()
    for i in range(2600):
        S.DB['market'].append({'id': 'a%d' % i, 'seller': seller['uid'], 'kind': 'ore', 'item': 'coal', 'qty': 1, 'price': 5, 't': S.now(), 'state': 'open'})
    S.tick_market()
    assert sum(1 for x in S.DB['market'] if x['state'] == 'open') == 2600
    for i in range(5200):
        S.DB['matches']['zz%d' % i] = {'id': 'zz%d' % i, 'state': 'settled', 'created': i, 'players': [seller['uid'], seller['uid']], 'subs': {}, 'deadline': 0}
    S.DB['matches']['live1'] = {'id': 'live1', 'state': 'active', 'created': -1, 'players': [seller['uid'], seller['uid']], 'subs': {}, 'deadline': S.now() + 999,
                                'stake': 0, 'game': 'quickdraw', 'seed': 1, 'started': {}, 'result': None}
    S.pvp_housekeeping()
    assert 'live1' in S.DB['matches']
    S.DB['market'] = [x for x in S.DB['market'] if not x['id'].startswith('a')]
    for k in [k for k in S.DB['matches'] if k.startswith('zz') or k == 'live1']:
        del S.DB['matches'][k]
    return 'flooding the market or duel lists can no longer push other players\' open listings or live duels out of memory'

def a_http():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    env = {k: v for k, v in os.environ.items() if not k.startswith('PULSE_')}
    env.update(PORT=str(port), PULSE_DATA_FILE=tempfile.mktemp(suffix='.json'), PULSE_MAX_CONNECTIONS='40')
    p = subprocess.Popen([sys.executable, os.path.join(HERE, 'server.py')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    base = 'http://127.0.0.1:%d' % port
    try:
        for _ in range(60):
            try:
                urllib.request.urlopen(base + '/health', timeout=1)
                break
            except Exception:
                time.sleep(0.2)
        # 1) slowloris: 60 sockets that never send a request
        idle = []
        for i in range(60):
            c = socket.socket()
            c.settimeout(2)
            try:
                c.connect(('127.0.0.1', port))
                idle.append(c)
            except Exception:
                pass
        t0 = time.time()
        r = urllib.request.urlopen(base + '/health', timeout=10)
        h = json.loads(r.read())
        assert h['version'] == 5.4
        dt = time.time() - t0
        for c in idle:
            c.close()
        # 2) oversized body
        req = urllib.request.Request(base + '/auth/login', data=b'{"a":"' + b'x' * 300000 + b'"}', headers={'Content-Type': 'application/json'})
        try:
            urllib.request.urlopen(req, timeout=10)
            raise AssertionError('300 KB body accepted')
        except urllib.error.HTTPError as e:
            assert e.code == 413
        except (ConnectionResetError, urllib.error.URLError, BrokenPipeError):
            pass
        # 3) broken JSON and deep nesting
        for body in (b'{not json', b'[' * 50000 + b']' * 50000):
            req = urllib.request.Request(base + '/auth/login', data=body, headers={'Content-Type': 'application/json'})
            try:
                urllib.request.urlopen(req, timeout=10)
            except urllib.error.HTTPError as e:
                assert e.code in (400, 401, 429), e.code
        # 4) flood: 150 fast requests from one client
        codes = []
        for i in range(150):
            try:
                urllib.request.urlopen(base + '/network/stats', timeout=5)
                codes.append(200)
            except urllib.error.HTTPError as e:
                codes.append(e.code)
        assert codes.count(429) > 60, codes.count(429)
        # 5) the server is still healthy afterwards
        time.sleep(1.2)
        assert json.loads(urllib.request.urlopen(base + '/health', timeout=5).read())['ok']
        return ('60 silent connections did not lock out a normal visitor (answered in %.2fs); a 300 KB body was refused; broken and '
                'deeply nested JSON got clean errors; %d of 150 flood requests were turned away; server healthy after' % (dt, codes.count(429)))
    finally:
        p.terminate()
        err = p.stderr.read().decode()
        if 'Traceback' in err and 'RecursionError' not in err:
            print(err[-1500:])

# ===========================================================================
# ACCOUNTS
# ===========================================================================
def a_login_bruteforce():
    u = reg()
    for i in range(8):
        S.AUTH_HITS.clear()
        raises('bad_login', lambda: S.h_login({'username': u['username'], 'password': 'guess%d' % i}, '198.18.0.%d' % i))
    S.AUTH_HITS.clear()
    raises('locked', lambda: S.h_login({'username': u['username'], 'password': 'secret123'}, '198.18.1.1'))
    v = reg()
    S.AUTH_HITS.clear()
    assert S.h_login({'username': v['username'], 'password': 'secret123'}, '198.18.1.1')['ok']
    tick(901)
    S.SEC['login_fail'].clear() if False else None
    assert S.h_login({'username': u['username'], 'password': 'secret123'}, '198.18.1.2')['ok']
    return 'password guessing from many addresses locks that one account for 15 minutes; other players log in normally'

def a_mass_register():
    ip = '100.64.9.9'
    made = 0
    for i in range(10):
        try:
            S.h_register({'username': 'farm%02d' % i, 'password': 'secret123'}, ip)
            made += 1
        except E as e:
            assert e.code in ('too_many_accounts', 'slow_down'), e.code
    assert made == S.REG_PER_IP_DAY, made
    bals = [S.DB['users'][S.DB['names']['farm%02d' % i]]['balance'] for i in range(made)]
    assert bals[:S.STARTER_PER_IP_DAY] == [S.STARTER_PLS] * S.STARTER_PER_IP_DAY and sum(bals[S.STARTER_PER_IP_DAY:]) == 0, bals
    raises('name_reserved', lambda: S.h_register({'username': 'Pulse', 'password': 'secret123'}, '100.64.9.10'))
    raises('name_reserved', lambda: S.h_register({'username': 'admin_bob', 'password': 'secret123'}, '100.64.9.10'))
    ledger_ok()
    return ('10 sign-ups from one network: %d accounts made, only the first %d got starter coins; names like "Pulse" or "admin..." '
            'cannot be taken to fake system messages' % (made, S.STARTER_PER_IP_DAY))

# ===========================================================================
# BOTS + AUTO-CLICKERS
# ===========================================================================
def a_autoclicker():
    u = reg()
    for i in range(45):
        mine_once(u, lambda ch: 900, 1.25)        # taps on a fixed beat, wherever the marker is
    assert u['flagged'] and 'auto-clicker' in u.get('flag_why', ''), u.get('flag_why')
    ok, why = node_counts(u, '10.9.0.1')
    assert not ok
    r = mine_once(u, lambda ch: ideal_tap(ch), 1.3)
    assert r['quality'] in ('good', 'miss')
    return 'a fixed-rhythm auto-clicker is caught after 40 taps (%s); node pay stops and strikes are capped' % u['flag_why']

def a_aimbot():
    u = reg()
    for i in range(45):
        mine_once(u, lambda ch: ideal_tap(ch) + rng.uniform(-1.5, 1.5), rng.uniform(0.6, 3.0))
    assert u['flagged'] and 'aim-bot' in u.get('flag_why', ''), u.get('flag_why')
    return 'a bot that reads the bar and taps the perfect moment is caught (%s)' % u['flag_why']

def a_random_clicker():
    u = reg()
    for i in range(30):
        mine_once(u, lambda ch: rng.uniform(200, 3000), rng.uniform(0.6, 3.0))
    ok, why = node_counts(u, '10.9.0.2')
    hits = u['hm']['hits']
    assert not ok and ('misses' in why or 'good strikes' in why), why
    return 'a random clicker (varied timing, %d%% hits) is not paid for node time: "%s"' % (100 * sum(hits) // len(hits), why)

def a_human_control():
    u = reg()
    for i in range(60):
        mine_once(u, human_tap, rng.uniform(0.8, 3.5))
    assert not u['flagged'], u.get('flag_why')
    ok, why = node_counts(u, '10.9.0.3')
    assert ok, why
    return 'CONTROL: a human-like player (60 strikes) is never flagged and earns node pay'

def a_node_farm_one_network():
    ip = '172.16.5.5'
    ok_count = 0
    # start at the top of a node period so the whole farm run lands inside one period
    e0 = S.epoch_of(S.now())
    while S.epoch_of(S.now()) == e0:
        tick(5)
    for i in range(9):
        u = reg(ip='172.16.200.%d' % i)
        for j in range(12):
            mine_once(u, human_tap, rng.uniform(0.8, 3.0))
        ok, why = node_counts(u, ip)
        ok_count += ok
    assert ok_count == S.EARNERS_PER_IP, ok_count
    return '9 farm accounts mining from one network: only %d are paid node time per 10-minute period' % ok_count

def a_fishing_bot():
    u = reg()
    c = S.h_fish_cast(u, {})
    tick(c['bite_ms'] / 1000.0 + 0.1)
    r = S.h_fish_reel(u, {'tap_ms': c['bite_ms'] + 40})
    assert not r['caught']
    for i in range(35):
        try:
            c = S.h_fish_cast(u, {})
        except E as e:
            assert e.code == 'review_hold'
            break
        tick(c['bite_ms'] / 1000.0 + 0.5)
        S.h_fish_reel(u, {'tap_ms': c['bite_ms'] + 210})
    assert u['flagged'] and 'fishing bot' in u.get('flag_why', '')
    h = reg()
    for i in range(S.FISH_PER_DAY):
        c = S.h_fish_cast(h, {})
        tick(c['bite_ms'] / 1000.0 + 0.6)
        S.h_fish_reel(h, {'tap_ms': c['bite_ms'] + rng.randint(200, 480)})
    raises('fish_tired', lambda: S.h_fish_cast(h, {}))
    return 'instant reels spook the fish; a bot reeling at the same delay is caught; even humans stop at %d fish a day' % S.FISH_PER_DAY

def a_expedition_limit():
    u = reg()
    u['ore']['coal'] = 1000
    for i in range(S.EXPEDITIONS_PER_DAY):
        S.h_exp_start(u, {})
        S.h_exp_exit(u, {})
    raises('too_tired', lambda: S.h_exp_start(u, {}))
    return 'expeditions stop after %d a day' % S.EXPEDITIONS_PER_DAY

def a_long_session_taper():
    u = reg()
    u['day_blocks'] = 130
    r = mine_once(u, human_tap, 1.5)
    assert r.get('taper') == 0.25, r.get('taper')
    return 'after 120 veins in one day ore drops to a quarter (24/7 farming stops paying)'

# ===========================================================================
# FORGED SKILL-GAME RESULTS
# ===========================================================================
def a_sequence_forge():
    u = reg()
    p = S.h_practice_start(u, {'game': 'sequence'})
    assert len(p['challenge']['runes']) == p['challenge']['start_len'], len(p['challenge']['runes'])
    tick(120)
    s = S.h_practice_submit(u, {'id': p['id'], 'result': {'reached': 20}})
    assert s['score'] == 0
    p = S.h_practice_start(u, {'game': 'sequence'})
    ch = S.CHALLENGES[p['id']]['challenge']
    raises('too_fast', lambda: S.h_skill_step(u, {'id': p['id'], 'entered': ch['runes'][:3]}))
    tick(5)
    r = S.h_skill_step(u, {'id': p['id'], 'entered': [(x + 1) % 4 for x in ch['runes'][:3]]})
    assert not r['correct']
    raises('game_over', lambda: S.h_skill_step(u, {'id': p['id'], 'entered': ch['runes'][:3]}))
    p = S.h_practice_start(u, {'game': 'sequence'})
    ch = S.CHALLENGES[p['id']]['challenge']
    for n in range(3, 8):
        tick(n * 0.6 + n * 0.35 + 1)
        r = S.h_skill_step(u, {'id': p['id'], 'entered': ch['runes'][:n]})
        assert r['correct'] and len(r['runes']) == n + 1
    tick(5)
    s = S.h_practice_submit(u, {'id': p['id'], 'result': {'reached': 20}})
    assert s['score'] == 700, s
    return ('Rune Sequence no longer sends the answers up front; a claimed "20 runes" scores 0, answers faster than the runes '
            'can be shown are refused, and an honest run scores exactly what was played (7 runes = 700, even when 20 is claimed)')

def a_reaction_forge():
    u = reg()
    p = S.h_practice_start(u, {'game': 'quickdraw'})
    S.CHALLENGES[p['id']]['issued'] -= 60
    raises('impossible_reaction', lambda: S.h_practice_submit(u, {'id': p['id'], 'result': {'reactions': [115, 200, 210, 220, 205]}}))
    for i in range(5):
        p = S.h_practice_start(u, {'game': 'quickdraw'})
        S.CHALLENGES[p['id']]['issued'] -= 60
        S.h_practice_submit(u, {'id': p['id'], 'result': {'reactions': [rng.randint(160, 200) for _ in range(5)]}})
    assert u['ac']['flag'], u['ac']
    give(u, 100)
    raises('review_hold', lambda: S.h_pvp_queue(u, {'game': 'quickdraw', 'stake': 10}))
    h = reg(practice=0)
    for i in range(6):
        p = S.h_practice_start(h, {'game': 'quickdraw'})
        S.CHALLENGES[p['id']]['issued'] -= 60
        S.h_practice_submit(h, {'id': p['id'], 'result': {'reactions': [rng.randint(230, 420) for _ in range(5)]}})
    assert not h['ac']['flag']
    return ('reactions under 120 ms are refused outright; a script sending fast "plausible" times (avg ~180 ms) has staked play '
            'paused after 20 taps; CONTROL: human times pass')

# ===========================================================================
# ECONOMY: multi-account farming, collusion, item bugs
# ===========================================================================
def a_new_account_cooldown():
    u = reg(age_h=1, practice=10)
    give(u, 500)
    u['gems']['amber'] = 5
    raises('new_account', lambda: S.h_pvp_queue(u, {'game': 'quickdraw', 'stake': 10}))
    raises('new_account', lambda: S.h_market_sell(u, {'kind': 'gem', 'item': 'amber', 'qty': 1, 'price': 50}))
    raises('new_account', lambda: S.h_bounty_post(u, {'game': 'quickdraw', 'amount': 20}))
    raises('new_account', lambda: S.h_t_enter(u, {'game': 'quickdraw'}))
    S.h_pvp_queue(u, {'game': 'quickdraw', 'stake': 0})
    S.h_pvp_cancel(u, {})
    return 'fresh accounts (the kind a farm makes) cannot stake, sell, post bounties or enter cups for %d hours; free play works' % S.NEW_ACCOUNT_HOURS

def a_practice_before_stake():
    u = reg(practice=2)
    give(u, 100)
    raises('practice_first', lambda: S.h_pvp_queue(u, {'game': 'quickdraw', 'stake': 10}))
    return 'staking needs %d practice games first (gives the cheat checks something to look at)' % S.MIN_PRACTICE_TO_STAKE

def a_collusion():
    main = reg(practice=10)
    alt = reg(practice=10)
    as_ip(main, '203.0.113.77')
    as_ip(alt, '203.0.113.77')
    give(main, 300)
    give(alt, 300)
    raises('linked_accounts', lambda: S.h_pvp_challenge(alt, {'username': main['username'], 'game': 'quickdraw', 'stake': 50}))
    raises('linked_accounts', lambda: S.h_series_challenge(alt, {'username': main['username'], 'game': 'quickdraw', 'stake': 50}))
    S.h_pvp_queue(main, {'game': 'quickdraw', 'stake': 50})
    r = S.h_pvp_queue(alt, {'game': 'quickdraw', 'stake': 50})
    assert r['status'] == 'waiting', r
    S.h_pvp_cancel(main, {})
    S.h_pvp_cancel(alt, {})
    alt['gems']['amber'] = 3
    S.h_market_sell(alt, {'kind': 'gem', 'item': 'amber', 'qty': 1, 'price': 250})
    lid = S.DB['market'][-1]['id']
    raises('linked_accounts', lambda: S.h_market_buy(main, {'id': lid}))
    S.h_market_cancel(alt, {'id': lid})
    alt['ore'].update({'iron': 50, 'coal': 50})
    S.h_forge(alt, {'recipe': 'iron_pickaxe'})
    S.h_rent_offer(alt, {'slot': 'pickaxe', 'price': 200})
    rid = S.DB['rentals'][-1]['id']
    raises('linked_accounts', lambda: S.h_rent_take(main, {'id': rid}))
    S.h_rent_cancel(alt, {'id': rid})
    alt['best']['quickdraw'] = 10
    S.h_bounty_post(alt, {'game': 'quickdraw', 'amount': 100})
    p = S.h_practice_start(main, {'game': 'quickdraw'})
    S.CHALLENGES[p['id']]['issued'] -= 60
    s = S.h_practice_submit(main, {'id': p['id'], 'result': {'reactions': [260, 300, 280, 330, 290]}})
    assert s['bounties_claimed'] == [], s
    S.DB['koth']['quickdraw'] = {'uid': alt['uid'], 'score': 99999, 'pot': 0, 'since': S.now(), 'defenses': 0}
    raises('linked_accounts', lambda: S.h_koth_challenge(main, {'game': 'quickdraw'}))
    stranger = reg(practice=10)
    as_ip(stranger, '198.51.100.200')
    give(stranger, 300)
    s2 = None
    p = S.h_practice_start(stranger, {'game': 'quickdraw'})
    S.CHALLENGES[p['id']]['issued'] -= 60
    s2 = S.h_practice_submit(stranger, {'id': p['id'], 'result': {'reactions': [270, 310, 290, 250, 300]}})
    assert s2['bounties_claimed'], s2
    S.h_pvp_challenge(stranger, {'username': main['username'], 'game': 'quickdraw', 'stake': 50})
    del S.DB['koth']['quickdraw']
    ledger_ok()
    return ('two accounts on the same network cannot pass PLS to each other by duels, best-of-3, the queue, the market, rentals, '
            'bounties or thrones; CONTROL: an unrelated player can claim the bounty and challenge normally')

def a_rental_forge_bug():
    owner = reg(practice=10)
    renter = reg(practice=10)
    as_ip(owner, '192.0.2.10')
    as_ip(renter, '192.0.2.20')
    give(owner, 500)
    give(renter, 500)
    owner['ore'].update({'iron': 50, 'coal': 50})
    renter['ore'].update({'iron': 50, 'coal': 50})
    S.h_forge(owner, {'recipe': 'iron_pickaxe'})
    S.h_rent_offer(owner, {'slot': 'pickaxe', 'price': 40})
    S.h_rent_take(renter, {'id': S.DB['rentals'][-1]['id']})
    raises('renting', lambda: S.h_forge(renter, {'recipe': 'iron_pickaxe'}))
    S.DB['rentals'][-1]['until'] = S.now() - 1
    S.tick_rentals()
    assert owner['gear']['pickaxe']['name'] == 'Iron Pickaxe'
    return 'forging over rented gear (which used to destroy the owner\'s item) is refused; the owner gets it back'

def a_wallet_guessing():
    u = reg()
    out = S.h_wallet_link_start(u, {'_base': 'https://x'})
    assert len(out['code']) == 16
    attacker_ip = '203.0.113.200'
    for i in range(10):
        try:
            S.h_wallet_link_finish({'code': '%016X' % rng.getrandbits(64), 'pubkey': '1' * 32, 'sig': '1' * 64}, attacker_ip)
        except E as e:
            assert e.code in ('code_expired', 'bad_signature'), e.code
    raises('slow_down', lambda: S.h_wallet_link_finish({'code': out['code'], 'pubkey': '1' * 32, 'sig': '1' * 64}, attacker_ip))
    for i in range(5):
        try:
            S.h_wallet_link_finish({'code': out['code'], 'pubkey': '1' * 32, 'sig': '1' * 64}, '203.0.113.%d' % (i + 1))
        except E:
            pass
    assert out['code'] not in S.DB['wallet_links']
    return ('link codes are now 64-bit; guessing is throttled per address and a code dies after 5 bad signatures '
            '(stops someone pointing your PULSE rewards at their wallet)')

def a_share_spam():
    u = reg()
    S.h_share_create(u, {'kind': 'profile'})
    raises('slow_down', lambda: S.h_share_create(u, {'kind': 'profile'}))
    return 'share cards are limited to one every %d seconds per player' % S.SHARE_GAP

def a_invite_spam():
    u = reg(practice=10)
    give(u, 1000)
    victims = [reg() for _ in range(7)]
    for v in victims:
        as_ip(v, '198.51.100.%d' % rng.randint(1, 250))
    as_ip(u, '192.0.2.99')
    sent = 0
    for v in victims:
        try:
            S.h_pvp_challenge(u, {'username': v['username'], 'game': 'quickdraw', 'stake': 0})
            sent += 1
        except E as e:
            assert e.code == 'too_many_invites'
    assert sent == 5
    return 'challenge spam stops at 5 open invites (friend requests at 30)'

def a_cavein_seed():
    u = reg()
    give(u, 100)
    S.h_cave_start(u, {'bet': 10, 'caves': 5})
    raises('finish_cavein', lambda: S.h_fair_seed(u, {}))
    return 'CHECKED: revealing the luck seed mid Cave-In (to see where the rocks are) was already blocked'

def a_public_cache():
    t0 = time.time()
    for i in range(300):
        S.h_network({})
    dt = time.time() - t0
    assert dt < 1.0, dt
    return '300 network-stat requests served from cache in %.3fs (cannot be used to pin the CPU)' % dt

for name, fn in [
        ('Faked IP headers', a_xff_spoof), ('Request flood (rate limit)', a_rate_limit), ('Game-start spam', a_challenge_spam),
        ('Session spam', a_session_spam), ('Oversized game results', a_result_bloat), ('Listing/duel flood pushing out others', a_pruning_keeps_escrow),
        ('Real HTTP: slowloris, huge body, bad JSON, flood', a_http), ('Password guessing', a_login_bruteforce),
        ('Account farm from one network', a_mass_register), ('Auto-clicker mining', a_autoclicker), ('Aim-bot mining', a_aimbot),
        ('Random clicker for node pay', a_random_clicker), ('CONTROL human miner', a_human_control),
        ('Node farm on one network', a_node_farm_one_network), ('Fishing bot', a_fishing_bot), ('Expedition grinding', a_expedition_limit),
        ('24/7 ore farming', a_long_session_taper), ('Forged Rune Sequence score', a_sequence_forge), ('Forged reaction times', a_reaction_forge),
        ('Brand-new account trading/staking', a_new_account_cooldown), ('Staking with no history', a_practice_before_stake),
        ('Alt accounts passing PLS', a_collusion), ('Rented gear destroyed by forging', a_rental_forge_bug),
        ('Wallet-link code guessing', a_wallet_guessing), ('Share-card spam', a_share_spam), ('Challenge spam', a_invite_spam),
        ('Luck seed reveal mid-game', a_cavein_seed), ('Public page hammering', a_public_cache)]:
    check(name, fn)

ok = sum(1 for r in RESULTS if r[0] != 'FAIL')
for st, name, detail in RESULTS:
    print('%s  %s - %s' % ('PASS' if st != 'FAIL' else 'FAIL', name, detail))
print('\nTOTAL %d PASS / %d FAIL' % (ok, len(RESULTS) - ok))
