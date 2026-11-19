extends Node
# This phone as a Pulse network node.
#   1. Makes its own RSA-2048 node key once (kept in the app's private storage; only the
#      PUBLIC key ever leaves the phone).
#   2. Registers the key with the server, then proves it holds the key with a signed handshake.
#   3. While active (the server's policy: while the player is mining) it sends a signed
#      heartbeat about every 30 s. Each heartbeat the server accepts is one contribution unit;
#      units turn into PLS rewards every 10 minutes.

signal status_changed(text: String, color: Color)
signal pulsed(counted: bool)    # v5: every accepted heartbeat (the town crystal flares)

const UI = preload("res://scripts/ui.gd")
const KEY_PATH := "user://pulse_node_key.key"
const STATE_PATH := "user://pulse_node.json"

var M
var key: CryptoKey = null
var crypto := Crypto.new()
var uid := ""
var node_id := ""
var node_token := ""
var seq := 0
var interval := 30.0
var policy := "while_mining"
var active := false
var ready_state := "off"      # off | starting | ready | error | removed
var since_beat := 0.0
var last_strike_ms := -1000000
var units_today := 0
var daily_cap := 0
var sending := false
var gen := 0


func setup(m) -> void:
	M = m


func note_strike() -> void:
	last_strike_ms = Time.get_ticks_msec()


func is_mining() -> bool:
	return Time.get_ticks_msec() - last_strike_ms < 60000


func _say(text: String, color: Color = UI.MUTED) -> void:
	status_changed.emit(text, color)


# ---- key ---------------------------------------------------------------------
func _ensure_key() -> bool:
	if key != null:
		return true
	if FileAccess.file_exists(KEY_PATH):
		var k := CryptoKey.new()
		if k.load(KEY_PATH) == OK:
			key = k
			return true
	_say("Setting up this phone as a node...")
	var made := []
	var task := WorkerThreadPool.add_task(func(): made.append(Crypto.new().generate_rsa(2048)))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if made.is_empty():
		return false
	key = made[0]
	key.save(KEY_PATH)
	return true


func public_pem() -> String:
	return key.save_to_string(true) if key != null else ""


func sign_msg(msg: String) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(msg.to_utf8_buffer())
	return Marshalls.raw_to_base64(crypto.sign(HashingContext.HASH_SHA256, h.finish(), key))


# ---- saved per-account state (node id + last heartbeat number) ------------------
func _load_state() -> Dictionary:
	var all: Dictionary = M._read_json(STATE_PATH)
	return all.get(uid, {})


func _save_state() -> void:
	var all: Dictionary = M._read_json(STATE_PATH)
	all[uid] = {"node_id": node_id, "seq": seq}
	M._write_json(STATE_PATH, all)


# ---- session ---------------------------------------------------------------------
func start_session(player_uid: String) -> void:
	gen += 1
	var my_gen := gen
	uid = player_uid
	node_token = ""
	ready_state = "starting"
	if uid == "":
		ready_state = "error"
		return
	var ok: bool = await _ensure_key()
	if my_gen != gen:
		return
	if not ok:
		ready_state = "error"
		_say("Could not create a node key on this phone.", UI.RED)
		return
	var st := _load_state()
	node_id = str(st.get("node_id", ""))
	seq = int(st.get("seq", 0))
	if node_id == "":
		await _register()
		if my_gen != gen or node_id == "":
			return
	await _handshake(my_gen)


func _register() -> void:
	var r: Dictionary = await M.api.post("/node/register", {"pub": public_pem(), "label": OS.get_model_name(), "tz": int(Time.get_time_zone_from_system().get("bias", 0))})
	if not r.get("ok", false):
		ready_state = "error"
		_say("Node not registered: %s" % str(r.get("message", r.get("error", ""))), UI.RED)
		return
	node_id = str(r["node_id"])
	_save_state()


func _handshake(my_gen: int) -> void:
	var c: Dictionary = await M.api.post("/node/challenge", {"node_id": node_id})
	if my_gen != gen:
		return
	if not c.get("ok", false):
		var err := str(c.get("error", ""))
		if err == "unknown_node":
			node_id = ""
			await _register()
			if node_id != "" and my_gen == gen:
				await _handshake(my_gen)
			return
		ready_state = "removed" if err == "node_removed" else "error"
		_say("Node offline: %s" % str(c.get("message", err)), UI.AMBER)
		return
	var h: Dictionary = await M.api.post("/node/handshake", {"node_id": node_id, "nonce": c["nonce"], "sig": sign_msg(str(c["message"]))})
	if my_gen != gen:
		return
	if not h.get("ok", false):
		ready_state = "error"
		_say("Node handshake failed: %s" % str(h.get("message", "")), UI.RED)
		return
	node_token = str(h["node_token"])
	interval = float(h.get("interval", 30))
	policy = str(h.get("policy", "while_mining"))
	seq = maxi(seq, int(h.get("last_seq", 0)))
	ready_state = "ready"
	since_beat = interval - 3.0      # first heartbeat a few seconds after starting
	_say(_idle_text())


func stop() -> void:
	gen += 1
	active = false
	node_token = ""
	ready_state = "off"


func re_add() -> void:
	node_id = ""
	_save_state()
	start_session(uid)


func set_active(on: bool) -> void:
	active = on
	if on:
		since_beat = maxf(since_beat, interval - 3.0)
		if ready_state == "ready":
			_say(_idle_text())


func _idle_text() -> String:
	if policy == "off":
		return "Node connected (rewards are paused right now)."
	if policy == "while_mining":
		return "Node connected - this phone earns while you mine. %d / %d units today." % [units_today, daily_cap] if daily_cap > 0 else "Node connected - this phone earns while you mine."
	return "Node connected. %d units today." % units_today


# ---- heartbeats ---------------------------------------------------------------------
func _process(delta: float) -> void:
	if not active or ready_state != "ready" or sending:
		return
	since_beat += delta
	if since_beat >= interval:
		since_beat = 0.0
		_beat()


func _beat() -> void:
	sending = true
	var my_gen := gen
	seq += 1
	_save_state()
	var ts := int(Time.get_unix_time_from_system())
	var mining := is_mining()
	var msg := "pulse-heartbeat:%s:%d:%d:%d" % [node_id, seq, ts, 1 if mining else 0]
	var tz := int(Time.get_time_zone_from_system().get("bias", 0))
	var r: Dictionary = await M.api.post("/node/heartbeat", {"node_token": node_token, "seq": seq, "ts": ts, "mining": mining, "sig": sign_msg(msg), "tz": tz})
	sending = false
	if my_gen != gen:
		return
	if r.get("ok", false):
		units_today = int(r.get("units_today", 0))
		daily_cap = int(r.get("daily_cap", 0))
		pulsed.emit(bool(r.get("counted", false)))
		if r.get("counted", false):
			_say("NODE ONLINE  +1 unit  -  %d / %d today" % [units_today, daily_cap], UI.TEAL_L)
		else:
			_say("Node online - not earning: %s" % str(r.get("reason", "")), UI.MUTED)
		return
	var err := str(r.get("error", ""))
	if err == "node_session_expired":
		ready_state = "starting"
		await _handshake(my_gen)
	elif err == "replayed":
		seq += 50
		_save_state()
	elif err == "node_removed" or err == "unknown_node":
		ready_state = "removed"
		_say("This phone was removed as a node. Re-add it in Profile > Stats.", UI.AMBER)
	elif err == "clock":
		_say("Node paused: your phone's clock is wrong.", UI.RED)
	else:
		_say("Node: %s" % str(r.get("message", "connection problem")), UI.AMBER)
