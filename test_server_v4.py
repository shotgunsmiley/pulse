"""Pulse v4 server tests.
Part 1 runs the server in-process (fast, lets us fake time for long scenarios).
Part 2 runs the real HTTP server in a subprocess and plays through it like the app does.
Run:  python test_server_v4.py
"""
import os as _os
_os.environ['PULSE_EXTRA_BONUSES'] = '0'   # this suite checks the exact base mining rules
import os, sys, json, time, tempfile, importlib, subprocess, socket, urllib.request, urllib.error, hashlib, random, types, sqlite3

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = []

def check(name, fn):
    try:
        detail = fn()
        RESULTS.append(('PASS', name, detail or ''))
    except Exception as e:
        import traceback
        traceback.print_exc()
        RESULTS.append(('FAIL', name, repr(e)))

def load_server(data_file, extra_env=None):
    os.environ['PULSE_DATA_FILE'] = data_file
    os.environ['PULSE_AUTH_LIMIT'] = '100000'
    os.environ.pop('DATABASE_URL', None)
    for k, v in (extra_env or {}).items():
        os.environ[k] = v
    sys.path.insert(0, HERE)
    if 'server' in sys.modules:
        del sys.modules['server']
    return importlib.import_module('server')

# ---------------------------------------------------------------------------
# PART 1: in-process
# ---------------------------------------------------------------------------
DATA = tempfile.mktemp(suffix='.json')
S = load_server(DATA)
B = S.ApiError

def reg(name):
    out = S.h_register({'username': name, 'password': 'secret123'}, '1.1.1.1')
    return S.session_user(out['token']), out['token']

def ledger_ok():
    circ = sum(x['balance'] for x in S.DB['users'].values())
    assert circ + sum(S.DB['accounts'].values()) == 0, (circ, S.DB['accounts'])
    return True

def give(u, amt):
    S.move('mint', S.U(u['uid']), amt, 'test_grant')

def backdate(cid, seconds):
    S.CHALLENGES[cid]['issued'] -= seconds

def perfect_tap(ch):
    best = None
    for target in (ch['zone_center'], 2 - ch['zone_center']):
        t = ((target - ch['offset']) % 2.0) / ch['speed'] * 1000.0
        while t < 160:
            t += 2.0 / ch['speed'] * 1000.0
        best = t if best is None else min(best, t)
    return int(round(best))

def strike(u, tier, quality='perfect'):
    r = S.h_mine_start(u, {'tier': tier})
    ch = r['challenge']
    tap = perfect_tap(ch)
    if quality == 'miss':
        # tap where the marker is far from the zone
        for t in range(160, 6000, 7):
            if abs(S.marker_pos(ch, t) - ch['zone_center']) > ch['zone_width']:
                tap = t
                break
    backdate(r['id'], tap / 1000.0 + 0.05)
    u['last_strike'] = 0
    return S.h_mine_strike(u, {'id': r['id'], 'tap_ms': tap})

def t_accounts():
    a, ta = reg('Alice')
    try:
        reg('alice')
        raise AssertionError('duplicate name allowed')
    except B as e:
        assert e.code == 'name_taken'
    for bad in ('ab', 'has space', 'x' * 17):
        try:
            S.h_register({'username': bad, 'password': 'secret123'}, 'ip')
            raise AssertionError('bad name allowed: ' + bad)
        except B as e:
            assert e.code == 'bad_username'
    try:
        S.h_login({'username': 'Alice', 'password': 'wrong'}, 'ip')
        raise AssertionError('wrong password accepted')
    except B as e:
        assert e.code == 'bad_login'
    out = S.h_login({'username': 'ALICE', 'password': 'secret123'}, 'ip')
    assert S.session_user(out['token'])['uid'] == a['uid']
    assert a['balance'] == 25
    S.h_logout(a, {}, out['token'])
    assert S.session_user(out['token']) is None and S.session_user(ta) is not None
    assert S.DB['users'][a['uid']]['fair'] is not S.new_user('x')['fair']
    ledger_ok()
    return 'register, duplicate/invalid names, wrong password, case-insensitive login, logout, 25 PLS welcome'

