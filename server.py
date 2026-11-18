# Pulse Network Server v3.3 - stdlib only
# Render coordinator: game API + authenticated node registration/heartbeat/discovery.
import os, json, hashlib, time, random, uuid, datetime, threading, secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DATA_FILE = os.environ.get('PULSE_DATA_FILE', 'pulse_data.json')
try:
 DIFFICULTY = max(0, min(6, int(os.environ.get('PULSE_DIFFICULTY', '2'))))
except Exception:
 DIFFICULTY = 2
MINE_COOLDOWN = float(os.environ.get('PULSE_MINE_COOLDOWN', '5'))
NODE_TTL = 180
DB_LOCK = threading.RLock()
ORE_TABLE = [('coal',60),('iron',25),('pulse_crystal',10),('void_shard',5)]
RECIPES = {
 'iron_pickaxe': {'name':'Iron Pickaxe','slot':'pickaxe','cost_ore':{'iron':10,'coal':5},'cost_pls':2,'stat':8,'durability':20},
 'iron_gauntlets': {'name':'Iron Gauntlets','slot':'gauntlets','cost_ore':{'iron':10,'coal':5},'cost_pls':2,'stat':15,'durability':20},
 'iron_visor': {'name':'Iron Visor','slot':'visor','cost_ore':{'iron':10,'coal':5},'cost_pls':2,'stat':3,'durability':20},
 'crystal_pickaxe': {'name':'Crystal Pickaxe','slot':'pickaxe','cost_ore':{'pulse_crystal':8,'iron':10},'cost_pls':5,'stat':12,'durability':40},
 'crystal_gauntlets': {'name':'Crystal Gauntlets','slot':'gauntlets','cost_ore':{'pulse_crystal':8,'iron':10},'cost_pls':5,'stat':30,'durability':40},
 'crystal_visor': {'name':'Crystal Visor','slot':'visor','cost_ore':{'pulse_crystal':8,'iron':10},'cost_pls':5,'stat':6,'durability':40},
 'void_pickaxe': {'name':'Void Pickaxe','slot':'pickaxe','cost_ore':{'void_shard':3,'pulse_crystal':10},'cost_pls':15,'stat':20,'durability':100},
 'void_gauntlets': {'name':'Void Gauntlets','slot':'gauntlets','cost_ore':{'void_shard':3,'pulse_crystal':10},'cost_pls':15,'stat':50,'durability':100},
 'void_visor': {'name':'Void Visor','slot':'visor','cost_ore':{'void_shard':3,'pulse_crystal':10},'cost_pls':15,'stat':10,'durability':100}}

def blank_db():
 return {'users':{},'messages':[],'friend_requests':[],'friends':[],'blocks':[],'quests':{},'nodes':{},'used_work':[]}
def load():
 try:
  with open(DATA_FILE,'r') as f: db=json.load(f)
 except Exception: db=blank_db()
 base=blank_db()
 for k,v in base.items():
  if k not in db: db[k]=v
 return db
def save():
 tmp=DATA_FILE+'.tmp'
 with open(tmp,'w') as f: json.dump(DB,f,separators=(',',':'))
 os.replace(tmp,DATA_FILE)
DB=load()
def valid_wallet(w): return isinstance(w,str) and 6 <= len(w) <= 80 and all(c.isalnum() or c in '_-' for c in w)
def get_user(wallet):
 wallet=(wallet or '').strip()
 if not valid_wallet(wallet): raise ValueError('invalid_wallet')
 if wallet not in DB['users']:
  n=random.randint(1000,9999)
  DB['users'][wallet]={'wallet':wallet,'tag':'player#%04d'%n,'display_name':'Player %04d'%n,'balance':0,'ore':{'coal':0,'iron':0,'pulse_crystal':0,'void_shard':0},'gear':{},'last_seen':time.time(),'last_chat':0,'last_mine':0,'nonce':0,'wins':0,'losses':0,'streak':0,'best_streak':0,'titles':[],'equipped_title':''}
 u=DB['users'][wallet]
 # Backward-compatible migration for accounts created by earlier Pulse builds.
 defaults={'balance':0,'ore':{'coal':0,'iron':0,'pulse_crystal':0,'void_shard':0},'gear':{},'last_seen':0,'last_chat':0,'last_mine':0,'nonce':0,'wins':0,'losses':0,'streak':0,'best_streak':0,'titles':[],'equipped_title':''}
 for key,value in defaults.items():
  if key not in u:u[key]=value.copy() if isinstance(value,dict) else value
 if not isinstance(u.get('ore'),dict):u['ore']=defaults['ore'].copy()
 for ore in defaults['ore']:
  u['ore'].setdefault(ore,0)
 return u
