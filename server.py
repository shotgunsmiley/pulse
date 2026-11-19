# Pulse Network Server v4.1 - Python standard library only (psycopg2 optional for Postgres)
# Game API for the Pulse v4 Godot client.
# PLS is an in-game, non-redeemable game balance: it can only be mined in game.
# v4.1: phones register as nodes (signed handshake + heartbeats); node contribution is rewarded
# through the internal PULSE ledger. A future Solana SPL token is planned separately.
# There is no purchase of PLS, no cash-out and no transfer of PLS to other players.
import os, json, hashlib, hmac, time, random, uuid, datetime, threading, secrets, re, traceback, math, signal, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

VERSION = 4.1
DATA_FILE = os.environ.get('PULSE_DATA_FILE', 'pulse_v4_data.json')
DATABASE_URL = os.environ.get('DATABASE_URL', '').strip()
SESSION_DAYS = 30
DB_LOCK = threading.RLock()

def now():
    return time.time()

def day_key():
    return os.environ.get('PULSE_FAKE_DAY') or datetime.datetime.utcnow().strftime('%Y-%m-%d')

def week_key():
    fake = os.environ.get('PULSE_FAKE_WEEK')
    if fake:
        return fake
    y, w, _ = datetime.datetime.utcnow().isocalendar()
    return '%d-W%02d' % (y, w)

def season_key():
    return os.environ.get('PULSE_FAKE_SEASON') or datetime.datetime.utcnow().strftime('%Y-%m')

class ApiError(Exception):
    def __init__(self, code, message=None, status=400):
        Exception.__init__(self, code)
        self.code, self.message, self.status = code, message or code.replace('_', ' '), status

def to_int(v, default=None):
    try:
        if isinstance(v, bool):
            return default
        return int(v)
    except Exception:
        return default

# ---------------------------------------------------------------------------
# STORAGE: whole-state snapshot to a JSON file, or to Postgres when DATABASE_URL
# is set (Render's own disk is wiped on restarts; a database is not).
# ---------------------------------------------------------------------------
class FileStore:
    name = 'file'
    def load(self):
        try:
            with open(DATA_FILE, 'r') as f:
                return json.load(f)
        except Exception:
            return None
    def save(self, text):
        tmp = DATA_FILE + '.tmp'
        with open(tmp, 'w') as f:
            f.write(text)
        os.replace(tmp, DATA_FILE)

class PgStore:
    name = 'postgres'
    def __init__(self, url):
        import psycopg2  # only needed when DATABASE_URL is set
        self.pg = psycopg2
        self.url = url
        self.conn = None
        self._exec('CREATE TABLE IF NOT EXISTS pulse_state (id INTEGER PRIMARY KEY, doc TEXT NOT NULL)')
    def _connect(self):
        if self.conn is None:
            self.conn = self.pg.connect(self.url)
            self.conn.autocommit = True
        return self.conn
    def _exec(self, sql, params=None, fetch=False):
        for attempt in (1, 2):
            try:
                cur = self._connect().cursor()
                cur.execute(sql, params or ())
                rows = cur.fetchall() if fetch else None
                cur.close()
                return rows
            except Exception:
                self.conn = None
                if attempt == 2:
                    raise
    def load(self):
        rows = self._exec('SELECT doc FROM pulse_state WHERE id = 1', fetch=True)
        return json.loads(rows[0][0]) if rows else None
    def save(self, text):
        self._exec('INSERT INTO pulse_state (id, doc) VALUES (1, %s) ON CONFLICT (id) DO UPDATE SET doc = EXCLUDED.doc', (text,))

def make_store():
    if DATABASE_URL:
        try:
            return PgStore(DATABASE_URL)
        except Exception:
            traceback.print_exc()
            print('WARNING: DATABASE_URL set but Postgres is unavailable - falling back to the local file.', flush=True)
    return FileStore()

def blank_db():
    return {'users': {}, 'names': {}, 'sessions': {}, 'accounts': {'mint': 0, 'burn': 0, 'house': 0, 'escrow': 0, 'pots': 0},
            'ledger': [], 'matches': {}, 'queue': [], 'invites': [], 'tournaments': {}, 'crews': {}, 'crew_names': {},
            'messages': [], 'friend_requests': [], 'friends': [], 'quests': {}, 'seq': 0,
            'nodes': {}, 'node_sessions': {}, 'node_rewards': [], 'node_settled': {}, 'node_carry': {}}

STORE = make_store()
DB = blank_db()
_loaded = STORE.load()
if isinstance(_loaded, dict):
    for _k, _v in _loaded.items():
        DB[_k] = _v
    for _k, _v in blank_db().items():
        DB.setdefault(_k, _v)
CHALLENGES = {}     # live game challenges (not persisted)
DIRTY = threading.Event()

def save():
    DIRTY.set()

def flush():
    with DB_LOCK:
        text = json.dumps(DB, separators=(',', ':'))
        DIRTY.clear()
    STORE.save(text)

def saver_loop():
    while True:
        time.sleep(1.0)
        if DIRTY.is_set():
            try:
                flush()
            except Exception:
                traceback.print_exc()

def next_id(prefix):
    DB['seq'] = DB.get('seq', 0) + 1
    return '%s%d%s' % (prefix, DB['seq'], secrets.token_hex(2))

# ---------------------------------------------------------------------------
# LEDGER: double-entry. Every PLS movement goes from one account to another, so
# the sum of every user balance and system account is always exactly zero.
# System accounts: mint (new PLS), burn (destroyed PLS), house (luck games),
# escrow (PvP stakes), pots (tournament pots).
# ---------------------------------------------------------------------------
SYSTEM_ACCOUNTS = ('mint', 'burn', 'house', 'escrow', 'pots')
LEDGER_CAP = 60000

def _bal_get(acct):
    if acct in SYSTEM_ACCOUNTS:
        return DB['accounts'].get(acct, 0)
    return DB['users'][acct[2:]]['balance']

def _bal_add(acct, delta):
    if acct in SYSTEM_ACCOUNTS:
        DB['accounts'][acct] = DB['accounts'].get(acct, 0) + delta
    else:
        DB['users'][acct[2:]]['balance'] += delta

def move(src, dst, amount, reason, ref=''):
    amount = int(amount)
    if amount <= 0:
        return
    if src not in ('mint', 'house') and _bal_get(src) < amount:
        raise ApiError('insufficient_pls', 'Not enough PLS.')
    _bal_add(src, -amount)
    _bal_add(dst, amount)
    DB['ledger'].append({'t': round(now(), 3), 'from': src, 'to': dst, 'amt': amount, 'why': reason, 'ref': ref})
    if len(DB['ledger']) > LEDGER_CAP:
        DB['ledger'] = DB['ledger'][-LEDGER_CAP:]

def U(uid):
    return 'u:' + uid

# ---------------------------------------------------------------------------
# ACCOUNTS
# ---------------------------------------------------------------------------
NAME_RE = re.compile(r'^[A-Za-z0-9_]{3,16}$')
ORES = ['coal', 'iron', 'crystal', 'void']
GAMES = ['quickdraw', 'sequence', 'sniper']

def hash_pw(password, salt):
    return hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), bytes.fromhex(salt), 60000).hex()

def new_fair():
    seed = secrets.token_hex(32)
    return {'server_seed': seed, 'server_hash': hashlib.sha256(seed.encode()).hexdigest(),
            'client_seed': secrets.token_hex(4), 'nonce': 0}

def new_user(username, password=None):
    uid = uuid.uuid4().hex[:12]
    salt = secrets.token_hex(16)
    return {'uid': uid, 'username': username, 'pw_salt': salt, 'pw_hash': hash_pw(password, salt) if password else '', 'created': now(),
            'balance': 0, 'ore': {o: 0 for o in ORES}, 'xp': 0, 'gear': {}, 'elo': {g: 1200 for g in GAMES},
            'elo_season': season_key(), 'best': {}, 'wins': 0, 'losses': 0, 'draws': 0,
            'appearance': {'skin': 1, 'hair_style': 0, 'hair_color': 0, 'shirt': 0, 'pants': 0, 'accent': 0},
            'cosmetics': [], 'crew': None, 'day_key': '', 'day_blocks': 0, 'week_key': '', 'week_blocks': 0,
            'lifetime_blocks': 0, 'strikes': 0, 'vein_hp': {}, 'recent_q': [], 'flagged': False, 'last_strike': 0,
            'last_seen': now(), 'last_chat': 0, 'last_practice': 0, 'fair': new_fair(), 'cavein': None,
            'luck': {'wagered': 0, 'paid': 0, 'bets': 0}, 'tickets': {}}

def user_fix(u):
    """Bring older records up to date so new fields never crash old accounts."""
    tmpl = new_user('x')          # fresh objects, so users never share dicts
    for k, v in tmpl.items():
        if k not in u:
            u[k] = v
    for o in ORES:
        u['ore'].setdefault(o, 0)
    for g in GAMES:
        u['elo'].setdefault(g, 1200)
    if u.get('elo_season') != season_key():
        # New season: everyone's rating drifts halfway back to 1200.
        for g in GAMES:
            u['elo'][g] = int(1200 + (u['elo'][g] - 1200) / 2)
        u['elo_season'] = season_key()
    return u

def create_session(uid):
    token = secrets.token_urlsafe(32)
    DB['sessions'][hashlib.sha256(token.encode()).hexdigest()] = {'uid': uid, 'exp': now() + SESSION_DAYS * 86400}
    if len(DB['sessions']) > 20000:
        cutoff = now()
        DB['sessions'] = {k: v for k, v in DB['sessions'].items() if v['exp'] > cutoff}
    return token

def session_user(token):
    if not token:
        return None
    s = DB['sessions'].get(hashlib.sha256(token.encode()).hexdigest())
    if not s or s['exp'] < now():
        return None
    u = DB['users'].get(s['uid'])
    return user_fix(u) if u else None

# ---------------------------------------------------------------------------
# LEVELS
# ---------------------------------------------------------------------------
LEVEL_TITLES = [(30, 'Void Walker'), (20, 'Crystal Warden'), (15, 'Deep Delver'), (10, 'Vein Seeker'),
                (6, 'Ore Hound'), (3, 'Tunnel Rat'), (1, 'Pebble Picker')]

def level_for(xp):
    lvl = 1
    while 25 * lvl * lvl <= xp:
        lvl += 1
    return lvl

def title_for(lvl):
    for need, name in LEVEL_TITLES:
        if lvl >= need:
            return name
    return 'Pebble Picker'

RANKS = [(1550, 'Diamond'), (1400, 'Platinum'), (1250, 'Gold'), (1100, 'Silver'), (0, 'Bronze')]

def rank_for(elo):
    for need, name in RANKS:
        if elo >= need:
            return name
    return 'Bronze'

def roll_counters(u):
    if u['day_key'] != day_key():
        u['day_key'], u['day_blocks'] = day_key(), 0
    if u['week_key'] != week_key():
        u['week_key'], u['week_blocks'] = week_key(), 0

# ---------------------------------------------------------------------------
# GEAR / FORGE (all gear helps MINING only - competitive games are gear-neutral)
# ---------------------------------------------------------------------------
TIER_NUM = {'iron': 1, 'crystal': 2, 'void': 3}
RECIPES = {}
for _tier, _ore, _pls, _dur in (('iron', {'iron': 12, 'coal': 8}, 40, 150),
                                ('crystal', {'crystal': 12, 'iron': 10}, 120, 300),
                                ('void', {'void': 10, 'crystal': 12}, 300, 600)):
    for _slot, _label in (('pickaxe', 'Pickaxe'), ('gauntlets', 'Gauntlets'), ('visor', 'Visor')):
        RECIPES['%s_%s' % (_tier, _slot)] = {'name': '%s %s' % (_tier.title(), _label), 'slot': _slot, 'tier': _tier,
                                             'cost_ore': dict(_ore), 'cost_pls': _pls, 'durability': _dur}
REPAIR_RATE = {'iron': 0.2, 'crystal': 0.4, 'void': 0.8}
MAX_STARS = 3

def gear_effect(u, slot):
    """Mining effect of an equipped, unbroken item."""
    g = u['gear'].get(slot)
    if not g or g.get('dur', 0) <= 0:
        return 0
    t = TIER_NUM.get(g['tier'], 0)
    s = g.get('stars', 0)
    if slot == 'pickaxe':
        return t + s                       # extra damage per strike
    if slot == 'gauntlets':
        return 0.015 * t + 0.008 * s       # wider strike zone
    if slot == 'visor':
        return 0.06 * t + 0.03 * s         # slower marker (fraction)
    return 0

