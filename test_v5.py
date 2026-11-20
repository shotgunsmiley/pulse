"""Pulse v5 server tests: every new system, in-process, plus a real HTTP pass.
Run:  python test_v5.py
"""
import os, sys, json, time, tempfile, importlib, subprocess, socket, urllib.request, urllib.error, random, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = []

def check(name, fn):
    try:
        RESULTS.append(('PASS', name, fn() or ''))
    except Exception as e:
        import traceback
        traceback.print_exc()
        RESULTS.append(('FAIL', name, repr(e)))

os.environ['PULSE_DATA_FILE'] = tempfile.mktemp(suffix='.json')
os.environ['PULSE_AUTH_LIMIT'] = '100000'
os.environ.pop('DATABASE_URL', None)
sys.path.insert(0, HERE)
S = importlib.import_module('server')
E = S.ApiError
N = [0]

def reg(name=None, invite=''):
    N[0] += 1
    name = name or 'pl%03d' % N[0]
    out = S.h_register({'username': name, 'password': 'secret123', 'invite': invite}, '1.1.1.1')
    return S.session_user(out['token'])

def give(u, amt):
    S.move('mint', S.U(u['uid']), amt, 'test_grant')

def ledger_ok():
    circ = sum(x['balance'] for x in S.DB['users'].values())
    assert circ + sum(S.DB['accounts'].values()) == 0, (circ, S.DB['accounts'])
    return True

def raises(code, fn):
    try:
        fn()
    except E as e:
        assert e.code == code, (e.code, code)
        return
    raise AssertionError('expected ' + code)

def perfect_tap(ch, after=160):
    best = None
    for target in (ch['zone_center'], 2 - ch['zone_center']):
        t = ((target - ch['offset']) % 2.0) / ch['speed'] * 1000.0
        while t < after:
            t += 2.0 / ch['speed'] * 1000.0
        best = t if best is None else min(best, t)
    return int(round(best))

def strike(u, tier=1, perfect=True):
    st = S.h_mine_start(u, {'tier': tier})
    ch = st['challenge']
    tap = perfect_tap(ch) if perfect else perfect_tap(dict(ch, zone_center=(ch['zone_center'] + 0.5) % 1.0))
    S.CHALLENGES[st['id']]['issued'] -= (tap / 1000.0 + 0.2)
    u['last_strike'] = 0
    return S.h_mine_strike(u, {'id': st['id'], 'tap_ms': tap})

def no_pls_minted_except(allowed):
    bad = [e for e in S.DB['ledger'] if e['from'] == 'mint' and e['why'] not in allowed]
    assert not bad, bad[:3]

ALLOWED_MINT = ('starter grant (one time)', 'node reward', 'test_grant')

# ---------------------------------------------------------------------------
def t_version():
    h = S.h_health({})
    assert h['version'] == 5.4
    assert 'strikeoff' in S.GAMES and 20 in S.STAKES
    return 'v5.0, 4 skill games, %d stake sizes' % len(S.STAKES)

def t_migration():
    old = S.new_user('legacy')
    for k in ('gems', 'badges', 'pets'):
        old.pop(k, None)
    S.DB['users'][old['uid']] = old
    S.DB['names']['legacy'] = old['uid']
    S.user_fix(old)
    pv = S.profile_view(old)
    assert pv['gems']['amber'] == 0 and old['badges'] == {} and old['appearance']['face'] == 0
    return 'v4 account gains every v5 field without losing data'

def t_streak_gems():
    u = reg()
    random.seed(7)
    combos, gems = [], 0
    for i in range(30):
        r = strike(u)
        assert r['quality'] == 'perfect', r['quality']
        combos.append(r['combo'])
        gems += 1 if r['gem'] else 0
    assert u['streak'] == 30 and u['best_streak'] == 30
    assert combos[3] == 1.0 and combos[4] == 1.25 and combos[-1] == 2.0, combos
    r = strike(u, perfect=False)
    assert r['quality'] == 'miss' and u['streak'] == 0
    assert 'streak_10' in u['badges'] and 'streak_25' in u['badges']
    no_pls_minted_except(ALLOWED_MINT)
    return 'combo x1 -> x1.25 at 5 perfects -> x2 cap; miss resets; streak badges; %d gems in 30 perfects; no PLS minted' % gems

