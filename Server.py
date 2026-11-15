# PULSE CHAIN SERVER - SECURE v2.0 - stdlib only, no Flask
# Patches: token auth, replay, rate limit, semaphore, save throttle, type checks, negative checks, body cap
import json, hashlib, time, threading, os, secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
CHAIN_FILE="pulse_chain.json"; AUTO_MINER=True; AUTO_MINER_TIMEOUT=15; VERSION="2.0-secure"
STARTED=time.time(); LOCK=threading.Lock(); SEM=threading.Semaphore(100)
LAST_MINE={}; SEEN_NONCES=set(); TOKENS={}  # wallet -> token (in-memory light; persist in real: save to file, here kept + saved to tokens.json)
TOKEN_FILE="pulse_tokens.json"
def load_json(path, default):
    if os.path.exists(path):
        try:
            with open(path) as f: return json.load(f)
        except Exception as e: print(f"load {path} failed: {e}", flush=True)
    return default
def atomic_save(path, data):
    tmp=path+".tmp"
    with open(tmp,"w") as f: json.dump(data,f)
    os.replace(tmp,path)
chain=load_json(CHAIN_FILE, {"height":0,"blocks":[],"balances":{},"state_root":"genesis","auto_miner_blocks":0,"phone_blocks":0})
for k,v in [("height",0),("blocks",[]),("balances",{}),("auto_miner_blocks",0),("phone_blocks",0)]: chain.setdefault(k,v)
TOKENS.update(load_json(TOKEN_FILE, {}))
LAST_SAVE=[0]
def save_throttled():
    # Save at most every 2s, caller holds LOCK
    if time.time()-LAST_SAVE[0] < 2: return
    atomic_save(CHAIN_FILE, chain); LAST_SAVE[0]=time.time()
def verify_pow(height, prev, nonce, miner):
    h=hashlib.sha256(f"{height}:{prev}:{nonce}:{miner}".encode()).hexdigest()
    return h.startswith("00"), h
def is_valid_wallet(w): return isinstance(w,str) and 1<=len(w)<=128 and all(c.isalnum() or c in "_-" for c in w)
def auth_ok(wallet, headers):
    # A1: token required for writes. Token = "Bearer <hex>"
    if not is_valid_wallet(wallet): return False
    auth=headers.get("Authorization","")
    if not auth.startswith("Bearer "): return False
    tok=auth[7:].strip()
    return TOKENS.get(wallet)==tok and len(tok)==64
def auto_loop():
    while True:
        time.sleep(5)
        if not AUTO_MINER: continue
        with LOCK:
            last_ts=chain["blocks"][-1]["ts"] if chain["blocks"] else STARTED
            if time.time()-last_ts>=AUTO_MINER_TIMEOUT:
                h=chain["height"]+1; prev=chain["blocks"][-1]["hash"] if chain["blocks"] else "genesis"
                nonce=0
                while True:
                    ok,hh=verify_pow(h,prev,nonce,"auto-miner")
                    if ok: break
                    nonce+=1
                    if nonce>500000: break
                if ok:
                    chain["blocks"].append({"height":h,"prev":prev,"hash":hh,"nonce":nonce,"miner":"auto-miner","ts":time.time(),"txs":[]}); chain["height"]=h; chain["auto_miner_blocks"]+=1; save_throttled()
class H(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*a): pass
    def send_json(self,obj,code=200):
        try:
            body=json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.send_header("Connection","close"); self.end_headers(); self.wfile.write(body)
        except Exception as e: print(f"send failed: {e}", flush=True)
    def read_body(self):
        try: n=int(self.headers.get("Content-Length",0) or 0)
        except Exception: n=0
        if n<0 or n>65536: return None  # C2
        raw=self.rfile.read(n) if n else b"{}"
        if raw.count(b"[")>1000: return None  # C3 deep nesting guard
        try: return json.loads(raw.decode() or "{}")
        except Exception: return {}
    def do_GET(self):
        try:
            with SEM:
                p=urlparse(self.path).path
                if p in ("/","/health"):
                    total=max(1, chain["auto_miner_blocks"]+chain["phone_blocks"])
                    return self.send_json({"ok":True,"version":VERSION,"height":chain["height"],"server_time":time.time(),"auto_miner":AUTO_MINER,"phone_pct":round(100*chain["phone_blocks"]/total,1)})
                if p=="/chain/headers": return self.send_json({"height":chain["height"],"blocks":chain["blocks"][-20:]})
                return self.send_json({"error":"not_found"},404)
        except Exception as e: return self.send_json({"ok":False,"error":"internal"},500)
    def do_POST(self):
        try:
            with SEM:
                p=urlparse(self.path).path; b=self.read_body()
                if b is None: return self.send_json({"ok":False,"error":"body_too_large_or_bad"},413)
                if not isinstance(b,dict): return self.send_json({"ok":False,"error":"body_must_be_object"},400)
                if p=="/auth/register":
                    # A1: server issues wallet+token, client never invents wallet
                    wallet="pulse_"+secrets.token_hex(12)
                    token=secrets.token_hex(32); TOKENS[wallet]=token; atomic_save(TOKEN_FILE, TOKENS)
                    return self.send_json({"ok":True,"wallet":wallet,"token":token,"warning":"Store token securely, never share. Lose it = lose account in light version."})
                if p=="/mine":
                    wallet=b.get("wallet"); nonce=b.get("nonce")
                    if not is_valid_wallet(wallet): return self.send_json({"ok":False,"error":"bad_wallet"},400)
                    if not auth_ok(wallet, self.headers): return self.send_json({"ok":False,"error":"auth_required"},401)  # A1
                    if not isinstance(nonce,int) or nonce<0 or nonce>500000: return self.send_json({"ok":False,"error":"bad_nonce"},400)  # A4/C9
                    ip=self.client_address[0] if self.client_address else "?"
                    now=time.time()
                    if now-LAST_MINE.get(ip,0)<2: return self.send_json({"ok":False,"error":"rate_limit_2s"},429)  # C5
                    with LOCK:
                        # A3 replay: nonce must be fresh for this height/prev
                        key=(chain["height"]+1, nonce, wallet)
                        if key in SEEN_NONCES: return self.send_json({"ok":False,"error":"replay_nonce"},400)
                        SEEN_NONCES.add(key)
                        if len(SEEN_NONCES)>1000: SEEN_NONCES.clear()
                        LAST_MINE[ip]=now
                        h=chain["height"]+1; prev=chain["blocks"][-1]["hash"] if chain["blocks"] else "genesis"
                        ok,hh=verify_pow(h,prev,nonce,wallet)
                        if not ok: return self.send_json({"ok":False,"error":"invalid_pow"},400)
                        blk={"height":h,"prev":prev,"hash":hh,"nonce":nonce,"miner":wallet,"ts":time.time(),"txs":[]}
                        chain["blocks"].append(blk); chain["height"]=h; chain["phone_blocks"]+=1; save_throttled()
                        return self.send_json({"ok":True,"block":blk})
                return self.send_json({"error":"not_found"},404)
        except Exception as e: print(f"POST failed: {type(e).__name__}", flush=True); return self.send_json({"ok":False,"error":"internal"},500)
if __name__=="__main__":
    threading.Thread(target=auto_loop,daemon=True).start()
    port=int(os.environ.get("PORT",8000))
    srv=ThreadingHTTPServer(("0.0.0.0",port),H); srv.daemon_threads=True; srv.request_queue_size=50; srv.socket_timeout=10
    print(f"Pulse Chain SECURE {VERSION} on {port}", flush=True); srv.serve_forever()