def t_mining():
    u, _ = reg('Miner')
    veins = S.h_veins(u, {})['veins']
    assert veins[0]['unlocked'] and not veins[2]['unlocked'] and 'level' in veins[1]['locked_reason'].lower()
    try:
        S.h_mine_start(u, {'tier': 3})
        raise AssertionError('locked vein allowed')
    except B as e:
        assert e.code == 'vein_locked'
    r1 = strike(u, 1)
    assert r1['quality'] == 'perfect' and r1['damage'] == 6 and r1['ore_gained'] == 3 and not r1['cleared'], r1
    r2 = strike(u, 1)
    assert r2['cleared'] and r2['pls'] == 10 and r2['vein_hp'] == 12, r2
    assert u['ore']['coal'] == 6 and u['balance'] == 35
    rm = strike(u, 1, 'miss')
    assert rm['quality'] == 'miss' and rm['damage'] == 0 and rm['ore_gained'] == 0
    # timing that does not match the server clock is rejected
    r = S.h_mine_start(u, {'tier': 1})
    try:
        S.h_mine_strike(u, {'id': r['id'], 'tap_ms': 5000})
        raise AssertionError('future tap accepted')
    except B as e:
        assert e.code == 'bad_timing'
    # challenge can only be used once
    r = S.h_mine_start(u, {'tier': 1})
    backdate(r['id'], 1)
    u['last_strike'] = 0
    S.h_mine_strike(u, {'id': r['id'], 'tap_ms': 500})
    try:
        S.h_mine_strike(u, {'id': r['id'], 'tap_ms': 500})
        raise AssertionError('replayed challenge accepted')
    except B as e:
        assert e.code == 'no_challenge'
    ledger_ok()
    return 'locked tiers, perfect strike = 6 dmg/3 ore, 2 perfects clear a coal vein for 10 PLS, misses, clock and replay checks'

def t_levels_and_tiers():
    u, _ = reg('Climber')
    u['xp'] = 25 * 2 * 2   # level 3
    assert S.level_for(u['xp']) == 3
    assert S.h_veins(u, {})['veins'][1]['unlocked']
    u['xp'] = 25 * 7 * 7   # level 8
    v = S.h_veins(u, {})['veins'][2]
    assert not v['unlocked'] and 'pickaxe' in v['locked_reason'].lower()
    u['ore'].update({'iron': 50, 'coal': 50})
    give(u, 100)
    S.h_forge(u, {'recipe': 'iron_pickaxe'})
    assert S.h_veins(u, {})['veins'][2]['unlocked']
    r = strike(u, 3)
    assert r['damage'] == 6 + 1, r
    return 'level gates, pickaxe gate opens after forging, pickaxe adds damage'

def t_daily_and_antibot():
    u, _ = reg('Grinder')
    u['day_key'] = S.day_key()
    u['day_blocks'] = 30
    assert S.daily_mult(u) == 0.5
    u['vein_hp']['1'] = 1
    r = strike(u, 1)
    assert r['cleared'] and r['pls'] == 5, r
    u['day_blocks'] = 60
    u['vein_hp']['1'] = 1
    r = strike(u, 1)
    assert r['pls'] == 2, r
    b, _ = reg('Botty')
    for i in range(40):
        strike(b, 1)
    assert b['flagged']
    r = strike(b, 1)
    assert r['quality'] == 'good', r
    return 'PLS halves after 30 veins/day and quarters after 60; 37+ perfects in 40 strikes flags the account and caps strikes at good'

def t_forge_sinks():
    u, _ = reg('Smith')
    give(u, 1000)
    u['ore'].update({'iron': 100, 'coal': 100, 'crystal': 100, 'void': 100})
    burn0 = S.DB['accounts']['burn']
    S.h_forge(u, {'recipe': 'iron_gauntlets'})
    assert S.DB['accounts']['burn'] - burn0 == 40
    g = u['gear']['gauntlets']
    assert g['dur'] == 150
    try:
        S.h_repair(u, {'slot': 'gauntlets'})
        raise AssertionError('repair of undamaged gear')
    except B as e:
        assert e.code == 'not_damaged'
    for i in range(10):
        strike(u, 1)
    assert g['dur'] == 140
    bal = u['balance']
    out = S.h_repair(u, {'slot': 'gauntlets'})
    assert out['cost'] == 2 and u['balance'] == bal - 2 + 0 and g['dur'] == 150
    S.h_upgrade(u, {'slot': 'gauntlets'})
    assert g['stars'] == 1 and g['max_dur'] == 200
    g['dur'] = 0
    assert S.gear_effect(u, 'gauntlets') == 0
    try:
        S.h_forge(u, {'recipe': 'nope'})
        raise AssertionError
    except B as e:
        assert e.code == 'bad_recipe'
    ledger_ok()
    return 'forge burns PLS, durability wears per strike, repair cost, upgrade stars, broken gear gives no bonus'