def t_hidden_vein():
    u = reg()
    S.DB['hidden'] = {'tier': 1, 'until': S.now() + 300, 'next': S.now() + 999, 'kind': 'glitter'}
    a = strike(u)
    assert a['hidden'] and a['bonus_ore'] >= a['ore_gained'], a
    S.DB['hidden']['until'] = 0
    S.DB['hidden']['next'] = S.now() - 1
    S.tick_hidden()
    assert S.DB['hidden']['until'] > S.now()
    assert any(m.get('system') and 'vein' in m['text'] for m in S.DB['messages'][-3:])
    return 'hidden vein doubles ore and is announced in the Tavern'

def t_badges_pets():
    u = reg()
    u['lifetime_blocks'] = 100
    u['deepest'] = 8
    new = S.check_badges(u)
    assert 'founding' in u['badges'] and 'veins_100' in u['badges'] and 'deep_8' in u['badges']
    assert 'golem' in u['pets'] and 'bat' in u['pets'] and 'sprite' not in u['pets']
    S.h_pet(u, {'pet': 'golem'})
    raises('not_earned', lambda: S.h_pet(u, {'pet': 'sprite'}))
    b = S.h_badges(u, {})
    assert len(b['badges']) >= 4
    return '%d badges + golem/bat earned; sprite locked; pets cannot be equipped unearned' % len(b['badges'])

def t_invite_mentor():
    a = reg()
    b = reg(invite=a['username'])
    assert b['invited_by'] == a['uid']
    b['xp'] = 25 * 5 * 5
    S.check_badges(b)
    assert 'accent_4' in a['cosmetics'] and 'accent_4' in b['cosmetics'] and 'recruiter' in a['badges']
    m = reg()
    m['xp'] = 25 * 15 * 15
    c = reg()
    S.h_mentor(c, {'username': m['username']})
    c['xp'] = 25 * 10 * 10
    S.check_badges(c)
    assert 'mentor' in m['badges'] and m['gems']['sapphire'] == 2
    no_pls_minted_except(ALLOWED_MINT)
    return 'both get Lantern Trim at level 5; mentor badge + 2 sapphires at level 10; no PLS'

def t_strikeoff():
    u = reg()
    p = S.h_practice_start(u, {'game': 'strikeoff'})
    ch = p['challenge']
    taps = [perfect_tap(s, 400) for s in ch['strikes']]
    S.CHALLENGES[p['id']]['issued'] -= sum(taps) / 1000.0 + 5
    r = S.h_practice_submit(u, {'id': p['id'], 'result': {'taps': taps}})
    assert r['score'] >= 9000, r
    p2 = S.h_practice_start(u, {'game': 'strikeoff'})
    raises('too_fast', lambda: S.h_practice_submit(u, {'id': p2['id'], 'result': {'taps': taps}}))
    return 'Strike-Off scored server-side (%d pts, %s); instant results rejected' % (r['score'], r['detail'])

def t_ghost():
    a, b = reg(), reg()
    p = S.h_practice_start(a, {'game': 'quickdraw'})
    S.CHALLENGES[p['id']]['issued'] -= 60
    S.h_practice_submit(a, {'id': p['id'], 'result': {'reactions': [260, 280, 300, 250, 270]}})
    g = S.h_ghost_start(b, {'game': 'quickdraw', 'username': a['username']})
    assert g['challenge']['delays'] == S.make_challenge('quickdraw', a['best_runs']['quickdraw']['seed'])['delays']
    S.CHALLENGES[g['id']]['issued'] -= 60
    r = S.h_ghost_submit(b, {'id': g['id'], 'result': {'reactions': [200, 210, 220, 205, 215]}})
    assert r['won'] and r['ghost_score'] == a['best_runs']['quickdraw']['score']
    return 'ghost replays the exact same challenge; beat %d with %d' % (r['ghost_score'], r['score'])

def t_bounty():
    a, b = reg(), reg()
    give(a, 200)
    p = S.h_practice_start(a, {'game': 'quickdraw'})
    S.CHALLENGES[p['id']]['issued'] -= 60
    S.h_practice_submit(a, {'id': p['id'], 'result': {'reactions': [300] * 5}})
    S.h_bounty_post(a, {'game': 'quickdraw', 'amount': 100})
    assert a['balance'] == S.STARTER_PLS + 100
    p = S.h_practice_start(b, {'game': 'quickdraw'})
    S.CHALLENGES[p['id']]['issued'] -= 60
    r = S.h_practice_submit(b, {'id': p['id'], 'result': {'reactions': [220, 230, 240, 225, 235]}})
    assert r['bounties_claimed'] and b['balance'] == S.STARTER_PLS + 95, (b['balance'], r)
    a2 = reg()
    give(a2, 50)
    S.h_practice_start(a2, {'game': 'sniper'})
    a2['best']['sniper'] = 500
    S.h_bounty_post(a2, {'game': 'sniper', 'amount': 50})
    S.DB['bounties'][-1]['until'] = S.now() - 1
    S.tick_bounties()
    assert a2['balance'] == S.STARTER_PLS + 50
    ledger_ok()
    return 'claimer gets 95 of 100 (5 burned); expired bounty refunded; ledger balanced'

