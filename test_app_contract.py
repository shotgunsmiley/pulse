"""Contract test: every field the Godot app reads from a server reply must be there.
The field lists below were taken from the GDScript screens (r["..."] / .get("...")).
Runs the server in-process."""
import os, sys, tempfile, importlib, time

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ['PULSE_DATA_FILE'] = tempfile.mktemp(suffix='.json')
os.environ['PULSE_AUTH_LIMIT'] = '10000'
sys.path.insert(0, HERE)
S = importlib.import_module('server')
fails = []
checked = [0]

def need(obj, keys, where):
    for k in keys:
        path = k.split('.')
        cur = obj
        for p in path:
            if isinstance(cur, list):
                if not cur:
                    break
                cur = cur[0]
            if not isinstance(cur, dict) or p not in cur:
                fails.append('%s is missing "%s"' % (where, k))
                break
            cur = cur[p]
        checked[0] += 1

def reg(name):
    r = S.h_register({'username': name, 'password': 'secret123'}, 'ip')
    need(r, ['token', 'profile'], '/auth/register')
    return S.session_user(r['token'])

a = reg('ContractA')
b = reg('ContractB')
for u in (a, b):
    S.move('mint', S.U(u['uid']), 5000, 'test')
    u['ore'].update({'coal': 99, 'iron': 99, 'crystal': 99, 'void': 99})
S.h_forge(a, {'recipe': 'iron_pickaxe'})
need(S.h_login({'username': 'ContractA', 'password': 'secret123'}, 'ip'), ['token', 'profile'], '/auth/login')
try:
    S.h_login({'username': 'ContractA', 'password': 'nope'}, 'ip')
except S.ApiError as e:
    assert e.message
prof = S.h_me(a, {})['profile']
need(prof, ['balance', 'ore.coal', 'ore.iron', 'ore.crystal', 'ore.void', 'level', 'title', 'xp', 'xp_level_start', 'xp_next',
            'gear.pickaxe.tier', 'gear.pickaxe.broken', 'gear.pickaxe.name', 'gear.pickaxe.dur', 'gear.pickaxe.max_dur',
            'gear.pickaxe.stars', 'gear.pickaxe.repair_cost', 'gear.pickaxe.upgrade_cost.pls', 'gear.pickaxe.upgrade_cost.ore',
            'appearance', 'username', 'best', 'cosmetics', 'crew', 'day_blocks', 'week_blocks', 'lifetime_blocks', 'wins',
            'losses', 'draws', 'ranks', 'elo', 'luck.bets', 'luck.wagered', 'luck.paid', 'flagged'], '/me profile')
need(S.h_veins(a, {}), ['veins.id', 'veins.unlocked', 'veins.name', 'veins.locked_reason', 'veins.hp_left', 'veins.hp', 'daily_mult', 'day_blocks'], '/mine/veins')
st = S.h_mine_start(a, {'tier': 1})
need(st, ['id', 'challenge.speed', 'challenge.offset', 'challenge.zone_center', 'challenge.zone_width'], '/mine/start')
S.CHALLENGES[st['id']]['issued'] -= 2
a['last_strike'] = 0
sk = S.h_mine_strike(a, {'id': st['id'], 'tap_ms': 1500})
need(sk, ['quality', 'ore_gained', 'ore', 'damage', 'vein_hp', 'vein_max', 'cleared', 'pls', 'level_up', 'level', 'title', 'gear', 'balance', 'ore_inv', 'xp'], '/mine/strike')
need(S.h_recipes({}), ['recipes.iron_pickaxe.name', 'recipes.iron_pickaxe.tier', 'recipes.iron_pickaxe.slot', 'recipes.iron_pickaxe.durability',
                       'recipes.iron_pickaxe.cost_ore', 'recipes.iron_pickaxe.cost_pls'], '/recipes')
