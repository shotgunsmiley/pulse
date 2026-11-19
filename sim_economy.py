"""Pulse v5 economy simulation.
Runs the real server code with a fake clock: hundreds of bot players mine (which earns node time),
then spend PLS the ways real players can (forge, repair, shop, duels, Strike-Off, King of the Hill,
bounties, auction house, gear rental, dice). Checks the rules hold every simulated day.

Run:  python sim_economy.py [days] [players]
"""
import os, sys, random, tempfile, importlib, statistics, json

DAYS = int(sys.argv[1]) if len(sys.argv) > 1 else 30
PLAYERS = int(sys.argv[2]) if len(sys.argv) > 2 else 300
HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.update({'PULSE_DATA_FILE': tempfile.mktemp(suffix='.json'), 'PULSE_AUTH_LIMIT': '1000000', 'PULSE_FAKE_DAY': 'D000',
                   'PULSE_FAKE_WEEK': 'W00', 'PULSE_FAKE_SEASON': 'S0'})
os.environ.pop('DATABASE_URL', None)
sys.path.insert(0, HERE)
S = importlib.import_module('server')
random.seed(42)

CLOCK = [S.epoch_of(S.now()) * S.EPOCH_SECONDS + 1.0]
S.now = lambda: CLOCK[0]

KINDS = [('casual', 0.40, 3), ('regular', 0.40, 8), ('grinder', 0.20, 20)]   # name, share, epochs (10 min) mined per day
bots = []
for i in range(PLAYERS):
    r = random.random()
    kind = 'casual' if r < 0.4 else 'regular' if r < 0.8 else 'grinder'
    out = S.h_register({'username': 'bot%04d' % i, 'password': 'secret123'}, '1.1.1.1')
    u = S.session_user(out['token'])
    nid = 'n%04d' % i
    S.DB['nodes'][nid] = {'id': nid, 'uid': u['uid'], 'pem': '', 'label': 'sim', 'created': S.now(), 'status': 'active', 'last_seq': 0,
                          'last_hb': 0, 'last_counted': 0, 'units_total': 0, 'units_epoch': {}, 'day': '', 'day_units': 0, 'rejected': 0,
                          'tz': random.choice([-360, -300, -240, 0, 60, 330, 480, 540])}
    skill = random.uniform(0.3, 0.95)
    bots.append({'u': u, 'node': nid, 'kind': kind, 'epochs': dict((k, e) for k, _, e in KINDS)[kind], 'skill': skill})