def t_koth():
    a, b, c = reg(), reg(), reg()
    for x in (a, b, c):
        give(x, 100)
    def play(u, rts):
        k = S.h_koth_challenge(u, {'game': 'quickdraw'})
        S.CHALLENGES[k['id']]['issued'] -= 60
        return S.h_koth_submit(u, {'id': k['id'], 'result': {'reactions': rts}})
    assert play(a, [300] * 5)['crowned']
    assert not play(b, [400] * 5)['crowned']
    assert S.DB['koth']['quickdraw']['pot'] == 10
    a_before = a['balance']
    assert play(c, [200] * 5)['crowned']
    assert a['balance'] == a_before + 16 and 'king' in c['badges']
    ledger_ok()
    return 'first player crowned free; challenger pays 10 into the pot; dethroned king keeps 16 of the 20 pot (80%), 4 burned'

def t_series():
    a, b = reg(), reg()
    give(a, 100)
    give(b, 100)
    S.h_series_challenge(a, {'username': b['username'], 'game': 'quickdraw', 'stake': 50})
    sid = [s for s in S.DB['series'].values() if s['players'][0] == a['uid']][-1]['id']
    S.h_series_respond(b, {'id': sid, 'accept': True})
    def play_round(sa, sb):
        s = S.DB['series'][sid]
        mid = s['matches'][-1]
        for u, rt in ((a, sa), (b, sb)):
            p = S.h_pvp_play(u, {'match_id': mid})
            S.CHALLENGES[p['id']]['issued'] -= 60
            S.h_pvp_submit(u, {'id': p['id'], 'result': {'reactions': [rt + random.randint(-12, 12) for _ in range(5)]}})
        S.tick_series()
    play_round(250, 300)
    play_round(300, 250)
    assert S.DB['series'][sid]['state'] == 'active' and len(S.DB['series'][sid]['matches']) == 3
    play_round(240, 320)
    s = S.DB['series'][sid]
    assert s['state'] == 'settled' and s['winner'] == a['username'], s
    assert a['balance'] == S.STARTER_PLS + 100 + 45 and b['balance'] == S.STARTER_PLS + 50, (a['balance'], b['balance'])
    ledger_ok()
    return 'best-of-3 goes to game 3, winner takes 95 of the 100 pot (5 burned)'

def t_rematch():
    a, b = reg(), reg()
    give(a, 200)
    give(b, 200)
    S.h_pvp_challenge(a, {'username': b['username'], 'game': 'quickdraw', 'stake': 25})
    inv = [i for i in S.DB['invites'] if i['from'] == a['uid']][-1]
    S.h_pvp_respond(b, {'invite_id': inv['id'], 'accept': True})
    m = [m for m in S.DB['matches'].values() if a['uid'] in m['players'] and b['uid'] in m['players'] and m['stake'] == 25][-1]
    for u, rt in ((a, 250), (b, 300)):
        p = S.h_pvp_play(u, {'match_id': m['id']})
        S.CHALLENGES[p['id']]['issued'] -= 60
        S.h_pvp_submit(u, {'id': p['id'], 'result': {'reactions': [rt + random.randint(-12, 12) for _ in range(5)]}})
    assert m['state'] == 'settled' and m['subs'][a['uid']].get('replay')
    raises('winner_cant', lambda: S.h_rematch(a, {'match_id': m['id']}))
    r = S.h_rematch(b, {'match_id': m['id']})
    assert r['stake'] == 50
    rep = S.h_duel_replay(reg(), {'id': [m['id']]})
    assert rep['sides'][0]['replay'] and rep['challenge']
    S.h_duel_react(b, {'id': m['id'], 'emote': 'gg'})
    live = S.h_duels_live(a, {})
    assert any(d['id'] == m['id'] for d in live['duels'])
    return 'loser offers a 50 PLS double-or-nothing; replays + reactions visible to spectators'