def find_by_tag(tag):
 for u in DB['users'].values():
  if u.get('tag','').lower()==str(tag).lower(): return u
 return None
def roll_ore():
 n=random.randint(1,100); total=0
 for name,chance in ORE_TABLE:
  total+=chance
  if n<=total:return name
 return 'coal'
def is_blocked(a,b): return any((x.get('a')==a and x.get('b')==b) or (x.get('a')==b and x.get('b')==a) for x in DB['blocks'])
def are_friends(a,b): return any((x.get('a')==a and x.get('b')==b) or (x.get('a')==b and x.get('b')==a) for x in DB['friends'])
def daily_quests(wallet):
 today=datetime.date.today().isoformat(); key=wallet+':'+today
 if key not in DB['quests']:
  DB['quests'][key]={'date':today,'quests':[
   {'id':'mine_5','title':'⛏ Mine 5 Blocks','desc':'Mine 5 blocks in the Deep Vein','target':5,'progress':0,'reward_pls':3,'reward_ore':'coal','reward_ore_amt':5,'claimed':False},
   {'id':'forge_1','title':'⚒ Forge 1 Gear','desc':'Forge any gear in The Forge','target':1,'progress':0,'reward_pls':5,'reward_ore':'iron','reward_ore_amt':3,'claimed':False},
   {'id':'duel_2','title':'⚔ Play 2 Practice Duels','desc':'Complete two solo practice games','target':2,'progress':0,'reward_pls':5,'reward_ore':'pulse_crystal','reward_ore_amt':2,'claimed':False},
   {'id':'win_1','title':'🏆 Practice High Score','desc':'Score 85 or higher in Vein Sniper','target':1,'progress':0,'reward_pls':5,'reward_ore':'void_shard','reward_ore_amt':1,'claimed':False}]}
 return DB['quests'][key]
def bump_quest(wallet,qid,amount=1):
 q=daily_quests(wallet)
 for x in q['quests']:
  if x['id']==qid:x['progress']=min(x['target'],x['progress']+amount)
def node_auth(b):
 node_id=b.get('node_id'); token=b.get('node_token')
 if not isinstance(node_id,str) or not isinstance(token,str): return None
 node=DB['nodes'].get(node_id)
 if not node:return None
 if not secrets.compare_digest(node.get('token_hash',''),hashlib.sha256(token.encode()).hexdigest()):return None
 node['last_seen']=time.time()
 return node