def pick_tier(u):
    g = u['gear'].get('pickaxe')
    if not g or g.get('dur', 0) <= 0:
        return 0
    return TIER_NUM.get(g['tier'], 0)

def gear_view(u):
    out = {}
    for slot, g in u['gear'].items():
        out[slot] = dict(g)
        out[slot]['broken'] = g.get('dur', 0) <= 0
        out[slot]['repair_cost'] = int(math.ceil((g['max_dur'] - g['dur']) * REPAIR_RATE[g['tier']]))
        out[slot]['upgrade_cost'] = upgrade_cost(g) if g.get('stars', 0) < MAX_STARS else None
    return out

def upgrade_cost(g):
    s = g.get('stars', 0)
    r = RECIPES['%s_%s' % (g['tier'], g['slot'])]
    ore = {'iron': 'iron', 'crystal': 'crystal', 'void': 'void'}[g['tier']]
    return {'pls': int(r['cost_pls'] * (s + 1) * 0.6), 'ore': {ore: 4 * (s + 1)}}

def wear(u, slot):
    g = u['gear'].get(slot)
    if g and g.get('dur', 0) > 0:
        g['dur'] -= 1

# ---------------------------------------------------------------------------
# SKILL MINING
# A strike is a timing challenge: a marker sweeps a bar; tap inside the zone.
# The player picks the vein, so yields are deterministic - no random ore rolls.
# ---------------------------------------------------------------------------
TIERS = [
    {'id': 1, 'name': 'Coal Seam', 'ore': 'coal', 'hp': 12, 'pls': 10, 'speed': 0.55, 'zone': 0.26, 'level': 1, 'pick': 0},
    {'id': 2, 'name': 'Iron Vein', 'ore': 'iron', 'hp': 18, 'pls': 18, 'speed': 0.72, 'zone': 0.22, 'level': 3, 'pick': 0},
    {'id': 3, 'name': 'Pulse Crystal Grotto', 'ore': 'crystal', 'hp': 26, 'pls': 30, 'speed': 0.92, 'zone': 0.18, 'level': 8, 'pick': 1},
    {'id': 4, 'name': 'Void Rift', 'ore': 'void', 'hp': 36, 'pls': 50, 'speed': 1.15, 'zone': 0.14, 'level': 15, 'pick': 2},
]
QUALITY_DAMAGE = {'perfect': 6, 'great': 4, 'good': 2, 'miss': 0}
QUALITY_ORE = {'perfect': 3, 'great': 2, 'good': 1, 'miss': 0}
QUALITY_XP = {'perfect': 4, 'great': 3, 'good': 1, 'miss': 0}
STRIKE_GAP = 0.45
CHALLENGE_TTL = 9.0

def tier_status(u, t):
    lvl = level_for(u['xp'])
    if lvl < t['level']:
        return False, 'Reach level %d' % t['level']
    if pick_tier(u) < t['pick']:
        return False, 'Needs a %s pickaxe or better' % {1: 'Iron', 2: 'Crystal'}[t['pick']]
    return True, ''

def marker_pos(ch, t_ms):
    phase = (t_ms / 1000.0 * ch['speed'] + ch['offset']) % 2.0
    return phase if phase <= 1.0 else 2.0 - phase

def daily_mult(u):
    if u['day_blocks'] < 30:
        return 1.0
    if u['day_blocks'] < 60:
        return 0.5
    return 0.25

# ---------------------------------------------------------------------------
# QUESTS
# ---------------------------------------------------------------------------
QUEST_DEFS = [
    {'id': 'strikes', 'title': 'Land 25 Strikes', 'desc': 'Hit good or better on any vein', 'target': 25, 'pls': 30, 'ore': 'coal', 'ore_amt': 10},
    {'id': 'veins', 'title': 'Clear 4 Veins', 'desc': 'Break a vein down to nothing', 'target': 4, 'pls': 40, 'ore': 'iron', 'ore_amt': 6},
    {'id': 'skill', 'title': 'Play 3 Skill Games', 'desc': 'Practice, ranked duels or tournaments', 'target': 3, 'pls': 30, 'ore': 'crystal', 'ore_amt': 3},
    {'id': 'pvp_win', 'title': 'Win a Duel', 'desc': 'Beat another player in the Arena', 'target': 1, 'pls': 50, 'ore': 'void', 'ore_amt': 1},
    {'id': 'smith', 'title': 'Visit the Smith', 'desc': 'Forge, upgrade or repair any gear', 'target': 1, 'pls': 25, 'ore': 'iron', 'ore_amt': 4},
]

def quests_for(u):
    key = u['uid'] + ':' + day_key()
    if key not in DB['quests']:
        cutoff = (datetime.datetime.utcnow() - datetime.timedelta(days=2)).strftime('%Y-%m-%d')
        for k in [k for k, v in DB['quests'].items() if v.get('date', '') < cutoff]:
            del DB['quests'][k]
        DB['quests'][key] = {'date': day_key(), 'quests': [dict(q, progress=0, claimed=False) for q in QUEST_DEFS]}
    return DB['quests'][key]

def bump(u, qid, n=1):
    for q in quests_for(u)['quests']:
        if q['id'] == qid:
            q['progress'] = min(q['target'], q['progress'] + n)

# ---------------------------------------------------------------------------
# APPEARANCE + COSMETIC SHOP (a PLS sink)
# ---------------------------------------------------------------------------
APPEARANCE_RANGES = {'skin': 5, 'hair_style': 4, 'hair_color': 6, 'shirt': 6, 'pants': 4, 'accent': 4}
FREE_OPTIONS = {'skin': {0, 1, 2, 3, 4}, 'hair_style': {0, 1}, 'hair_color': {0, 1, 2}, 'shirt': {0, 1}, 'pants': {0, 1}, 'accent': {0}}
SHOP = [
    {'id': 'hair_style_2', 'slot': 'hair_style', 'value': 2, 'name': 'Braided Crest', 'price': 80},
    {'id': 'hair_style_3', 'slot': 'hair_style', 'value': 3, 'name': 'Miner Mohawk', 'price': 120},
    {'id': 'hair_color_3', 'slot': 'hair_color', 'value': 3, 'name': 'Ember Red Hair', 'price': 60},
    {'id': 'hair_color_4', 'slot': 'hair_color', 'value': 4, 'name': 'Frost White Hair', 'price': 90},
    {'id': 'hair_color_5', 'slot': 'hair_color', 'value': 5, 'name': 'Pulse Teal Hair', 'price': 150},
    {'id': 'shirt_2', 'slot': 'shirt', 'value': 2, 'name': 'Forest Tunic', 'price': 70},
    {'id': 'shirt_3', 'slot': 'shirt', 'value': 3, 'name': 'Royal Blue Tunic', 'price': 90},
    {'id': 'shirt_4', 'slot': 'shirt', 'value': 4, 'name': 'Crimson Tunic', 'price': 110},
    {'id': 'shirt_5', 'slot': 'shirt', 'value': 5, 'name': 'Void Cloak', 'price': 400},
    {'id': 'pants_2', 'slot': 'pants', 'value': 2, 'name': 'Sand Trousers', 'price': 50},
    {'id': 'pants_3', 'slot': 'pants', 'value': 3, 'name': 'Iron-Plated Legs', 'price': 160},
    {'id': 'accent_1', 'slot': 'accent', 'value': 1, 'name': 'Gold Trim', 'price': 120},
    {'id': 'accent_2', 'slot': 'accent', 'value': 2, 'name': 'Ember Trim', 'price': 120},
    {'id': 'accent_3', 'slot': 'accent', 'value': 3, 'name': 'Void Trim', 'price': 250},
]
SHOP_BY_ID = {s['id']: s for s in SHOP}

def profile_view(u, full=True):
    lvl = level_for(u['xp'])
    out = {'username': u['username'], 'level': lvl, 'title': title_for(lvl), 'xp': u['xp'],
           'xp_level_start': 25 * (lvl - 1) ** 2, 'xp_next': 25 * lvl * lvl, 'appearance': u['appearance'],
           'crew': crew_tag(u), 'elo': u['elo'], 'ranks': {g: rank_for(e) for g, e in u['elo'].items()},
           'wins': u['wins'], 'losses': u['losses'], 'draws': u['draws']}
    if full:
        roll_counters(u)
        out.update({'balance': u['balance'], 'ore': u['ore'], 'gear': gear_view(u), 'best': u['best'],
                    'cosmetics': u['cosmetics'], 'day_blocks': u['day_blocks'], 'week_blocks': u['week_blocks'],
                    'lifetime_blocks': u['lifetime_blocks'], 'daily_mult': daily_mult(u), 'flagged': u['flagged'],
                    'vein_hp': u['vein_hp'], 'luck': u['luck'], 'uid': u['uid']})
    return out

def crew_tag(u):
    c = DB['crews'].get(u.get('crew') or '')
    return {'id': c['id'], 'name': c['name'], 'tag': c['tag']} if c else None

# ---------------------------------------------------------------------------
# SKILL GAMES - seeded challenges. Everyone in a duel or tournament gets the
# exact same challenge, and the server scores the results. No gear bonuses.
# ---------------------------------------------------------------------------
SEQ_MAX = 20
SEQ_SHOW_MS = 450
SEQ_GAP_MS = 150

def make_challenge(game, seed):
    rng = random.Random(seed)
    if game == 'quickdraw':
        return {'game': game, 'rounds': 5, 'delays': [rng.randint(1200, 3600) for _ in range(5)]}
    if game == 'sequence':
        return {'game': game, 'runes': [rng.randint(0, 3) for _ in range(SEQ_MAX)], 'start_len': 3,
                'show_ms': SEQ_SHOW_MS, 'gap_ms': SEQ_GAP_MS}
    if game == 'sniper':
        return {'game': game, 'grid': 4, 'targets': [{'cell': rng.randint(0, 15), 'delay': rng.randint(400, 1400)} for _ in range(12)],
                'window_ms': 1200}
    raise ApiError('bad_game')

