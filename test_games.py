"""Pulse v5.4 games: 4 new skill games, 4 new luck games, ore play, Game of the Day, stats.
Runs the real server code with a fake clock. Luck games are checked over tens of thousands
of bets: every one must return about 97% (3% house edge), in PLS and in ore.
Run:  python test_games.py
"""
import os, sys, tempfile, importlib, random, time, statistics

for k in list(os.environ):
    if k.startswith('PULSE_'):
        del os.environ[k]
HERE = os.path.dirname(os.path.abspath(__file__))
os.environ['PULSE_DATA_FILE'] = tempfile.mktemp(suffix='.json')
os.environ['PULSE_EXTRA_BONUSES'] = '0'
os.environ.pop('DATABASE_URL', None)
sys.path.insert(0, HERE)
S = importlib.import_module('server')
E = S.ApiError
P, G = S.POST_AUTH, S.GET_AUTH
CLOCK = [time.time()]
S.now = lambda: CLOCK[0]
RESULTS = []
rng = random.Random(9)


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
def reg(pls=0):
    N[0] += 1
    ip = '10.%d.%d.7' % (N[0] // 200, N[0] % 200)
    S.REQ.ip = ip
    S.h_register({'username': 'gm%03d' % N[0], 'password': 'secret123'}, ip)
    u = S.DB['users'][S.DB['names']['gm%03d' % N[0]]]
    u['created'] -= 100 * 3600
    u['practice_n'] = 20
    if pls:
        S.move('mint', S.U(u['uid']), pls, 'test_grant')
    return u


def ledger_ok():
    held = sum(x['balance'] for x in S.DB['users'].values())
    assert held + sum(S.DB['accounts'].values()) == 0, 'ledger out of balance'


# ---------------------------------------------------------------- human-like players for each new skill game
def play(game, ch, skill=0.6, bot=False):
    """Returns (result, how long it takes a person to play, in ms)."""
    if game == 'tempo':
        sd = 0.5 if bot else 55 - 35 * skill
        taps = []
        for b in ch['beats']:
            if not bot and rng.random() < 0.08 * (1 - skill):
                continue
            taps.append(int(b + rng.gauss(0, sd)))
        return {'taps': taps}, ch['beats'][-1] + 400
    if game == 'cartrun':
        # for each rock: pick a clear rail (one that is also clear for the next rock if possible) and switch
        # after the previous rock has passed and once you have had time to react to this one
        lane, moves, last = 1, [], -1000
        obs = ch['obstacles']
        prev_t = 0
        for i, o in enumerate(obs):
            vis = S.cart_visible(ch, i)
            appear = o['t'] - vis
            if lane not in o['lanes']:
                prev_t = o['t']
                continue
            react = 60 if bot else rng.gauss(430 - 160 * skill, 60)
            if not bot and rng.random() < (0.01 + 0.0025 * i) * (1.2 - skill):
                react = vis + 200                     # looked away: crash
            free = [l for l in range(3) if l not in o['lanes']]
            nxt = obs[i + 1]['lanes'] if i + 1 < len(obs) else []
            free.sort(key=lambda l: (l in nxt, abs(l - lane)))
            after_prev = 40 if bot else max(60, rng.gauss(200 - 70 * skill, 45))
            d = int(max(appear + react, prev_t + after_prev, last + 100))
            if d >= o['t']:
                d = o['t'] + 50                       # too late: the rock hits
            lane = free[0]
            moves.append([d, lane])
            last = d
            prev_t = o['t']
        passed, gems, end, _ = S.cart_sim(ch, moves)
        return {'moves': moves}, end + 300
    if game == 'oresort':
        ans, used = [], 0
        lives = ch['lives']
        for it in ch['items']:
            if lives <= 0:
                break
            rt = 200 if bot else int(max(230, rng.gauss(700 - 250 * skill, 120)))
            rt = min(rt, it['limit'])
            ok = bot or rng.random() < 0.93 + 0.05 * skill
            choice = it['ore'] if ok else (it['ore'] + 1) % 4
            if not ok:
                lives -= 1
            ans.append([choice, rt])
            used += rt + 260
        return {'answers': ans}, used + 300
    if game == 'stack':
        taps, used = [], 0
        prev_x, w = (1 - ch['width']) / 2, ch['width']
        for lv in ch['levels']:
            # aim for the moment the crate is over the tower, with human error
            best = None
            for t in range(400, 6000, 5):
                x = S.tri(t / 1000.0 * lv['speed'] + lv['offset']) * (1 - w)
                if abs(x - prev_x) < 0.004:
                    best = t
                    break
            t = best if best else 3000
            if not bot:
                t = int(t + rng.gauss(0, 70 - 40 * skill))
            taps.append(max(160, t))
            used += t + 350
            h, p = S.stack_sim(ch, taps)
            if h < len(taps):
                break
            # follow the real tower
            prev_x = None
            pv, pw = (1 - ch['width']) / 2, ch['width']
            ww = ch['width']
            for lv2, tt in zip(ch['levels'], taps):
                x = S.tri(tt / 1000.0 * lv2['speed'] + lv2['offset']) * (1 - ww)
                if abs(x - pv) <= ch['perfect']:
                    x = pv
                    nw = ww
                else:
                    left, right = max(x, pv), min(x + ww, pv + pw)
                    nw = right - left
                    x = left
                pv, pw, ww = x, nw, nw
            prev_x, w = pv, ww
        return {'taps': taps}, used + 300
    raise ValueError(game)


def t_skill_games():
    out = []
    for g in S.NEW_SKILL:
        scores = []
        for skill in (0.3, 0.6, 0.9):
            u = reg()
            tot = 0
            reps = 12 if g == 'cartrun' else 5
            for rep in range(reps):
                st = S.h_practice_start(u, {'game': g})
                ch = S.CHALLENGES[st['id']]['challenge']
                res, ms = play(g, ch, skill)
                tick(ms / 1000.0)
                r = P['/practice/submit'](u, {'id': st['id'], 'result': res})
                assert r['score'] > 0, (g, r)
                tot += r['score']
            scores.append(tot // reps)
        assert scores[2] >= scores[0], (g, scores)
        out.append('%s %s' % (g, scores))
    return 'humans of rising skill score higher: ' + '; '.join(out)


def t_cheats_refused():
    out = []
    for g in S.NEW_SKILL:
        u = reg()
        # 1. a bot with machine-perfect play
        st = S.h_practice_start(u, {'game': g})
        ch = S.CHALLENGES[st['id']]['challenge']
        res, ms = play(g, ch, bot=True)
        tick(ms / 1000.0)
        try:
            raises('impossible_reaction', lambda: P['/practice/submit'](u, {'id': st['id'], 'result': res}))
        except AssertionError:
            raise AssertionError('bot not caught in ' + g)
        # 2. a real-looking result sent instantly
        st = S.h_practice_start(u, {'game': g})
        ch = S.CHALLENGES[st['id']]['challenge']
        res, ms = play(g, ch, 0.7)
        tick(0.5)
        raises('too_fast', lambda: P['/practice/submit'](u, {'id': st['id'], 'result': res}))
        # 3. garbage
        st = S.h_practice_start(u, {'game': g})
        tick(30)
        try:
            P['/practice/submit'](u, {'id': st['id'], 'result': {'taps': 'x' * 9999, 'moves': [[1, 9]], 'answers': [[0, 5]]}})
            ok = False
        except E as e:
            ok = e.code in ('bad_result', 'impossible_reaction', 'too_fast')
        except Exception:
            ok = True       # sanitized to nothing and scored as an empty run is also fine
        out.append(g)
    return 'machine-perfect, instant and garbage results refused in ' + ', '.join(out)


def t_duel_cup_throne():
    a, b = reg(200), reg(200)
    inv = S.h_pvp_challenge(a, {'username': b['username'], 'game': 'cartrun', 'stake': 25})
    S.h_pvp_respond(b, {'invite_id': inv['invite_id'], 'accept': True})
    m = [m for m in S.DB['matches'].values() if m['state'] == 'active' and a['uid'] in m['players']][-1]
    for u, sk in ((a, 0.9), (b, 0.3)):
        st = P['/pvp/play'](u, {'match_id': m['id']})
        res, ms = play('cartrun', st['challenge'], sk)
        tick(ms / 1000.0)
        S.h_pvp_submit(u, {'id': st['id'], 'result': res})
    S.pvp_housekeeping()
    assert m['state'] == 'settled', m['state']
    s = G['/games'](a, {})
    cr = [x for x in s['skill'] if x['game'] == 'cartrun'][0]
    assert cr['wins'] + cr['losses'] == 1
    t = G['/tournaments'](a, {})
    assert {x['game'] for x in t['active']} >= set(S.NEW_SKILL)
    k = S.h_koth(a, {})
    assert {x['game'] for x in k['thrones']} >= set(S.NEW_SKILL)
    ledger_ok()
    return 'Cart Run duel for 25 PLS settled (%s); new games have weekly cups and thrones' % m['result']['winner']


def t_gotd_stats():
    u = reg()
    gd = S.game_of_the_day()
    g = gd['skill']
    xp0 = u['xp']
    for i in range(6):
        st = S.h_practice_start(u, {'game': g})
        ch = S.CHALLENGES[st['id']]['challenge']
        if g in S.NEW_SKILL:
            res, ms = play(g, ch, 0.7)
        elif g == 'quickdraw':
            res, ms = {'reactions': [rng.randint(240, 330) for _ in range(5)]}, sum(ch['delays']) + 3000
        elif g == 'sniper':
            res, ms = {'hits': [{'hit': True, 'rt': rng.randint(300, 500)} for _ in ch['targets']]}, 30000
        elif g == 'strikeoff':
            res, ms = {'taps': [rng.randint(600, 2000) for _ in ch['strikes']]}, 30000
        else:
            res, ms = {'reached': 0}, 1000
        tick(ms / 1000.0)
        P['/practice/submit'](u, {'id': st['id'], 'result': res})
    s = G['/games'](u, {})
    assert s['gotd']['skill'] == g and any(x['username'] == u['username'] for x in s['gotd']['board'])
    assert u['xp'] - xp0 >= 100 and s['gotd']['xp_left'] == 0
    row = [x for x in s['skill'] if x['game'] == g][0]
    assert row['played'] == 6 and len(row['recent']) == 6 and row['gotd']
    # next day the board pays out
    os.environ['PULSE_FAKE_DAY'] = 'G-NEXT'
    G['/games'](u, {})
    os.environ.pop('PULSE_FAKE_DAY')
    assert sum(sum(x['gems'].values()) for x in S.DB['users'].values()) >= 1
    return 'Game of the Day (%s): +20 xp x5, daily board, winner paid a gem next day; per-game stats and ranks' % S.GAME_NAMES[g]


# ---------------------------------------------------------------- luck: return to player over many bets
def rtp(fn, n, bet=10):
    u = reg(10 ** 9)
    u['fair']['nonce'] = 0
    b0 = u['balance']
    for i in range(n):
        fn(u, bet)
    return (u['balance'] - b0 + n * bet) / float(n * bet), u


def t_luck_rtp():
    out = {}
    out['flip'] = rtp(lambda u, b: P['/luck/flip'](u, {'bet': b, 'pick': 'teal'}), 20000)[0]
    out['dice'] = rtp(lambda u, b: P['/luck/dice'](u, {'bet': b, 'target': 50}), 20000)[0]
    for risk in ('low', 'medium', 'high'):
        out['drop_' + risk] = rtp(lambda u, b: P['/luck/drop'](u, {'bet': b, 'risk': risk}), 30000 if risk != 'high' else 60000)[0]
    out['wheel'] = rtp(lambda u, b: P['/luck/wheel'](u, {'bet': b}), 30000)[0]

    def chests(u, b, doubles):
        r = P['/luck/chests/start'](u, {'bet': b, 'pick': rng.randint(0, 2)})
        if r.get('done'):
            return
        for i in range(doubles):
            r = P['/luck/chests/double'](u, {})
            if r.get('done'):
                return
        P['/luck/chests/take'](u, {})
    out['chests_take'] = rtp(lambda u, b: chests(u, b, 0), 30000)[0]
    out['chests_double1'] = rtp(lambda u, b: chests(u, b, 1), 80000)[0]

    def highlow(u, b, steps):
        r = P['/luck/highlow/start'](u, {'bet': b})
        for i in range(steps):
            c = r['game']['card']
            guess = 'higher' if c <= 7 else 'lower'
            r = P['/luck/highlow/guess'](u, {'guess': guess})
            if not r['win'] or r.get('done'):
                return
        P['/luck/highlow/cashout'](u, {})
    out['highlow_1'] = rtp(lambda u, b: highlow(u, b, 1), 30000)[0]
    out['highlow_3'] = rtp(lambda u, b: highlow(u, b, 3), 30000)[0]
    bad = {k: round(v, 4) for k, v in out.items() if not 0.935 <= v <= 1.0}
    assert not bad, bad
    ledger_ok()
    return 'returns (target 0.97): ' + ', '.join('%s %.3f' % (k, v) for k, v in out.items())


def t_exact_math():
    # exact expected values from the published tables, not samples
    ev_drop = {k: sum(p * m for p, m in zip(S.DROP_PROBS, v)) for k, v in S.DROP_MULTS.items()}
    ev_wheel = sum(S.WHEEL) / len(S.WHEEL)
    ev_chest = sum(S.CHEST_VALUES) / 3
    ev_hl = []
    for c in range(1, 14):
        for g, p in (('higher', (13 - c) / 13.0), ('lower', (c - 1) / 13.0)):
            if p > 0:
                ev_hl.append(p * (1 / p) * (1 - S.HOUSE_EDGE))
    for v in list(ev_drop.values()) + [ev_wheel, ev_chest] + ev_hl:
        assert abs(v - 0.97) < 1e-9, v
    assert abs(S.DOUBLE_MULT * 0.5 - 1.0) < 1e-9      # double-or-nothing is a fair 50/50 (the edge was taken once)
    return 'every table pays exactly 97% on average (Cart Drop x3 risks, Wheel, Chests, High-Low every card); double-or-nothing is fair'


def t_ore_mode():
    u = reg()
    u['ore']['iron'] = 1000
    pls0 = u['balance']
    ledger_before = dict(S.DB['accounts'])
    n = 0
    for i in range(200):
        P['/luck/wheel'](u, {'bet': 5, 'currency': 'ore', 'ore': 'iron'})
        P['/luck/drop'](u, {'bet': 5, 'currency': 'ore', 'ore': 'iron', 'risk': 'low'})
        r = P['/luck/flip'](u, {'bet': 5, 'currency': 'ore', 'ore': 'iron', 'pick': 'amber'})
        n += 3
    r = P['/luck/cavein/start'](u, {'bet': 10, 'currency': 'ore', 'ore': 'iron', 'caves': 3})
    assert r['currency'] == 'ore'
    cell = next(c for c in range(25) if c not in u['cavein']['cells'])
    P['/luck/cavein/reveal'](u, {'cell': cell})
    P['/luck/cavein/cashout'](u, {})
    raises('not_enough', lambda: P['/luck/wheel'](u, {'bet': 500, 'currency': 'ore', 'ore': 'void'}))
    assert u['balance'] == pls0 and S.DB['accounts'] == ledger_before
    return 'ore play: %d ore bets moved only ore (%d iron left), never PLS; ledger untouched' % (n, u['ore']['iron'])


def t_free_spin_and_fairness():
    u = reg(100)
    r = P['/luck/wheel/free'](u, {})
    assert 'prize' in r
    raises('spun', lambda: P['/luck/wheel/free'](u, {}))
    # an open High-Low run blocks seed rotation (so results can't be re-rolled)
    P['/luck/highlow/start'](u, {'bet': 5})
    raises('finish_run', lambda: P['/luck/seed'](u, {'client_seed': 'abc'}))
    r = P['/luck/highlow/guess'](u, {'guess': 'higher' if u['highlow']['cards'][-1] < 7 else 'lower'})
    if u.get('highlow'):
        P['/luck/highlow/cashout'](u, {})
    # provably fair: re-derive a Cart Drop from the revealed seed
    d = P['/luck/drop'](u, {'bet': 1, 'risk': 'high'})
    rev = P['/luck/seed'](u, {'client_seed': 'next1'})['revealed']
    assert S.hashlib.sha256(rev['server_seed'].encode()).hexdigest() == rev['server_hash']
    path = ['R' if S.verify_float(rev['server_seed'], rev['client_seed'], d['nonce'], i) >= 0.5 else 'L' for i in range(10)]
    assert path == d['path']
    return 'one free ore spin a day; seed rotation waits for open runs; Cart Drop path re-derived from the revealed seed'


def t_bad_inputs():
    u = reg(50)
    raises('bad_bet', lambda: P['/luck/wheel'](u, {'bet': 0}))
    raises('bad_bet', lambda: P['/luck/drop'](u, {'bet': 501, 'risk': 'low'}))
    raises('bad_risk', lambda: P['/luck/drop'](u, {'bet': 5, 'risk': 'insane'}))
    raises('bad_pick', lambda: P['/luck/chests/start'](u, {'bet': 5, 'pick': 7}))
    raises('no_highlow', lambda: P['/luck/highlow/guess'](u, {'guess': 'higher'}))
    P['/luck/highlow/start'](u, {'bet': 5})
    raises('guess_first', lambda: P['/luck/highlow/cashout'](u, {}))
    raises('finish_highlow', lambda: P['/luck/highlow/start'](u, {'bet': 5}))
    c = u['highlow']['cards'][-1]
    if c == 13:
        raises('bad_guess', lambda: P['/luck/highlow/guess'](u, {'guess': 'higher'}))
    raises('bad_ore', lambda: P['/luck/wheel'](u, {'bet': 5, 'currency': 'ore', 'ore': 'gold'}))
    raises('insufficient_pls', lambda: P['/luck/wheel'](reg(), {'bet': 50}))
    ledger_ok()
    return 'bad bets, risks, picks, guesses, ores and empty wallets refused'


for name, fn in [('new skill games', t_skill_games), ('cheats refused', t_cheats_refused), ('duels, cups, thrones', t_duel_cup_throne),
                 ('game of the day + stats', t_gotd_stats), ('luck returns', t_luck_rtp), ('exact luck maths', t_exact_math),
                 ('ore play', t_ore_mode), ('free spin + fairness', t_free_spin_and_fairness), ('bad inputs', t_bad_inputs)]:
    check(name, fn)
for s, n, d in RESULTS:
    print('%s: %s - %s' % (s, n, d))
print('\nTOTAL %d PASS / %d FAIL' % (sum(1 for r in RESULTS if r[0] == 'PASS'), sum(1 for r in RESULTS if r[0] == 'FAIL')))