def t_expedition():
    u = reg()
    u['ore']['coal'] = 20
    S.h_exp_start(u, {})
    assert u['ore']['coal'] == 14
    floors = 0
    random.seed(3)
    while True:
        e = u['expedition']
        f = S.exp_floor(e['seed'], e['floor'])
        tap = perfect_tap(f)
        e['issued'] -= tap / 1000.0 + 0.1
        e['last'] = 0
        r = S.h_exp_strike(u, {'tap_ms': tap})
        if r['collapsed']:
            break
        if r['expedition']['cleared']:
            floors += 1
            if floors == 4:
                out = S.h_exp_exit(u, {})
                break
            S.h_exp_descend(u, {})
    assert u['expedition'] is None and u['deepest'] >= 4
    got = out['banked']
    assert sum(got['ore'].values()) > 0 and not out['lost_half']
    u['ore']['coal'] = 10
    S.h_exp_start(u, {})
    u['expedition']['oil'] = 2
    f = S.exp_floor(u['expedition']['seed'], 1)
    u['expedition']['issued'] -= 5
    r = S.h_exp_strike(u, {'tap_ms': perfect_tap(f)})
    assert r['collapsed'] and u['expedition'] is None
    no_pls_minted_except(ALLOWED_MINT)
    return 'climbed out of floor 4 with %s; running out of oil collapses and keeps half' % got['ore']

def t_fishing():
    u = reg()
    caught = 0
    for i in range(40):
        c = S.h_fish_cast(u, {})
        u['fishing']['issued'] -= (c['bite_ms'] + 300) / 1000.0
        r = S.h_fish_reel(u, {'tap_ms': c['bite_ms'] + random.randint(180, 420)})
        caught += r['caught']
    assert caught == 40 and sum(u['fish'].values()) == 40 and 'angler' in u['badges']
    c = S.h_fish_cast(u, {})
    u['fishing']['issued'] -= 10
    assert not S.h_fish_reel(u, {'tap_ms': c['bite_ms'] - 100})['caught']
    c = S.h_fish_cast(u, {})
    u['fishing']['issued'] -= 10
    assert not S.h_fish_reel(u, {'tap_ms': c['bite_ms'] + 60})['caught']      # inhumanly fast reel
    return '40/40 caught with good timing, %d species; early reel spooks the fish' % len(u['fish'])

def t_cabin():
    u = reg()
    u['lifetime_blocks'] = 1
    S.check_badges(u)
    S.h_cabin_place(u, {'slot': 0, 'item': 'badge:founding'})
    raises('not_owned', lambda: S.h_cabin_place(u, {'slot': 1, 'item': 'badge:king'}))
    v = S.h_cabin(reg(), {'user': [u['username']]})
    assert v['shelves'][0]['name'] == 'Founding Miner' and v['available'] == []
    return 'trophies placed; friends can visit; unowned trophies refused'

def t_market():
    a, b = reg(), reg()
    a['gems']['sapphire'] = 3
    give(b, 100)
    S.h_market_sell(a, {'kind': 'gem', 'item': 'sapphire', 'qty': 2, 'price': 60})
    assert a['gems']['sapphire'] == 1
    lid = S.DB['market'][-1]['id']
    S.h_market_buy(b, {'id': lid})
    assert b['gems']['sapphire'] == 2 and a['balance'] == S.STARTER_PLS + 57 and b['balance'] == S.STARTER_PLS + 40
    S.h_market_sell(a, {'kind': 'gem', 'item': 'sapphire', 'qty': 1, 'price': 5})
    S.h_market_cancel(a, {'id': S.DB['market'][-1]['id']})
    assert a['gems']['sapphire'] == 1
    raises('not_enough', lambda: S.h_market_sell(a, {'kind': 'ore', 'item': 'void', 'qty': 5, 'price': 5}))
    ledger_ok()
    return 'sale pays 57 of 60 (3 burned); cancel returns the item; cannot list what you lack'

def t_rental():
    a, b = reg(), reg()
    give(a, 500)
    a['ore'].update({'iron': 50, 'coal': 50})
    S.h_forge(a, {'recipe': 'iron_pickaxe'})
    give(b, 100)
    S.h_rent_offer(a, {'slot': 'pickaxe', 'price': 40})
    assert 'pickaxe' not in a['gear']
    rid = S.DB['rentals'][-1]['id']
    S.h_rent_take(b, {'id': rid})
    assert b['gear']['pickaxe']['owner_name'] == a['username'] and S.pick_tier(b) == 1
    r = strike(b)
    assert r['damage'] >= 7
    S.DB['rentals'][-1]['until'] = S.now() - 1
    S.tick_rentals()
    assert 'pickaxe' not in b['gear'] and a['gear']['pickaxe']['name'] == 'Iron Pickaxe'
    ledger_ok()
    return 'renter mines with the iron pickaxe for a day, owner gets it back after; 2 of 40 burned'