def seq_play(u, cid, reached):
    """Play Rune Sequence round by round against the server (v5.1 reveals one round at a time)."""
    ch = S.CHALLENGES[cid]['challenge']
    for n in range(ch['start_len'], reached + 1):
        ch['seq_t'] -= 60
        out = S.h_skill_step(u, {'id': cid, 'entered': ch['runes'][:n]})
        assert out['correct'], out
    ch['seq_t'] -= 60
    S.h_skill_step(u, {'id': cid, 'entered': [(x + 1) % 4 for x in ch['runes'][:reached + 1]]})

def play(ch, how='good'):
    """Build a valid result + elapsed time for a skill challenge."""
    g = ch['game']
    if g == 'quickdraw':
        rts = ([230, 250, 210, -1, 300] if how == 'good' else [400, 420, 450, -1, -1])
        return {'reactions': rts}, sum(ch['delays']) + sum(r for r in rts if r > 0) + 200
    if g == 'sequence':
        reached = 9 if how == 'good' else 5
        need = sum(n * (ch['show_ms'] + ch['gap_ms']) for n in range(ch['start_len'], reached + 1))
        return {'reached': reached, '_steps': reached}, need + 2000
    hits = [{'hit': True, 'rt': 300 + (i * 37) % 80 - 40} for i in range(len(ch['targets']))] if how == 'good' else [{'hit': i % 2 == 0, 'rt': 500} for i in range(len(ch['targets']))]
    return {'hits': hits}, sum(t['delay'] for t in ch['targets']) + 12 * 1200

def t_practice():
    u, _ = reg('Practicer')
    out = []
    for g in ['quickdraw', 'sequence', 'sniper']:
        r = S.h_practice_start(u, {'game': g})
        res, el = play(r['challenge'])
        if g == 'sequence':
            seq_play(u, r['id'], res['_steps'])
        backdate(r['id'], el / 1000.0)
        s = S.h_practice_submit(u, {'id': r['id'], 'result': res})
        assert s['score'] > 0 and s['new_best'], s
        out.append('%s=%d' % (g, s['score']))
    # impossible results rejected
    r = S.h_practice_start(u, {'game': 'quickdraw'})
    backdate(r['id'], 30)
    try:
        S.h_practice_submit(u, {'id': r['id'], 'result': {'reactions': [50, 200, 200, 200, 200]}})
        raise AssertionError('50ms accepted')
    except B as e:
        assert e.code == 'impossible_reaction'
    r = S.h_practice_start(u, {'game': 'sequence'})
    s2 = S.h_practice_submit(u, {'id': r['id'], 'result': {'reached': 15}})
    assert s2['score'] == 0, s2          # v5.1: a claimed score without playing the rounds counts for nothing
    q = {x['id']: x for x in S.h_quests(u, {})['quests']}
    assert q['skill']['progress'] == 3
    # same seed -> same challenge
    assert S.make_challenge('sniper', 42) == S.make_challenge('sniper', 42)
    return ', '.join(out) + '; impossible/too-fast results rejected; identical seeds give identical challenges'

def run_duel(a, b, stake, a_how='good', b_how='weak'):
    ra = S.h_pvp_queue(a, {'game': 'sniper', 'stake': stake})
    assert ra['status'] == 'waiting'
    rb = S.h_pvp_queue(b, {'game': 'sniper', 'stake': stake})
    assert rb['status'] == 'matched'
    mid = rb['match']['id']
    for u, how in ((a, a_how), (b, b_how)):
        p = S.h_pvp_play(u, {'match_id': mid})
        res, el = play(p['challenge'], how)
        backdate(p['id'], el / 1000.0)
        S.h_pvp_submit(u, {'id': p['id'], 'result': res})
    return S.DB['matches'][mid]