def score_result(ch, result, elapsed_ms):
    """Return (score, detail). Higher score is always better. Raises on impossible data."""
    if not isinstance(result, dict):
        raise ApiError('bad_result')
    game = ch['game']
    slack = 600
    if game == 'quickdraw':
        rts = result.get('reactions')
        if not isinstance(rts, list) or len(rts) != ch['rounds']:
            raise ApiError('bad_result')
        total, fouls, used = 0, 0, 0
        for i, rt in enumerate(rts):
            rt = to_int(rt, -2)
            if rt == -1:
                fouls += 1                       # tapped too early
                continue
            if rt < 100 or rt > 3000:
                raise ApiError('impossible_reaction', 'That reaction time is not humanly possible.')
            total += max(0, 500 - rt)
            used += rt
        if elapsed_ms + slack < sum(ch['delays']) + used:
            raise ApiError('too_fast', 'Result arrived faster than the game can be played.')
        return total, '%d pts - %d clean rounds, %d early taps' % (total, ch['rounds'] - fouls, fouls)
    if game == 'sequence':
        reached = to_int(result.get('reached'), -1)
        if reached < 0 or reached > SEQ_MAX:
            raise ApiError('bad_result')
        need = 0
        for n in range(ch['start_len'], reached + 1):
            need += n * (ch['show_ms'] + ch['gap_ms'])
        if elapsed_ms + slack < need * 0.9:
            raise ApiError('too_fast', 'Result arrived faster than the runes can be shown.')
        best = max(0, reached)
        return best * 100, 'Remembered %d runes' % best
    if game == 'sniper':
        hits = result.get('hits')
        if not isinstance(hits, list) or len(hits) != len(ch['targets']):
            raise ApiError('bad_result')
        total, n_hit, used = 0, 0, 0
        for h in hits:
            if not isinstance(h, dict):
                raise ApiError('bad_result')
            if h.get('hit') is True:
                rt = to_int(h.get('rt'), -1)
                if rt < 120 or rt > ch['window_ms']:
                    raise ApiError('impossible_reaction', 'That reaction time is not humanly possible.')
                total += max(0, 100 - max(0, rt - 220) // 7)
                n_hit += 1
                used += rt
            else:
                used += ch['window_ms']
        delays = sum(t['delay'] for t in ch['targets'])
        if elapsed_ms + slack < delays + used * 0.8:
            raise ApiError('too_fast', 'Result arrived faster than the game can be played.')
        return total, '%d/%d veins hit - %d pts' % (n_hit, len(ch['targets']), total)
    raise ApiError('bad_game')

def new_challenge(u, game, mode, extra=None):
    if game not in GAMES:
        raise ApiError('bad_game')
    seed = secrets.randbits(48)
    cid = 'c' + secrets.token_hex(6)
    ch = make_challenge(game, seed)
    CHALLENGES[cid] = {'uid': u['uid'], 'mode': mode, 'game': game, 'challenge': ch, 'issued': now(), 'extra': extra or {}}
    for k in [k for k, v in CHALLENGES.items() if now() - v['issued'] > 900]:
        del CHALLENGES[k]
    return cid, ch

def take_challenge(u, cid, mode):
    c = CHALLENGES.pop(cid or '', None)
    if not c or c['uid'] != u['uid'] or c['mode'] != mode:
        raise ApiError('no_challenge', 'That game session expired. Start again.')
    return c, int((now() - c['issued']) * 1000)

def record_best(u, game, score):
    old = u['best'].get(game)
    if old is None or score > old:
        u['best'][game] = score
        return True
    return False

def elo_update(a, b, game, score_a):
    ea = 1.0 / (1 + 10 ** ((b['elo'][game] - a['elo'][game]) / 400.0))
    k = 32
    da = int(round(k * (score_a - ea)))
    a['elo'][game] += da
    b['elo'][game] -= da
    return da

# ---------------------------------------------------------------------------
# PVP DUELS (asynchronous: both players play the same seeded challenge)
# ---------------------------------------------------------------------------
STAKES = [0, 10, 25, 50, 100, 250]
RAKE = 0.05            # 5% of every PvP pot is burned
MATCH_TTL = 15 * 60
QUEUE_TTL = 10 * 60

def user_busy(uid):
    if any(q['uid'] == uid for q in DB['queue']):
        return 'already_queued'
    for m in DB['matches'].values():
        if m['state'] == 'active' and uid in m['players'] and uid not in m['subs']:
            return 'finish_your_duel'
    return None

def create_match(a_uid, b_uid, game, stake):
    mid = next_id('m')
    seed = secrets.randbits(48)
    DB['matches'][mid] = {'id': mid, 'game': game, 'stake': stake, 'seed': seed, 'players': [a_uid, b_uid],
                          'created': now(), 'deadline': now() + MATCH_TTL, 'subs': {}, 'started': {},
                          'state': 'active', 'result': None}
    return DB['matches'][mid]

def settle_match(m):
    if m['state'] != 'active':
        return
    a_uid, b_uid = m['players']
    a, b = DB['users'][a_uid], DB['users'][b_uid]
    sa, sb = m['subs'].get(a_uid), m['subs'].get(b_uid)
    pot = m['stake'] * 2
    if sa is None and sb is None:
        move('escrow', U(a_uid), m['stake'], 'duel_refund', m['id'])
        move('escrow', U(b_uid), m['stake'], 'duel_refund', m['id'])
        m['state'], m['result'] = 'void', {'winner': None, 'reason': 'nobody played'}
        return
    if sa is not None and sb is not None and sa['score'] == sb['score']:
        move('escrow', U(a_uid), m['stake'], 'duel_draw', m['id'])
        move('escrow', U(b_uid), m['stake'], 'duel_draw', m['id'])
        elo_update(a, b, m['game'], 0.5)
        a['draws'] += 1
        b['draws'] += 1
        m['state'], m['result'] = 'settled', {'winner': None, 'reason': 'draw'}
        return
    if sb is None or (sa is not None and sa['score'] > sb['score']):
        win, lose = a, b
    else:
        win, lose = b, a
    rake = int(pot * RAKE)
    move('escrow', U(win['uid']), pot - rake, 'duel_win', m['id'])
    move('escrow', 'burn', rake, 'duel_rake', m['id'])
    da = elo_update(win, lose, m['game'], 1.0)
    win['wins'] += 1
    lose['losses'] += 1
    bump(win, 'pvp_win')
    reason = 'higher score' if (sa is not None and sb is not None) else 'opponent did not play in time'
    m['state'], m['result'] = 'settled', {'winner': win['username'], 'payout': pot - rake, 'rake': rake, 'elo_change': da, 'reason': reason}

def pvp_housekeeping():
    t = now()
    for q in list(DB['queue']):
        if t - q['ts'] > QUEUE_TTL:
            DB['queue'].remove(q)
            move('escrow', U(q['uid']), q['stake'], 'queue_timeout', '')
    for inv in list(DB['invites']):
        if t - inv['ts'] > QUEUE_TTL:
            DB['invites'].remove(inv)
            move('escrow', U(inv['from']), inv['stake'], 'invite_expired', inv['id'])
    for m in DB['matches'].values():
        if m['state'] == 'active' and (len(m['subs']) == 2 or t > m['deadline']):
            settle_match(m)
    if len(DB['matches']) > 5000:
        keep = sorted(DB['matches'].values(), key=lambda m: m['created'])[-4000:]
        DB['matches'] = {m['id']: m for m in keep}

def match_view(m, uid):
    opp_uid = [p for p in m['players'] if p != uid][0]
    opp = DB['users'].get(opp_uid, {})
    mine = m['subs'].get(uid)
    theirs = m['subs'].get(opp_uid)
    done = m['state'] != 'active'
    return {'id': m['id'], 'game': m['game'], 'stake': m['stake'], 'state': m['state'], 'opponent': opp.get('username', '?'),
            'opponent_elo': opp.get('elo', {}).get(m['game'], 1200), 'my_score': mine['score'] if mine else None,
            'their_score': theirs['score'] if (theirs and (done or mine)) else None, 'they_played': theirs is not None,
            'deadline_in': max(0, int(m['deadline'] - now())), 'result': m['result'], 'created': m['created']}

# ---------------------------------------------------------------------------
# TOURNAMENTS (weekly, one per skill game)
# ---------------------------------------------------------------------------
T_ENTRY = 50
T_ATTEMPTS = 5
T_RAKE = 0.10
T_SPLIT = [0.5, 0.3, 0.2]

def tournament(game, wk=None):
    key = '%s:%s' % (game, wk or week_key())
    if key not in DB['tournaments']:
        DB['tournaments'][key] = {'key': key, 'game': game, 'week': wk or week_key(), 'pot': 0, 'entries': {}, 'settled': False, 'payouts': []}
    return DB['tournaments'][key]

def settle_tournaments():
    wk = week_key()
    for t in DB['tournaments'].values():
        if t['settled'] or t['week'] == wk:
            continue
        ranked = sorted([(e['best'], uid) for uid, e in t['entries'].items() if e['best'] is not None], reverse=True)
        places = ranked[:len(T_SPLIT)]
        weights = T_SPLIT[:len(places)]
        total_w = sum(weights) or 1
        paid = 0
        for i, (score, uid) in enumerate(places):
            amt = int(t['pot'] * weights[i] / total_w) if i < len(places) - 1 else t['pot'] - paid
            if amt > 0 and uid in DB['users']:
                move('pots', U(uid), amt, 'tournament_prize', t['key'])
                paid += amt
                t['payouts'].append({'place': i + 1, 'username': DB['users'][uid]['username'], 'score': score, 'prize': amt})
        if t['pot'] - paid > 0:
            move('pots', 'burn', t['pot'] - paid, 'tournament_unclaimed', t['key'])
        t['settled'] = True

def tournament_view(t, uid):
    rows = sorted([(e['best'], DB['users'][u]['username']) for u, e in t['entries'].items() if e['best'] is not None and u in DB['users']], reverse=True)
    me = t['entries'].get(uid)
    return {'game': t['game'], 'week': t['week'], 'pot': t['pot'], 'entry_fee': T_ENTRY, 'attempts_per_entry': T_ATTEMPTS,
            'players': len(t['entries']), 'top': [{'place': i + 1, 'username': n, 'score': s} for i, (s, n) in enumerate(rows[:10])],
            'my_best': me['best'] if me else None, 'my_attempts_left': me['attempts'] if me else 0,
            'my_place': next((i + 1 for i, (s, n) in enumerate(rows) if me and n == DB['users'][uid]['username']), None),
            'payout_split': T_SPLIT, 'settled': t['settled'], 'payouts': t['payouts']}

# ---------------------------------------------------------------------------
# LUCK GAMES - house-banked, provably fair.
# result = HMAC_SHA256(server_seed, client_seed:nonce). The server publishes
# sha256(server_seed) BEFORE you bet and reveals the seed when you rotate it,
# so every past result can be checked.
# ---------------------------------------------------------------------------
HOUSE_EDGE = 0.03
MIN_BET, MAX_BET = 1, 500

def fair_floats(u, count=1):
    f = u['fair']
    f['nonce'] += 1
    out = []
    i = 0
    while len(out) < count:
        h = hmac.new(f['server_seed'].encode(), ('%s:%d:%d' % (f['client_seed'], f['nonce'], i)).encode(), hashlib.sha256).hexdigest()
        for j in range(0, 52, 13):
            if len(out) < count:
                out.append(int(h[j:j + 13], 16) / float(16 ** 13))
        i += 1
    return out, f['nonce']

def verify_float(server_seed, client_seed, nonce, index=0):
    """Same math the server uses - published so players can check results."""
    block, pos = divmod(index, 4)
    h = hmac.new(server_seed.encode(), ('%s:%d:%d' % (client_seed, nonce, block)).encode(), hashlib.sha256).hexdigest()
    return int(h[pos * 13:pos * 13 + 13], 16) / float(16 ** 13)

def check_bet(u, bet):
    bet = to_int(bet, 0)
    if bet < MIN_BET or bet > MAX_BET:
        raise ApiError('bad_bet', 'Bets are %d to %d PLS.' % (MIN_BET, MAX_BET))
    if u['balance'] < bet:
        raise ApiError('insufficient_pls', 'Not enough PLS.')
    return bet

def cavein_mult(caves, safe):
    m = 1.0
    for i in range(safe):
        m *= (25 - i) / float(25 - caves - i)
    return round(m * (1 - HOUSE_EDGE), 4)

# ---------------------------------------------------------------------------
# HANDLERS
# ---------------------------------------------------------------------------
AUTH_HITS = {}

AUTH_LIMIT = int(os.environ.get('PULSE_AUTH_LIMIT', '12'))

def rate_limit(ip, limit=None, window=60):
    limit = limit or AUTH_LIMIT
    t = now()
    hits = [h for h in AUTH_HITS.get(ip, []) if t - h < window]
    if len(hits) >= limit:
        raise ApiError('slow_down', 'Too many attempts. Wait a minute.', 429)
    hits.append(t)
    AUTH_HITS[ip] = hits

def h_register(b, ip):
    rate_limit(ip)
    name = str(b.get('username', '')).strip()
    pw = str(b.get('password', ''))
    if not NAME_RE.match(name):
        raise ApiError('bad_username', 'Usernames are 3-16 letters, numbers or _.')
    if len(pw) < 6 or len(pw) > 100:
        raise ApiError('bad_password', 'Passwords need at least 6 characters.')
    if name.lower() in DB['names']:
        raise ApiError('name_taken', 'That username is taken.')
    u = new_user(name, pw)
    DB['users'][u['uid']] = u
    DB['names'][name.lower()] = u['uid']
    move('mint', U(u['uid']), 25, 'welcome_bonus')
    token = create_session(u['uid'])
    save()
    return {'ok': True, 'token': token, 'profile': profile_view(u)}

def h_login(b, ip):
    rate_limit(ip)
    uid = DB['names'].get(str(b.get('username', '')).strip().lower())
    u = DB['users'].get(uid) if uid else None
    if not u or not hmac.compare_digest(u['pw_hash'], hash_pw(str(b.get('password', '')), u['pw_salt'])):
        raise ApiError('bad_login', 'Wrong username or password.', 401)
    user_fix(u)
    token = create_session(u['uid'])
    save()
    return {'ok': True, 'token': token, 'profile': profile_view(u)}

def h_logout(u, b, token):
    DB['sessions'].pop(hashlib.sha256(token.encode()).hexdigest(), None)
    save()
    return {'ok': True}

def h_me(u, q):
    return {'ok': True, 'profile': profile_view(u)}

def h_heartbeat(u, b):
    u['last_seen'] = now()
    online = [x['username'] for x in DB['users'].values() if now() - x.get('last_seen', 0) < 120]
    return {'ok': True, 'online': len(online), 'players': sorted(online)[:40], 'server_time': int(now())}

def h_ledger(u, q):
    acct = U(u['uid'])
    limit = max(1, min(100, to_int(q.get('limit', ['40'])[0], 40)))
    out = []
    for e in reversed(DB['ledger']):
        if e['from'] == acct or e['to'] == acct:
            out.append({'t': e['t'], 'amount': e['amt'] if e['to'] == acct else -e['amt'], 'why': e['why'], 'ref': e['ref']})
            if len(out) >= limit:
                break
    return {'ok': True, 'entries': out, 'balance': u['balance']}

def h_economy(q):
    acc = DB['accounts']
    circ = sum(x['balance'] for x in DB['users'].values())
    return {'ok': True, 'minted': -acc['mint'], 'burned': acc['burn'], 'circulating': circ, 'in_escrow': acc['escrow'],
            'in_tournament_pots': acc['pots'], 'house_net': acc['house'], 'players': len(DB['users']),
            'ledger_check': circ + sum(acc.values()) == 0}

# ---- mining ---------------------------------------------------------------
def h_veins(u, q):
    out = []
    for t in TIERS:
        ok, why = tier_status(u, t)
        out.append({'id': t['id'], 'name': t['name'], 'ore': t['ore'], 'hp': t['hp'], 'hp_left': u['vein_hp'].get(str(t['id']), t['hp']),
                    'pls': t['pls'], 'unlocked': ok, 'locked_reason': why, 'level': t['level']})
    roll_counters(u)
    return {'ok': True, 'veins': out, 'daily_mult': daily_mult(u), 'day_blocks': u['day_blocks']}

def h_mine_start(u, b):
    tid = to_int(b.get('tier'), 0)
    t = next((x for x in TIERS if x['id'] == tid), None)
    if not t:
        raise ApiError('bad_tier')
    ok, why = tier_status(u, t)
    if not ok:
        raise ApiError('vein_locked', why)
    rng = random.Random(secrets.randbits(48))
    zone = t['zone'] + gear_effect(u, 'gauntlets')
    speed = t['speed'] * (1 - gear_effect(u, 'visor'))
    center = round(rng.uniform(zone / 2 + 0.05, 1 - zone / 2 - 0.05), 4)
    ch = {'tier': tid, 'speed': round(speed, 4), 'offset': round(rng.random(), 4), 'zone_center': center, 'zone_width': round(zone, 4)}
    for k in [k for k, v in CHALLENGES.items() if v['uid'] == u['uid'] and v['mode'] == 'mine']:
        del CHALLENGES[k]
    cid = 'c' + secrets.token_hex(6)
    CHALLENGES[cid] = {'uid': u['uid'], 'mode': 'mine', 'game': 'mine', 'challenge': ch, 'issued': now(), 'extra': {}}
    return {'ok': True, 'id': cid, 'challenge': ch, 'expires_in': CHALLENGE_TTL}

def h_mine_strike(u, b):
    c, elapsed = take_challenge(u, b.get('id'), 'mine')
    ch = c['challenge']
    tap = to_int(b.get('tap_ms'), -1)
    if elapsed > CHALLENGE_TTL * 1000:
        raise ApiError('too_slow', 'The strike window closed. Swing again.')
    if tap < 150 or tap > elapsed + 150:
        raise ApiError('bad_timing', 'Strike timing did not match the server clock.')
    if now() - u['last_strike'] < STRIKE_GAP:
        raise ApiError('too_fast', 'Catch your breath between strikes.', 429)
    u['last_strike'] = now()
    t = TIERS[ch['tier'] - 1]
    d = abs(marker_pos(ch, tap) - ch['zone_center'])
    half = ch['zone_width'] / 2
    q = 'perfect' if d <= half * 0.3 else 'great' if d <= half * 0.65 else 'good' if d <= half else 'miss'
    # Anti-bot: a long run of near-perfect strikes gets capped at "good".
    u['recent_q'] = (u['recent_q'] + [q])[-40:]
    if len(u['recent_q']) >= 40 and u['recent_q'].count('perfect') >= 37:
        u['flagged'] = True
    if u['flagged'] and q in ('perfect', 'great'):
        q = 'good'
    roll_counters(u)
    old_lvl = level_for(u['xp'])
    dmg = QUALITY_DAMAGE[q] + (gear_effect(u, 'pickaxe') if q != 'miss' else 0)
    ore_amt = QUALITY_ORE[q]
    u['ore'][t['ore']] += ore_amt
    u['xp'] += QUALITY_XP[q] + (t['id'] - 1 if q != 'miss' else 0)
    u['strikes'] += 1
    if q != 'miss':
        bump(u, 'strikes')
    wear(u, 'pickaxe')
    wear(u, 'gauntlets')
    wear(u, 'visor')
    key = str(t['id'])
    hp = u['vein_hp'].get(key, t['hp']) - dmg
    cleared, pls = False, 0
    if hp <= 0:
        cleared = True
        pls = max(1, int(t['pls'] * daily_mult(u)))
        move('mint', U(u['uid']), pls, 'vein_cleared', t['name'])
        u['day_blocks'] += 1
        u['week_blocks'] += 1
        u['lifetime_blocks'] += 1
        bump(u, 'veins')
        hp = t['hp']
    u['vein_hp'][key] = hp
    new_lvl = level_for(u['xp'])
    save()
    return {'ok': True, 'quality': q, 'marker': round(marker_pos(ch, tap), 4), 'damage': dmg, 'ore': t['ore'], 'ore_gained': ore_amt,
            'vein_hp': hp, 'vein_max': t['hp'], 'cleared': cleared, 'pls': pls, 'balance': u['balance'], 'ore_inv': u['ore'],
            'xp': u['xp'], 'level': new_lvl, 'level_up': new_lvl > old_lvl, 'title': title_for(new_lvl), 'daily_mult': daily_mult(u),
            'gear': gear_view(u)}

# ---- forge ----------------------------------------------------------------
def h_recipes(q):
    return {'ok': True, 'recipes': RECIPES, 'repair_rate': REPAIR_RATE, 'max_stars': MAX_STARS}

def pay_ore(u, cost):
    for k, v in cost.items():
        if u['ore'].get(k, 0) < v:
            raise ApiError('need_' + k, 'Not enough %s.' % k)
    for k, v in cost.items():
        u['ore'][k] -= v

def h_forge(u, b):
    rid = b.get('recipe')
    r = RECIPES.get(rid)
    if not r:
        raise ApiError('bad_recipe')
    for k, v in r['cost_ore'].items():
        if u['ore'].get(k, 0) < v:
            raise ApiError('need_' + k, 'Not enough %s.' % k)
    if u['balance'] < r['cost_pls']:
        raise ApiError('insufficient_pls', 'Not enough PLS.')
    pay_ore(u, r['cost_ore'])
    move(U(u['uid']), 'burn', r['cost_pls'], 'forge', rid)
    u['gear'][r['slot']] = {'recipe': rid, 'name': r['name'], 'slot': r['slot'], 'tier': r['tier'], 'stars': 0,
                            'dur': r['durability'], 'max_dur': r['durability']}
    bump(u, 'smith')
    save()
    return {'ok': True, 'profile': profile_view(u)}

def h_repair(u, b):
    g = u['gear'].get(b.get('slot'))
    if not g:
        raise ApiError('no_gear')
    cost = int(math.ceil((g['max_dur'] - g['dur']) * REPAIR_RATE[g['tier']]))
    if cost <= 0:
        raise ApiError('not_damaged', 'That gear is already in perfect shape.')
    move(U(u['uid']), 'burn', cost, 'repair', g['recipe'])
    g['dur'] = g['max_dur']
    bump(u, 'smith')
    save()
    return {'ok': True, 'cost': cost, 'profile': profile_view(u)}

def h_upgrade(u, b):
    g = u['gear'].get(b.get('slot'))
    if not g:
        raise ApiError('no_gear')
    if g.get('stars', 0) >= MAX_STARS:
        raise ApiError('max_stars', 'Already fully upgraded.')
    cost = upgrade_cost(g)
    if u['balance'] < cost['pls']:
        raise ApiError('insufficient_pls', 'Not enough PLS.')
    pay_ore(u, cost['ore'])
    move(U(u['uid']), 'burn', cost['pls'], 'upgrade', g['recipe'])
    g['stars'] = g.get('stars', 0) + 1
    g['max_dur'] += 50
    g['dur'] = g['max_dur']
    bump(u, 'smith')
    save()
    return {'ok': True, 'profile': profile_view(u)}

# ---- quests ---------------------------------------------------------------
def h_quests(u, q):
    left = 86400 - int(now() % 86400)
    return {'ok': True, 'quests': quests_for(u)['quests'], 'resets_in': left}

def h_claim(u, b):
    qq = next((x for x in quests_for(u)['quests'] if x['id'] == b.get('quest_id')), None)
    if not qq:
        raise ApiError('not_found')
    if qq['claimed']:
        raise ApiError('already_claimed', 'Already claimed.', 409)
    if qq['progress'] < qq['target']:
        raise ApiError('not_complete', 'Not finished yet.')
    qq['claimed'] = True
    move('mint', U(u['uid']), qq['pls'], 'quest', qq['id'])
    u['ore'][qq['ore']] += qq['ore_amt']
    save()
    return {'ok': True, 'pls': qq['pls'], 'ore': qq['ore'], 'ore_amt': qq['ore_amt'], 'balance': u['balance']}

# ---- practice -------------------------------------------------------------
def h_practice_start(u, b):
    cid, ch = new_challenge(u, b.get('game'), 'practice')
    return {'ok': True, 'id': cid, 'challenge': ch}

def h_practice_submit(u, b):
    c, elapsed = take_challenge(u, b.get('id'), 'practice')
    score, detail = score_result(c['challenge'], b.get('result'), elapsed)
    new_best = record_best(u, c['game'], score)
    bump(u, 'skill')
    save()
    return {'ok': True, 'game': c['game'], 'score': score, 'detail': detail, 'best': u['best'][c['game']], 'new_best': new_best}

# ---- pvp ------------------------------------------------------------------
def check_stake(u, game, stake):
    if game not in GAMES:
        raise ApiError('bad_game')
    stake = to_int(stake, -1)
    if stake not in STAKES:
        raise ApiError('bad_stake', 'Stakes are %s PLS.' % ', '.join(str(s) for s in STAKES))
    if u['balance'] < stake:
        raise ApiError('insufficient_pls', 'Not enough PLS for that stake.')
    return stake

def h_pvp_queue(u, b):
    pvp_housekeeping()
    game = b.get('game')
    stake = check_stake(u, game, b.get('stake'))
    busy = user_busy(u['uid'])
    if busy:
        raise ApiError(busy, 'Finish or cancel your current duel first.')
    move(U(u['uid']), 'escrow', stake, 'duel_stake', game)
    t = now()
    best = None
    for q in DB['queue']:
        if q['game'] == game and q['stake'] == stake and q['uid'] != u['uid']:
            other = DB['users'][q['uid']]
            gap = abs(other['elo'][game] - u['elo'][game])
            if gap <= 300 + 10 * (t - q['ts']):
                if best is None or gap < best[0]:
                    best = (gap, q)
    if best:
        DB['queue'].remove(best[1])
        m = create_match(best[1]['uid'], u['uid'], game, stake)
        save()
        return {'ok': True, 'status': 'matched', 'match': match_view(m, u['uid'])}
    DB['queue'].append({'uid': u['uid'], 'game': game, 'stake': stake, 'ts': t})
    save()
    return {'ok': True, 'status': 'waiting'}

def h_pvp_cancel(u, b):
    for q in list(DB['queue']):
        if q['uid'] == u['uid']:
            DB['queue'].remove(q)
            move('escrow', U(u['uid']), q['stake'], 'queue_cancel', q['game'])
            save()
            return {'ok': True}
    raise ApiError('not_queued')

def h_pvp_challenge(u, b):
    pvp_housekeeping()
    game = b.get('game')
    stake = check_stake(u, game, b.get('stake'))
    to_uid = DB['names'].get(str(b.get('username', '')).strip().lower())
    if not to_uid or to_uid == u['uid']:
        raise ApiError('player_not_found', 'No player with that name.')
    busy = user_busy(u['uid'])
    if busy:
        raise ApiError(busy, 'Finish or cancel your current duel first.')
    move(U(u['uid']), 'escrow', stake, 'duel_stake', game)
    inv = {'id': next_id('i'), 'from': u['uid'], 'to': to_uid, 'game': game, 'stake': stake, 'ts': now()}
    DB['invites'].append(inv)
    save()
    return {'ok': True, 'invite_id': inv['id']}

def h_pvp_respond(u, b):
    pvp_housekeeping()
    inv = next((i for i in DB['invites'] if i['id'] == b.get('invite_id') and i['to'] == u['uid']), None)
    if not inv:
        raise ApiError('invite_gone', 'That challenge is no longer open.')
    DB['invites'].remove(inv)
    if not b.get('accept'):
        move('escrow', U(inv['from']), inv['stake'], 'invite_declined', inv['id'])
        save()
        return {'ok': True, 'status': 'declined'}
    if u['balance'] < inv['stake']:
        move('escrow', U(inv['from']), inv['stake'], 'invite_failed', inv['id'])
        save()
        raise ApiError('insufficient_pls', 'Not enough PLS for that stake.')
    busy = user_busy(u['uid'])
    if busy:
        DB['invites'].append(inv)
        raise ApiError(busy, 'Finish or cancel your current duel first.')
    move(U(u['uid']), 'escrow', inv['stake'], 'duel_stake', inv['game'])
    m = create_match(inv['from'], u['uid'], inv['game'], inv['stake'])
    save()
    return {'ok': True, 'status': 'matched', 'match': match_view(m, u['uid'])}

def h_pvp_status(u, q):
    pvp_housekeeping()
    mine = sorted([m for m in DB['matches'].values() if u['uid'] in m['players']], key=lambda m: -m['created'])[:12]
    queued = next((x for x in DB['queue'] if x['uid'] == u['uid']), None)
    invites = [{'id': i['id'], 'from': DB['users'][i['from']]['username'], 'game': i['game'], 'stake': i['stake']}
               for i in DB['invites'] if i['to'] == u['uid']]
    sent = [{'id': i['id'], 'to': DB['users'][i['to']]['username'], 'game': i['game'], 'stake': i['stake']}
            for i in DB['invites'] if i['from'] == u['uid']]
    save()
    return {'ok': True, 'queue': {'game': queued['game'], 'stake': queued['stake'], 'waiting': int(now() - queued['ts'])} if queued else None,
            'matches': [match_view(m, u['uid']) for m in mine], 'invites': invites, 'sent': sent, 'stakes': STAKES,
            'elo': u['elo'], 'ranks': {g: rank_for(e) for g, e in u['elo'].items()}, 'rake': RAKE}

def h_pvp_play(u, b):
    m = DB['matches'].get(b.get('match_id'))
    if not m or u['uid'] not in m['players'] or m['state'] != 'active':
        raise ApiError('no_match', 'That duel is over.')
    if u['uid'] in m['subs']:
        raise ApiError('already_played')
    if u['uid'] in m['started']:
        # Restarting would let a player retry until they get a good score. A restart counts as a forfeit.
        m['subs'][u['uid']] = {'score': 0, 'detail': 'left the duel mid-game', 'at': now()}
        pvp_housekeeping()
        save()
        raise ApiError('duel_forfeited', 'You left this duel mid-game, so it counted as 0 points.')
    m['started'][u['uid']] = now()
    ch = make_challenge(m['game'], m['seed'])
    cid = 'c' + secrets.token_hex(6)
    CHALLENGES[cid] = {'uid': u['uid'], 'mode': 'pvp', 'game': m['game'], 'challenge': ch, 'issued': now(), 'extra': {'match': m['id']}}
    save()
    return {'ok': True, 'id': cid, 'challenge': ch}

def h_pvp_forfeit(u, b):
    m = DB['matches'].get(b.get('match_id'))
    if not m or u['uid'] not in m['players'] or m['state'] != 'active' or u['uid'] in m['subs']:
        raise ApiError('no_match', 'That duel is over.')
    for k in [k for k, v in CHALLENGES.items() if v['uid'] == u['uid'] and v['extra'].get('match') == m['id']]:
        del CHALLENGES[k]
    m['subs'][u['uid']] = {'score': 0, 'detail': 'forfeited', 'at': now()}
    pvp_housekeeping()
    save()
    return {'ok': True, 'match': match_view(m, u['uid'])}

def h_pvp_submit(u, b):
    c, elapsed = take_challenge(u, b.get('id'), 'pvp')
    m = DB['matches'].get(c['extra']['match'])
    if not m or m['state'] != 'active' or u['uid'] in m['subs']:
        raise ApiError('no_match', 'That duel is over.')
    score, detail = score_result(c['challenge'], b.get('result'), elapsed)
    m['subs'][u['uid']] = {'score': score, 'detail': detail, 'at': now()}
    record_best(u, c['game'], score)
    bump(u, 'skill')
    pvp_housekeeping()
    save()
    return {'ok': True, 'score': score, 'detail': detail, 'match': match_view(m, u['uid'])}

# ---- tournaments ----------------------------------------------------------
def h_tournaments(u, q):
    settle_tournaments()
    save()
    last = [tournament_view(t, u['uid']) for t in sorted(DB['tournaments'].values(), key=lambda t: t['week']) if t['settled']][-3:]
    return {'ok': True, 'week': week_key(), 'active': [tournament_view(tournament(g), u['uid']) for g in GAMES], 'recent': last}

def h_t_enter(u, b):
    settle_tournaments()
    game = b.get('game')
    if game not in GAMES:
        raise ApiError('bad_game')
    t = tournament(game)
    e = t['entries'].get(u['uid'])
    if e and e['attempts'] > 0:
        raise ApiError('already_entered', 'Use your remaining attempts first.')
    move(U(u['uid']), 'pots', T_ENTRY, 'tournament_entry', t['key'])
    rake = int(T_ENTRY * T_RAKE)
    move('pots', 'burn', rake, 'tournament_rake', t['key'])
    t['pot'] += T_ENTRY - rake
    if e:
        e['attempts'] += T_ATTEMPTS
    else:
        t['entries'][u['uid']] = {'attempts': T_ATTEMPTS, 'best': None}
    save()
    return {'ok': True, 'tournament': tournament_view(t, u['uid'])}

def h_t_start(u, b):
    settle_tournaments()
    game = b.get('game')
    if game not in GAMES:
        raise ApiError('bad_game')
    t = tournament(game)
    e = t['entries'].get(u['uid'])
    if not e or e['attempts'] <= 0:
        raise ApiError('no_attempts', 'Enter the tournament first.')
    e['attempts'] -= 1
    cid, ch = new_challenge(u, game, 'tournament', {'key': t['key']})
    save()
    return {'ok': True, 'id': cid, 'challenge': ch, 'attempts_left': e['attempts']}

def h_t_submit(u, b):
    c, elapsed = take_challenge(u, b.get('id'), 'tournament')
    t = DB['tournaments'].get(c['extra']['key'])
    if not t or t['settled']:
        raise ApiError('tournament_closed', 'That tournament has ended.')
    score, detail = score_result(c['challenge'], b.get('result'), elapsed)
    e = t['entries'][u['uid']]
    improved = e['best'] is None or score > e['best']
    if improved:
        e['best'] = score
    record_best(u, c['game'], score)
    bump(u, 'skill')
    save()
    return {'ok': True, 'score': score, 'detail': detail, 'improved': improved, 'tournament': tournament_view(t, u['uid'])}

# ---- luck -----------------------------------------------------------------
def payout_of(u, exact):
    """Whole PLS now; the leftover fraction is carried to the next win so rounding never adds to the house edge."""
    if exact <= 0:
        return 0
    total = exact + u['luck'].get('dust', 0.0)
    whole = int(total)
    u['luck']['dust'] = round(total - whole, 6)
    return whole

def luck_done(u, bet, payout):
    u['luck']['wagered'] += bet
    u['luck']['paid'] += payout
    u['luck']['bets'] += 1

def fair_view(u):
    f = u['fair']
    return {'server_hash': f['server_hash'], 'client_seed': f['client_seed'], 'nonce': f['nonce']}

def h_fair(u, q):
    return {'ok': True, 'fair': fair_view(u), 'house_edge': HOUSE_EDGE, 'min_bet': MIN_BET, 'max_bet': MAX_BET}

def h_fair_seed(u, b):
    if u.get('cavein'):
        raise ApiError('finish_cavein', 'Finish your Cave-In run first.')
    old = u['fair']
    seed = str(b.get('client_seed') or secrets.token_hex(4))[:32]
    if not re.match(r'^[A-Za-z0-9_-]{1,32}$', seed):
        raise ApiError('bad_seed', 'Seeds are letters, numbers, _ or -.')
    u['fair'] = new_fair()
    u['fair']['client_seed'] = seed
    save()
    return {'ok': True, 'revealed': {'server_seed': old['server_seed'], 'server_hash': old['server_hash'],
                                     'client_seed': old['client_seed'], 'last_nonce': old['nonce']}, 'fair': fair_view(u)}

def h_flip(u, b):
    bet = check_bet(u, b.get('bet'))
    pick = b.get('pick')
    if pick not in ('teal', 'amber'):
        raise ApiError('bad_pick')
    (r,), nonce = fair_floats(u, 1)
    side = 'teal' if r < 0.5 else 'amber'
    move(U(u['uid']), 'house', bet, 'flip_bet')
    payout = payout_of(u, bet * 2 * (1 - HOUSE_EDGE)) if side == pick else 0
    if payout:
        move('house', U(u['uid']), payout, 'flip_win')
    luck_done(u, bet, payout)
    save()
    return {'ok': True, 'result': side, 'win': payout > 0, 'payout': payout, 'roll': round(r, 6), 'nonce': nonce,
            'server_hash': u['fair']['server_hash'], 'balance': u['balance']}

def h_dice(u, b):
    bet = check_bet(u, b.get('bet'))
    target = to_int(b.get('target'), 0)
    if target < 2 or target > 95:
        raise ApiError('bad_target', 'Pick a target from 2 to 95.')
    (r,), nonce = fair_floats(u, 1)
    roll = int(r * 10000) / 100.0
    move(U(u['uid']), 'house', bet, 'dice_bet')
    payout = payout_of(u, bet * 100 * (1 - HOUSE_EDGE) / target) if roll < target else 0
    if payout:
        move('house', U(u['uid']), payout, 'dice_win')
    luck_done(u, bet, payout)
    save()
    return {'ok': True, 'roll': roll, 'target': target, 'win': payout > 0, 'payout': payout,
            'multiplier': round(100 * (1 - HOUSE_EDGE) / target, 4), 'nonce': nonce, 'server_hash': u['fair']['server_hash'], 'balance': u['balance']}

def cavein_view(g, reveal=False):
    out = {'bet': g['bet'], 'caves': g['caves'], 'opened': g['opened'], 'multiplier': cavein_mult(g['caves'], len(g['opened'])),
           'next_multiplier': cavein_mult(g['caves'], len(g['opened']) + 1) if len(g['opened']) < 25 - g['caves'] else None,
           'nonce': g['nonce']}
    if reveal:
        out['cave_cells'] = g['cells']
    return out

def h_cave_start(u, b):
    if u.get('cavein'):
        raise ApiError('finish_cavein', 'Finish your current Cave-In run first.')
    bet = check_bet(u, b.get('bet'))
    caves = to_int(b.get('caves'), 0)
    if caves < 1 or caves > 10:
        raise ApiError('bad_caves', 'Pick 1 to 10 cave-ins.')
    vals, nonce = fair_floats(u, 24)
    cells = list(range(25))
    for i in range(24, 0, -1):          # Fisher-Yates shuffle driven by the fair rolls
        j = int(vals[24 - i] * (i + 1))
        cells[i], cells[j] = cells[j], cells[i]
    move(U(u['uid']), 'house', bet, 'cavein_bet')
    u['cavein'] = {'bet': bet, 'caves': caves, 'cells': sorted(cells[:caves]), 'opened': [], 'nonce': nonce}
    save()
    return {'ok': True, 'game': cavein_view(u['cavein']), 'balance': u['balance'], 'server_hash': u['fair']['server_hash']}

def cave_cashout(u):
    g = u['cavein']
    payout = payout_of(u, g['bet'] * cavein_mult(g['caves'], len(g['opened'])))
    if payout:
        move('house', U(u['uid']), payout, 'cavein_win')
    luck_done(u, g['bet'], payout)
    u['cavein'] = None
    return payout

def h_cave_reveal(u, b):
    g = u.get('cavein')
    if not g:
        raise ApiError('no_cavein', 'Start a Cave-In run first.')
    cell = to_int(b.get('cell'), -1)
    if cell < 0 or cell > 24 or cell in g['opened']:
        raise ApiError('bad_cell')
    if cell in g['cells']:
        view = cavein_view(g, reveal=True)
        luck_done(u, g['bet'], 0)
        u['cavein'] = None
        save()
        return {'ok': True, 'hit': True, 'cell': cell, 'game': view, 'payout': 0, 'balance': u['balance']}
    g['opened'].append(cell)
    if len(g['opened']) == 25 - g['caves']:
        view = cavein_view(g, reveal=True)
        payout = cave_cashout(u)
        save()
        return {'ok': True, 'hit': False, 'cell': cell, 'game': view, 'cleared': True, 'payout': payout, 'balance': u['balance']}
    save()
    return {'ok': True, 'hit': False, 'cell': cell, 'game': cavein_view(g)}

def h_cave_cashout(u, b):
    g = u.get('cavein')
    if not g:
        raise ApiError('no_cavein')
    if not g['opened']:
        raise ApiError('open_one_first', 'Open at least one tile first.')
    view = cavein_view(g, reveal=True)
    payout = cave_cashout(u)
    save()
    return {'ok': True, 'payout': payout, 'game': view, 'balance': u['balance']}

def h_cave_state(u, q):
    return {'ok': True, 'game': cavein_view(u['cavein']) if u.get('cavein') else None}

# ---- profile, shop, crews --------------------------------------------------
def h_appearance(u, b):
    a = b.get('appearance')
    if not isinstance(a, dict):
        raise ApiError('bad_appearance')
    new = dict(u['appearance'])
    for k, n in APPEARANCE_RANGES.items():
        if k in a:
            v = to_int(a[k], -1)
            if v < 0 or v >= n:
                raise ApiError('bad_appearance')
            if v not in FREE_OPTIONS[k] and '%s_%d' % (k, v) not in u['cosmetics']:
                raise ApiError('not_owned', 'Buy that style in the shop first.')
            new[k] = v
    u['appearance'] = new
    save()
    return {'ok': True, 'appearance': new}

def h_shop(q):
    return {'ok': True, 'items': SHOP}

def h_buy(u, b):
    item = SHOP_BY_ID.get(b.get('item'))
    if not item:
        raise ApiError('bad_item')
    if item['id'] in u['cosmetics']:
        raise ApiError('owned', 'You already own that.')
    move(U(u['uid']), 'burn', item['price'], 'shop', item['id'])
    u['cosmetics'].append(item['id'])
    save()
    return {'ok': True, 'cosmetics': u['cosmetics'], 'balance': u['balance']}

CREW_COST = 300
CREW_MAX = 20

def crew_view(c):
    members = []
    for uid in c['members']:
        m = DB['users'].get(uid)
        if m:
            roll_counters(m)
            members.append({'username': m['username'], 'level': level_for(m['xp']), 'week_blocks': m['week_blocks'],
                            'owner': uid == c['owner'], 'online': now() - m.get('last_seen', 0) < 120})
    members.sort(key=lambda x: -x['week_blocks'])
    return {'id': c['id'], 'name': c['name'], 'tag': c['tag'], 'members': members, 'week_blocks': sum(m['week_blocks'] for m in members)}

def h_crew(u, q):
    c = DB['crews'].get(u.get('crew') or '')
    top = sorted([crew_view(x) for x in DB['crews'].values()], key=lambda x: -x['week_blocks'])[:10]
    return {'ok': True, 'crew': crew_view(c) if c else None, 'top': [{'name': t['name'], 'tag': t['tag'], 'week_blocks': t['week_blocks'],
                                                                       'members': len(t['members'])} for t in top], 'cost': CREW_COST}

def h_crew_create(u, b):
    if u.get('crew'):
        raise ApiError('in_crew', 'Leave your crew first.')
    name = str(b.get('name', '')).strip()
    tag = str(b.get('tag', '')).strip().upper()
    if not re.match(r'^[A-Za-z0-9 ]{3,20}$', name):
        raise ApiError('bad_name', 'Crew names are 3-20 letters or numbers.')
    if not re.match(r'^[A-Z0-9]{2,4}$', tag):
        raise ApiError('bad_tag', 'Crew tags are 2-4 letters or numbers.')
    if name.lower() in DB['crew_names']:
        raise ApiError('name_taken', 'That crew name is taken.')
    move(U(u['uid']), 'burn', CREW_COST, 'crew_create', name)
    cid = next_id('k')
    DB['crews'][cid] = {'id': cid, 'name': name, 'tag': tag, 'owner': u['uid'], 'members': [u['uid']], 'created': now()}
    DB['crew_names'][name.lower()] = cid
    u['crew'] = cid
    save()
    return {'ok': True, 'crew': crew_view(DB['crews'][cid])}

def h_crew_join(u, b):
    if u.get('crew'):
        raise ApiError('in_crew', 'Leave your crew first.')
    cid = DB['crew_names'].get(str(b.get('name', '')).strip().lower())
    c = DB['crews'].get(cid or '')
    if not c:
        raise ApiError('crew_not_found', 'No crew with that name.')
    if len(c['members']) >= CREW_MAX:
        raise ApiError('crew_full', 'That crew is full.')
    c['members'].append(u['uid'])
    u['crew'] = cid
    save()
    return {'ok': True, 'crew': crew_view(c)}

def h_crew_leave(u, b):
    c = DB['crews'].get(u.get('crew') or '')
    u['crew'] = None
    if c:
        c['members'] = [m for m in c['members'] if m != u['uid']]
        if not c['members']:
            DB['crew_names'].pop(c['name'].lower(), None)
            del DB['crews'][c['id']]
        elif c['owner'] == u['uid']:
            c['owner'] = c['members'][0]
    save()
    return {'ok': True}

# ---- chat + friends ---------------------------------------------------------
BAD_WORDS = ('nigger', 'faggot')

def friends_of(uid):
    return [f['b'] if f['a'] == uid else f['a'] for f in DB['friends'] if uid in (f['a'], f['b'])]

def channel_ok(u, channel):
    if channel == 'lobby':
        return True
    if channel == 'crew':
        return bool(u and u.get('crew'))
    if channel.startswith('dm_') and u:
        parts = channel[3:].split('__')
        return len(parts) == 2 and u['uid'] in parts and (parts[0] if parts[1] == u['uid'] else parts[1]) in friends_of(u['uid'])
    return False

def real_channel(u, channel):
    return 'crew_' + u['crew'] if channel == 'crew' else channel

def h_history(u, q):
    channel = q.get('channel', ['lobby'])[0][:80]
    if not channel_ok(u, channel):
        raise ApiError('channel_forbidden', 'You cannot read that chat.', 403)
    real = real_channel(u, channel) if u else channel
    msgs = [m for m in DB['messages'] if m['channel'] == real][-50:]
    return {'ok': True, 'channel': channel, 'messages': msgs}

def h_send(u, b):
    channel = str(b.get('channel') or 'lobby')[:80]
    text = str(b.get('text') or '').strip()[:200]
    if not text:
        raise ApiError('empty')
    if not channel_ok(u, channel):
        raise ApiError('channel_forbidden', 'You cannot post there.', 403)
    if now() - u['last_chat'] < 2.5:
        raise ApiError('slow_mode', 'Slow down a little.', 429)
    for bad in BAD_WORDS:
        text = re.sub(r'(?i)\b' + re.escape(bad) + r'\b', '***', text)
    u['last_chat'] = now()
    c = crew_tag(u)
    msg = {'id': next_id('x'), 'channel': real_channel(u, channel), 'from': u['username'], 'level': level_for(u['xp']),
           'crew': c['tag'] if c else '', 'text': text, 't': now()}
    DB['messages'].append(msg)
    DB['messages'] = DB['messages'][-3000:]
    save()
    return {'ok': True, 'message': msg}

def h_friends(u, q):
    out = []
    for fid in friends_of(u['uid']):
        f = DB['users'].get(fid)
        if f:
            a, b2 = sorted([u['uid'], fid])
            out.append({'username': f['username'], 'level': level_for(f['xp']), 'online': now() - f.get('last_seen', 0) < 120,
                        'channel': 'dm_%s__%s' % (a, b2)})
    pend = [{'id': r['id'], 'from': DB['users'][r['from']]['username']} for r in DB['friend_requests']
            if r['to'] == u['uid'] and r['status'] == 'pending' and r['from'] in DB['users']]
    return {'ok': True, 'friends': sorted(out, key=lambda x: (not x['online'], x['username'].lower())), 'pending': pend}

def h_friend_request(u, b):
    to_uid = DB['names'].get(str(b.get('username', '')).strip().lower())
    if not to_uid or to_uid == u['uid']:
        raise ApiError('player_not_found', 'No player with that name.')
    if to_uid in friends_of(u['uid']):
        raise ApiError('already_friends', 'Already friends.')
    if any(r['from'] == u['uid'] and r['to'] == to_uid and r['status'] == 'pending' for r in DB['friend_requests']):
        raise ApiError('already_pending', 'Request already sent.')
    DB['friend_requests'].append({'id': next_id('f'), 'from': u['uid'], 'to': to_uid, 'status': 'pending', 't': now()})
    save()
    return {'ok': True}

def h_friend_respond(u, b):
    r = next((x for x in DB['friend_requests'] if x['id'] == b.get('id') and x['to'] == u['uid'] and x['status'] == 'pending'), None)
    if not r:
        raise ApiError('not_found')
    r['status'] = 'accepted' if b.get('accept') else 'declined'
    if b.get('accept') and r['from'] not in friends_of(u['uid']):
        DB['friends'].append({'a': r['from'], 'b': u['uid']})
    save()
    return {'ok': True}

# ---- leaderboards ---------------------------------------------------------------
def h_leaderboard(u, q):
    board = q.get('board', ['miners'])[0]
    users = list(DB['users'].values())
    for x in users:
        roll_counters(x)
    if board == 'miners':
        rows = sorted([(x['week_blocks'], x) for x in users if x['week_blocks'] > 0], key=lambda r: -r[0])
        value_name = 'veins cleared this week'
    elif board == 'level':
        rows = sorted([(x['xp'], x) for x in users], key=lambda r: -r[0])
        value_name = 'xp'
    elif board.startswith('elo_') and board[4:] in GAMES:
        g = board[4:]
        rows = sorted([(user_fix(x)['elo'][g], x) for x in users if x['wins'] + x['losses'] + x['draws'] > 0], key=lambda r: -r[0])
        value_name = 'rating'
    else:
        raise ApiError('bad_board')
    top = [{'rank': i + 1, 'username': x['username'], 'value': v, 'level': level_for(x['xp']), 'title': title_for(level_for(x['xp'])),
            'crew': (crew_tag(x) or {}).get('tag', '')} for i, (v, x) in enumerate(rows[:20])]
    me = None
    if u:
        me = next(({'rank': i + 1, 'value': v} for i, (v, x) in enumerate(rows) if x['uid'] == u['uid']), None)
    return {'ok': True, 'board': board, 'value_name': value_name, 'top': top, 'me': me, 'week': week_key()}

# ---------------------------------------------------------------------------
# ROUTING
# ---------------------------------------------------------------------------
GET_PUBLIC = {'/health': lambda q: {'ok': True, 'service': 'pulse', 'version': VERSION, 'storage': STORE.name, 'players': len(DB['users'])},
              '/economy': h_economy, '/recipes': h_recipes, '/shop': h_shop}
GET_OPTIONAL = {'/leaderboard': h_leaderboard, '/chat/history': h_history}
GET_AUTH = {'/me': h_me, '/ledger': h_ledger, '/mine/veins': h_veins, '/quests': h_quests, '/pvp/status': h_pvp_status,
            '/tournaments': h_tournaments, '/luck/fair': h_fair, '/luck/cavein': h_cave_state, '/friends': h_friends, '/crew': h_crew}
POST_PUBLIC = {'/auth/register': h_register, '/auth/login': h_login}
POST_AUTH = {'/heartbeat': h_heartbeat, '/mine/start': h_mine_start, '/mine/strike': h_mine_strike, '/forge': h_forge,
             '/repair': h_repair, '/upgrade': h_upgrade, '/quests/claim': h_claim, '/practice/start': h_practice_start,
             '/practice/submit': h_practice_submit, '/pvp/queue': h_pvp_queue, '/pvp/cancel': h_pvp_cancel,
             '/pvp/challenge': h_pvp_challenge, '/pvp/respond': h_pvp_respond, '/pvp/play': h_pvp_play, '/pvp/submit': h_pvp_submit, '/pvp/forfeit': h_pvp_forfeit,
             '/tournament/enter': h_t_enter, '/tournament/start': h_t_start, '/tournament/submit': h_t_submit,
             '/luck/flip': h_flip, '/luck/dice': h_dice, '/luck/cavein/start': h_cave_start, '/luck/cavein/reveal': h_cave_reveal,
             '/luck/cavein/cashout': h_cave_cashout, '/luck/seed': h_fair_seed, '/profile/appearance': h_appearance,
             '/shop/buy': h_buy, '/crew/create': h_crew_create, '/crew/join': h_crew_join, '/crew/leave': h_crew_leave,
             '/chat/send': h_send, '/friend/request': h_friend_request, '/friend/respond': h_friend_respond}

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def send_json(self, obj, code=200):
        raw = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def read_json(self):
        try:
            n = int(self.headers.get('Content-Length', '0'))
            if n < 0 or n > 200000:
                return {}
            data = json.loads(self.rfile.read(n).decode('utf-8')) if n else {}
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}

    def token(self):
        h = self.headers.get('Authorization', '')
        return h[7:].strip() if h.startswith('Bearer ') else ''

    def ip(self):
        return (self.headers.get('X-Forwarded-For', '') or self.client_address[0]).split(',')[0].strip()

    def do_OPTIONS(self):
        self.send_json({'ok': True})

    def run(self, fn):
        try:
            with DB_LOCK:
                out = fn()
            self.send_json(out)
        except ApiError as e:
            self.send_json({'ok': False, 'error': e.code, 'message': e.message}, e.status)
        except Exception:
            traceback.print_exc()
            self.send_json({'ok': False, 'error': 'server_error', 'message': 'Something went wrong on the server.'}, 500)

    def do_GET(self):
        p = urlparse(self.path)
        q = parse_qs(p.query)
        path = p.path.rstrip('/') or '/health'
        if path == '/':
            path = '/health'

        def go():
            if path in GET_PUBLIC:
                return GET_PUBLIC[path](q)
            if path in GET_ADMIN:
                if not ADMIN_TOKEN or not hmac.compare_digest(self.token(), ADMIN_TOKEN):
                    raise ApiError('not_found', 'Unknown address.', 404)
                return GET_ADMIN[path](q)
            if path in GET_OPTIONAL:
                return GET_OPTIONAL[path](session_user(self.token()), q)
            if path in GET_AUTH:
                u = session_user(self.token())
                if not u:
                    raise ApiError('login_required', 'Please log in again.', 401)
                u['last_seen'] = now()
                return GET_AUTH[path](u, q)
            raise ApiError('not_found', 'Unknown address.', 404)
        self.run(go)

    def do_POST(self):
        path = urlparse(self.path).path.rstrip('/')
        b = self.read_json()

        def go():
            if path in POST_PUBLIC:
                return POST_PUBLIC[path](b, self.ip())
            if path == '/auth/logout':
                u = session_user(self.token())
                return h_logout(u, b, self.token()) if u else {'ok': True}
            if path in POST_AUTH:
                u = session_user(self.token())
                if not u:
                    raise ApiError('login_required', 'Please log in again.', 401)
                u['last_seen'] = now()
                return POST_AUTH[path](u, b)
            raise ApiError('not_found', 'Unknown address.', 404)
        self.run(go)

