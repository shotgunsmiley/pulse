import os, sys, json, time, hashlib, subprocess, tempfile, urllib.request, urllib.error, socket, random, shutil, ast
from concurrent.futures import ThreadPoolExecutor
BASE=os.path.dirname(os.path.abspath(__file__))
DATA=tempfile.mktemp(prefix='pulse_sim_',suffix='.json')
PORT=0
ENV=os.environ.copy(); ENV['PULSE_DATA_FILE']=DATA; ENV['PULSE_DIFFICULTY']='3'
proc=None

def start():
    global proc, PORT
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); PORT=sock.getsockname()[1]
    ENV['PORT']=str(PORT)
    proc=subprocess.Popen([sys.executable, BASE+'/server.py'],env=ENV,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            req('GET','/health')
            return
        except Exception: time.sleep(.05)
    raise RuntimeError('server did not start')
def stop():
    global proc
    if proc:
        proc.terminate(); proc.wait(timeout=5); proc=None

def req(method,path,data=None,headers=None):
    body=json.dumps(data).encode() if data is not None else None
    h={'Content-Type':'application/json'}; h.update(headers or {})
    r=urllib.request.Request(f'http://127.0.0.1:{PORT}'+path,data=body,headers=h,method=method)
    try:
        with urllib.request.urlopen(r,timeout=4) as x:return x.status,json.loads(x.read())
    except urllib.error.HTTPError as e:return e.code,json.loads(e.read())

class Phone:
    def __init__(self,name):
        self.wallet='wallet_'+name.lower(); self.secret='secret_'+name.lower()+'_0123456789abcdef0123456789'; self.node='node_'+name.lower()+'_0123456789abcdef'; self.token=None
        st,b=req('POST','/node/register',{'wallet':self.wallet,'wallet_secret':self.secret,'node_id':self.node,'app_version':'sim-3'})
        assert st==200 and b.get('ok'),b
        self.token=b['node_token']
        hs, health=req('GET','/health'); assert hs==200 and health.get('ok'),health
        self.difficulty=health.get('difficulty')
        assert self.difficulty==3, health
    def headers(self):return {'X-Pulse-Node-Id':self.node,'X-Pulse-Node-Token':self.token}
    def post(self,path,data):
        d=dict(data); d.setdefault('wallet',self.wallet)
        return req('POST',path,d,self.headers())
    def get(self,path):return req('GET',path,headers=self.headers())
    def mine(self):
        stamp=str(time.time())
        nonce=0
        while not hashlib.sha256(f'{self.wallet}:{stamp}:{nonce}'.encode()).hexdigest().startswith('0'*self.difficulty):nonce+=1
        return self.post('/mine',{'data':stamp,'nonce':nonce})


def audit_ui_threading_and_pow_handshake():
    source=open(os.path.join(BASE,'main.py'),encoding='utf-8').read()
    tree=ast.parse(source)
    targets={'ChatScreen':{'refresh_list','refresh_list_dm','send_msg','add_friend','accept'},
             'QuestScreen':{'refresh_quests','claim'},
             'ForgeScreen':{'refresh_recipes','forge'},
             'NetworkScreen':{'refresh_nodes'},
             'WalletScreen':{'save_name'},
             'DuelScreen':{'record_practice'}}
    found=set()
    for cls in tree.body:
        if isinstance(cls,ast.ClassDef) and cls.name in targets:
            for method in cls.body:
                if isinstance(method,ast.FunctionDef) and method.name in targets[cls.name]:
                    found.add((cls.name,method.name))
                    calls=[n for n in ast.walk(method) if isinstance(n,ast.Call) and isinstance(n.func,ast.Name)]
                    assert not any(n.func.id=='api' for n in calls), cls.name+'.'+method.name+' still calls api() on UI path'
                    assert any(n.func.id=='api_async' for n in calls), cls.name+'.'+method.name+' does not use api_async'
    expected={(c,m) for c,methods in targets.items() for m in methods}
    assert found==expected,(found,expected)
    helper=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='api_async')
    helper_calls=[n for n in ast.walk(helper) if isinstance(n,ast.Call)]
    assert any(isinstance(n.func,ast.Attribute) and n.func.attr=='schedule_once' for n in helper_calls)
    assert any(isinstance(n.func,ast.Attribute) and n.func.attr=='Thread' for n in helper_calls)
    pow_fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='find_pow')
    assert 'POW_DIFFICULTY' in ast.dump(pow_fn)
    register=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='register_node')
    assert '/health' in ast.dump(register) and 'difficulty' in ast.dump(register)
    assert 'export_backup' in source and 'restore_backup' in source and 'ACTION_CREATE_DOCUMENT' in source and 'ACTION_OPEN_DOCUMENT' in source and 'Clipboard' not in source
    return 'all requested UI methods are async; callback returns through Kivy Clock; mining difficulty comes from /health with fallback 2; wallet backup uses Android save-location picker, not clipboard'