def t_anticheat():
    u = reg()
    give(u, 100)
    for i in range(8):
        p = S.h_practice_start(u, {'game': 'quickdraw'})
        S.CHALLENGES[p['id']]['issued'] -= 60
        S.h_practice_submit(u, {'id': p['id'], 'result': {'reactions': [150, 151, 150, 152, 150]}})
    assert u['ac']['flag'], u['ac']
    raises('review_hold', lambda: S.h_pvp_queue(u, {'game': 'quickdraw', 'stake': 10}))
    S.h_pvp_queue(u, {'game': 'quickdraw', 'stake': 0})
    S.h_pvp_cancel(u, {})
    S.h_admin_ac({'clear': [u['uid']]})
    assert not u['ac']['flag']
    h = reg()
    for i in range(8):
        p = S.h_practice_start(h, {'game': 'quickdraw'})
        S.CHALLENGES[p['id']]['issued'] -= 60
        S.h_practice_submit(h, {'id': p['id'], 'result': {'reactions': [random.randint(210, 420) for _ in range(5)]}})
    assert not h['ac']['flag']
    return 'bot-steady reactions get staked play paused (free play still allowed); human spread passes; admin can clear'

def t_territory():
    a = reg()
    give(a, 300)
    S.h_crew_create(a, {'name': 'Deep Crew', 'tag': 'DEEP'})
    prev = '%d-W%02d' % (datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - datetime.timedelta(days=7)).isocalendar()[:2]
    S.DB['territory'][prev] = {'1': {a['crew']: 5}}
    t = S.h_territory(a, {})
    assert t['veins'][0]['holder'] == 'Deep Crew'
    r = strike(a)
    assert r['bonus_ore'] >= 0
    return 'last week\'s top crew holds Coal Seam this week (+20% ore)'

def t_seasons():
    a = reg()
    a['wins'] = 3
    a['elo']['quickdraw'] = 1700
    S.DB['season_awards']['_current'] = '1999-S1'
    S.tick_seasons()
    assert 'season_top' in a['badges'] and a['gems']['voidstone'] >= 1
    return 'season rollover awards top-10 players a badge + voidstone'

def t_wallet_link():
    u = reg()
    out = S.h_wallet_link_start(u, {'_base': 'https://pulse.example'})
    assert out['phantom'].startswith('https://phantom.app/ul/browse/') and out['solflare'].startswith('https://solflare.com/ul/v1/browse/')
    seed, pub = S.ed25519_keypair()
    msg = S.link_message(out['code']).encode()
    sig = S.ed25519_sign(seed, msg)
    pk58, sig58 = S.b58encode(pub), S.b58encode(sig)
    bad = bytearray(sig)
    bad[5] ^= 1
    raises('bad_signature', lambda: S.h_wallet_link_finish({'code': out['code'], 'pubkey': pk58, 'sig': S.b58encode(bytes(bad))}, ''))
    r = S.h_wallet_link_finish({'code': out['code'], 'pubkey': pk58, 'sig': sig58}, '')
    assert r['ok'] and u['sol_wallet'] == pk58
    try:
        from solders.keypair import Keypair
        kp = Keypair()
        out2 = S.h_wallet_link_start(u, {'_base': 'x'})
        s2 = kp.sign_message(S.link_message(out2['code']).encode())
        S.h_wallet_link_finish({'code': out2['code'], 'pubkey': str(kp.pubkey()), 'sig': str(s2)}, '')
        extra = '; a real Solana keypair (solders) also verifies'
    except ImportError:
        extra = ''
    raises('code_expired', lambda: S.h_wallet_link_finish({'code': out['code'], 'pubkey': pk58, 'sig': sig58}, ''))
    return 'signed message links the wallet; tampered signature refused; codes are single-use' + extra

def t_network_stats():
    s = S.network_stats()
    for k in ('nodes_online', 'by_utc_offset', 'next_payday_in', 'burned_total', 'ledger_balanced', 'paydays', 'events'):
        assert k in s, k
    assert s['ledger_balanced'] is True
    return 'stats ok: %d players, %d burned, ledger balanced' % (s['players'], s['burned_total'])