a['gear']['pickaxe']['dur'] -= 5
need(S.h_repair(a, {'slot': 'pickaxe'}), ['profile'], '/repair')
need(S.h_upgrade(a, {'slot': 'pickaxe'}), ['profile'], '/upgrade')
need(S.h_forge(a, {'recipe': 'iron_visor'}), ['profile'], '/forge')
for g in S.GAMES:
    p = S.h_practice_start(a, {'game': g})
    keys = {'quickdraw': ['challenge.game', 'challenge.rounds', 'challenge.delays'],
            'sequence': ['challenge.runes', 'challenge.start_len', 'challenge.show_ms', 'challenge.gap_ms'],
            'sniper': ['challenge.targets.cell', 'challenge.targets.delay', 'challenge.window_ms']}[g]
    need(p, ['id'] + keys, '/practice/start ' + g)
    S.CHALLENGES[p['id']]['issued'] -= 60
    res = {'quickdraw': {'reactions': [250] * 5}, 'sequence': {'reached': 4}, 'sniper': {'hits': [{'hit': True, 'rt': 300}] * 12}}[g]
    need(S.h_practice_submit(a, {'id': p['id'], 'result': res}), ['score', 'detail', 'new_best', 'best'], '/practice/submit')
q = S.h_pvp_queue(a, {'game': 'sniper', 'stake': 10})
need(q, ['status'], '/pvp/queue waiting')
q2 = S.h_pvp_queue(b, {'game': 'sniper', 'stake': 10})
need(q2, ['status', 'match.opponent'], '/pvp/queue matched')
mid = q2['match']['id']
pl = S.h_pvp_play(a, {'match_id': mid})
need(pl, ['id', 'challenge'], '/pvp/play')
S.CHALLENGES[pl['id']]['issued'] -= 60
need(S.h_pvp_submit(a, {'id': pl['id'], 'result': {'hits': [{'hit': True, 'rt': 300}] * 12}}), ['score', 'detail'], '/pvp/submit')
S.h_pvp_play(b, {'match_id': mid})
need(S.h_pvp_forfeit(b, {'match_id': mid}), ['ok'], '/pvp/forfeit')
S.h_pvp_challenge(a, {'username': 'ContractB', 'game': 'quickdraw', 'stake': 25})
stt = S.h_pvp_status(b, {})
need(stt, ['matches.id', 'matches.game', 'matches.stake', 'matches.state', 'matches.opponent', 'matches.opponent_elo', 'matches.my_score',
           'matches.their_score', 'matches.they_played', 'matches.deadline_in', 'matches.result.winner', 'matches.result.payout',
           'invites.id', 'invites.from', 'invites.game', 'invites.stake', 'stakes', 'elo', 'ranks'], '/pvp/status')
need(S.h_pvp_status(a, {}), ['sent.to', 'sent.game', 'sent.stake'], '/pvp/status sent')
S.h_pvp_queue(b, {'game': 'quickdraw', 'stake': 0}) if False else None
need(S.h_pvp_respond(b, {'invite_id': stt['invites'][0]['id'], 'accept': False}), ['ok'], '/pvp/respond')
S.h_pvp_queue(a, {'game': 'sequence', 'stake': 50})
need(S.h_pvp_status(a, {}), ['queue.game', 'queue.stake', 'queue.waiting'], '/pvp/status queue')
S.h_pvp_cancel(a, {})
os.environ['PULSE_FAKE_WEEK'] = '2098-W01'
need(S.h_t_enter(a, {'game': 'quickdraw'}), ['tournament'], '/tournament/enter')
ts = S.h_t_start(a, {'game': 'quickdraw'})
need(ts, ['id', 'challenge'], '/tournament/start')
S.CHALLENGES[ts['id']]['issued'] -= 60
need(S.h_t_submit(a, {'id': ts['id'], 'result': {'reactions': [250] * 5}}), ['score', 'detail', 'improved'], '/tournament/submit')
os.environ['PULSE_FAKE_WEEK'] = '2098-W02'
tl = S.h_tournaments(a, {})
need(tl, ['week', 'active.game', 'active.pot', 'active.players', 'active.my_best', 'active.my_place', 'active.my_attempts_left',
          'recent.week', 'recent.game', 'recent.payouts.place', 'recent.payouts.username', 'recent.payouts.prize'], '/tournaments')