def t_pvp():
    a, _ = reg('DuelA')
    b, _ = reg('DuelB')
    give(a, 200)
    give(b, 200)
    a0, b0, burn0 = a['balance'], b['balance'], S.DB['accounts']['burn']
    m = run_duel(a, b, 100)
    assert m['state'] == 'settled' and m['result']['winner'] == 'DuelA', m['result']
    assert a['balance'] == a0 - 100 + 190 and b['balance'] == b0 - 100, (a['balance'], b['balance'])
    assert S.DB['accounts']['burn'] - burn0 == 10 and S.DB['accounts']['escrow'] == 0
    assert a['elo']['sniper'] > 1200 > b['elo']['sniper'] and a['wins'] == 1 and b['losses'] == 1
    # both sides get the same challenge
    assert S.make_challenge('sniper', m['seed']) == S.make_challenge('sniper', m['seed'])
    # draw refunds both
    a1, b1 = a['balance'], b['balance']
    m = run_duel(a, b, 25, 'good', 'good')
    assert m['result']['reason'] == 'draw' and a['balance'] == a1 and b['balance'] == b1
    # replaying a duel = forfeit
    S.h_pvp_queue(a, {'game': 'quickdraw', 'stake': 10})
    mid = S.h_pvp_queue(b, {'game': 'quickdraw', 'stake': 10})['match']['id']
    S.h_pvp_play(a, {'match_id': mid})
    try:
        S.h_pvp_play(a, {'match_id': mid})
        raise AssertionError('replay allowed')
    except B as e:
        assert e.code == 'duel_forfeited'
    p = S.h_pvp_play(b, {'match_id': mid})
    res, el = play(p['challenge'], 'weak')
    backdate(p['id'], el / 1000.0)
    S.h_pvp_submit(b, {'id': p['id'], 'result': res})
    assert S.DB['matches'][mid]['result']['winner'] == 'DuelB'
    # explicit forfeit settles at once when the other side already played
    S.h_pvp_queue(a, {'game': 'quickdraw', 'stake': 10})
    mid = S.h_pvp_queue(b, {'game': 'quickdraw', 'stake': 10})['match']['id']
    p = S.h_pvp_play(b, {'match_id': mid})
    res, el = play(p['challenge'], 'weak')
    backdate(p['id'], el / 1000.0)
    S.h_pvp_submit(b, {'id': p['id'], 'result': res})
    S.h_pvp_play(a, {'match_id': mid})
    S.h_pvp_forfeit(a, {'match_id': mid})
    assert S.DB['matches'][mid]['result']['winner'] == 'DuelB'
    # timeout: only one player plays
    S.h_pvp_queue(a, {'game': 'sequence', 'stake': 10})
    mid = S.h_pvp_queue(b, {'game': 'sequence', 'stake': 10})['match']['id']
    p = S.h_pvp_play(a, {'match_id': mid})
    res, el = play(p['challenge'])
    backdate(p['id'], el / 1000.0)
    S.h_pvp_submit(a, {'id': p['id'], 'result': res})
    S.DB['matches'][mid]['deadline'] = time.time() - 1
    S.pvp_housekeeping()
    assert S.DB['matches'][mid]['result']['reason'] == 'opponent did not play in time'
    # queue cancel refunds; busy players can't double queue
    bal = a['balance']
    S.h_pvp_queue(a, {'game': 'quickdraw', 'stake': 50})
    try:
        S.h_pvp_queue(a, {'game': 'sniper', 'stake': 10})
        raise AssertionError('double queue')
    except B as e:
        assert e.code == 'already_queued'
    S.h_pvp_cancel(a, {})
    assert a['balance'] == bal
    # direct challenge: decline refunds, accept creates a match
    inv = S.h_pvp_challenge(a, {'username': 'duelb', 'game': 'quickdraw', 'stake': 25})['invite_id']
    assert S.h_pvp_status(b, {})['invites'][0]['from'] == 'DuelA'
    S.h_pvp_respond(b, {'invite_id': inv, 'accept': False})
    assert a['balance'] == bal
    inv = S.h_pvp_challenge(a, {'username': 'DuelB', 'game': 'quickdraw', 'stake': 25})['invite_id']
    r = S.h_pvp_respond(b, {'invite_id': inv, 'accept': True})
    assert r['status'] == 'matched' and S.DB['accounts']['escrow'] == 50
    try:
        S.h_pvp_queue(a, {'game': 'quickdraw', 'stake': 999})
        raise AssertionError
    except B as e:
        assert e.code in ('bad_stake', 'finish_your_duel')
    ledger_ok()
    return 'matchmaking, same seed both sides, winner gets pot minus 5% (burned), ELO moves, draws refund, replay = forfeit, timeout win, cancel refund, challenge decline/accept'

