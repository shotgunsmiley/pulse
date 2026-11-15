
"""
Pulse server.py - NO FLASK NEEDED, stdlib only
Run locally:  python server.py
Run on Render: Start Command = python server.py
                 (Render sets PORT automatically, this file reads it)

This is the server that lives on Render at https://pulse-nadr.onrender.com/
Your phone app talks to it. It holds the REAL balances.
The phone NEVER decides its own balance - only this file does.

Endpoints (all match fixed main.py):
  GET  /                -> {"status":"ok",...}
  GET  /latest_block   -> {"hash","difficulty","height"}
  GET  /balance?address=PLS_... -> {"balance": float}
  GET  /leaderboard    -> [{"address","score"}, ...]
  POST /register       -> store public key
  POST /submit_transaction -> signed send
  POST /submit_block   -> verify PoW + signature, pay 5.0 PLS
  POST /vein_play      -> server rolls 50%, settles
  POST /buy_upgrade    -> server charges 10 PLS
"""
import hashlib, json, secrets, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import os

DIFFICULTY = 2
BLOCK_REWARD = 5.0
UPGRADE_COST = 10.0

lock = threading.Lock()
balances = {}   # address -> float
pubkeys = {}    # address -> public_key hex
upgrades = {}   # address -> level (multiplier = 1 + 0.25*level)
chain = [{"index":0,"prev_hash":"GENESIS","hash":hashlib.sha256(b"GENESIS").hexdigest(),"miner":"GENESIS","nonce":0,"timestamp":int(time.time())}]

# --- secp256k1 verify (same math as phone app, pure stdlib) ---
P = (1 << 256) - (1 << 32) - 977
N = int("115792089237316195423570985008687907852837564279074904382605163141518161494337")
Gx = int("55066263022277343669578718895168534326250603453777594175500187360389116729240")
Gy = int("32670510020758816978083085130507043184471273380659243275938904335757337482424")  # secp256k1 generator Y
def _inv(a,m): return pow(a,-1,m)
def _add(p1,p2):
    if p1 is None: return p2
    if p2 is None: return p1
    x1,y1=p1; x2,y2=p2
    if x1==x2 and y1!=y2: return None
    m=((3*x1*x1)*_inv(2*y1,P))%P if p1==p2 else ((y2-y1)*_inv(x2-x1,P))%P
    x3=(m*m-x1-x2)%P; y3=(m*(x1-x3)-y1)%P
    return (x3,y3)
def _mul(k,pt):
    r=None
    while k:
        if k&1: r=_add(r,pt)
        pt=_add(pt,pt); k>>=1
    return r
def verify(pub_hex, message, sig):
    try:
        x=int(pub_hex[:64],16); y=int(pub_hex[64:],16)
        r=int(sig["r"],16); s=int(sig["s"],16)
        if not (1<=r<N and 1<=s<N): return False
        z=int.from_bytes(hashlib.sha256(message.encode()).digest(),"big")
        w=_inv(s,N); u1=(z*w)%N; u2=(r*w)%N
        pt=_add(_mul(u1,(Gx,Gy)), _mul(u2,(x,y)))
        return pt is not None and pt[0]%N==r
    except Exception:
        return False
def canon(o): return json.dumps(o, sort_keys=True, separators=(",",":"))