def shutdown(*a):
    try:
        flush()
    finally:
        os._exit(0)


# ---------------------------------------------------------------------------
# CRYPTO for phone-node handshakes: base58, canonical JSON, SHA-256 and RSA-2048
# signature checks (PKCS#1 v1.5 + SHA-256 - what Godot's Crypto class makes).
# The server only ever sees phones' PUBLIC keys; private keys never leave the phone.
# ---------------------------------------------------------------------------
import base64 as _b64

B58_ALPHA = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
B58_IDX = {c: i for i, c in enumerate(B58_ALPHA)}

def b58encode(b):
    n = int.from_bytes(b, 'big')
    out = ''
    while n > 0:
        n, r = divmod(n, 58)
        out = B58_ALPHA[r] + out
    pad = len(b) - len(b.lstrip(b'\0'))
    return '1' * pad + out

def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=True)

def sha256b(b):
    return hashlib.sha256(b).digest()

def sha256h(s):
    if isinstance(s, str):
        s = s.encode('utf-8')
    return hashlib.sha256(s).hexdigest()

def b64e(b):
    return _b64.b64encode(b).decode()

def b64d(s):
    return _b64.b64decode(s)

# ---- RSA-2048, PKCS#1 v1.5 with SHA-256 (what Godot's Crypto class uses) ----
_SHA256_PREFIX = bytes.fromhex('3031300d060960864801650304020105000420')
_RSA_OID = bytes.fromhex('06092a864886f70d0101010500')