def t_tournament():
    os.environ['PULSE_FAKE_WEEK'] = '2099-W01'
    players = [reg('Tour%d' % i)[0] for i in range(4)]
    for i, u in enumerate(players):
        give(u, 100)
        S.h_t_enter(u, {'game': 'sequence'})
        r = S.h_t_start(u, {'game': 'sequence'})
        ch = r['challenge']
        reached = 4 + i
        need = sum(n * (ch['show_ms'] + ch['gap_ms']) for n in range(ch['start_len'], reached + 1))
        seq_play(u, r['id'], reached)
        backdate(r['id'], need / 1000.0 + 1)
        S.h_t_submit(u, {'id': r['id'], 'result': {'reached': reached}})
    t = S.tournament('sequence')
    assert t['pot'] == 4 * 45 and S.DB['accounts']['pots'] >= 180
    try:
        S.h_t_enter(players[0], {'game': 'sequence'})
        raise AssertionError('re-entry with attempts left')
    except B as e:
        assert e.code == 'already_entered'
    bals = [u['balance'] for u in players]
    os.environ['PULSE_FAKE_WEEK'] = '2099-W02'
    S.settle_tournaments()
    assert t['settled']
    won = [players[i]['balance'] - bals[i] for i in range(4)]
    assert won == [0, 36, 54, 90], won
    assert t['payouts'][0]['username'] == 'Tour3'
    os.environ.pop('PULSE_FAKE_WEEK')
    ledger_ok()
    return 'entry 50 PLS (10% burned), 5 attempts, best score counts, week rollover pays 50/30/20 of a 180 PLS pot'

def t_luck():
    u, _ = reg('Lucky')
    give(u, 100000)
    fair = S.h_fair(u, {})['fair']
    rolls = []
    for i in range(5):
        r = S.h_flip(u, {'bet': 10, 'pick': 'teal'})
        rolls.append((r['nonce'], r['roll']))
    rev = S.h_fair_seed(u, {'client_seed': 'myseed'})['revealed']
    assert hashlib.sha256(rev['server_seed'].encode()).hexdigest() == fair['server_hash']
    for nonce, roll in rolls:
        assert abs(S.verify_float(rev['server_seed'], rev['client_seed'], nonce) - roll) < 1e-6
    # dice payout math + long-run house edge
    wag, paid = 0, 0
    for i in range(20000):
        r = S.h_dice(u, {'bet': 10, 'target': 50})
        wag += 10
        paid += r['payout']
    rtp = paid / float(wag)
    assert 0.955 < rtp < 0.985, rtp
    for bad in ({'bet': 0, 'target': 50}, {'bet': 10, 'target': 99}, {'bet': 501, 'target': 50}):
        try:
            S.h_dice(u, bad)
            raise AssertionError('bad bet accepted %s' % bad)
        except B:
            pass
    # cave-in
    assert abs(S.cavein_mult(3, 1) - 0.97 * 25 / 22) < 1e-3
    g = S.h_cave_start(u, {'bet': 20, 'caves': 3})['game']
    safe = [c for c in range(25) if c not in u['cavein']['cells']]
    assert len(u['cavein']['cells']) == 3
    S.h_cave_reveal(u, {'cell': safe[0]})
    S.h_cave_reveal(u, {'cell': safe[1]})
    bal = u['balance']
    out = S.h_cave_cashout(u, {})
    assert abs(out['payout'] - 20 * S.cavein_mult(3, 2)) < 1.0 and u['balance'] == bal + out['payout'] and u['cavein'] is None
    S.h_cave_start(u, {'bet': 20, 'caves': 10})
    cave = u['cavein']['cells'][0]
    out = S.h_cave_reveal(u, {'cell': cave})
    assert out['hit'] and out['payout'] == 0 and u['cavein'] is None and len(out['game']['cave_cells']) == 10
    # cave cells are reproducible from the revealed seed
    S.h_fair_seed(u, {})
    fair = S.h_fair(u, {})['fair']
    S.h_cave_start(u, {'bet': 5, 'caves': 4})
    cells = list(u['cavein']['cells'])
    nonce = u['cavein']['nonce']
    S.h_cave_reveal(u, {'cell': cells[0]})
    rev = S.h_fair_seed(u, {})['revealed']
    vals = [S.verify_float(rev['server_seed'], rev['client_seed'], nonce, i) for i in range(24)]
    grid = list(range(25))
    for i in range(24, 0, -1):
        j = int(vals[24 - i] * (i + 1))
        grid[i], grid[j] = grid[j], grid[i]
    assert sorted(grid[:4]) == cells
    ledger_ok()
    return 'fair seeds verify (hash commit + HMAC rolls), dice RTP over 20k bets = %.3f (3%% edge), bet limits, cave-in multipliers, cashout, bust, reproducible cave map' % rtp

