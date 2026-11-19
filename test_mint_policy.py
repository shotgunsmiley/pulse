#!/usr/bin/env python3
"""Mint-policy tests (default nodes_only): PLS is created ONLY by hourly phone-node rewards,
plus a one-time starter grant per new account. Veins and quests give ore and XP, not PLS."""
import os, sys, tempfile, importlib.util, traceback

os.environ['PULSE_DATA_FILE'] = tempfile.mktemp(suffix='.json')
os.environ.pop('DATABASE_URL', None)
os.environ.pop('PULSE_MINT_POLICY', None)          # test the default
os.environ['PULSE_UNITS_PER_PLS'] = '2'
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('srv', os.path.join(HERE, 'server.py'))
S = importlib.util.module_from_spec(spec)
spec.loader.exec_module(S)
RESULTS = []

def check(name, fn):
    try:
        d = fn()
        RESULTS.append(True)
        print('PASS:', name, '-', d or '')
    except Exception as e:
        traceback.print_exc()
        RESULTS.append(False)
        print('FAIL:', name, '-', repr(e))

def reasons():
    out = {}
    for e in S.DB['ledger']:
        if e['from'] == 'mint':
            out[e['why']] = out.get(e['why'], 0) + e['amt']
    return out

STATE = {}

def t_starter():
    assert S.MINT_POLICY == 'nodes_only'
    r = S.h_register({'username': 'Fresh', 'password': 'secret123'}, '1.1.1.1')
    u = S.DB['users'][r['profile']['uid']]
    STATE['u'] = u
    assert u['balance'] == S.STARTER_PLS == 10, u['balance']
    assert reasons() == {'starter grant (one time)': 10}
    return 'new account gets a one-time %d PLS starter grant' % S.STARTER_PLS

def perfect_strike(u):
    st = S.h_mine_start(u, {'tier': 1})
    cid, ch = st['id'], st['challenge']
    S.CHALLENGES[cid]['issued'] = S.now() - 6.0
    best = min(range(200, 5800, 2), key=lambda t: abs(S.marker_pos(ch, t) - ch['zone_center']))
    u['last_strike'] = 0
    return S.h_mine_strike(u, {'id': cid, 'tap_ms': best})

def t_vein():
    u = STATE['u']
    before = u['balance']
    cleared = None
    for _ in range(6):
        r = perfect_strike(u)
        if r['cleared']:
            cleared = r
            break
    assert cleared, 'vein never cleared'
    assert cleared['pls'] == 0 and u['balance'] == before and cleared['ore_gained'] > 0
    assert u['day_blocks'] == 1
    assert all(v['pls'] == 0 for v in S.h_veins(u, {})['veins'])
    return 'vein cleared: +%d coal and XP, 0 PLS (balance still %d)' % (cleared['ore_gained'], u['balance'])

def t_quest():
    u = STATE['u']
    qs = S.h_quests(u, {})['quests']
    assert all(q['pls'] == 0 for q in qs)
    q = next(x for x in S.quests_for(u)['quests'] if x['id'] == 'veins')
    q['progress'] = q['target']
    before, ore = u['balance'], u['ore'][q['ore']]
    r = S.h_claim(u, {'quest_id': 'veins'})
    assert r['pls'] == 0 and u['balance'] == before and u['ore'][q['ore']] == ore + q['ore_amt']
    return 'quest reward: ore only, 0 PLS'

def t_node_mints():
    u = STATE['u']
    S.DB['nodes']['n1'] = {'id': 'n1', 'uid': u['uid'], 'units_epoch': {'1': 9}, 'status': 'active'}
    before = u['balance']
    paid = S.settle_node_rewards(up_to_epoch=2)
    assert paid == 4 and u['balance'] == before + 4          # 9 units / 2 per PLS = 4, 1 unit carried
    assert set(reasons()) == {'starter grant (one time)', 'node reward'}
    acc = S.DB['accounts']
    circ = sum(x['balance'] for x in S.DB['users'].values())
    assert circ + sum(acc.values()) == 0
    return 'only two sources of new PLS in the ledger: starter grant + node rewards; ledger balanced'

def t_classic_switch():
    S.MINT_POLICY = 'classic'
    r = S.h_register({'username': 'Classic', 'password': 'secret123'}, '1.1.1.2')
    assert S.DB['users'][r['profile']['uid']]['balance'] == 25
    S.MINT_POLICY = 'nodes_only'
    return 'PULSE_MINT_POLICY=classic brings back the old rules'

check('one-time starter grant', t_starter)
check('veins give ore, not PLS', t_vein)
check('quests give ore, not PLS', t_quest)
check('node rewards are the only ongoing source of PLS', t_node_mints)
check('switch back to classic', t_classic_switch)
ok = sum(RESULTS)
print('\nTOTAL %d PASS / %d FAIL' % (ok, len(RESULTS) - ok))
sys.exit(0 if ok == len(RESULTS) else 1)
