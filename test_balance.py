"""Pulse v5.2 balance rules (found by sim_week.py). Runs the real server code.
Run:  python test_balance.py
"""
import os, sys, tempfile, importlib, subprocess

for k in list(os.environ):
    if k.startswith('PULSE_'):
        del os.environ[k]
HERE = os.path.dirname(os.path.abspath(__file__))
os.environ['PULSE_DATA_FILE'] = tempfile.mktemp(suffix='.json')
os.environ.pop('DATABASE_URL', None)
sys.path.insert(0, HERE)
S = importlib.import_module('server')
E = S.ApiError
RESULTS = []


def check(name, fn):
    try:
        RESULTS.append(('PASS', name, fn() or ''))
    except Exception as e:
        import traceback
        traceback.print_exc()
        RESULTS.append(('FAIL', name, repr(e)))


N = [0]
def reg():
    N[0] += 1
    S.REQ.ip = '10.9.%d.%d' % (N[0] // 200, N[0] % 200 + 1)
    S.h_register({'username': 'bal%03d' % N[0], 'password': 'secret123'}, S.REQ.ip)
    return S.DB['users'][S.DB['names']['bal%03d' % N[0]]]


def give(u, n):
    S.move('mint', S.U(u['uid']), n, 'test_grant')


def t_prices():
    r = S.h_recipes({})['recipes']
    assert r['iron_pickaxe']['cost_pls'] == 10 and r['iron_pickaxe']['durability'] == 600
    assert r['crystal_pickaxe']['cost_pls'] == 35 and r['void_pickaxe']['cost_pls'] == 90
    assert S.T_ENTRY == 20
    u = reg()
    u['ore']['iron'], u['ore']['coal'] = 12, 8
    S.h_forge(u, {'recipe': 'iron_pickaxe'})          # the 10 PLS starter grant is enough
    assert u['balance'] == 0 and u['gear']['pickaxe']['max_dur'] == 600
    return 'iron gear 10 PLS / 600 durability (starter grant buys a first pickaxe); crystal 35, void 90; cup 20 PLS'


def t_repair_ore():
    u = reg()
    u['ore']['iron'], u['ore']['coal'] = 12, 8
    S.h_forge(u, {'recipe': 'iron_pickaxe'})
    g = u['gear']['pickaxe']
    g['dur'] = 0
    v = S.gear_view(u)['pickaxe']
    assert v['repair_cost'] == 0 and v['repair_ore'] == {'iron': 150} and not v['can_repair']
    try:
        S.h_repair(u, {'slot': 'pickaxe'})
        raise AssertionError('repaired without ore')
    except E as e:
        assert e.code == 'not_enough_ore'
    u['ore']['iron'], u['ore']['crystal'] = 100, 80     # 100 iron + 50 crystal covers it
    bal = u['balance']
    r = S.h_repair(u, {'slot': 'pickaxe'})
    assert g['dur'] == 600 and u['ore']['iron'] == 0 and u['ore']['crystal'] == 30 and u['balance'] == bal
    return 'iron repairs cost ore only (150 iron for a full repair); better ore covers the gap'


def t_crystal_repair():
    u = reg()
    give(u, 100)
    u['ore']['crystal'], u['ore']['iron'] = 12, 10
    S.h_forge(u, {'recipe': 'crystal_pickaxe'})
    g = u['gear']['pickaxe']
    g['dur'] = 200
    v = S.gear_view(u)['pickaxe']
    assert v['repair_cost'] == 5 and v['repair_ore'] == {'crystal': 125}
    u['ore']['crystal'] = 200
    bal = u['balance']
    S.h_repair(u, {'slot': 'pickaxe'})
    assert u['balance'] == bal - 5 and g['dur'] == 1200
    held = sum(x['balance'] for x in S.DB['users'].values())
    assert held + sum(S.DB['accounts'].values()) == 0
    return 'crystal repair: 5 PLS (burned) + 125 crystal for 1000 durability; ledger balanced'


def t_old_gear():
    u = reg()
    u['gear']['pickaxe'] = {'recipe': 'iron_pickaxe', 'name': 'Iron Pickaxe', 'slot': 'pickaxe', 'tier': 'iron', 'stars': 0,
                            'dur': 75, 'max_dur': 150}
    v = S.gear_view(u)['pickaxe']
    assert v['max_dur'] == 600 and v['dur'] == 300
    return 'gear forged under the old rules keeps its fraction: 75/150 becomes 300/600'


def t_upgrade_ore():
    u = reg()
    u['ore']['iron'], u['ore']['coal'] = 12, 8
    S.h_forge(u, {'recipe': 'iron_pickaxe'})
    c = S.upgrade_cost(u['gear']['pickaxe'])
    assert c['ore'] == {'iron': 25} and c['pls'] == 6
    return 'upgrades soak up ore: 25 / 50 / 75 iron per star'


def t_classic_unchanged():
    code = ("import os,sys,tempfile;os.environ['PULSE_DATA_FILE']=tempfile.mktemp();sys.path.insert(0,%r);"
            "import server as S;r=S.h_recipes({})['recipes'];"
            "assert r['iron_pickaxe']['cost_pls']==40 and r['iron_pickaxe']['durability']==150 and S.T_ENTRY==50;print('ok')") % HERE
    env = {k: v for k, v in os.environ.items() if not k.startswith('PULSE_')}
    env['PULSE_MINT_POLICY'] = 'classic'
    out = subprocess.run([sys.executable, '-c', code], env=env, capture_output=True, text=True, timeout=60)
    assert out.stdout.strip().endswith('ok'), out.stderr[-400:]
    return 'classic economy keeps the old prices'


for name, fn in [('new prices', t_prices), ('iron repairs in ore', t_repair_ore), ('crystal repair', t_crystal_repair),
                 ('old gear rescaled', t_old_gear), ('upgrade ore', t_upgrade_ore), ('classic unchanged', t_classic_unchanged)]:
    check(name, fn)
for s, n, d in RESULTS:
    print('%s: %s - %s' % (s, n, d))
print('\nTOTAL %d PASS / %d FAIL' % (sum(1 for r in RESULTS if r[0] == 'PASS'), sum(1 for r in RESULTS if r[0] == 'FAIL')))
