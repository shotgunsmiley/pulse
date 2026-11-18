
# Pulse Network - main.py v3
# Clean Pulse style: dark slate + cream + amber + teal. NOT RuneScape clone.
# Screens: MINE / FORGE / DUEL / CHAT / QUESTS / WALLET / NODES
# Backend: https://pulse-nadr.onrender.com/
import json, hashlib, random, time, threading, os, uuid, secrets
import urllib.request, urllib.error
from kivy.app import App
from kivy.uix.screenmanager import ScreenManager, Screen
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.gridlayout import GridLayout
from kivy.uix.scrollview import ScrollView
from kivy.uix.label import Label
from kivy.uix.button import Button
from kivy.uix.textinput import TextInput
from kivy.uix.popup import Popup
from kivy.clock import Clock
from kivy.graphics import Color, RoundedRectangle
from kivy.metrics import dp
from kivy.core.window import Window

SERVER = "https://pulse-nadr.onrender.com"
WALLET_FILE = "pulse_wallet.json"
NODE_FILE = "pulse_node.json"
APP_VERSION = "3.3"
NODE_ID = ""
NODE_TOKEN = ""
WALLET_SECRET = ""
POW_DIFFICULTY = 2

# --- Pulse palette ---
BG = (0.13, 0.15, 0.18, 1)      # dark slate
CARD = (0.94, 0.90, 0.82, 1)    # cream
CARD_DARK = (0.18, 0.20, 0.24, 1)
AMBER = (0.89, 0.66, 0.23, 1)   # main
TEAL = (0.16, 0.62, 0.56, 1)    # accent
WHITE = (0.96, 0.96, 0.95, 1)
MUTED = (0.65, 0.65, 0.62, 1)
GREEN = (0.2, 0.8, 0.4, 1)
RED = (0.9, 0.3, 0.3, 1)

def get_wallet():
    global WALLET_SECRET
    obj = {}
    try:
        with open(WALLET_FILE, "r") as f: obj = json.load(f)
    except Exception: pass
    wallet = obj.get("wallet")
    if not isinstance(wallet, str) or not wallet:
        wallet = "pulse_" + hashlib.sha256((str(time.time()) + str(random.random())).encode()).hexdigest()[:12]
    WALLET_SECRET = obj.get("wallet_secret") or secrets.token_urlsafe(32)
    with open(WALLET_FILE, "w") as f:
        json.dump({"wallet": wallet, "wallet_secret": WALLET_SECRET}, f)
    return wallet

WALLET = get_wallet()

def load_node_identity():
    global NODE_ID, NODE_TOKEN
    try:
        with open(NODE_FILE, "r") as f:
            obj = json.load(f)
            NODE_ID = str(obj.get("node_id", ""))
            NODE_TOKEN = str(obj.get("node_token", ""))
    except Exception:
        NODE_ID, NODE_TOKEN = "", ""
    if not NODE_ID:
        NODE_ID = "node_" + uuid.uuid4().hex
    return NODE_ID, NODE_TOKEN

def save_node_identity():
    with open(NODE_FILE, "w") as f:
        json.dump({"node_id": NODE_ID, "node_token": NODE_TOKEN}, f)

load_node_identity()

def api(method, path, data=None):
    try:
        url = SERVER + path
        payload = dict(data or {}) if data is not None else None
        if payload is not None and NODE_ID:
            payload.setdefault("node_id", NODE_ID)
            if NODE_TOKEN: payload.setdefault("node_token", NODE_TOKEN)
        body = json.dumps(payload).encode() if payload is not None else None
        headers = {"Content-Type": "application/json"}
        if NODE_ID: headers["X-Pulse-Node-Id"] = NODE_ID
        if NODE_TOKEN: headers["X-Pulse-Node-Token"] = NODE_TOKEN
        req = urllib.request.Request(url, data=body, method=method, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read().decode())
        except Exception: return {"ok": False, "error": "http_" + str(e.code)}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def api_async(method, path, data=None, on_done=None):
    """Run HTTP work off the Kivy thread; deliver callback on the UI thread."""
    def worker():
        result = api(method, path, data)
        if on_done:
            Clock.schedule_once(lambda dt: on_done(result), 0)
    threading.Thread(target=worker, daemon=True).start()


def register_node():
    global NODE_ID, NODE_TOKEN, POW_DIFFICULTY
    payload = {"wallet": WALLET, "wallet_secret": WALLET_SECRET, "node_id": NODE_ID, "node_token": NODE_TOKEN, "app_version": APP_VERSION}
    r = api("POST", "/node/register", payload)
    if not r.get("ok") and r.get("error") in ("node_already_registered", "node_auth_required"):
        NODE_ID = "node_" + uuid.uuid4().hex
        NODE_TOKEN = ""
        r = api("POST", "/node/register", {"wallet": WALLET, "wallet_secret": WALLET_SECRET, "node_id": NODE_ID, "app_version": APP_VERSION})
    if r.get("ok"):
        try:
            health = api("GET", "/health")
            POW_DIFFICULTY = max(0, min(6, int(health.get("difficulty", 2))))
        except Exception:
            POW_DIFFICULTY = 2
        NODE_ID = r.get("node_id", NODE_ID)
        NODE_TOKEN = r.get("node_token", NODE_TOKEN)
        save_node_identity()
    return r

def find_pow(wallet, data, difficulty=None):
    if difficulty is None:
        difficulty = POW_DIFFICULTY
    try:
        difficulty = max(0, min(6, int(difficulty)))
    except Exception:
        difficulty = 2
    prefix = "0" * difficulty
    nonce = 0
    while True:
        h = hashlib.sha256(f"{wallet}:{data}:{nonce}".encode()).hexdigest()
        if h.startswith(prefix):
            return nonce, h
        nonce += 1