def heartbeat(b):
    """Same accounting as /node/heartbeat for a counted beat (signature already verified)."""
    u, n = b['u'], S.DB['nodes'][b['node']]
    u['last_strike'] = u['last_good_strike'] = S.now()
    if hasattr(S, 'REQ'):
        S.REQ.ip = '10.%d.%d.1' % (int(b['node'][1:]) // 250, int(b['node'][1:]) % 250)
    ok, why = S.node_eligibility(u, n, True)
    if not ok:
        return False
    d = S.day_key()
    if n['day'] != d:
        n['day'], n['day_units'] = d, 0
    if n['day_units'] >= S.DAILY_UNIT_CAP:
        return False
    ep = str(S.epoch_of(S.now()))
    n['units_epoch'][ep] = n['units_epoch'].get(ep, 0) + 1
    n['units_total'] += 1
    n['day_units'] += 1
    n['last_hb'] = n['last_counted'] = S.now()
    return True

def ledger_ok():
    held = sum(x['balance'] for x in S.DB['users'].values())
    assert held + sum(S.DB['accounts'].values()) == 0, 'LEDGER OUT OF BALANCE'
    assert all(x['balance'] >= 0 for x in S.DB['users'].values()), 'NEGATIVE BALANCE'
    return held

def try_(fn, *a):
    try:
        return fn(*a)
    except S.ApiError:
        return None

def reactions(skill):
    return [int(random.gauss(420 - skill * 180, 45)) for _ in range(5)]

def play_skill(u, start, submit, skill, extra=None):
    st = try_(start, u, dict({'game': 'quickdraw'}, **(extra or {})))
    if not st:
        return None
    S.CHALLENGES[st['id']]['issued'] -= 60
    res = {'reactions': [max(110, x) for x in reactions(skill)]}
    return try_(submit, u, {'id': st['id'], 'result': res})

daily = []
minted_per_player_day = []
for day in range(DAYS):
    os.environ['PULSE_FAKE_DAY'] = 'D%03d' % day
    os.environ['PULSE_FAKE_WEEK'] = 'W%02d' % (day // 7)
    mint_before = -S.DB['accounts']['mint']
    burn_before = S.DB['accounts']['burn']
    earned_today = {b['u']['uid']: 0 for b in bots}
    # --- mining time: each bot mines a few 10-minute stretches spread over the day ------------
    plan = {}
    for b in bots:
        n = max(0, int(random.gauss(b['epochs'], b['epochs'] * 0.3)))
        for ep in random.sample(range(144), min(144, n)):
            plan.setdefault(ep, []).append(b)
    day_start = CLOCK[0]
    for ep in range(144):
        for beat in range(20):                       # 20 heartbeats of 30 s in a 10-minute epoch
            CLOCK[0] = day_start + ep * 600 + beat * 30 + 1
            for b in plan.get(ep, []):
                heartbeat(b)
        CLOCK[0] = day_start + (ep + 1) * 600 + 1
        bal_before = {b['u']['uid']: b['u']['balance'] for b in plan.get(ep, [])}
        S.settle_node_rewards()
        for b in plan.get(ep, []):
            earned_today[b['u']['uid']] += b['u']['balance'] - bal_before[b['u']['uid']]
    minted_per_player_day.extend(earned_today.values())
    # --- spending -------------------------------------------------------------------------------
    random.shuffle(bots)
    for b in bots:
        u, sk = b['u'], b['skill']
        r = random.random()
        u['ore'] = {o: v + random.randint(5, 40) for o, v in u['ore'].items()}       # ore from mining (not PLS)
        if r < 0.10 and 'pickaxe' not in u['gear']:
            try_(S.h_forge, u, {'recipe': 'iron_pickaxe'})
        elif r < 0.18 and u['gear']:
            g = next(iter(u['gear']))
            u['gear'][g]['dur'] = max(0, u['gear'][g]['dur'] - 60)
            try_(S.h_repair, u, {'slot': g})
        elif r < 0.22:
            item = random.choice(S.SHOP)
            try_(S.h_buy, u, {'item': item['id']})
        elif r < 0.30 and u['balance'] >= 20:
            try_(S.h_dice, u, {'bet': min(u['balance'] // 4, 20), 'target': 50})
        elif r < 0.33:
            play_skill(u, S.h_koth_challenge, S.h_koth_submit, sk)
        elif r < 0.36 and u['balance'] > 40 and u['best'].get('quickdraw') is not None:
            try_(S.h_bounty_post, u, {'game': 'quickdraw', 'amount': 20})
        elif r < 0.40:
            play_skill(u, S.h_practice_start, S.h_practice_submit, sk)
        elif r < 0.44 and u['gems']['amber'] == 0:
            u['gems']['amber'] += 1
            try_(S.h_market_sell, u, {'kind': 'gem', 'item': 'amber', 'qty': 1, 'price': random.randint(5, 30)})
        elif r < 0.50:
            lst = [x for x in S.DB['market'] if x['state'] == 'open' and x['seller'] != u['uid']]
            if lst:
                try_(S.h_market_buy, u, {'id': random.choice(lst)['id']})
        elif r < 0.53 and 'pickaxe' in u['gear'] and not u['gear']['pickaxe'].get('rental'):
            try_(S.h_rent_offer, u, {'slot': 'pickaxe', 'price': random.randint(10, 40)})
        elif r < 0.56:
            lst = [x for x in S.DB['rentals'] if x['state'] == 'offered' and x['owner'] != u['uid']]
            if lst:
                try_(S.h_rent_take, u, {'id': random.choice(lst)['id']})
    # duels: pairs queue at random stakes, both play, settle
    pool = [b for b in bots if b['u']['balance'] >= 10]
    random.shuffle(pool)
    for a, c in zip(pool[0::2][:60], pool[1::2][:60]):
        stake = random.choice([s for s in S.STAKES if 0 < s <= min(a['u']['balance'], c['u']['balance'], 50)] or [0])
        if not try_(S.h_pvp_challenge, a['u'], {'username': c['u']['username'], 'game': 'quickdraw', 'stake': stake}):
            continue
        inv = [i for i in S.DB['invites'] if i['from'] == a['u']['uid']][-1]
        if not try_(S.h_pvp_respond, c['u'], {'invite_id': inv['id'], 'accept': True}):
            continue
        m = [m for m in S.DB['matches'].values() if m['state'] == 'active' and a['u']['uid'] in m['players'] and c['u']['uid'] in m['players']][-1]
        for x in (a, c):
            p = try_(S.h_pvp_play, x['u'], {'match_id': m['id']})
            if p:
                S.CHALLENGES[p['id']]['issued'] -= 60
                try_(S.h_pvp_submit, x['u'], {'id': p['id'], 'result': {'reactions': [max(110, r) for r in reactions(x['skill'])]}})
    CLOCK[0] = day_start + 86400 + 1
    S.v5_tick(force=True)
    held = ledger_ok()
    bad = [e for e in S.DB['ledger'] if e['from'] == 'mint' and e['why'] not in ('starter grant (one time)', 'node reward')]
    assert not bad, 'PLS created by something other than node time: %s' % bad[:2]
    bals = sorted(x['balance'] for x in S.DB['users'].values())
    top = sum(bals[-max(1, len(bals) // 10):]) / max(1, sum(bals))
    daily.append({'day': day + 1, 'minted': -S.DB['accounts']['mint'] - mint_before, 'burned': S.DB['accounts']['burn'] - burn_before,
                  'supply_held': held, 'house': S.DB['accounts']['house'], 'locked': S.DB['accounts']['escrow'] + S.DB['accounts']['pots'],
                  'median_balance': statistics.median(bals), 'top10_share': round(top, 3)})

cap_day = S.DAILY_UNIT_CAP // S.UNITS_PER_PLS
over = [x for x in minted_per_player_day if x > cap_day]
assert not over, 'a player earned more than the daily cap: %s' % over[:3]
by_kind = {}
for b in bots:
    by_kind.setdefault(b['kind'], []).append(b['u']['balance'])
tot_minted = sum(d['minted'] for d in daily)
tot_burned = sum(d['burned'] for d in daily)
print('Pulse v5 economy simulation: %d players, %d days\n' % (PLAYERS, DAYS))
print('day  minted  burned   held   house  locked  median  top10%')
for d in daily:
    if d['day'] in (1, 2, 3, 7, 14, 21, 28, 30) or d['day'] == DAYS:
        print('%3d  %6d  %6d  %6d  %6d  %6d  %6d   %4.0f%%' % (d['day'], d['minted'], d['burned'], d['supply_held'], d['house'], d['locked'],
                                                      d['median_balance'], d['top10_share'] * 100))
print('\nTotal minted by node time: %d PLS   burned: %d PLS (%.0f%% of minted)' % (tot_minted, tot_burned, 100.0 * tot_burned / max(1, tot_minted)))
print('Average earned per player-day: %.1f PLS (cap %d)   max: %d' % (statistics.mean(minted_per_player_day), cap_day, max(minted_per_player_day)))
for k, v in by_kind.items():
    print('  %-8s %3d players  median balance %d' % (k, len(v), statistics.median(v)))
print('\nCHECKS: ledger balanced every day, no negative balances, PLS only from starter grant + node time, nobody over the daily cap -> ALL OK')
json.dump(daily, open(os.path.join(HERE, 'sim_economy_result.json'), 'w'), indent=1)