def check_sig(payload):
    """payload is a copy. Returns True only if signature matches public key."""
    sig = payload.pop("signature", None)
    # figure out who sent it
    addr = payload.get("sender") or payload.get("miner") or payload.get("player") or payload.get("buyer") or payload.get("address")
    pub = payload.get("public_key") or pubkeys.get(addr)
    if not sig or not pub or not addr: return False
    if payload.get("public_key"): pubkeys[addr] = payload["public_key"]
    return verify(pub, canon(payload), sig)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass  # keep Render logs clean
    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def _read_json(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n==0: return {}
            return json.loads(self.rfile.read(n).decode() or "{}")
        except Exception: return {}
    def do_GET(self):
        u = urlparse(self.path); path = u.path.rstrip("/") or "/"
        q = parse_qs(u.query)
        if path == "/":
            self._send({"status":"ok","height":len(chain)-1,"difficulty":DIFFICULTY,"note":"Pulse server running - no Flask needed"})
        elif path == "/latest_block":
            b = chain[-1]; self._send({"hash":b["hash"],"prev_hash":b["prev_hash"],"difficulty":DIFFICULTY,"height":b["index"]})
        elif path == "/balance":
            a = (q.get("address") or [""])[0]; self._send({"balance": round(balances.get(a,0.0),6)})
        elif path == "/leaderboard":
            ranked = sorted(balances.items(), key=lambda kv: kv[1], reverse=True)[:50]
            self._send([{"address":a,"score":round(b,2)} for a,b in ranked])
        else: self._send({"error":"Not found"}, 404)
    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        d = self._read_json()
        if path == "/register":
            if d.get("address") and d.get("public_key"):
                pubkeys[d["address"]] = d["public_key"]; balances.setdefault(d["address"], 0.0)
                self._send({"success":True})
            else: self._send({"error":"Need address + public_key"}, 400); return
        elif path == "/submit_transaction":
            if not check_sig(dict(d)): self._send({"error":"Invalid signature - are you using the FIXED app?"}, 401); return
            try: amt = float(d.get("amount",0))
            except Exception: self._send({"error":"Invalid amount"},400); return
            if amt <= 0: self._send({"error":"Amount must be > 0"},400); return
            if not str(d.get("recipient","")).startswith("PLS_"): self._send({"error":"Invalid recipient"},400); return
            with lock:
                if balances.get(d["sender"],0.0) < amt: self._send({"error":"Insufficient balance"},400); return
                balances[d["sender"]] -= amt; balances[d["recipient"]] = balances.get(d["recipient"],0.0)+amt
            self._send({"success":True,"message":f"Sent {amt:.2f} PLS"})
        elif path == "/submit_block":
            if not check_sig(dict(d)): self._send({"error":"Invalid signature"},401); return
            prev = chain[-1]["hash"]
            if d.get("prev_hash") != prev: self._send({"success":False,"error":"Stale block - refetch latest_block"},409); return
            try: h = hashlib.sha256(f"{d['prev_hash']}{d['miner']}{d['nonce']}".encode()).hexdigest()
            except Exception: self._send({"success":False,"error":"Bad block data"},400); return
            if h != d.get("hash") or not h.startswith("0"*DIFFICULTY): self._send({"success":False,"error":"Invalid PoW"},400); return
            with lock:
                if chain[-1]["hash"] != prev: self._send({"success":False,"error":"Stale block"},409); return
                chain.append({"index":len(chain),"prev_hash":prev,"hash":h,"miner":d["miner"],"nonce":d["nonce"],"timestamp":int(time.time())})
                balances[d["miner"]] = balances.get(d["miner"],0.0)+BLOCK_REWARD
            self._send({"success":True,"reward":BLOCK_REWARD,"height":len(chain)-1})
        elif path == "/vein_play":
            if not check_sig(dict(d)): self._send({"error":"Invalid signature"},401); return
            try: wager = float(d.get("wager",0))
            except Exception: self._send({"error":"Invalid wager"},400); return
            player = d.get("player")
            if wager<=0 or wager>100: self._send({"error":"Wager must be 0-100 PLS"},400); return
            with lock:
                if balances.get(player,0.0) < wager: self._send({"error":"Insufficient balance"},400); return
                win = secrets.randbelow(100) < 50  # SERVER rolls, phone cannot cheat
                if win:
                    payout = round(wager*1.95,6); balances[player] += (payout-wager)
                else:
                    payout = 0.0; balances[player] -= wager
                self._send({"success":True,"win":win,"wager":wager,"payout":payout,"balance":round(balances[player],6)})
        elif path == "/buy_upgrade":
            if not check_sig(dict(d)): self._send({"error":"Invalid signature"},401); return
            buyer = d.get("buyer")
            with lock:
                if balances.get(buyer,0.0) < UPGRADE_COST: self._send({"error":"Insufficient balance"},400); return
                balances[buyer] -= UPGRADE_COST; upgrades[buyer] = upgrades.get(buyer,0)+1
                level = upgrades[buyer]; mult = round(1.0+0.25*level,3)
            self._send({"success":True,"upgrade_level":level,"multiplier":mult,"balance":round(balances[buyer],6)})
        else: self._send({"error":"Not found"},404)

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "10000"))  # Render sets PORT for you
    print(f"Pulse server running on port {port} - no Flask needed", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