# --- UI helpers ---
class Card(BoxLayout):
    def __init__(self, **kw):
        super().__init__(**kw)
        with self.canvas.before:
            Color(*CARD)
            self._r = RoundedRectangle(pos=self.pos, size=self.size, radius=[dp(14)])
        self.bind(pos=lambda *a: setattr(self._r, 'pos', self.pos), size=lambda *a: setattr(self._r, 'size', self.size))

class DarkCard(BoxLayout):
    def __init__(self, **kw):
        super().__init__(**kw)
        with self.canvas.before:
            Color(*CARD_DARK)
            self._r = RoundedRectangle(pos=self.pos, size=self.size, radius=[dp(14)])
        self.bind(pos=lambda *a: setattr(self._r, 'pos', self.pos), size=lambda *a: setattr(self._r, 'size', self.size))

class PBtn(Button):
    def __init__(self, text="", bg=AMBER, fg=(0.15,0.12,0.05,1), **kw):
        super().__init__(text=text, background_normal="", background_color=bg, color=fg, bold=True, font_size=dp(16), size_hint_y=None, height=dp(52), **kw)

class NavBar(BoxLayout):
    def __init__(self, sm, current, **kw):
        super().__init__(orientation="horizontal", size_hint_y=None, height=dp(62), spacing=dp(6), padding=dp(6), **kw)
        for name, label in [("mine","⛏ MINE"),("forge","⚒ FORGE"),("duel","⚔ DUEL"),("chat","💬 CHAT"),("quests","📜 QUESTS"),("network","◉ DEVICES")]:
            b = Button(text=label, background_normal="", background_color=AMBER if name==current else CARD_DARK, color=(0.15,0.12,0.05,1) if name==current else WHITE, bold=True, font_size=dp(11))
            b.bind(on_release=lambda _, n=name: setattr(sm, 'current', n))
            self.add_widget(b)

class TopBar(BoxLayout):
    def __init__(self, app, **kw):
        super().__init__(orientation="horizontal", size_hint_y=None, height=dp(56), spacing=dp(8), padding=[dp(12),dp(8),dp(12),dp(8)], **kw)
        self.app = app
        self.bal = Label(text="— PLS", color=WHITE, bold=True, font_size=dp(17), halign="left", valign="middle")
        self.tag = Label(text="", color=MUTED, font_size=dp(12), halign="right", valign="middle")
        self.add_widget(self.bal); self.add_widget(self.tag)
        w = Button(text="Wallet", size_hint_x=None, width=dp(72), background_normal="", background_color=TEAL, color=WHITE, bold=True)
        w.bind(on_release=lambda _: setattr(app.sm, 'current', 'wallet'))
        self.add_widget(w)
    def refresh(self, state):
        self.bal.text = f"{state.get('balance',0)} PLS  •  ⛏ {state.get('ore',{}).get('coal',0)} 🪨 {state.get('ore',{}).get('iron',0)} 💎 {state.get('ore',{}).get('pulse_crystal',0)} 🟣 {state.get('ore',{}).get('void_shard',0)}"
        self.tag.text = state.get('tag','')

class BaseScreen(Screen):
    def __init__(self, app, name, **kw):
        super().__init__(name=name, **kw)
        self.app = app
        self.root = BoxLayout(orientation="vertical")
        self.top = TopBar(app)
        self.root.add_widget(self.top)
        self.body = BoxLayout(orientation="vertical", padding=dp(12), spacing=dp(10))
        self.root.add_widget(self.body)
        self.root.add_widget(NavBar(app.sm, name))
        self.add_widget(self.root)
    def log(self, msg):
        self.app.log(msg)

# --- MINE ---
class MineScreen(BaseScreen):
    def __init__(self, app, **kw):
        super().__init__(app, "mine", **kw)
        c = Card(orientation="vertical", padding=dp(16), spacing=dp(10), size_hint_y=None, height=dp(240))
        c.add_widget(Label(text="DEEP VEIN", color=(0.3,0.25,0.15,1), bold=True, font_size=dp(22)))
        c.add_widget(Label(text="Tap MINE to complete a work challenge.\nThe server verifies it. You earn +1 PLS + 1 ore.", color=(0.35,0.3,0.22,1), font_size=dp(14)))
        self.status = Label(text="Ready", color=(0.35,0.3,0.22,1), font_size=dp(14))
        c.add_widget(self.status)
        self.btn = PBtn("⛏  MINE BLOCK")
        self.btn.bind(on_release=lambda _: self.do_mine())
        c.add_widget(self.btn)
        self.body.add_widget(c)
        self.log_label = Label(text="", color=WHITE, font_size=dp(13), size_hint_y=None, height=dp(28))
        self.body.add_widget(self.log_label)
        self.body.add_widget(Label(text="Ore drops: Coal 60% • Iron 25% • Crystal 10% • Void 5%\nGear boosts your duels. Forge it below.", color=MUTED, font_size=dp(12)))
    def do_mine(self):
        self.btn.disabled = True; self.status.text = "Solving block..."
        def work():
            data = str(time.time())
            nonce, h = find_pow(WALLET, data)
            r = api("POST", "/mine", {"wallet": WALLET, "nonce": nonce, "data": data})
            def done(dt):
                self.btn.disabled = False
                if r.get("ok"):
                    self.status.text = f"Found {r.get('ore')} + 1 PLS!"
                    self.log_label.text = f"You struck {r.get('ore')} in the Deep Vein."
                    self.app.refresh_state()
                else:
                    self.status.text = f"Error: {r.get('error')}"
            Clock.schedule_once(done, 0)
        threading.Thread(target=work, daemon=True).start()