os.environ['PULSE_FAKE_WEEK'] = '2098-W01'
need(S.h_tournaments(a, {}), ['active.top.place', 'active.top.username', 'active.top.score'], '/tournaments top')
os.environ.pop('PULSE_FAKE_WEEK')
need(S.h_flip(a, {'bet': 5, 'pick': 'teal'}), ['result', 'win', 'payout', 'roll', 'nonce', 'server_hash', 'balance'], '/luck/flip')
need(S.h_dice(a, {'bet': 5, 'target': 50}), ['roll', 'win', 'payout', 'nonce', 'server_hash', 'balance'], '/luck/dice')
cs = S.h_cave_start(a, {'bet': 5, 'caves': 3})
need(cs, ['game.bet', 'game.caves', 'game.multiplier', 'game.next_multiplier', 'game.opened', 'game.nonce', 'balance'], '/luck/cavein/start')
need(S.h_cave_state(a, {}), ['game'], '/luck/cavein')
safe = [c for c in range(25) if c not in a['cavein']['cells']]
need(S.h_cave_reveal(a, {'cell': safe[0]}), ['hit', 'game'], '/luck/cavein/reveal safe')
need(S.h_cave_cashout(a, {}), ['payout', 'game.cave_cells', 'balance'], '/luck/cavein/cashout')
S.h_cave_start(a, {'bet': 5, 'caves': 3})
need(S.h_cave_reveal(a, {'cell': a['cavein']['cells'][0]}), ['hit', 'game.cave_cells', 'balance'], '/luck/cavein/reveal bust')
need(S.h_fair(a, {}), ['fair.server_hash', 'fair.client_seed', 'fair.nonce'], '/luck/fair')
need(S.h_fair_seed(a, {}), ['revealed.server_seed', 'revealed.server_hash', 'revealed.client_seed'], '/luck/seed')
S.h_send(a, {'channel': 'lobby', 'text': 'hi'})
need(S.h_history(a, {'channel': ['lobby']}), ['messages.id', 'messages.from', 'messages.crew', 'messages.level', 'messages.text'], '/chat/history')
S.h_crew_create(a, {'name': 'Contract Crew', 'tag': 'CC'})
need(S.h_crew(a, {}), ['crew.tag', 'crew.name', 'crew.week_blocks', 'crew.members.owner', 'crew.members.username', 'crew.members.level',
                       'crew.members.week_blocks', 'crew.members.online', 'top.tag', 'top.name', 'top.week_blocks', 'top.members', 'cost'], '/crew')
S.h_friend_request(a, {'username': 'ContractB'})
need(S.h_friends(b, {}), ['pending.id', 'pending.from'], '/friends pending')
S.h_friend_respond(b, {'id': S.h_friends(b, {})['pending'][0]['id'], 'accept': True})
need(S.h_friends(a, {}), ['friends.username', 'friends.level', 'friends.online', 'friends.channel'], '/friends')
need(S.h_quests(a, {}), ['resets_in', 'quests.id', 'quests.title', 'quests.desc', 'quests.progress', 'quests.target', 'quests.pls',
                         'quests.ore', 'quests.ore_amt', 'quests.claimed'], '/quests')
a_q = S.quests_for(a)['quests'][0]
a_q['progress'] = a_q['target']
need(S.h_claim(a, {'quest_id': a_q['id']}), ['pls', 'ore_amt', 'ore', 'balance'], '/quests/claim')
a['week_key'] = S.week_key(); a['week_blocks'] = 3
for board in ('miners', 'level', 'elo_sniper'):
    need(S.h_leaderboard(a, {'board': [board]}), ['value_name', 'top.rank', 'top.crew', 'top.username', 'top.level', 'top.value', 'me.rank', 'me.value'], '/leaderboard ' + board)
need(S.h_economy({}), ['minted', 'burned', 'players', 'circulating', 'in_escrow', 'in_tournament_pots', 'ledger_check'], '/economy')
need(S.h_ledger(a, {}), ['entries.amount', 'entries.t', 'entries.why'], '/ledger')
need(S.h_shop({}), ['items.id', 'items.name', 'items.price'], '/shop')
need(S.h_buy(a, {'item': 'shirt_2'}), ['cosmetics', 'balance'], '/shop/buy')
need(S.h_appearance(a, {'appearance': {'shirt': 2}}), ['appearance'], '/profile/appearance')
need(S.h_heartbeat(a, {}), ['ok'], '/heartbeat')
need(S.GET_PUBLIC['/health']({}), ['ok', 'version'], '/health')

print('Checked %d fields the app reads across every endpoint.' % checked[0])
for f in fails:
    print('MISSING', f)
print('CONTRACT', 'PASS' if not fails else 'FAIL (%d)' % len(fails))
sys.exit(1 if fails else 0)
