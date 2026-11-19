extends SceneTree
# Plays Rune Sequence through the real app code against a local server, tapping the right runes.
var M
func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	M = scene.instantiate()
	root.add_child(M)
	_run()

func _run() -> void:
	await create_timer(3.0).timeout
	var r: Dictionary = await M.api.post("/auth/register", {"username": "seq%d" % (randi() % 99999), "password": "secret123"})
	M._on_logged_in(r["token"], r["profile"])
	await create_timer(1.0).timeout
	var st: Dictionary = await M.api.post("/practice/start", {"game": "sequence"})
	print("RUNES SENT ", st["challenge"]["runes"].size(), " interactive=", st["challenge"].get("interactive"))
	var SG = load("res://scripts/games/skill_game.gd")
	var sg = SG.new()
	sg.cid = st["id"]
	root.add_child(sg)
	sg.run(M, st["challenge"], "TEST")
	var target := 6
	var pressed := 0
	var done := false
	sg.finished.connect(func(res):
		print("RESULT ", res)
		var s: Dictionary = await M.api.post("/practice/submit", {"id": st["id"], "result": res})
		print("SERVER SCORE ", s.get("score"), " ", s.get("detail"))
		quit())
	var idx := 0
	var round_n := 3
	while true:
		await process_frame
		if sg.accept_input and not sg.tap_flag:
			await create_timer(0.3).timeout
			var runes: Array = sg.seq_runes
			if idx < runes.size():
				var want := int(runes[idx]) if round_n <= target else (int(runes[idx]) + 1) % 4
				sg.tap_index = want
				sg.tap_flag = true
				idx += 1
				if idx >= round_n:
					idx = 0
					round_n += 1