# --- FORGE ---
class ForgeScreen(BaseScreen):
    def __init__(self, app, **kw):
        super().__init__(app, "forge", **kw)
        self.body.add_widget(Label(text="THE FORGE", color=WHITE, bold=True, font_size=dp(22), size_hint_y=None, height=dp(30)))
        self.body.add_widget(Label(text="Ore + PLS → Gear. Gear boosts duels. No fail chance.", color=MUTED, font_size=dp(12), size_hint_y=None, height=dp(20)))
        self.gear_label = Label(text="No gear yet", color=WHITE, font_size=dp(13), size_hint_y=None, height=dp(60))
        self.body.add_widget(self.gear_label)
        self.grid = GridLayout(cols=1, spacing=dp(8), size_hint_y=None)
        self.grid.bind(minimum_height=self.grid.setter('height'))
        sv = ScrollView(); sv.add_widget(self.grid); self.body.add_widget(sv)
        self.refresh_recipes()
    def refresh_recipes(self):
        self.grid.clear_widgets()
        self.grid.add_widget(Label(text="Loading recipes...", color=MUTED, size_hint_y=None, height=dp(28)))
        def done(r):
            self.grid.clear_widgets()
            if not r.get("recipes"):
                self.grid.add_widget(Label(text="Recipes unavailable: " + str(r.get("error", "unknown")), color=RED, size_hint_y=None, height=dp(32)))
                return
            recipes = r.get("recipes", {})
            state = self.app.state
            gear = state.get("gear", {})
            lines = ["Your Gear:"]
            if not gear: lines.append("— Empty. Forge below.")
            for slot, item in gear.items(): lines.append(f"{slot}: {item.get('name')} +{item.get('stat')}")
            self.gear_label.text = "\n".join(lines)
            for rid, rec in recipes.items():
                ore = rec.get("cost_ore", {})
                cost = " + ".join([f"{v} {k}" for k, v in ore.items()]) + f" + {rec.get('cost_pls')} PLS"
                owned = state.get("ore", {})
                can = all(owned.get(k, 0) >= v for k, v in ore.items()) and state.get("balance", 0) >= rec.get("cost_pls", 0)
                card = DarkCard(orientation="vertical", padding=dp(12), spacing=dp(4), size_hint_y=None, height=dp(104))
                card.add_widget(Label(text=f"{rec['name']}  •  {rec['slot']}  +{rec['stat']}", color=WHITE, bold=True, font_size=dp(15), halign="left", size_hint_y=None, height=dp(22)))
                card.add_widget(Label(text=cost, color=MUTED, font_size=dp(12), size_hint_y=None, height=dp(18)))
                button = PBtn("FORGE" if can else "NEED MORE ORE", bg=AMBER if can else (0.4, 0.4, 0.4, 1))
                button.disabled = not can
                button.bind(on_release=lambda _, recipe_id=rid: self.forge(recipe_id))
                card.add_widget(button)
                self.grid.add_widget(card)
        api_async("GET", "/recipes", None, done)
    def forge(self, rid):
        def done(r):
            if r.get("ok"):
                self.app.refresh_state()
                self.refresh_recipes()
                Popup(title="Forged!", content=Label(text="Gear added to your loadout."), size_hint=(0.8, 0.3)).open()
            else:
                Popup(title="Can't forge", content=Label(text=str(r.get("error"))), size_hint=(0.8, 0.3)).open()
        api_async("POST", "/forge", {"wallet": WALLET, "recipe": rid}, done)