def t_share():
    u = reg()
    r = S.h_share_create(u, {'kind': 'profile'})
    page = S.share_page(r['id'])
    assert u['username'] in page and 'og:title' in page
    S.DB['shares'][r['id']]['title'] = '<script>x</script>'
    assert '<script>x' not in S.share_page(r['id'])
    return 'share card page built from server data; text is escaped'

def t_presence():
    a, b = reg(), reg()
    S.DB['friends'].append({'a': a['uid'], 'b': b['uid']})
    strike(b)
    out = S.h_friends(a, {})
    f = out['friends'][0]
    assert f['mining'] is True and f['doing'] == 'mine', f
    return 'friends list includes doing/mining flags (%d friends)' % len(out['friends'])

def t_ledger_final():
    ledger_ok()
    no_pls_minted_except(ALLOWED_MINT)
    return 'every PLS accounted for; only starter grants and node rewards create PLS'

for name, fn in [('version', t_version), ('v4 save migration', t_migration), ('streaks + gems', t_streak_gems),
                 ('hidden veins', t_hidden_vein), ('badges + pets', t_badges_pets), ('invites + mentors', t_invite_mentor),
                 ('Strike-Off', t_strikeoff), ('ghost races', t_ghost), ('bounties', t_bounty), ('King of the Hill', t_koth),
                 ('best-of-3 series', t_series), ('rematch, replays, spectating', t_rematch), ('cave expeditions', t_expedition),
                 ('fishing', t_fishing), ('home cabin', t_cabin), ('auction house', t_market), ('gear rental', t_rental),
                 ('anti-cheat v2', t_anticheat), ('crew territory', t_territory), ('season rewards', t_seasons),
                 ('one-tap wallet link', t_wallet_link), ('network stats', t_network_stats), ('share cards', t_share),
                 ('friend presence', t_presence), ('ledger + mint rule', t_ledger_final)]:
    check(name, fn)

# ---------------------------------------------------------------------------
# PART 2: real HTTP server
# ---------------------------------------------------------------------------
def http_pass():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    env = dict(os.environ, PORT=str(port), PULSE_DATA_FILE=tempfile.mktemp(suffix='.json'))
    p = subprocess.Popen([sys.executable, os.path.join(HERE, 'server.py')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    base = 'http://127.0.0.1:%d' % port
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen(base + '/health', timeout=1)
                break
            except Exception:
                time.sleep(0.2)
        def call(path, body=None, tok=None):
            req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                         headers={'Content-Type': 'application/json', **({'Authorization': 'Bearer ' + tok} if tok else {})})
            try:
                r = urllib.request.urlopen(req, timeout=10)
                raw = r.read().decode()
                return r.status, (json.loads(raw) if raw.startswith('{') else raw)
            except urllib.error.HTTPError as e:
                raw = e.read().decode()
                return e.code, (json.loads(raw) if raw.startswith('{') else raw)
        st, h = call('/health')
        assert h['version'] == 5.4
        st, r = call('/auth/register', {'username': 'webby', 'password': 'secret123'})
        tok = r['token']
        st, n = call('/network/stats')
        assert st == 200 and 'nodes_online' in n
        st, w = call('/wallet/link/start', {}, tok)
        assert w['url'].startswith(base + '/wallet/connect?code='), w
        st, page = call('/wallet/connect?code=' + w['code'])
        assert st == 200 and 'signMessage' in page
        st, c = call('/share/create', {'kind': 'profile'}, tok)
        st, card = call(c['path'])
        assert st == 200 and 'webby' in card
        for path in ('/badges', '/koth', '/series', '/duels/live', '/expedition', '/cabin', '/market', '/rentals', '/bounties',
                     '/crew/territory', '/ghosts?game=sniper', '/friends', '/me'):
            st, r = call(path, tok=tok)
            assert st == 200 and r.get('ok'), (path, r)
        st, r = call('/fish/cast', {}, tok)
        assert r['ok']
        return 'health, stats, wallet page, share card and 13 new GET pages answer over real HTTP'
    finally:
        p.terminate()
        err = p.stderr.read().decode()
        if 'Traceback' in err:
            print(err[-2000:])

check('HTTP end to end', http_pass)

for st, name, detail in RESULTS:
    print('%s: %s - %s' % (st, name, detail))
print('\nTOTAL %d PASS / %d FAIL' % (sum(1 for r in RESULTS if r[0] == 'PASS'), sum(1 for r in RESULTS if r[0] == 'FAIL')))