def t_social():
    a, _ = reg('SocA')
    b, _ = reg('SocB')
    c, _ = reg('SocC')
    give(a, 1000)
    S.h_send(a, {'channel': 'lobby', 'text': 'hello miners'})
    assert S.h_history(None, {'channel': ['lobby']})['messages'][-1]['text'] == 'hello miners'
    S.h_friend_request(a, {'username': 'socb'})
    pid = S.h_friends(b, {})['pending'][0]['id']
    S.h_friend_respond(b, {'id': pid, 'accept': True})
    ch = S.h_friends(a, {})['friends'][0]['channel']
    a['last_chat'] = 0
    S.h_send(a, {'channel': ch, 'text': 'secret'})
    assert S.h_history(b, {'channel': [ch]})['messages'][0]['text'] == 'secret'
    for who in (c, None):
        try:
            S.h_history(who, {'channel': [ch]})
            raise AssertionError('DM leak')
        except B as e:
            assert e.code == 'channel_forbidden'
    S.h_crew_create(a, {'name': 'Deep Diggers', 'tag': 'dig'})
    assert a['balance'] == 1025 - 300
    S.h_crew_join(b, {'name': 'deep diggers'})
    a['last_chat'] = 0
    S.h_send(a, {'channel': 'crew', 'text': 'crew only'})
    assert S.h_history(b, {'channel': ['crew']})['messages'][0]['text'] == 'crew only'
    try:
        S.h_history(c, {'channel': ['crew']})
        raise AssertionError('crew leak')
    except B as e:
        assert e.code == 'channel_forbidden'
    S.h_crew_leave(a, {})
    assert S.DB['crews'][b['crew']]['owner'] == b['uid']
    # shop + appearance
    try:
        S.h_appearance(a, {'appearance': {'shirt': 5}})
        raise AssertionError('unowned cosmetic')
    except B as e:
        assert e.code == 'not_owned'
    S.h_buy(a, {'item': 'shirt_5'})
    assert S.h_appearance(a, {'appearance': {'shirt': 5, 'skin': 3}})['appearance']['shirt'] == 5
    lb = S.h_leaderboard(a, {'board': ['level']})
    assert lb['top'] and lb['me']
    ledger_ok()
    return 'lobby, friend DM privacy, crew create (300 PLS burn)/join/chat privacy/leave, shop + appearance checks, leaderboards'

def t_persistence_file():
    S.flush()
    S2 = load_server(DATA)
    assert len(S2.DB['users']) == len(S.DB['users']) and S2.DB['accounts'] == S.DB['accounts']
    circ = sum(x['balance'] for x in S2.DB['users'].values())
    assert circ + sum(S2.DB['accounts'].values()) == 0
    return '%d accounts and all balances reload from disk; ledger still sums to zero' % len(S2.DB['users'])

def t_persistence_pg():
    # Fake psycopg2 backed by SQLite, to exercise the Postgres code path.
    db_path = tempfile.mktemp(suffix='.sqlite')
    fake = types.ModuleType('psycopg2')
    class Cur:
        def __init__(self, conn): self.c = conn.cursor()
        def execute(self, sql, params=()): self.c.execute(sql.replace('%s', '?'), params)
        def fetchall(self): return self.c.fetchall()
        def close(self): pass
    class Conn:
        def __init__(self, url): self.db = sqlite3.connect(db_path, isolation_level=None)
        def cursor(self): return Cur(self.db)
        autocommit = False
    fake.connect = lambda url: Conn(url)
    sys.modules['psycopg2'] = fake
    S3 = load_server(tempfile.mktemp(suffix='.json'), {'DATABASE_URL': 'postgres://fake'})
    assert S3.STORE.name == 'postgres'
    S3.h_register({'username': 'PgUser', 'password': 'secret123'}, 'ip')
    S3.flush()
    S4 = load_server(tempfile.mktemp(suffix='.json'), {'DATABASE_URL': 'postgres://fake'})
    assert 'pguser' in S4.DB['names']
    os.environ.pop('DATABASE_URL', None)
    del sys.modules['psycopg2']
    return 'state saved to and reloaded from the database code path (Postgres SQL run against a stand-in)'