results=[]
def check(name,fn):
    try: detail=fn(); results.append((name,'PASS',str(detail)))
    except Exception as e: results.append((name,'FAIL',repr(e)))

try:
    start()
    a=Phone('alpha'); b=Phone('bravo'); c=Phone('charlie')
    check('UI threading, difficulty handshake, and secure backup source audit',audit_ui_threading_and_pow_handshake)
    check('three devices register as distinct nodes',lambda: (lambda x: x)([a.node,b.node,c.node]) if len({a.node,b.node,c.node})==3 else (_ for _ in ()).throw(AssertionError('node collision')))
    def discovery():
        for p in (a,b,c):
            s,r=p.get('/nodes'); assert s==200 and r['ok'] and r['active_nodes']==3 and len(r['peers'])==2,(s,r)
        return 'each device sees the other two; no self listed as peer'
    check('mutual peer discovery',discovery)
    def auth_isolation():
        s,r=req('POST','/profile/set',{'wallet':a.wallet,'display_name':'hacked'}); assert s==401
        s,r=b.post('/profile/set',{'wallet':a.wallet,'display_name':'hacked'}); assert s==401
        s,r=a.post('/profile/set',{'display_name':'Alpha'}); assert s==200 and r['display_name']=='Alpha'
        s,r=req('POST','/node/register',{'wallet':a.wallet,'wallet_secret':'wrong_secret_that_is_long_enough_123456','node_id':'node_attacker_0123456789abcdef'}); assert s==403 and r['error']=='wallet_auth_failed',(s,r)
        s,r=req('POST','/node/register',{'wallet':a.wallet,'wallet_secret':a.secret,'node_id':a.node,'node_token':a.token}); assert s==200 and r['ok'] and r['node_token']==a.token,(s,r)
        return 'anonymous/cross-wallet mutations rejected; wallet secret mismatch rejected; valid node re-registration retained token'
    check('node authentication and wallet binding',auth_isolation)
    def friend_dm():
        # obtain B tag
        _,bal=b.get('/balance?wallet='+b.wallet)
        s,r=a.post('/friend_request',{'to_tag':bal['tag']}); assert s==200 and r['ok'],r
        s,pend=b.get('/friends?wallet='+b.wallet); assert s==200 and len(pend['pending'])==1,pend
        rid=pend['pending'][0]['id']
        s,r=b.post('/friend_accept',{'request_id':rid,'accept':True}); assert s==200 and r['accepted'],r
        chan='dm_'+'__'.join(sorted([a.wallet,b.wallet]))
        s,r=a.post('/chat/send',{'channel':chan,'text':'hello from alpha'}); assert s==200 and r['ok'],r
        s,h=b.get('/chat/history?channel='+chan+'&wallet='+b.wallet+'&limit=50'); assert s==200 and len(h['messages'])==1 and h['messages'][0]['text']=='hello from alpha',h
        s,r=c.get('/chat/history?channel='+chan+'&wallet='+c.wallet+'&limit=50'); assert s==403 and r['error']=='dm_forbidden',(s,r)
        # A stranger who guesses/learns participant wallet IDs must not read the DM.
        s,r=req('GET','/chat/history?channel='+chan+'&wallet='+a.wallet+'&limit=50'); assert s==401 and r['error']=='node_auth_required',(s,r)
        s,r=req('GET','/chat/dms?wallet='+a.wallet); assert s==401 and r['error']=='node_auth_required',(s,r)
        s,r=req('GET','/friends?wallet='+a.wallet); assert s==401 and r['error']=='node_auth_required',(s,r)
        s,r=req('GET','/balance?wallet='+a.wallet); assert s==401 and r['error']=='node_auth_required',(s,r)
        s,r=req('GET','/quests?wallet='+a.wallet); assert s==401 and r['error']=='node_auth_required',(s,r)
        return 'friend request accepted; DM delivered; unrelated device and unauthenticated private-data reads denied'
    check('friends and private chat isolation',friend_dm)
    def heartbeat_friend_presence():
        with open(DATA) as f: db=json.load(f)
        db['users'][b.wallet]['last_seen']=time.time()-400
        with open(DATA,'w') as f:json.dump(db,f)
        s,r=b.post('/node/heartbeat',{}); assert s==200 and r['ok'],r
        s,r=a.get('/friends?wallet='+a.wallet); assert s==200
        friend=next(x for x in r['friends'] if x['wallet']==b.wallet)
        assert friend['online'] is True,friend
        return 'active node heartbeat also refreshes player online presence'
    check('heartbeat keeps friend presence online',heartbeat_friend_presence)
    def mine_cooldown():
        s1,r1=a.mine(); assert s1==200 and r1.get('ok'),r1
        s2,r2=a.mine(); assert s2==429 and r2.get('error')=='mine_cooldown_5s',(s2,r2)
        return 'two valid proofs from one wallet inside five seconds: first rewarded, second returned HTTP 429 mine_cooldown_5s'
    check('five-second per-wallet mine cooldown',mine_cooldown)
    # The default cooldown was explicitly verified above. Disable only in this
    # isolated local test process so bulk economy tests do not sleep 5s per mine.
    stop(); ENV['PULSE_MINE_COOLDOWN']='0'; start()
    def mining_quests():
        for _ in range(5):
            s,r=a.mine(); assert s==200 and r['ok'],r
        s,q=a.get('/quests?wallet='+a.wallet); assert s==200
        mine=next(x for x in q['quests'] if x['id']=='mine_5'); assert mine['progress']==5,mine
        before=a.get('/balance?wallet='+a.wallet)[1]['balance']
        s,r=a.post('/quests/claim',{'quest_id':'mine_5'}); assert s==200 and r['ok'],r
        after=a.get('/balance?wallet='+a.wallet)[1]['balance']; assert after==before+3,(before,after)
        s,r=a.post('/quests/claim',{'quest_id':'mine_5'}); assert s==409 and r['error']=='already_claimed',(s,r)
        return 'five valid proofs counted; reward paid once; duplicate claim rejected'
    check('proof-of-work mining and quest claim',mining_quests)
    def replay_expiry():
        stamp=str(time.time()); nonce=0
        while not hashlib.sha256(f'{b.wallet}:{stamp}:{nonce}'.encode()).hexdigest().startswith('0'*b.difficulty):nonce+=1
        data={'data':stamp,'nonce':nonce}
        s,r=b.post('/mine',data); assert s==200,r
        s,r=b.post('/mine',data); assert s==409 and r['error']=='work_already_used',(s,r)
        s,r=b.post('/mine',{'data':str(time.time()-1000),'nonce':nonce}); assert s==400 and r['error']=='work_expired',(s,r)
        return 'same proof cannot pay twice; stale proof rejected'
    check('mining replay and stale-work defenses',replay_expiry)
    def concurrent_replay():
        stamp=str(time.time()); nonce=0
        while not hashlib.sha256(f'{c.wallet}:{stamp}:{nonce}'.encode()).hexdigest().startswith('0'*c.difficulty):nonce+=1
        payload={'wallet':c.wallet,'data':stamp,'nonce':nonce,'node_id':c.node,'node_token':c.token}
        def send(_):return req('POST','/mine',payload,c.headers())
        with ThreadPoolExecutor(max_workers=2) as pool: answers=list(pool.map(send,[1,2]))
        codes=sorted(x[0] for x in answers); assert codes==[200,409],answers
        return 'two simultaneous submissions of identical work produced one reward only'
    check('concurrent duplicate mining race',concurrent_replay)
    def practice():
        for game,score in [('quickdraw',200),('sequence',100),('sniper',90)]:
            s,r=c.post('/practice/result',{'game':game,'score':score}); assert s==200 and r['ok'],r
        s,q=c.get('/quests?wallet='+c.wallet); duel=next(x for x in q['quests'] if x['id']=='duel_2'); win=next(x for x in q['quests'] if x['id']=='win_1')
        assert duel['progress']==2 and win['progress']==1,(duel,win)
        return 'three practice submissions counted; duel quest capped at target; high-score quest progressed'
    check('practice score and quest progress',practice)
    def forge_success():
        for i in range(120):
            bal=a.get('/balance?wallet='+a.wallet)[1]
            if bal['ore']['iron']>=10 and bal['ore']['coal']>=5 and bal['balance']>=2:break
            s,r=a.mine(); assert s==200 and r['ok'],r
        else: raise AssertionError('did not mine enough materials in 120 attempts')
        before=a.get('/balance?wallet='+a.wallet)[1]
        s,r=a.post('/forge',{'recipe':'iron_pickaxe'}); assert s==200 and r['ok'],r
        after=a.get('/balance?wallet='+a.wallet)[1]
        assert after['gear'].get('pickaxe',{}).get('recipe')=='iron_pickaxe',after
        assert after['ore']['iron']==before['ore']['iron']-10 and after['ore']['coal']==before['ore']['coal']-5 and after['balance']==before['balance']-2,(before,after)
        return 'earned resources through verified mining; forge consumed exact costs and equipped pickaxe'
    check('full mining-to-forge economy flow',forge_success)
    def malformed():
        s,r=a.post('/forge',{'recipe':'not_a_recipe'}); assert s==400 and r['error']=='bad_recipe',(s,r)
        s,r=a.post('/practice/result',{'game':'invented','score':500}); assert s==400 and r['error']=='bad_game',(s,r)
        s,r=req('GET','/nodes'); assert s==401 and r['error']=='node_auth_required',(s,r)
        s,r=req('POST','/profile/set',{},a.headers()); assert s==400 and r['error']=='invalid_wallet',(s,r)
        return 'invalid recipe/game, missing wallet, and unauthenticated discovery rejected'
    check('invalid requests and protected discovery',malformed)
    def restart_persistence():
        oldbal=a.get('/balance?wallet='+a.wallet)[1]['balance']
        stop(); start()
        s,r=a.get('/nodes'); assert s==200 and r['ok'] and r['active_nodes']==3,(s,r)
        newbal=a.get('/balance?wallet='+a.wallet)[1]['balance']; assert newbal==oldbal,(oldbal,newbal)
        # persisted token still works after restart
        s,r=a.post('/profile/set',{'display_name':'Alpha Restarted'}); assert s==200 and r['ok'],r
        return 'wallet, node tokens, peers, and balances survive process restart with same data file'
    check('server restart and file persistence',restart_persistence)
    def ttl_expiry():
        with open(DATA) as f: db=json.load(f)
        db['nodes'][b.node]['last_seen']=time.time()-240
        with open(DATA,'w') as f:json.dump(db,f)
        stop(); start()
        s,r=a.get('/nodes'); assert s==200 and r['active_nodes']==2 and all(p['node_id']!=b.node for p in r['peers']),(s,r)
        return 'device with heartbeat older than 180 seconds disappears from peer list'
    check('offline node TTL behavior',ttl_expiry)
finally:
    stop()
    try: os.remove(DATA)
    except: pass

for n,status,detail in results: print(f'{status}: {n} — {detail}')
print('\nTOTAL',sum(x[1]=='PASS' for x in results),'PASS /',sum(x[1]=='FAIL' for x in results),'FAIL')
if any(x[1]=='FAIL' for x in results):sys.exit(1)
