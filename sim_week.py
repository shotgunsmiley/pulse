"""Pulse - one simulated week of real play.

Runs the real server code (real security settings, nothing relaxed) with a fake clock.
A handful of human-like players go through the same calls the app makes: mining strikes
with human timing and pauses, node heartbeats every 30 s while the app is open, daily
quests, practice games, forging, fishing, expeditions, duels, cups, thrones and the market.
A brand-new player also joins every day.

The point is to find friction: errors honest players hit, honest players getting flagged,
things nobody can afford, dead features, slow progression. Everything is written to
sim_week_report.json and a readable summary is printed.

Run:  python sim_week.py [days]
"""
import os, sys, json, random, tempfile, importlib, statistics, collections

for k in list(os.environ):
    if k.startswith('PULSE_'):
        del os.environ[k]
DAYS = int(sys.argv[1]) if len(sys.argv) > 1 else 7
HERE = os.path.dirname(os.path.abspath(__file__))
os.environ['PULSE_DATA_FILE'] = tempfile.mktemp(suffix='.json')
os.environ.pop('DATABASE_URL', None)
sys.path.insert(0, HERE)
S = importlib.import_module('server')
E = S.ApiError
rng = random.Random(7)

T0 = (int(S.now()) // 86400 + 1) * 86400.0          # midnight UTC
CLOCK = [T0]
S.now = lambda: CLOCK[0]
LAST_EPOCH = [S.epoch_of(CLOCK[0])]


def tick(sec):
    CLOCK[0] += sec
    ep = S.epoch_of(CLOCK[0])
    if ep != LAST_EPOCH[0]:
        LAST_EPOCH[0] = ep
        S.settle_node_rewards()


def set_day(d):
    os.environ['PULSE_FAKE_DAY'] = 'D%03d' % d
    os.environ['PULSE_FAKE_WEEK'] = 'W%02d' % (d // 7)


# ------------------------------------------------------------------ players
class P:
    def __init__(self, name, kind, ip, skill, sessions, minutes, joined_day=0):
        self.name, self.kind, self.ip, self.skill = name, kind, ip, skill
        self.sessions, self.minutes, self.joined_day = sessions, minutes, joined_day
        self.u = None
        self.node = None
        self.errors = collections.Counter()
        self.node_denied = collections.Counter()
        self.log = collections.defaultdict(lambda: collections.Counter())
        self.days = []
        self.first_pls_day = None
        self.notes = []

    def call(self, fn, body, tag=None):
        S.REQ.ip = self.ip
        try:
            return fn(self.u, body)
        except E as e:
            self.errors['%s:%s' % (tag or fn.__name__, e.code)] += 1
            return None


def register(p):
    S.REQ.ip = p.ip
    out = S.h_register({'username': p.name, 'password': 'secret123'}, p.ip)
    p.u = S.session_user(out['token'])
    S.note_ip(p.u, p.ip)
    nid = 'n_' + p.name
    S.DB['nodes'][nid] = {'id': nid, 'uid': p.u['uid'], 'pem': '', 'label': 'phone', 'created': S.now(), 'status': 'active',
                          'last_seq': 0, 'last_hb': 0, 'last_counted': 0, 'units_total': 0, 'units_epoch': {}, 'day': '',
                          'day_units': 0, 'rejected': 0, 'tz': -360}
    p.node = nid


def heartbeat(p):
    """Same accounting as a counted /node/heartbeat (the signature part is device-level and tested elsewhere)."""
    u, n = p.u, S.DB['nodes'][p.node]
    S.REQ.ip = p.ip
    ok, why = S.node_eligibility(u, n, True)
    if not ok:
        p.node_denied[why] += 1
        return
    d = S.day_key()
    if n['day'] != d:
        n['day'], n['day_units'] = d, 0
    if n['day_units'] >= S.DAILY_UNIT_CAP:
        p.node_denied['daily cap'] += 1
        return
    ep = str(S.epoch_of(S.now()))
    n['units_epoch'][ep] = n['units_epoch'].get(ep, 0) + 1
    n['units_total'] += 1
    n['day_units'] += 1
    n['last_hb'] = n['last_counted'] = S.now()


def ideal_tap(ch, after=180):
    best = None
    for target in (ch['zone_center'], 2 - ch['zone_center']):
        t = ((target - ch['offset']) % 2.0) / ch['speed'] * 1000.0
        while t < after:
            t += 2.0 / ch['speed'] * 1000.0
        best = t if best is None else min(best, t)
    return best


def human_tap(p, ch):
    sd = 95 - 60 * p.skill                      # good players are tighter
    t = ideal_tap(ch) + rng.gauss(0, sd)
    if rng.random() < 0.06:                     # lapses: looked away, thumb slipped
        t += rng.uniform(150, 700)
    return max(170, int(t))


def best_tier(p):
    v = S.h_veins(p.u, {})
    ok = [x['id'] for x in v['veins'] if x['unlocked']]
    return max(ok) if ok else 1


# ------------------------------------------------------------------ activities
def mine_session(p, minutes, day):
    """Mine for `minutes`, heartbeating every 30 s like the phone node does."""
    end = CLOCK[0] + minutes * 60
    next_hb = CLOCK[0] + 30
    c = p.log[day]
    tier = best_tier(p)
    while CLOCK[0] < end:
        st = p.call(S.h_mine_start, {'tier': tier}, 'mine_start')
        if not st:
            tick(3)
            if p.errors.get('mine_start:review_hold'):
                break
            # what the app should do: drop to the best vein still open
            tier = best_tier(p)
            c['vein_relocked'] += 1
            continue
        tap = human_tap(p, st['challenge'])
        tick(tap / 1000.0 + 0.03)
        r = p.call(S.h_mine_strike, {'id': st['id'], 'tap_ms': tap}, 'mine_strike')
        if r:
            c['strikes'] += 1
            c['hits'] += 1 if r.get('quality') in ('good', 'great', 'perfect') else 0
            c['cleared'] += 1 if r.get('cleared') else 0
            if r.get('level_up'):
                c['level_ups'] += 1
            if r.get('flagged'):
                c['flagged_strikes'] += 1
            if r.get('gem'):
                c['gems'] += 1
            if r.get('cleared'):
                tier = best_tier(p)
        gap = rng.lognormvariate(0.45, 0.35)    # ~1.6 s between strikes
        if rng.random() < 0.04:
            gap += rng.uniform(8, 40)            # a text message, a sip of coffee
        tick(gap)
        while CLOCK[0] >= next_hb:
            heartbeat(p)
            next_hb += 30


def claim_quests(p, day):
    q = p.call(S.h_quests, {}, 'quests')
    if not q:
        return
    for x in q['quests']:
        if x['progress'] >= x['target'] and not x['claimed']:
            if p.call(S.h_claim, {'quest_id': x['id']}, 'claim'):
                p.log[day]['quests'] += 1


def qd_play(p, ch):
    """Real-time length of a 5-round Quickdraw: waits for green, reactions, and the pause between rounds."""
    rts = [max(150, int(rng.gauss(400 - p.skill * 150, 50))) for _ in range(int(ch.get('rounds', 5)))]
    tick(sum(ch.get('delays', [2500] * 5)) / 1000.0 + sum(rts) / 1000.0 + 1.0 * len(rts) + 1.2)
    return {'reactions': rts}


def seq_play(p, cid):
    full = S.CHALLENGES[cid]['challenge']
    n = int(full.get('seq_n', full.get('start_len', 3)))
    reached = 0
    while True:
        tick(n * (full['show_ms'] + full['gap_ms']) / 1000.0 + n * 0.45 + 0.6)
        correct = rng.random() < (0.985 - n * (0.05 - p.skill * 0.03))
        entered = full['runes'][:n] if correct else [(x + 1) % 4 for x in full['runes'][:n]]
        r = p.call(S.h_skill_step, {'id': cid, 'entered': entered}, 'skill_step')
        if not r or not r.get('correct'):
            break
        reached = n
        if r.get('done'):
            break
        n += 1
    return {'reached': reached}


def practice(p, day, game='quickdraw'):
    st = p.call(S.h_practice_start, {'game': game}, 'practice_start')
    if not st:
        return
    res = qd_play(p, st['challenge']) if game == 'quickdraw' else seq_play(p, st['id'])
    r = p.call(S.h_practice_submit, {'id': st['id'], 'result': res}, 'practice_submit')
    if r:
        p.log[day]['practice'] += 1


def fish(p, day, casts):
    for i in range(casts):
        c = p.call(S.h_fish_cast, {}, 'fish_cast')
        if not c:
            return
        wait = c['bite_ms'] + rng.gauss(260 - p.skill * 60, 70)
        tick(max(0.2, wait / 1000.0))
        r = p.call(S.h_fish_reel, {'tap_ms': int(wait)}, 'fish_reel')
        if r and r.get('caught'):
            p.log[day]['fish'] += 1
        tick(rng.uniform(2, 6))


def expedition(p, day):
    if not p.call(S.h_exp_start, {}, 'exp_start'):
        return
    floors = 0
    target = 2 + int(p.skill * 4)
    for i in range(200):
        e = p.u.get('expedition')
        if not e:
            break
        f = S.exp_floor(e['seed'], e['floor'])
        tap = max(170, int(ideal_tap(f, 160) + rng.gauss(0, 95 - 60 * p.skill)))
        tick(tap / 1000.0 + 0.05)
        r = p.call(S.h_exp_strike, {'tap_ms': tap}, 'exp_strike')
        tick(rng.uniform(0.8, 2.0))
        if not r:
            break
        if r.get('collapsed'):
            p.log[day]['exp_collapsed'] += 1
            break
        if r['expedition']['cleared']:
            floors += 1
            if floors >= target:
                if p.call(S.h_exp_exit, {}, 'exp_exit'):
                    p.log[day]['exp_banked'] += 1
                break
            p.call(S.h_exp_descend, {}, 'exp_descend')
    p.log[day]['exp_floors'] += floors


def try_forge(p, day):
    gv = S.gear_view(p.u)
    for slot, g in gv.items():
        if g['dur'] < 0.3 * g['max_dur']:
            if p.call(S.h_repair, {'slot': slot}, 'repair'):
                p.log[day]['repairs'] += 1
            else:
                p.log[day]['cant_afford_repair'] += 1
    rec = S.h_recipes({})['recipes']
    for rid in ('iron_pickaxe', 'iron_gauntlets', 'iron_visor', 'crystal_pickaxe'):
        r = rec[rid]
        if r['slot'] in p.u['gear'] and S_tier_rank(p.u['gear'][r['slot']]) >= S_tier_rank({'tier': r['tier']}):
            continue
        if all(p.u['ore'].get(o, 0) >= n for o, n in r['cost_ore'].items()) and p.u['balance'] >= r['cost_pls']:
            if p.call(S.h_forge, {'recipe': rid}, 'forge'):
                p.log[day]['forged'] += 1
                p.notes.append('day %d: forged %s' % (day + 1, r['name']))
            return
        else:
            p.log[day]['cant_afford_forge'] += 1
            return


def S_tier_rank(g):
    return {'iron': 1, 'crystal': 2, 'void': 3}.get(g.get('tier', ''), 0)


def duel(a, b, day, stake):
    inv = a.call(S.h_pvp_challenge, {'username': b.name, 'game': 'quickdraw', 'stake': stake}, 'pvp_challenge')
    if not inv:
        return
    if not b.call(S.h_pvp_respond, {'invite_id': inv['invite_id'], 'accept': True}, 'pvp_respond'):
        return
    m = [m for m in S.DB['matches'].values() if a.u['uid'] in m['players'] and b.u['uid'] in m['players']][-1]
    for p in (a, b):
        st = p.call(S.h_pvp_play, {'match_id': m['id']}, 'pvp_play')
        if not st:
            continue
        r = p.call(S.h_pvp_submit, {'id': st['id'], 'result': qd_play(p, st['challenge'])}, 'pvp_submit')
    a.log[day]['duels'] += 1
    b.log[day]['duels'] += 1
    rep = a.call(S.h_duel_replay, {'id': [m['id']]}, 'duel_replay')
    if rep is not None and not all('look' in s for s in rep.get('sides', [])):
        a.notes.append('replay missing looks')


def cup(p, day):
    if day == 0 or p.log.get('cup_entered_w'):
        pass
    if not p.u.get('_cup'):
        if p.call(S.h_t_enter, {'game': 'quickdraw'}, 't_enter'):
            p.u['_cup'] = True
            p.notes.append('day %d: entered the weekly cup' % (day + 1))
    st = p.call(S.h_t_start, {'game': 'quickdraw'}, 't_start')
    if st:
        if p.call(S.h_t_submit, {'id': st['id'], 'result': qd_play(p, st['challenge'])}, 't_submit'):
            p.log[day]['cup_runs'] += 1


def throne(p, day):
    k = p.call(S.h_koth_challenge, {'game': 'quickdraw'}, 'koth_challenge')
    if k:
        r = p.call(S.h_koth_submit, {'id': k['id'], 'result': qd_play(p, k['challenge'])}, 'koth_submit')
        if r:
            p.log[day]['throne_tries'] += 1


def sell_gems(p, day):
    for g, n in p.u['gems'].items():
        if n > 0:
            if p.call(S.h_market_sell, {'kind': 'gem', 'item': g, 'qty': 1, 'price': 30}, 'market_sell'):
                p.log[day]['listed'] += 1
            return


def buy_from_market(p, day):
    m = p.call(S.h_market, {}, 'market')
    if not m:
        return
    for it in (m.get('listings') or [])[:3]:
        if not it.get('mine') and p.u['balance'] >= it.get('price', 999999):
            if p.call(S.h_market_buy, {'id': it['id']}, 'market_buy'):
                p.log[day]['bought'] += 1
                return


# ------------------------------------------------------------------ the week
cara = P('CasualCara', 'casual', '73.12.40.7', 0.45, 2, 8)
rob = P('RegularRob', 'regular', '98.20.11.4', 0.65, 3, 15)
robs_kid = P('RobsKid', 'regular', '98.20.11.4', 0.5, 2, 10)        # same home wifi as Rob
gia = P('GrinderGia', 'grinder', '24.9.200.3', 0.8, 6, 30)
dan = P('DuelistDan', 'duelist', '67.33.2.91', 0.85, 2, 10)
players = [cara, rob, robs_kid, gia, dan]
newbies = []
for p in players:
    register(p)
# a few casual fishers so the market and thrones have some life
for p in players:
    p.u['created'] -= 0      # everyone starts brand new on day 1 (the real case)

HOURS = {'casual': [12, 21], 'regular': [7, 12, 19], 'grinder': [8, 10, 13, 16, 19, 22], 'duelist': [18, 21]}

for day in range(DAYS):
    set_day(day)
    day_start = T0 + day * 86400
    # a new player joins every day (onboarding check)
    nb = P('Newbie%d' % (day + 1), 'newbie', '50.%d.7.%d' % (day, 10 + day), rng.uniform(0.3, 0.7), 1, 10, joined_day=day)
    CLOCK[0] = max(CLOCK[0], day_start + 15 * 3600)
    register(nb)
    newbies.append(nb)
    bal0 = {p.name: p.u['balance'] for p in players + newbies}
    events = []
    for p in players:
        for i, h in enumerate(HOURS[p.kind][:p.sessions]):
            events.append((day_start + h * 3600 + rng.uniform(0, 2400), p, i))
    for nb2 in newbies:
        if nb2.joined_day == day:
            events.append((day_start + 15 * 3600 + 60, nb2, 0))
        elif day - nb2.joined_day <= 2 and rng.random() < 0.6:    # do new players come back?
            events.append((day_start + 20 * 3600, nb2, 0))
    events.sort(key=lambda x: x[0])
    for t, p, i in events:
        if CLOCK[0] < t:
            tick(t - CLOCK[0])
        mins = max(3, rng.gauss(p.minutes, p.minutes * 0.25))
        mine_session(p, mins, day)
        if i == 0 or p.kind == 'grinder':
            practice(p, day, rng.choice(['quickdraw', 'sequence']))
        if p.kind in ('regular', 'grinder', 'duelist') and i == 0:
            practice(p, day, 'sequence')
            fish(p, day, 10 if p.kind != 'grinder' else 25)
        if p.kind == 'grinder' and i in (1, 3):
            expedition(p, day)
        if p.kind == 'grinder' and i == 2:
            sell_gems(p, day)
        if p.kind == 'regular' and i == 2:
            buy_from_market(p, day)
        try_forge(p, day)
        claim_quests(p, day)
    # evening duels and competitive play
    tick(max(0, day_start + 22.5 * 3600 - CLOCK[0]))
    duel(dan, rob, day, 0 if rob.u['balance'] < 20 else 10)
    if day % 2 == 0:
        duel(dan, gia, day, 0 if gia.u['balance'] < 30 else 20)
    if day >= 1:
        cup(dan, day)
        cup(gia, day)
        throne(dan, day)
        throne(rob, day)
    tick(max(0, day_start + 86400 - CLOCK[0]) + 1)
    S.settle_node_rewards()
    for p in players + newbies:
        if p.joined_day > day:
            continue
        lv = S.level_for(p.u['xp']) if hasattr(S, 'level_for') else p.u.get('level')
        earned = p.u['balance'] - bal0.get(p.name, S.STARTER_PLS)
        p.days.append({'day': day + 1, 'balance': p.u['balance'], 'xp': p.u['xp'], 'level': lv,
                       'ore': dict(p.u['ore']), 'gear': sorted(p.u['gear']), 'flagged': p.u.get('flagged', False),
                       **{k: v for k, v in p.log[day].items()}})
        if p.first_pls_day is None and p.u['balance'] > S.STARTER_PLS and p.log[day]['strikes']:
            p.first_pls_day = day + 1

# ------------------------------------------------------------------ report
held = sum(x['balance'] for x in S.DB['users'].values())
assert held + sum(S.DB['accounts'].values()) == 0, 'ledger out of balance'

report = {'players': {}, 'newbies': {}}
print('=' * 72)
print('PULSE - ONE SIMULATED WEEK (%d days, real security settings)' % DAYS)
print('=' * 72)
for p in players + newbies:
    d = p.days[-1] if p.days else {}
    strikes = sum(x.get('strikes', 0) for x in p.days)
    hits = sum(x.get('hits', 0) for x in p.days)
    row = {'kind': p.kind, 'skill': round(p.skill, 2), 'final': d, 'strikes': strikes,
           'hit_rate': round(hits / max(1, strikes), 2), 'errors': dict(p.errors), 'node_denied': dict(p.node_denied),
           'first_pls_day': p.first_pls_day, 'notes': p.notes, 'days': p.days}
    (report['newbies'] if p.kind == 'newbie' else report['players'])[p.name] = row
    if p.kind == 'newbie' and p.joined_day < DAYS - 2:
        continue
    print('\n%s (%s, skill %.2f)' % (p.name, p.kind, p.skill))
    print('  level %s  xp %s  balance %s PLS  gear %s  flagged %s' % (d.get('level'), d.get('xp'), d.get('balance'), d.get('gear'), d.get('flagged')))
    print('  strikes %d  hit rate %.0f%%  ore %s' % (strikes, 100 * hits / max(1, strikes), d.get('ore')))
    print('  PLS by day: %s' % [x['balance'] for x in p.days])
    if p.errors:
        print('  errors hit: %s' % dict(p.errors.most_common(8)))
    if p.node_denied:
        print('  node pay refused: %s' % dict(p.node_denied.most_common(5)))
    for n in p.notes[:6]:
        print('  - ' + n)
print('\nNEW PLAYERS (one per day):')
for p in newbies:
    d0 = p.days[0] if p.days else {}
    print('  %s day1: %d strikes, level %s, balance %s, node refused %s, errors %s' % (
        p.name, d0.get('strikes', 0), d0.get('level'), d0.get('balance'), dict(p.node_denied.most_common(2)), dict(p.errors.most_common(3))))
json.dump(report, open(os.path.join(HERE, 'sim_week_report.json'), 'w'), indent=1, default=str)
print('\nledger balanced; full report in sim_week_report.json')