for name, fn in [('accounts and sessions', t_accounts), ('skill mining', t_mining), ('levels and vein tiers', t_levels_and_tiers),
                 ('daily limits and anti-bot', t_daily_and_antibot), ('forge, durability, repair, upgrade', t_forge_sinks),
                 ('practice skill games', t_practice), ('PvP staking duels', t_pvp), ('weekly tournaments', t_tournament),
                 ('luck games and provable fairness', t_luck), ('chat, friends, crews, shop', t_social),
                 ('file persistence', t_persistence_file), ('database persistence', t_persistence_pg)]:
    check(name, fn)

# ---------------------------------------------------------------------------
# PART 2: real HTTP server
# ---------------------------------------------------------------------------
def http_part():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    env = dict(os.environ, PORT=str(port), PULSE_DATA_FILE=tempfile.mktemp(suffix='.json'), PULSE_AUTH_LIMIT='1000')
    env.pop('DATABASE_URL', None)
    proc = subprocess.Popen([sys.executable, os.path.join(HERE, 'server.py')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    base = 'http://127.0.0.1:%d' % port

    def req(method, path, body=None, token=None):
        data = json.dumps(body).encode() if body is not None else None
        h = {'Content-Type': 'application/json'}
        if token:
            h['Authorization'] = 'Bearer ' + token
        r = urllib.request.Request(base + path, data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(r, timeout=10) as x:
                return x.status, json.loads(x.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())
    try:
        for _ in range(100):
            try:
                if req('GET', '/health')[0] == 200:
                    break
            except Exception:
                time.sleep(0.05)
        out = []
        st, h = req('GET', '/health')
        assert st == 200 and h['version'] == 5.5
        st, r = req('POST', '/auth/register', {'username': 'HttpHero', 'password': 'secret123'})
        assert st == 200
        tok = r['token']
        assert req('GET', '/me')[0] == 401
        st, me = req('GET', '/me', token=tok)
        assert st == 200 and me['profile']['balance'] == 25
        # a real timed strike through HTTP
        st, r = req('POST', '/mine/start', {'tier': 1}, tok)
        ch = r['challenge']
        tap = perfect_tap(ch)
        time.sleep(tap / 1000.0 + 0.05)
        st, s1 = req('POST', '/mine/strike', {'id': r['id'], 'tap_ms': tap}, tok)
        assert st == 200 and s1['quality'] == 'perfect', s1
        out.append('real-time perfect strike')
        st, r = req('POST', '/luck/flip', {'bet': 5, 'pick': 'amber'}, tok)
        assert st == 200 and r['result'] in ('teal', 'amber')
        st, r = req('POST', '/practice/start', {'game': 'quickdraw'}, tok)
        assert st == 200 and len(r['challenge']['delays']) == 5
        st, r = req('GET', '/leaderboard?board=miners')
        assert st == 200
        st, r = req('GET', '/chat/history?channel=lobby')
        assert st == 200
        for path in ('/quests', '/pvp/status', '/tournaments', '/luck/fair', '/friends', '/crew', '/ledger', '/mine/veins', '/luck/cavein'):
            st, r = req('GET', path, token=tok)
            assert st == 200 and r['ok'], (path, r)
        st, r = req('GET', '/economy')
        assert r['ledger_check'] is True
        st, r = req('POST', '/forge', {'recipe': 'iron_pickaxe'}, tok)
        assert st == 400 and r['error'].startswith('need_')
        st, r = req('GET', '/nope')
        assert st == 404
        st, r = req('GET', '/leaderboard?board=bogus')
        assert st == 400
        out.append('every GET page answers; errors come back as clean JSON')
        return '; '.join(out)
    finally:
        proc.terminate()
        proc.wait(timeout=5)

check('HTTP server end to end', http_part)

for status, name, detail in RESULTS:
    print('%s: %s - %s' % (status, name, detail))
print('\nTOTAL %d PASS / %d FAIL' % (sum(r[0] == 'PASS' for r in RESULTS), sum(r[0] == 'FAIL' for r in RESULTS)))
sys.exit(1 if any(r[0] == 'FAIL' for r in RESULTS) else 0)
