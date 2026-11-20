extends Node
# Music and ambience. One music track and one ambience loop per area, cross-faded
# when you travel. Music and ambience each have their own on/off setting.

const TRACKS := {
	"town": ["music_town", "amb_town"], "mine": ["music_mine", "amb_cave"], "arena": ["music_arena", "amb_town"],
	"lake": ["music_mine", "amb_lake"], "cabin": ["music_town", "amb_tavern"], "tavern": ["music_town", "amb_tavern"],
	"boss": ["music_boss", "amb_town"],
}
const MUSIC_DB := -14.0
const AMB_DB := -10.0

var M
var music: Array = []     # two players for cross-fading
var amb: Array = []
var cur := 0
var cur_amb := 0
var music_name := ""
var amb_name := ""
var streams := {}


func setup(m) -> void:
	M = m
	for i in range(2):
		var p := AudioStreamPlayer.new()
		p.volume_db = -60.0
		add_child(p)
		music.append(p)
		var a := AudioStreamPlayer.new()
		a.volume_db = -60.0
		add_child(a)
		amb.append(a)
	set_area("town")


func _stream(name: String) -> AudioStream:
	if not streams.has(name):
		var s = load("res://sounds/%s.ogg" % name)
		if s is AudioStreamOggVorbis:
			s.loop = true
		streams[name] = s
	return streams[name]


func set_area(area: String) -> void:
	var t: Array = TRACKS.get(area, TRACKS["town"])
	_switch(music, true, str(t[0]), MUSIC_DB if M.settings.get("music", true) else -80.0)
	_switch(amb, false, str(t[1]), AMB_DB if M.settings.get("ambience", true) else -80.0)


func _switch(pair: Array, is_music: bool, name: String, target_db: float) -> void:
	var playing_name := music_name if is_music else amb_name
	var idx := cur if is_music else cur_amb
	if name == playing_name:
		var tw0 := create_tween()
		tw0.tween_property(pair[idx], "volume_db", target_db, 0.5)
		return
	var old: AudioStreamPlayer = pair[idx]
	var nxt: AudioStreamPlayer = pair[1 - idx]
	nxt.stream = _stream(name)
	nxt.volume_db = -50.0
	nxt.play()
	var tw := create_tween()
	tw.tween_property(nxt, "volume_db", target_db, 1.6)
	tw.parallel().tween_property(old, "volume_db", -60.0, 1.6)
	tw.tween_callback(old.stop)
	if is_music:
		music_name = name
		cur = 1 - idx
	else:
		amb_name = name
		cur_amb = 1 - idx


# The tavern jukebox: play the next tune (until you leave the area).
const SONGS := [["music_town", "Market Morning"], ["music_mine", "Down the Deep Veins"], ["music_arena", "Steel and Sand"],
	["music_boss", "The Square Holds"]]
var juke := -1

func jukebox() -> String:
	juke = (juke + 1) % SONGS.size()
	_switch(music, true, SONGS[juke][0], MUSIC_DB if M.settings.get("music", true) else -80.0)
	return SONGS[juke][1]


func refresh() -> void:
	var area: String = "town"
	if M.world != null:
		area = M.world.area
	music_name = ""
	amb_name = ""
	set_area(area)