# --- DUEL ---
class DuelScreen(BaseScreen):
    def __init__(self, app, **kw):
        super().__init__(app, "duel", **kw)
        self.body.add_widget(Label(text="DUEL", color=WHITE, bold=True, font_size=dp(22), size_hint_y=None, height=dp(30)))
        self.body.add_widget(Label(text="Skill practice only. No PLS stakes or transfers.", color=MUTED, font_size=dp(12), size_hint_y=None, height=dp(22)))
        self.result = Label(text="Choose a solo practice game.", color=WHITE, font_size=dp(14))
        self.body.add_widget(self.result)
        for title, desc, fn in [
            ("⚡ QUICKDRAW — Reaction", "Tap when it turns GREEN. Gauntlets forgive early taps.", self.quickdraw),
            ("🔢 FORGE SEQUENCE — Memory", "Repeat the sequence. Visor gives you more time.", self.sequence),
            ("🎯 VEIN SNIPER — Precision", "Tap the vein fast. Pickaxe makes your taps count more.", self.sniper),
        ]:
            c = DarkCard(orientation="vertical", padding=dp(12), spacing=dp(4), size_hint_y=None, height=dp(96))
            c.add_widget(Label(text=title, color=WHITE, bold=True, font_size=dp(15)))
            c.add_widget(Label(text=desc, color=MUTED, font_size=dp(12)))
            b = PBtn("PLAY", bg=TEAL, fg=WHITE); b.bind(on_release=lambda _, f=fn: f()); c.add_widget(b)
            self.body.add_widget(c)
    def record_practice(self, game, score):
        def done(r):
            if r.get("ok"):
                self.app.refresh_state()
            else:
                self.result.text = "Practice save failed: " + str(r.get("error", "network error"))
        api_async("POST", "/practice/result", {"wallet": WALLET, "game": game, "score": int(score)}, done)
    def gear_bonus(self, slot):
        g = self.app.state.get("gear", {}).get(slot, {})
        return g.get("stat", 0)
    def quickdraw(self):
        self.result.text = "Wait for GREEN..."; self.result.color = (1,0.8,0.2,1)
        def go(dt):
            self.result.text = "🟢 TAP NOW! (tap this text)"; self.result.color = GREEN
            self._t = time.time()
            self._waiting = True
        Clock.schedule_once(go, random.uniform(1.0, 2.5))
        # tap handling via touch on label
        orig = self.result.on_touch_down
        def on_touch(inst, touch):
            if getattr(self, "_waiting", False) and inst.collide_point(*touch.pos):
                rt = int((time.time()-self._t)*1000)
                forg = self.gear_bonus("gauntlets")
                adj = max(0, rt - forg)
                win = adj < 350
                self.result.text = f"Reaction {rt}ms (gear -{forg}ms = {adj}ms) — {'PRACTICE SUCCESS' if win else 'TRY AGAIN'}"
                self._waiting = False
                self.record_practice("quickdraw", adj)
                return True
            return orig(inst, touch) if orig else False
        self.result.on_touch_down = on_touch
    def sequence(self):
        seq = [random.randint(1,4) for _ in range(4)]
        self.result.text = "Memorize: " + " - ".join(map(str,seq))
        visor = self.gear_bonus("visor")
        def ask(dt):
            entry = TextInput(hint_text="Example: 1 3 2 4", multiline=False, size_hint_y=None, height=dp(48))
            box = BoxLayout(orientation="vertical", padding=dp(10), spacing=dp(8))
            box.add_widget(Label(text="Enter the four numbers in order.", size_hint_y=None, height=dp(30)))
            box.add_widget(entry)
            submit = PBtn("CHECK", bg=TEAL, fg=WHITE)
            box.add_widget(submit)
            pop = Popup(title="Forge Sequence", content=box, size_hint=(0.85,0.42), auto_dismiss=False)
            def check(_):
                raw = entry.text.replace(",", " ").replace("-", " ").split()
                good = raw == [str(x) for x in seq]
                self.result.text = "Correct sequence!" if good else "Not quite. Sequence was " + " - ".join(map(str,seq))
                pop.dismiss()
                self.record_practice("sequence", 100 if good else 0)
            submit.bind(on_release=check)
            pop.open()
        Clock.schedule_once(ask, 2.0 + visor/10.0)
    def sniper(self):
        self.result.text = "Aim... wait for the target."
        self.result.color = (1,0.8,0.2,1)
        self._sniper_waiting = False
        def target(dt):
            self.result.text = "🎯 TARGET! TAP NOW"
            self.result.color = GREEN
            self._sniper_time = time.time()
            self._sniper_waiting = True
        Clock.schedule_once(target, random.uniform(0.8, 2.0))
        orig = self.result.on_touch_down
        def on_touch(inst, touch):
            if getattr(self, "_sniper_waiting", False) and inst.collide_point(*touch.pos):
                rt = int((time.time()-self._sniper_time)*1000)
                pick = self.gear_bonus("pickaxe")
                score = max(0, min(100, 100 - rt//20 + pick//2))
                self.result.text = f"Vein Sniper: {rt}ms • Score {score}/100 — {'PRACTICE SUCCESS' if score>=85 else 'Try again'}"
                self._sniper_waiting = False
                self.record_practice("sniper", score)
                return True
            return orig(inst, touch) if orig else False
        self.result.on_touch_down = on_touch

# --- CHAT + FRIENDS ---
class ChatScreen(BaseScreen):
    def __init__(self, app, **kw):
        super().__init__(app, "chat", **kw)
        self.channel = "lobby"
        self.body.add_widget(Label(text="CHAT & FRIENDS", color=WHITE, bold=True, font_size=dp(20), size_hint_y=None, height=dp(28)))
        tabs = BoxLayout(orientation="horizontal", size_hint_y=None, height=dp(44), spacing=dp(6))
        self.tab_btns = {}
        for ch, lab in [("lobby","Lobby"),("friends","Friends"),("dms","DMs")]:
            b = Button(text=lab, background_normal="", background_color=AMBER if ch=="lobby" else CARD_DARK, color=(0.15,0.12,0.05,1) if ch=="lobby" else WHITE, bold=True)
            b.bind(on_release=lambda _, c=ch: self.set_tab(c))
            tabs.add_widget(b); self.tab_btns[ch]=b
        self.body.add_widget(tabs)
        # Add friend row
        add = BoxLayout(orientation="horizontal", size_hint_y=None, height=dp(44), spacing=dp(6))
        self.tag_in = TextInput(hint_text="Add by Tag e.g. player#1234", multiline=False, background_color=CARD)
        ab = Button(text="ADD", size_hint_x=None, width=dp(70), background_normal="", background_color=TEAL, color=WHITE, bold=True)
        ab.bind(on_release=lambda _: self.add_friend())
        add.add_widget(self.tag_in); add.add_widget(ab); self.body.add_widget(add)
        self.list = GridLayout(cols=1, spacing=dp(6), size_hint_y=None); self.list.bind(minimum_height=self.list.setter('height'))
        sv = ScrollView(); sv.add_widget(self.list); self.body.add_widget(sv)
        # input
        inp = BoxLayout(orientation="horizontal", size_hint_y=None, height=dp(48), spacing=dp(6))
        self.msg_in = TextInput(hint_text="Say something...", multiline=False, background_color=CARD)
        sb = Button(text="SEND", size_hint_x=None, width=dp(72), background_normal="", background_color=AMBER, color=(0.15,0.12,0.05,1), bold=True)
        sb.bind(on_release=lambda _: self.send_msg())
        inp.add_widget(self.msg_in); inp.add_widget(sb); self.body.add_widget(inp)
        self.set_tab("lobby")
        Clock.schedule_interval(lambda dt: self.auto_refresh() if self.app.sm.current=="chat" else None, 4)
    def set_tab(self, ch):
        self.channel = ch
        for k,b in self.tab_btns.items():
            b.background_color = AMBER if k==ch else CARD_DARK
            b.color = (0.15,0.12,0.05,1) if k==ch else WHITE
        self.refresh_list()
    def auto_refresh(self): self.refresh_list()
    def refresh_list(self):
        if self.channel.startswith("dm_"):
            self.refresh_list_dm(self.channel)
            return
        self._dm_channel = None
        self.list.clear_widgets()
        self.list.add_widget(Label(text="Loading...", color=MUTED, size_hint_y=None, height=dp(26)))
        requested_channel = self.channel
        if requested_channel == "friends":
            def done(r):
                if self.channel != requested_channel: return
                self.list.clear_widgets()
                for pending in r.get("pending", []):
                    row = DarkCard(orientation="horizontal", padding=dp(10), spacing=dp(6), size_hint_y=None, height=dp(52))
                    row.add_widget(Label(text=f"{pending.get('from_tag')} wants to be friends", color=WHITE, font_size=dp(11)))
                    accept_button = Button(text="Accept", size_hint_x=None, width=dp(70), background_normal="", background_color=GREEN, color=WHITE, bold=True)
                    accept_button.bind(on_release=lambda _, rid=pending["id"]: self.accept(rid, True))
                    decline_button = Button(text="Decline", size_hint_x=None, width=dp(70), background_normal="", background_color=RED, color=WHITE, bold=True)
                    decline_button.bind(on_release=lambda _, rid=pending["id"]: self.accept(rid, False))
                    row.add_widget(accept_button); row.add_widget(decline_button); self.list.add_widget(row)
                for friend in r.get("friends", []):
                    row = DarkCard(orientation="horizontal", padding=dp(10), spacing=dp(6), size_hint_y=None, height=dp(52))
                    row.add_widget(Label(text=f"{'🟢' if friend.get('online') else '⚪'} {friend.get('display_name')} {friend.get('tag')}", color=WHITE, font_size=dp(11)))
                    dm_button = Button(text="DM", size_hint_x=None, width=dp(56), background_normal="", background_color=TEAL, color=WHITE, bold=True)
                    dm_button.bind(on_release=lambda _, fw=friend["wallet"]: self.open_dm(fw))
                    row.add_widget(dm_button); self.list.add_widget(row)
                if not r.get("friends") and not r.get("pending"):
                    self.list.add_widget(Label(text="No friends yet. Add by Tag above.", color=MUTED, size_hint_y=None, height=dp(30)))
            api_async("GET", f"/friends?wallet={WALLET}", None, done)
            return
        if requested_channel == "dms":
            def done(r):
                if self.channel != requested_channel: return
                self.list.clear_widgets()
                for dm in r.get("dms", []):
                    row = DarkCard(orientation="horizontal", padding=dp(10), size_hint_y=None, height=dp(48))
                    row.add_widget(Label(text=f"{dm.get('other_tag')} — {(dm.get('last') or {}).get('text', '')[:40]}", color=WHITE, font_size=dp(11)))
                    open_button = Button(text="Open", size_hint_x=None, width=dp(64), background_normal="", background_color=TEAL, color=WHITE, bold=True)
                    open_button.bind(on_release=lambda _, channel=dm["channel"]: self.open_channel(channel))
                    row.add_widget(open_button); self.list.add_widget(row)
                if not r.get("dms"):
                    self.list.add_widget(Label(text="No DMs yet. DM from Friends tab.", color=MUTED, size_hint_y=None, height=dp(30)))
            api_async("GET", f"/chat/dms?wallet={WALLET}", None, done)
            return
        def done(r):
            if self.channel != requested_channel: return
            self.list.clear_widgets()
            for message in r.get("messages", []):
                mine = message.get("sender") == WALLET
                box = BoxLayout(orientation="vertical", size_hint_y=None, height=dp(44), padding=[dp(10), 0, dp(10), 0])
                box.add_widget(Label(text=f"{message.get('sender_name')} {message.get('sender_tag')}", color=AMBER if mine else TEAL, font_size=dp(11), halign="left", size_hint_y=None, height=dp(16)))
                box.add_widget(Label(text=message.get("text", ""), color=WHITE, font_size=dp(13), halign="left", size_hint_y=None, height=dp(22)))
                self.list.add_widget(box)
        api_async("GET", "/chat/history?channel=lobby&limit=50", None, done)
    def add_friend(self):
        tag = self.tag_in.text.strip()
        if not tag: return
        def done(r):
            Popup(title="Friend Request", content=Label(text="Sent!" if r.get("ok") else str(r.get("error"))), size_hint=(0.8, 0.3)).open()
            if r.get("ok"):
                self.tag_in.text = ""
                if self.channel == "friends": self.refresh_list()
        api_async("POST", "/friend_request", {"wallet": WALLET, "to_tag": tag}, done)
    def accept(self, rid, yes):
        def done(r):
            if not r.get("ok"):
                Popup(title="Friend Request", content=Label(text=str(r.get("error"))), size_hint=(0.8, 0.3)).open()
            self.refresh_list()
        api_async("POST", "/friend_accept", {"wallet": WALLET, "request_id": rid, "accept": yes}, done)
    def open_dm(self, other):
        a,b = sorted([WALLET, other]); self.open_channel(f"dm_{a}__{b}")
    def open_channel(self, ch):
        self.channel = ch; self.refresh_list_dm(ch)
    def refresh_list_dm(self, ch):
        self.list.clear_widgets()
        self.list.add_widget(Label(text="Loading private messages...", color=MUTED, size_hint_y=None, height=dp(24)))
        self._dm_channel = ch
        def done(r):
            if self.channel != ch: return
            self.list.clear_widgets()
            self.list.add_widget(Label(text="Private conversation", color=MUTED, size_hint_y=None, height=dp(24)))
            for message in r.get("messages", []):
                self.list.add_widget(Label(text=f"{message.get('sender_name')}: {message.get('text')}", color=WHITE, font_size=dp(13), size_hint_y=None, height=dp(28)))
            if not r.get("ok", True):
                self.list.add_widget(Label(text="Unable to load: " + str(r.get("error")), color=RED, size_hint_y=None, height=dp(28)))
        api_async("GET", f"/chat/history?channel={ch}&wallet={WALLET}&limit=50", None, done)
    def send_msg(self):
        text = self.msg_in.text.strip()
        if not text: return
        if self.channel in ("friends", "dms"):
            Popup(title="Chat", content=Label(text="Open a friend DM or switch to Lobby first."), size_hint=(0.8, 0.3)).open()
            return
        channel = self.channel if self.channel == "lobby" or self.channel.startswith("dm_") else "lobby"
        self.msg_in.disabled = True
        def done(r):
            self.msg_in.disabled = False
            if r.get("ok"):
                self.msg_in.text = ""
                self.refresh_list()
            else:
                Popup(title="Chat", content=Label(text=str(r.get("error"))), size_hint=(0.8, 0.3)).open()
        api_async("POST", "/chat/send", {"wallet": WALLET, "channel": channel, "text": text}, done)


# --- NETWORK NODES ---
class NetworkScreen(BaseScreen):
    def __init__(self, app, **kw):
        super().__init__(app, "network", **kw)
        self.body.add_widget(Label(text="CONNECTED DEVICES", color=WHITE, bold=True, font_size=dp(22), size_hint_y=None, height=dp(30)))
        self.status = Label(text="Connecting this phone to Pulse...", color=MUTED, font_size=dp(13), size_hint_y=None, height=dp(44))
        self.body.add_widget(self.status)
        self.list = GridLayout(cols=1, spacing=dp(8), size_hint_y=None)
        self.list.bind(minimum_height=self.list.setter('height'))
        sv = ScrollView(); sv.add_widget(self.list); self.body.add_widget(sv)
        b = PBtn("↻ REFRESH DEVICES", bg=TEAL, fg=WHITE); b.bind(on_release=lambda _: self.refresh_nodes()); self.body.add_widget(b)
    def refresh_nodes(self):
        self.status.text = "Discovering active devices..."
        def done(r):
            self.list.clear_widgets()
            if not r.get("ok"):
                self.status.text = "Network unavailable: " + str(r.get("error", "unknown"))
                return
            peers = r.get("peers", [])
            self.status.text = "Connected • %s active node(s) including this phone" % r.get("active_nodes", 1)
            own = DarkCard(orientation="vertical", padding=dp(10), size_hint_y=None, height=dp(66))
            own.add_widget(Label(text="THIS DEVICE • ONLINE", color=GREEN, bold=True, font_size=dp(14)))
            own.add_widget(Label(text="Node " + NODE_ID[-12:], color=MUTED, font_size=dp(11)))
            self.list.add_widget(own)
            for peer in peers:
                card = DarkCard(orientation="vertical", padding=dp(10), size_hint_y=None, height=dp(72))
                card.add_widget(Label(text="● " + peer.get("display_name", "Pulse Player") + "  " + peer.get("tag", ""), color=TEAL, bold=True, font_size=dp(14)))
                card.add_widget(Label(text="Node " + peer.get("node_id", "")[-12:] + " • " + peer.get("wallet", "")[:18], color=WHITE, font_size=dp(11)))
                self.list.add_widget(card)
            if not peers:
                self.list.add_widget(Label(text="No other phones are online yet. Share the app and have another phone connect.", color=MUTED, size_hint_y=None, height=dp(54)))
        api_async("GET", "/nodes", None, done)

# --- QUESTS ---
class QuestScreen(BaseScreen):
    def __init__(self, app, **kw):
        super().__init__(app, "quests", **kw)
        self.body.add_widget(Label(text="📜 DAILY QUESTS", color=WHITE, bold=True, font_size=dp(22), size_hint_y=None, height=dp(30)))
        self.body.add_widget(Label(text="Reset every day. Complete → Claim → Get PLS + Ore.", color=MUTED, font_size=dp(12), size_hint_y=None, height=dp(20)))
        self.list = GridLayout(cols=1, spacing=dp(8), size_hint_y=None); self.list.bind(minimum_height=self.list.setter('height'))
        sv = ScrollView(); sv.add_widget(self.list); self.body.add_widget(sv)
        rb = PBtn("↻ REFRESH", bg=TEAL, fg=WHITE); rb.bind(on_release=lambda _: self.refresh_quests()); self.body.add_widget(rb)
        Clock.schedule_interval(lambda dt: self.refresh_quests() if self.app.sm.current=="quests" else None, 10)
    def refresh_quests(self):
        self.list.clear_widgets()
        self.list.add_widget(Label(text="Loading quests...", color=MUTED, size_hint_y=None, height=dp(28)))
        def done(r):
            self.list.clear_widgets()
            if not r.get("quests"):
                self.list.add_widget(Label(text="Quests unavailable: " + str(r.get("error", "unknown")), color=RED, size_hint_y=None, height=dp(30)))
                return
            for quest in r.get("quests", []):
                completed = quest["progress"] >= quest["target"]
                card = DarkCard(orientation="vertical", padding=dp(12), spacing=dp(4), size_hint_y=None, height=dp(104))
                card.add_widget(Label(text=f"{quest['title']}  {'✅ DONE' if completed else ''}", color=GREEN if completed else WHITE, bold=True, font_size=dp(15)))
                card.add_widget(Label(text=f"{quest['desc']} — {quest['progress']}/{quest['target']} • Reward: +{quest['reward_pls']} PLS + {quest['reward_ore_amt']} {quest['reward_ore']}", color=MUTED, font_size=dp(12)))
                if completed and not quest["claimed"]:
                    button = PBtn("CLAIM REWARD", bg=AMBER)
                    button.bind(on_release=lambda _, qid=quest["id"]: self.claim(qid))
                    card.add_widget(button)
                elif quest["claimed"]:
                    card.add_widget(Label(text="Claimed ✓", color=GREEN, font_size=dp(12), size_hint_y=None, height=dp(24)))
                else:
                    card.add_widget(Label(text=f"Progress {quest['progress']}/{quest['target']}", color=WHITE, font_size=dp(12), size_hint_y=None, height=dp(24)))
                self.list.add_widget(card)
        api_async("GET", f"/quests?wallet={WALLET}", None, done)
    def claim(self, qid):
        def done(r):
            if r.get("ok"):
                self.app.refresh_state()
                self.refresh_quests()
                Popup(title="Quest Complete!", content=Label(text=f"+{r['reward_pls']} PLS + {r['reward_ore_amt']} {r['reward_ore']}"), size_hint=(0.8, 0.3)).open()
            else:
                Popup(title="Can't claim", content=Label(text=str(r.get("error"))), size_hint=(0.8, 0.3)).open()
        api_async("POST", "/quests/claim", {"wallet": WALLET, "quest_id": qid}, done)

# --- WALLET ---
class WalletScreen(BaseScreen):
    def __init__(self, app, **kw):
        super().__init__(app, "wallet", **kw)
        self.body.add_widget(Label(text="WALLET", color=WHITE, bold=True, font_size=dp(22), size_hint_y=None, height=dp(30)))
        self.info = Label(text="", color=WHITE, font_size=dp(11))
        self.body.add_widget(self.info)
        self.name_in = TextInput(hint_text="Display name (max 20)", multiline=False, size_hint_y=None, height=dp(44), background_color=CARD)
        self.body.add_widget(self.name_in)
        b = PBtn("SAVE NAME", bg=TEAL, fg=WHITE); b.bind(on_release=lambda _: self.save_name()); self.body.add_widget(b)
        self.body.add_widget(Label(text="WALLET BACKUP", color=AMBER, bold=True, font_size=dp(13), size_hint_y=None, height=dp(24)))
        self.body.add_widget(Label(text="Export both identity files to a location you choose. The ZIP contains your private wallet secret.", color=MUTED, font_size=dp(12), size_hint_y=None, height=dp(48)))
        backup_button = PBtn("EXPORT SECURE BACKUP", bg=TEAL, fg=WHITE)
        backup_button.bind(on_release=lambda _: self.export_backup())
        self.body.add_widget(backup_button)
        restore_button = PBtn("RESTORE FROM BACKUP", bg=AMBER)
        restore_button.bind(on_release=lambda _: self.restore_backup())
        self.body.add_widget(restore_button)
        self.body.add_widget(Label(text="Back this up somewhere private. Losing it locks your account. Never share the backup.", color=RED, font_size=dp(12), size_hint_y=None, height=dp(42)))
        self._backup_request_code = 7319
        self._restore_request_code = 7320
        self._backup_bound = False
        self._restore_bound = False
        self.body.add_widget(Label(text="Your Pulse Tag is your friend ID.\nShare it to get friend requests.\nPLS is in-game only for now — no cash-out in this version.", color=MUTED, font_size=dp(12)))
    def export_backup(self):
        try:
            from jnius import autoclass
            from android import activity
            Intent = autoclass("android.content.Intent")
            intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            intent.addCategory(Intent.CATEGORY_OPENABLE)
            intent.setType("application/zip")
            intent.putExtra(Intent.EXTRA_TITLE, "pulse_network_wallet_backup.zip")
            self._backup_activity = activity
            if not self._backup_bound:
                activity.bind(on_activity_result=self._on_backup_result)
                self._backup_bound = True
            PythonActivity = autoclass("org.kivy.android.PythonActivity")
            PythonActivity.mActivity.startActivityForResult(intent, self._backup_request_code)
        except Exception as exc:
            Popup(title="Backup unavailable", content=Label(text="Android file export could not start: " + str(exc)), size_hint=(0.9, 0.35)).open()

    def restore_backup(self):
        try:
            from jnius import autoclass
            from android import activity
            Intent = autoclass("android.content.Intent")
            intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            intent.addCategory(Intent.CATEGORY_OPENABLE)
            intent.setType("application/zip")
            self._restore_activity = activity
            if not self._restore_bound:
                activity.bind(on_activity_result=self._on_restore_result)
                self._restore_bound = True
            PythonActivity = autoclass("org.kivy.android.PythonActivity")
            PythonActivity.mActivity.startActivityForResult(intent, self._restore_request_code)
        except Exception as exc:
            Popup(title="Restore unavailable", content=Label(text="Android file picker could not open: " + str(exc)), size_hint=(0.9, 0.35)).open()

    def _on_restore_result(self, request_code, result_code, intent):
        if request_code != self._restore_request_code: return
        try:
            if self._restore_bound:
                self._restore_activity.unbind(on_activity_result=self._on_restore_result)
                self._restore_bound = False
            if result_code != -1 or intent is None: return
            from jnius import autoclass
            import io, zipfile
            PythonActivity = autoclass("org.kivy.android.PythonActivity")
            stream = PythonActivity.mActivity.getContentResolver().openInputStream(intent.getData())
            if stream is None: raise IOError("Android could not open the selected backup.")
            payload = bytearray()
            try:
                while True:
                    value = stream.read()
                    if value < 0: break
                    payload.append(value & 255)
            finally:
                stream.close()
            with zipfile.ZipFile(io.BytesIO(bytes(payload)), "r") as archive:
                wallet_obj = json.loads(archive.read("pulse_wallet.json").decode("utf-8"))
                # The old node token is not reused. A restored install gets a fresh node identity.
                archive.read("pulse_node.json")
            wallet_id = wallet_obj.get("wallet")
            wallet_secret = wallet_obj.get("wallet_secret")
            if not isinstance(wallet_id, str) or len(wallet_id) < 6 or len(wallet_id) > 80 or not all(c.isalnum() or c in "_-" for c in wallet_id):
                raise ValueError("The backup wallet ID is invalid.")
            if not isinstance(wallet_secret, str) or len(wallet_secret) < 24:
                raise ValueError("The backup wallet secret is missing or invalid.")
            wallet_tmp = WALLET_FILE + ".restore"
            node_tmp = NODE_FILE + ".restore"
            with open(wallet_tmp, "w") as target:
                json.dump({"wallet": wallet_id, "wallet_secret": wallet_secret}, target)
            with open(node_tmp, "w") as target:
                json.dump({"node_id": "node_" + uuid.uuid4().hex, "node_token": ""}, target)
            os.replace(wallet_tmp, WALLET_FILE)
            os.replace(node_tmp, NODE_FILE)
            Popup(title="Backup restored", content=Label(text="Backup validated and restored. Fully close and reopen Pulse Network to load the recovered account."), size_hint=(0.9, 0.4)).open()
        except Exception as exc:
            Popup(title="Restore failed", content=Label(text="Backup was not installed: " + str(exc)), size_hint=(0.9, 0.35)).open()

    def _on_backup_result(self, request_code, result_code, intent):
        if request_code != self._backup_request_code: return
        try:
            if self._backup_bound:
                self._backup_activity.unbind(on_activity_result=self._on_backup_result)
                self._backup_bound = False
            if result_code != -1 or intent is None: return
            from jnius import autoclass
            import io, zipfile
            with open(WALLET_FILE, "rb") as source: wallet_bytes = source.read()
            try:
                with open(NODE_FILE, "rb") as source: node_bytes = source.read()
            except Exception:
                node_bytes = json.dumps({"node_id": NODE_ID, "node_token": NODE_TOKEN}).encode("utf-8")
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("pulse_wallet.json", wallet_bytes)
                archive.writestr("pulse_node.json", node_bytes)
            PythonActivity = autoclass("org.kivy.android.PythonActivity")
            stream = PythonActivity.mActivity.getContentResolver().openOutputStream(intent.getData())
            if stream is None: raise IOError("Android could not open the selected destination.")
            try:
                for byte_value in buffer.getvalue(): stream.write(int(byte_value))
                stream.flush()
            finally:
                stream.close()
            Popup(title="Backup exported", content=Label(text="Wallet and device files saved. Keep this ZIP private."), size_hint=(0.9, 0.35)).open()
        except Exception as exc:
            Popup(title="Backup failed", content=Label(text=str(exc)), size_hint=(0.9, 0.35)).open()

    def save_name(self):
        def done(r):
            if r.get("ok"):
                self.app.refresh_state()
                Popup(title="Saved", content=Label(text="Display name updated."), size_hint=(0.8, 0.3)).open()
            else:
                Popup(title="Save failed", content=Label(text=str(r.get("error"))), size_hint=(0.8, 0.3)).open()
        api_async("POST", "/profile/set", {"wallet": WALLET, "display_name": self.name_in.text.strip()}, done)

class PulseApp(App):
    def build(self):
        Window.clearcolor = BG
        self.state = {"balance": 0, "ore": {}, "gear": {}, "tag": ""}
        self.sm = ScreenManager()
        self.mine = MineScreen(self); self.forge = ForgeScreen(self); self.duel = DuelScreen(self); self.chat = ChatScreen(self); self.wallet = WalletScreen(self); self.quests = QuestScreen(self)
        for s in [self.mine, self.forge, self.duel, self.chat, self.wallet, self.quests]: self.sm.add_widget(s)
        self.log_label = None
        self.network = NetworkScreen(self)
        self.sm.add_widget(self.network)
        Clock.schedule_once(lambda dt: self.start_network(), 0.3)
        return self.sm
    def log(self, msg): pass
    def start_network(self):
        def work():
            r = register_node()
            if r.get("ok"):
                api("POST", "/node/heartbeat", {"wallet": WALLET})
                Clock.schedule_once(lambda dt: self.network.refresh_nodes(), 0)
                Clock.schedule_once(lambda dt: self.quests.refresh_quests(), 0)
                self.refresh_state()
            else:
                Clock.schedule_once(lambda dt: setattr(self.network.status, "text", "Could not connect: " + str(r.get("error"))), 0)
        threading.Thread(target=work, daemon=True).start()
        Clock.schedule_interval(lambda dt: self.node_heartbeat(), 60)
    def node_heartbeat(self):
        def work():
            r = api("POST", "/node/heartbeat", {"wallet": WALLET})
            if r.get("ok"):
                Clock.schedule_once(lambda dt: self.network.refresh_nodes() if self.sm.current == "network" else None, 0)
            elif r.get("error") == "node_auth_required":
                register_node()
        threading.Thread(target=work, daemon=True).start()
    def refresh_state(self):
        def work():
            r = api("GET", f"/balance?wallet={WALLET}")
            if "balance" in r: self.state = r
            def done(dt):
                for s in [self.mine, self.forge, self.duel, self.chat, self.wallet, self.quests, self.network]:
                    try: s.top.refresh(self.state)
                    except: pass
                try: self.forge.refresh_recipes()
                except: pass
                try: self.wallet.info.text = f"Wallet: {WALLET}\nTag: {self.state.get('tag')}\nName: {self.state.get('display_name')}\nBalance: {self.state.get('balance')} PLS"
                except: pass
            Clock.schedule_once(done, 0)
        threading.Thread(target=work, daemon=True).start()

if __name__ == "__main__":
    PulseApp().run()