class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def send_json(self,obj,code=200):
  raw=json.dumps(obj,ensure_ascii=False).encode('utf-8')
  self.send_response(code);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Cache-Control','no-store')
  self.send_header('Access-Control-Allow-Origin','*');self.send_header('Access-Control-Allow-Headers','Content-Type,X-Pulse-Node-Id,X-Pulse-Node-Token');self.send_header('Access-Control-Allow-Methods','GET,POST,OPTIONS')
  self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
 def read_json(self):
  try:
   n=int(self.headers.get('Content-Length','0'))
   if n<0 or n>100000:return {}
   return json.loads(self.rfile.read(n).decode('utf-8')) if n else {}
  except Exception:return {}
 def identity(self,b):
  node_id=self.headers.get('X-Pulse-Node-Id') or b.get('node_id')
  token=self.headers.get('X-Pulse-Node-Token') or b.get('node_token')
  return {'node_id':node_id,'node_token':token}
 def require_node(self,b,wallet=None):
  ident=self.identity(b); node=node_auth(ident)
  if not node:return None
  if wallet and node.get('wallet')!=wallet:return None
  return node
 def do_OPTIONS(self): self.send_response(204);self.send_header('Access-Control-Allow-Origin','*');self.send_header('Access-Control-Allow-Headers','Content-Type,X-Pulse-Node-Id,X-Pulse-Node-Token');self.send_header('Access-Control-Allow-Methods','GET,POST,OPTIONS');self.end_headers()
 def do_GET(self):
  with DB_LOCK:
   p=urlparse(self.path);q=parse_qs(p.query);path=p.path
   if path in ('/','/health'):
    active=sum(1 for n in DB['nodes'].values() if time.time()-n.get('last_seen',0)<NODE_TTL)
    return self.send_json({'ok':True,'service':'pulse','version':3.3,'difficulty':DIFFICULTY,'users':len(DB['users']),'active_nodes':active})
   b=self.identity({})
   if path=='/nodes':
    node=self.require_node(b)
    if not node:return self.send_json({'ok':False,'error':'node_auth_required'},401)
    now=time.time(); peers=[]
    for nid,n in DB['nodes'].items():
     if nid!=b['node_id'] and now-n.get('last_seen',0)<NODE_TTL:
      u=DB['users'].get(n.get('wallet'),{})
      peers.append({'node_id':nid,'wallet':n.get('wallet'),'display_name':u.get('display_name','Player'),'tag':u.get('tag',''),'last_seen':int(n.get('last_seen',0)),'app_version':n.get('app_version','')})
    peers.sort(key=lambda x:x['last_seen'],reverse=True)
    return self.send_json({'ok':True,'node_id':b['node_id'],'active_nodes':len(peers)+1,'peers':peers})
   if path=='/balance':
    wallet=q.get('wallet',[''])[0]
    if not valid_wallet(wallet):return self.send_json({'ok':False,'error':'invalid_wallet'},400)
    if not self.require_node(b,wallet):return self.send_json({'ok':False,'error':'node_auth_required'},401)
    u=get_user(wallet);u['last_seen']=time.time();save()
    return self.send_json({k:u.get(k) for k in ('wallet','tag','display_name','balance','ore','gear','wins','losses','streak','best_streak','titles','equipped_title')})
   if path=='/friends':
    wallet=q.get('wallet',[''])[0]
    if not valid_wallet(wallet):return self.send_json({'ok':False,'error':'invalid_wallet'},400)
    if not self.require_node(b,wallet):return self.send_json({'ok':False,'error':'node_auth_required'},401)
    get_user(wallet);out=[]
    for f in DB['friends']:
     other=f['b'] if f['a']==wallet else f['a'] if f['b']==wallet else None
     if other:
      ou=DB['users'].get(other,{})
      out.append({'wallet':other,'tag':ou.get('tag',''),'display_name':ou.get('display_name',''),'online':time.time()-ou.get('last_seen',0)<300})
    pending=[r for r in DB['friend_requests'] if r['to']==wallet and r['status']=='pending']
    return self.send_json({'friends':out,'pending':pending})
   if path=='/chat/history':
    channel=q.get('channel',['lobby'])[0][:100];wallet=q.get('wallet',[''])[0];limit=max(1,min(100,int(q.get('limit',['50'])[0] or 50)))
    if channel.startswith('dm_'):
     parts=channel[3:].split('__')
     if len(parts)!=2 or wallet not in parts or not are_friends(*parts) or is_blocked(*parts):return self.send_json({'ok':False,'error':'dm_forbidden'},403)
     if not self.require_node(b,wallet):return self.send_json({'ok':False,'error':'node_auth_required'},401)
    msgs=[m for m in DB['messages'] if m['channel']==channel][-limit:]
    return self.send_json({'channel':channel,'messages':msgs})
   if path=='/chat/dms':
    wallet=q.get('wallet',[''])[0]
    if not valid_wallet(wallet):return self.send_json({'ok':False,'error':'invalid_wallet'},400)
    if not self.require_node(b,wallet):return self.send_json({'ok':False,'error':'node_auth_required'},401)
    chans=sorted(set(m['channel'] for m in DB['messages'] if m['channel'].startswith('dm_') and wallet in m['channel']))
    out=[]
    for c in chans:
     parts=c[3:].split('__')
     if len(parts)!=2 or wallet not in parts:continue
     other=parts[1] if parts[0]==wallet else parts[0];ou=DB['users'].get(other,{})
     last=next((m for m in reversed(DB['messages']) if m['channel']==c),None)
     out.append({'channel':c,'other_wallet':other,'other_tag':ou.get('tag',''),'last':last})
    return self.send_json({'dms':out})
   if path=='/quests':
    wallet=q.get('wallet',[''])[0]
    if not valid_wallet(wallet):return self.send_json({'ok':False,'error':'invalid_wallet'},400)
    if not self.require_node(b,wallet):return self.send_json({'ok':False,'error':'node_auth_required'},401)
    qq=daily_quests(wallet);save();return self.send_json(qq)
   if path=='/recipes':return self.send_json({'recipes':RECIPES})
   return self.send_json({'ok':False,'error':'not_found'},404)
 def do_POST(self):
  with DB_LOCK:
   b=self.read_json();path=urlparse(self.path).path
   if path=='/node/register':
    wallet=b.get('wallet');node_id=b.get('node_id')
    if not valid_wallet(wallet) or not isinstance(node_id,str) or len(node_id)<12 or len(node_id)>100:return self.send_json({'ok':False,'error':'bad_node_identity'},400)
    u=get_user(wallet)
    wallet_secret=b.get('wallet_secret','')
    if not isinstance(wallet_secret,str) or len(wallet_secret)<24:return self.send_json({'ok':False,'error':'wallet_secret_required'},400)
    wallet_hash=hashlib.sha256(wallet_secret.encode()).hexdigest()
    stored_wallet_hash=u.get('wallet_secret_hash')
    if stored_wallet_hash and not secrets.compare_digest(stored_wallet_hash,wallet_hash):return self.send_json({'ok':False,'error':'wallet_auth_failed'},403)
    if not stored_wallet_hash:u['wallet_secret_hash']=wallet_hash
    u['last_seen']=time.time()
    existing=DB['nodes'].get(node_id)
    if existing:
     if existing.get('wallet')!=wallet:return self.send_json({'ok':False,'error':'node_wallet_mismatch'},403)
     # Re-registration requires the existing secret; clients retain it locally.
     token=b.get('node_token','')
     if not token or not secrets.compare_digest(existing.get('token_hash',''),hashlib.sha256(token.encode()).hexdigest()):return self.send_json({'ok':False,'error':'node_already_registered'},409)
    else:
     token=secrets.token_urlsafe(32)
     DB['nodes'][node_id]={'wallet':wallet,'token_hash':hashlib.sha256(token.encode()).hexdigest(),'created_at':time.time(),'last_seen':time.time(),'app_version':str(b.get('app_version',''))[:30]}
    DB['nodes'][node_id]['last_seen']=time.time();save()
    return self.send_json({'ok':True,'node_id':node_id,'node_token':token,'heartbeat_seconds':60,'node_ttl_seconds':NODE_TTL,'difficulty':DIFFICULTY})
   if path=='/node/heartbeat':
    node=self.require_node(b,b.get('wallet'))
    if not node:return self.send_json({'ok':False,'error':'node_auth_required'},401)
    node['last_seen']=time.time()
    if node.get('wallet') in DB['users']:DB['users'][node['wallet']]['last_seen']=time.time()
    save();return self.send_json({'ok':True,'server_time':int(time.time()),'active_nodes':sum(1 for n in DB['nodes'].values() if time.time()-n.get('last_seen',0)<NODE_TTL)})
   wallet=b.get('wallet','')
   # All mutations require a registered node belonging to the wallet.
   if path not in ('/node/register',) and not self.require_node(b,wallet if wallet else None):return self.send_json({'ok':False,'error':'node_auth_required'},401)
   if path not in ('/node/register',) and not valid_wallet(wallet):return self.send_json({'ok':False,'error':'invalid_wallet'},400)
   if path=='/profile/set':
    u=get_user(wallet);name=str(b.get('display_name') or '').strip()[:20]
    if name:u['display_name']=name
    save();return self.send_json({'ok':True,'tag':u['tag'],'display_name':u['display_name']})
   if path=='/mine':
    now=time.time()
    data=str(b.get('data',''));nonce=b.get('nonce')
    if not data or len(data)>100 or not str(nonce).isdigit():return self.send_json({'ok':False,'error':'bad_work'},400)
    try:stamp=float(data)
    except Exception:stamp=0
    if abs(now-stamp)>600:return self.send_json({'ok':False,'error':'work_expired'},400)
    h=hashlib.sha256(('%s:%s:%s'%(wallet,data,nonce)).encode()).hexdigest()
    if not h.startswith('0'*DIFFICULTY):return self.send_json({'ok':False,'error':'invalid_pow','need':'0'*DIFFICULTY},400)
    work_id=hashlib.sha256((wallet+':'+data+':'+str(nonce)).encode()).hexdigest()
    if work_id in DB['used_work']:return self.send_json({'ok':False,'error':'work_already_used'},409)
    u=get_user(wallet)
    if now-u.get('last_mine',0)<MINE_COOLDOWN:return self.send_json({'ok':False,'error':'mine_cooldown_5s'},429)
    ore=roll_ore();u['ore'][ore]=u['ore'].get(ore,0)+1;u['balance']+=1;u['nonce']=max(u.get('nonce',0),int(nonce));u['last_seen']=now;u['last_mine']=now
    DB['used_work'].append(work_id);DB['used_work']=DB['used_work'][-10000:];bump_quest(wallet,'mine_5');save()
    return self.send_json({'ok':True,'hash':h,'reward_pls':1,'ore':ore,'balance':u['balance'],'ore_inv':u['ore']})
   if path=='/forge':
    rid=b.get('recipe')
    if rid not in RECIPES:return self.send_json({'ok':False,'error':'bad_recipe'},400)
    r=RECIPES[rid];u=get_user(wallet)
    for k,v in r['cost_ore'].items():
     if u['ore'].get(k,0)<v:return self.send_json({'ok':False,'error':'need_%s'%k},400)
    if u['balance']<r['cost_pls']:return self.send_json({'ok':False,'error':'need_pls'},400)
    for k,v in r['cost_ore'].items():u['ore'][k]-=v
    u['balance']-=r['cost_pls'];u['gear'][r['slot']]={'id':str(uuid.uuid4())[:8],'recipe':rid,'name':r['name'],'stat':r['stat'],'durability':r['durability'],'max_durability':r['durability']}
    bump_quest(wallet,'forge_1');save();return self.send_json({'ok':True,'gear':u['gear'],'balance':u['balance'],'ore':u['ore']})
   if path=='/friend_request':
    target=find_by_tag(str(b.get('to_tag','')).strip());frm=wallet
    if not target:return self.send_json({'ok':False,'error':'tag_not_found'},404)
    if target['wallet']==frm:return self.send_json({'ok':False,'error':'cannot_add_self'},400)
    if is_blocked(frm,target['wallet']):return self.send_json({'ok':False,'error':'blocked'},403)
    if are_friends(frm,target['wallet']):return self.send_json({'ok':False,'error':'already_friends'},400)
    if any(x['from']==frm and x['to']==target['wallet'] and x['status']=='pending' for x in DB['friend_requests']):return self.send_json({'ok':False,'error':'already_pending'},400)
    DB['friend_requests'].append({'id':str(uuid.uuid4())[:8],'from':frm,'from_tag':get_user(frm)['tag'],'to':target['wallet'],'status':'pending','created_at':time.time()});save();return self.send_json({'ok':True})
   if path=='/friend_accept':
    rid=b.get('request_id');accept=bool(b.get('accept',True))
    for req in DB['friend_requests']:
     if req['id']==rid and req['to']==wallet and req['status']=='pending':
      req['status']='accepted' if accept else 'declined'
      if accept and not are_friends(req['from'],req['to']):DB['friends'].append({'a':req['from'],'b':req['to'],'created_at':time.time()})
      save();return self.send_json({'ok':True,'accepted':accept})
    return self.send_json({'ok':False,'error':'not_found'},404)
   if path=='/friend_remove':
    other=b.get('friend_wallet','');DB['friends']=[f for f in DB['friends'] if set((f['a'],f['b']))!=set((wallet,other))];save();return self.send_json({'ok':True})
   if path=='/block':
    other=b.get('target_wallet','')
    if other==wallet:return self.send_json({'ok':False,'error':'cannot_block_self'},400)
    if not is_blocked(wallet,other):DB['blocks'].append({'a':wallet,'b':other})
    DB['friends']=[f for f in DB['friends'] if set((f['a'],f['b']))!=set((wallet,other))];save();return self.send_json({'ok':True})
   if path=='/quests/claim':
    q=daily_quests(wallet);quest=next((x for x in q['quests'] if x['id']==b.get('quest_id')),None)
    if not quest:return self.send_json({'ok':False,'error':'not_found'},404)
    if quest['claimed']:return self.send_json({'ok':False,'error':'already_claimed'},409)
    if quest['progress']<quest['target']:return self.send_json({'ok':False,'error':'not_complete'},400)
    u=get_user(wallet);u['balance']+=quest['reward_pls'];ore=quest['reward_ore'];u['ore'][ore]=u['ore'].get(ore,0)+quest['reward_ore_amt'];quest['claimed']=True;save()
    return self.send_json({'ok':True,'reward_pls':quest['reward_pls'],'reward_ore':ore,'reward_ore_amt':quest['reward_ore_amt'],'balance':u['balance']})
   if path=='/practice/result':
    score=max(0,min(2000,int(b.get('score',0))));game=str(b.get('game',''))
    if game not in ('quickdraw','sequence','sniper'):return self.send_json({'ok':False,'error':'bad_game'},400)
    bump_quest(wallet,'duel_2')
    won=(score>=85 if game!='quickdraw' else score<=350)
    if won:bump_quest(wallet,'win_1')
    save();return self.send_json({'ok':True,'won':won,'score':score,'message':'Practice result recorded. Practice does not transfer PLS between players.'})
   if path=='/chat/send':
    channel=str(b.get('channel') or 'lobby').strip()[:100];txt=str(b.get('text') or '').strip()[:200]
    if not txt:return self.send_json({'ok':False,'error':'empty'},400)
    u=get_user(wallet)
    if channel=='lobby' and time.time()-u.get('last_chat',0)<5:return self.send_json({'ok':False,'error':'slow_mode_5s'},429)
    if channel.startswith('dm_'):
     parts=channel[3:].split('__')
     if len(parts)!=2 or wallet not in parts:return self.send_json({'ok':False,'error':'not_in_dm'},403)
     if is_blocked(*parts) or not are_friends(*parts):return self.send_json({'ok':False,'error':'not_friends_or_blocked'},403)
    # Keep filtering narrow and avoid partial-word replacement.
    for bad in ('nigger','faggot'):
     import re
     txt=re.sub(r'(?i)\b'+re.escape(bad)+r'\b','***',txt)
    u['last_chat']=time.time();u['last_seen']=time.time()
    msg={'id':str(uuid.uuid4())[:8],'channel':channel,'sender':wallet,'sender_tag':u['tag'],'sender_name':u['display_name'],'sender_title':u.get('equipped_title',''),'text':txt,'created_at':time.time()}
    DB['messages'].append(msg);DB['messages']=DB['messages'][-2000:];save();return self.send_json({'ok':True,'message':msg})
   return self.send_json({'ok':False,'error':'not_found'},404)

if __name__=='__main__':
 port=int(os.environ.get('PORT','10000'))
 print('Pulse Network v3 listening on',port,flush=True)
 ThreadingHTTPServer(('0.0.0.0',port),Handler).serve_forever()