def _der_len(n):
    if n < 128:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    return bytes([0x80 | len(b)]) + b

def _der_int(v):
    b = v.to_bytes((v.bit_length() + 8) // 8, 'big')   # leading 0 keeps it positive
    return b'\x02' + _der_len(len(b)) + b

def _der_seq(body):
    return b'\x30' + _der_len(len(body)) + body

def rsa_public_der(n, e):
    rsa_pub = _der_seq(_der_int(n) + _der_int(e))
    bitstr = b'\x03' + _der_len(len(rsa_pub) + 1) + b'\x00' + rsa_pub
    return _der_seq(_der_seq(_RSA_OID) + bitstr)

def rsa_public_pem(n, e):
    b = b64e(rsa_public_der(n, e))
    lines = [b[i:i + 64] for i in range(0, len(b), 64)]
    return '-----BEGIN PUBLIC KEY-----\n' + '\n'.join(lines) + '\n-----END PUBLIC KEY-----\n'

def _der_read(b, i):
    tag = b[i]
    ln = b[i + 1]
    i += 2
    if ln & 0x80:
        k = ln & 0x7f
        ln = int.from_bytes(b[i:i + k], 'big')
        i += k
    return tag, b[i:i + ln], i + ln

def rsa_parse_pem(pem):
    """SubjectPublicKeyInfo (BEGIN PUBLIC KEY) or PKCS#1 (BEGIN RSA PUBLIC KEY) -> (n, e, spki_der)."""
    body = ''.join(l.strip() for l in pem.strip().splitlines() if l.strip() and not l.startswith('-----'))
    der = b64d(body)
    tag, seq, _ = _der_read(der, 0)
    if tag != 0x30:
        raise ValueError('bad key')
    t1, v1, j = _der_read(seq, 0)
    if t1 == 0x30:      # SPKI: algorithm, bit string
        t2, bits, _ = _der_read(seq, j)
        if t2 != 0x03:
            raise ValueError('bad key')
        _, inner, _ = _der_read(bits[1:], 0)
        tn, nb, k = _der_read(inner, 0)
        te, eb, _ = _der_read(inner, k)
    else:               # PKCS#1
        nb = v1
        te, eb, _ = _der_read(seq, j)
    n, e = int.from_bytes(nb, 'big'), int.from_bytes(eb, 'big')
    if n.bit_length() < 2000 or n.bit_length() > 4100:
        raise ValueError('RSA key must be 2048-4096 bits')
    return n, e, rsa_public_der(n, e)

def rsa_verify_digest(n, e, digest, sig):
    k = (n.bit_length() + 7) // 8
    if len(sig) != k:
        return False
    s = int.from_bytes(sig, 'big')
    if s >= n:
        return False
    em = pow(s, e, n).to_bytes(k, 'big')
    t = _SHA256_PREFIX + digest
    return hmac.compare_digest(em, b'\x00\x01' + b'\xff' * (k - len(t) - 3) + b'\x00' + t)

def node_id_for(pem):
    """A phone node's id: base58 of sha256 over its public key (like a Solana address)."""
    n, e, der = rsa_parse_pem(pem)
    return b58encode(sha256b(b'rsa:' + der))

# ===========================================================================
# PHONE NODES - registration, signed handshake, heartbeats, contribution
# accounting and reward settlement into the internal PULSE ledger.
#
# Each phone makes its own RSA-2048 node key; only the PUBLIC key is sent here.
#   register   -> the server records the public key; node id = base58(sha256(key))
#   challenge  -> the server hands out a one-time nonce (60 s)
#   handshake  -> the phone signs the nonce; a valid signature proves it holds the key
#   heartbeat  -> every ~30 s the phone signs (node, seq, time, mining); each accepted,
#                 eligible heartbeat is one CONTRIBUTION UNIT
#   settlement -> once an hour (an "epoch") units become PLS rewards in the ledger,
#                 exactly once per (epoch, node), with a full issuance record
#
# NODE_POLICY decides when a phone counts as an active node:
#   while_mining (default) - only while the player is actively mining in game
#   always                 - whenever the app is open and heartbeating
#   off                    - nodes register and heartbeat but earn nothing
# All reward numbers below are PLACEHOLDERS until tokenomics are finalised.
# ===========================================================================
NODE_POLICY = os.environ.get('PULSE_NODE_POLICY', 'while_mining').strip()
if NODE_POLICY not in ('while_mining', 'always', 'off'):
    NODE_POLICY = 'while_mining'
HB_INTERVAL = int(os.environ.get('PULSE_HB_INTERVAL', '30'))   # seconds the app waits between heartbeats
HB_MIN_GAP = int(os.environ.get('PULSE_HB_MIN_GAP', '25'))   # a heartbeat sooner than this after the last counted one is not counted
HB_CLOCK_SKEW = 120              # phone clock may differ from the server by this much
MINING_WINDOW = 90               # "actively mining" = a strike within the last 90 s
EPOCH_SECONDS = int(os.environ.get('PULSE_EPOCH_SECONDS', '3600'))   # rewards settle per hour
UNITS_PER_PLS = int(os.environ.get('PULSE_UNITS_PER_PLS', '10'))          # PLACEHOLDER: 10 units (~5 min) = 1 PLS
DAILY_UNIT_CAP = int(os.environ.get('PULSE_DAILY_UNIT_CAP', '240'))       # PLACEHOLDER: max 2 h of counted node time per player per day
EPOCH_EMISSION_CAP = int(os.environ.get('PULSE_EPOCH_CAP_PLS', '2000'))   # PLACEHOLDER: max PLS paid to ALL nodes per hour (pro-rata above it)
MAX_NODES_PER_USER = 3
NODE_SESSION_TTL = 1800
CHALLENGE_TTL = 60
ADMIN_TOKEN = os.environ.get('PULSE_ADMIN_TOKEN', '').strip()     # set on Render; never in code

NODE_CHALLENGES = {}             # node_id -> (nonce, expires); in memory only

for _k, _v in (('nodes', {}), ('node_sessions', {}), ('node_rewards', []), ('node_settled', {}), ('node_carry', {})):
    DB.setdefault(_k, _v)

def epoch_of(t):
    return int(t // EPOCH_SECONDS)

def node_eligibility(u, node, mining_flag):
    """Returns (counts, reason). The one place to change when the node policy changes."""
    if NODE_POLICY == 'off':
        return False, 'node rewards are switched off'
    if u.get('flagged'):
        return False, 'account under review'
    if NODE_POLICY == 'while_mining':
        if not mining_flag:
            return False, 'not mining'
        if now() - u.get('last_strike', 0) > MINING_WINDOW:
            return False, 'no recent mining strikes'
    return True, 'counted'

def _sig_ok(node, msg, sig_b64):
    try:
        n, e, der = rsa_parse_pem(node['pem'])
        return rsa_verify_digest(n, e, sha256b(msg.encode('utf-8')), b64d(sig_b64))
    except Exception:
        return False

def _user_node(u, node_id):
    node = DB['nodes'].get(str(node_id))
    if not node or node['uid'] != u['uid']:
        raise ApiError('unknown_node', 'This phone is not registered as a node for your account.')
    if node['status'] != 'active':
        raise ApiError('node_removed', 'This node was removed. Register this phone again.')
    return node

def h_node_register(u, b):
    pem = str(b.get('pub', ''))
    try:
        nid = node_id_for(pem)
    except Exception:
        raise ApiError('bad_key', 'That is not a valid node key.')
    existing = DB['nodes'].get(nid)
    if existing and existing['uid'] != u['uid']:
        raise ApiError('node_taken', 'This phone key belongs to another player.')
    if existing:
        existing['status'] = 'active'
        existing['label'] = str(b.get('label', existing.get('label', '')))[:40]
        save()
        return {'ok': True, 'node_id': nid, 'new': False}
    mine = [n for n in DB['nodes'].values() if n['uid'] == u['uid'] and n['status'] == 'active']
    if len(mine) >= MAX_NODES_PER_USER:
        raise ApiError('too_many_nodes', 'You already have %d phones registered. Remove one in Profile > Node first.' % MAX_NODES_PER_USER)
    DB['nodes'][nid] = {'id': nid, 'uid': u['uid'], 'pem': pem, 'label': str(b.get('label', 'Phone'))[:40], 'created': now(),
                        'status': 'active', 'last_seq': 0, 'last_hb': 0, 'last_counted': 0, 'units_total': 0,
                        'units_epoch': {}, 'day': '', 'day_units': 0, 'handshakes': 0, 'rejected': 0}
    save()
    return {'ok': True, 'node_id': nid, 'new': True}

def h_node_challenge(u, b):
    node = _user_node(u, b.get('node_id'))
    nonce = secrets.token_hex(16)
    NODE_CHALLENGES[node['id']] = (nonce, now() + CHALLENGE_TTL)
    return {'ok': True, 'nonce': nonce, 'message': 'pulse-handshake:%s:%s:%s' % (node['id'], u['uid'], nonce), 'expires_in': CHALLENGE_TTL}

def h_node_handshake(u, b):
    node = _user_node(u, b.get('node_id'))
    ch = NODE_CHALLENGES.pop(node['id'], None)
    if not ch or ch[1] < now() or ch[0] != str(b.get('nonce', '')):
        raise ApiError('challenge_expired', 'Handshake expired - try again.')
    msg = 'pulse-handshake:%s:%s:%s' % (node['id'], u['uid'], ch[0])
    if not _sig_ok(node, msg, str(b.get('sig', ''))):
        node['rejected'] += 1
        raise ApiError('bad_signature', 'Node signature did not check out.')
    for k in [k for k, s in DB['node_sessions'].items() if s['exp'] < now() or s['node'] == node['id']]:
        del DB['node_sessions'][k]
    tok = secrets.token_urlsafe(24)
    DB['node_sessions'][tok] = {'node': node['id'], 'uid': u['uid'], 'exp': now() + NODE_SESSION_TTL}
    node['handshakes'] += 1
    save()
    return {'ok': True, 'node_token': tok, 'expires_in': NODE_SESSION_TTL, 'policy': NODE_POLICY, 'interval': HB_INTERVAL,
            'last_seq': node['last_seq']}

def h_node_heartbeat(u, b):
    sess = DB['node_sessions'].get(str(b.get('node_token', '')))
    if not sess or sess['uid'] != u['uid'] or sess['exp'] < now():
        raise ApiError('node_session_expired', 'Node session expired - handshake again.')
    node = _user_node(u, sess['node'])
    seq, ts = to_int(b.get('seq'), -1), to_int(b.get('ts'), 0)
    mining = bool(b.get('mining'))
    msg = 'pulse-heartbeat:%s:%d:%d:%d' % (node['id'], seq, ts, 1 if mining else 0)
    if not _sig_ok(node, msg, str(b.get('sig', ''))):
        node['rejected'] += 1
        raise ApiError('bad_signature', 'Heartbeat signature did not check out.')
    if seq <= node['last_seq']:
        node['rejected'] += 1
        raise ApiError('replayed', 'Old heartbeat (sequence number already used).')
    if abs(ts - now()) > HB_CLOCK_SKEW:
        raise ApiError('clock', 'Phone clock is too far off - check the date and time settings.')
    node['last_seq'] = seq
    node['last_hb'] = now()
    sess['exp'] = now() + NODE_SESSION_TTL
    counted, reason = node_eligibility(u, node, mining)
    if counted and now() - node['last_counted'] < HB_MIN_GAP:
        counted, reason = False, 'too soon after the last heartbeat'
    if counted:
        others = [n for n in DB['nodes'].values() if n['uid'] == u['uid'] and n['id'] != node['id'] and now() - n['last_counted'] < HB_MIN_GAP]
        if others:
            counted, reason = False, 'another of your phones is already the active node'
    d = day_key()
    if node['day'] != d:
        node['day'], node['day_units'] = d, 0
    used_today = sum(n['day_units'] for n in DB['nodes'].values() if n['uid'] == u['uid'] and n['day'] == d)
    if counted and used_today >= DAILY_UNIT_CAP:
        counted, reason = False, 'daily node limit reached'
    if counted:
        ep = str(epoch_of(now()))
        node['units_epoch'][ep] = node['units_epoch'].get(ep, 0) + 1
        node['units_total'] += 1
        node['day_units'] += 1
        node['last_counted'] = now()
        used_today += 1
    save()
    return {'ok': True, 'counted': counted, 'reason': reason, 'units_today': used_today, 'daily_cap': DAILY_UNIT_CAP,
            'units_this_hour': node['units_epoch'].get(str(epoch_of(now())), 0), 'policy': NODE_POLICY}

def h_node_remove(u, b):
    node = DB['nodes'].get(str(b.get('node_id', '')))
    if not node or node['uid'] != u['uid']:
        raise ApiError('unknown_node')
    node['status'] = 'removed'
    for k in [k for k, s in DB['node_sessions'].items() if s['node'] == node['id']]:
        del DB['node_sessions'][k]
    save()
    return {'ok': True}

def h_node_status(u, q):
    d = day_key()
    mine = [n for n in DB['nodes'].values() if n['uid'] == u['uid']]
    nodes = [{'node_id': n['id'], 'label': n['label'], 'status': n['status'], 'units_total': n['units_total'],
              'pending_units': sum(n['units_epoch'].values()), 'last_heartbeat': int(n['last_hb']),
              'online': now() - n['last_hb'] < HB_INTERVAL * 2.5} for n in mine]
    rewards = [r for r in DB['node_rewards'] if r['uid'] == u['uid']][-20:]
    return {'ok': True, 'policy': NODE_POLICY, 'interval': HB_INTERVAL, 'units_per_pls': UNITS_PER_PLS, 'daily_cap': DAILY_UNIT_CAP,
            'units_today': sum(n['day_units'] for n in mine if n['day'] == d), 'nodes': nodes,
            'rewards': list(reversed(rewards)), 'total_earned': sum(r['pls'] for r in DB['node_rewards'] if r['uid'] == u['uid']),
            'next_settlement_in': int(EPOCH_SECONDS - now() % EPOCH_SECONDS)}

def settle_node_rewards(up_to_epoch=None):
    """Turns contribution units from finished epochs into PLS. Safe to run any number of times:
    each (epoch, node) is paid at most once, and every payment has an issuance record."""
    cur = epoch_of(now()) if up_to_epoch is None else up_to_epoch
    by_epoch = {}
    for n in DB['nodes'].values():
        for ep, units in n['units_epoch'].items():
            if int(ep) < cur and units > 0:
                by_epoch.setdefault(int(ep), []).append((n, units))
    paid = 0
    for ep in sorted(by_epoch):
        rows = by_epoch[ep]
        total_units = sum(x[1] for x in rows)
        raw_pls_milli = total_units * 1000 // UNITS_PER_PLS
        cap_milli = EPOCH_EMISSION_CAP * 1000
        num, den = (cap_milli, raw_pls_milli) if raw_pls_milli > cap_milli else (1, 1)
        for n, units in rows:
            key = '%d:%s' % (ep, n['id'])
            if key in DB['node_settled']:
                n['units_epoch'].pop(str(ep), None)
                continue
            u = DB['users'].get(n['uid'])
            carry = DB['node_carry'].get(n['id'], 0)
            milli = units * 1000 * num // den // UNITS_PER_PLS + carry
            pls, rest = divmod(milli, 1000)
            DB['node_carry'][n['id']] = rest
            DB['node_settled'][key] = now()
            n['units_epoch'].pop(str(ep), None)
            rec = {'key': key, 'epoch': ep, 'node': n['id'], 'uid': n['uid'], 'units': units, 'pls': pls,
                   'scaled': num != den, 't': round(now(), 3)}
            if u is not None and pls > 0:
                move('mint', U(u['uid']), pls, 'node reward', key)
                paid += pls
            DB['node_rewards'].append(rec)
    if len(DB['node_rewards']) > 50000:
        DB['node_rewards'] = DB['node_rewards'][-50000:]
    if paid or by_epoch:
        save()
    return paid

SETTLE_EVERY = float(os.environ.get('PULSE_SETTLE_EVERY', '30'))

def node_loop():
    while True:
        time.sleep(SETTLE_EVERY)
        try:
            with DB_LOCK:
                settle_node_rewards()
                for k in [k for k, s in DB['node_sessions'].items() if s['exp'] < now()]:
                    del DB['node_sessions'][k]
                for k in [k for k, v in NODE_CHALLENGES.items() if v[1] < now()]:
                    NODE_CHALLENGES.pop(k, None)
        except Exception:
            traceback.print_exc()

# ---- admin audit (needs PULSE_ADMIN_TOKEN set on the server) -------------------
def h_admin_audit(q):
    acc = DB['accounts']
    circ = sum(x['balance'] for x in DB['users'].values())
    reasons = {}
    for e in DB['ledger']:
        r = reasons.setdefault(e['why'], {'count': 0, 'pls': 0})
        r['count'] += 1
        r['pls'] += e['amt']
    rec_total = sum(r['pls'] for r in DB['node_rewards'])
    led_node = [e for e in DB['ledger'] if e['why'] == 'node reward']
    keys = [r['key'] for r in DB['node_rewards']]
    led_keys = [e['ref'] for e in led_node]
    nodes = list(DB['nodes'].values())
    top = sorted(({'uid': u['uid'], 'username': u['username'],
                   'node_pls': sum(r['pls'] for r in DB['node_rewards'] if r['uid'] == u['uid'])} for u in DB['users'].values()),
                 key=lambda x: -x['node_pls'])[:10]
    return {'ok': True, 'ledger_balanced': circ + sum(acc.values()) == 0, 'minted_total': -acc['mint'], 'burned_total': acc['burn'],
            'circulating': circ, 'ledger_entries_kept': len(DB['ledger']), 'by_reason_in_kept_ledger': reasons,
            'node_policy': NODE_POLICY, 'reward_params': {'units_per_pls': UNITS_PER_PLS, 'daily_unit_cap': DAILY_UNIT_CAP,
                                                          'epoch_cap_pls': EPOCH_EMISSION_CAP, 'epoch_seconds': EPOCH_SECONDS},
            'node_rewards_issued': rec_total, 'node_reward_records': len(keys),
            'duplicate_reward_records': len(keys) - len(set(keys)), 'duplicate_ledger_rewards': len(led_keys) - len(set(led_keys)),
            'reward_records_match_ledger': sum(e['amt'] for e in led_node) == sum(r['pls'] for r in DB['node_rewards'] if r['key'] in set(led_keys)),
            'nodes_active': sum(1 for n in nodes if n['status'] == 'active'), 'nodes_removed': sum(1 for n in nodes if n['status'] != 'active'),
            'nodes_online_now': sum(1 for n in nodes if now() - n['last_hb'] < HB_INTERVAL * 2.5),
            'rejected_signatures_or_replays': sum(n.get('rejected', 0) for n in nodes),
            'pending_units': sum(sum(n['units_epoch'].values()) for n in nodes),
            'flagged_players': [u['username'] for u in DB['users'].values() if u.get('flagged')],
            'top_node_earners': top}

GET_ADMIN = {'/admin/audit': h_admin_audit}
POST_AUTH.update({'/node/register': h_node_register, '/node/challenge': h_node_challenge, '/node/handshake': h_node_handshake,
                  '/node/heartbeat': h_node_heartbeat, '/node/remove': h_node_remove})
GET_AUTH.update({'/node/status': h_node_status})

# ---------------------------------------------------------------------------
# START
# ---------------------------------------------------------------------------
if __name__ == '__main__':
    port = int(os.environ.get('PORT', '10000'))
    threading.Thread(target=saver_loop, daemon=True).start()
    threading.Thread(target=node_loop, daemon=True).start()
    signal.signal(signal.SIGTERM, shutdown)
    print('Pulse Network v%s listening on %d (storage: %s, node policy: %s)' % (VERSION, port, STORE.name, NODE_POLICY), flush=True)
    try:
        ThreadingHTTPServer(('0.0.0.0', port), Handler).serve_forever()
    except KeyboardInterrupt:
        shutdown()
