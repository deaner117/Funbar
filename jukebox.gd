extends Node3D
## A jukebox in the lounge. Its songs are synthesized when first played (chords, bass, a plucked
## arpeggio and soft hats), on a worker thread so nothing stutters. Play/stop and the song
## choice are shared, so everyone in the room hears the same thing.

const Kit := preload("res://kit.gd")
const Button3D := preload("res://button3d.gd")

const RATE := 22050
## name, bpm, chords (MIDI notes, root first), swing
const SONGS := [
	["Lo-fi Lounge", 78.0, [[48, 64, 67, 71], [45, 64, 67, 72], [50, 65, 69, 72], [43, 65, 67, 71]], 0.12],
	["Sunset Drive", 96.0, [[45, 64, 69, 72], [41, 65, 69, 72], [48, 64, 67, 72], [43, 62, 67, 71]], 0.0],
	["Fireside", 66.0, [[50, 64, 65, 69], [46, 62, 65, 69], [41, 64, 69, 72], [48, 64, 67, 72]], 0.08],
]

var main: Node
var playing := false
var song := 0

var _player: AudioStreamPlayer3D
var _streams := {}
var _rendering := {}
var _label: Label3D
var _play_button: Button3D
var _lights: Array[MeshInstance3D] = []
var _light_colors: Array[Color] = []
var _t := 0.0
var _speakers: Array[AudioStreamPlayer3D] = []
var _speaker_labels: Array[Label3D] = []


func _ready() -> void:
	var wood := Kit.mat(Color("5a2d18"), 0.4)
	Kit.add_box(self, Vector3(0.9, 1.3, 0.5), Vector3(0, 0.65, 0), wood, Kit.LAYER_FURNITURE)
	Kit.add_cylinder(self, 0.45, 0.5, Vector3(0, 1.3, 0), wood, 0, -1.0, 24, Vector3(PI / 2, 0, 0))
	Kit.add_box(self, Vector3(0.7, 0.35, 0.02), Vector3(0, 0.95, 0.26), Kit.flat(Color(0.1, 0.08, 0.12)))
	var colors := [Color(1.0, 0.3, 0.4), Color(1.0, 0.75, 0.2), Color(0.3, 0.8, 1.0), Color(0.5, 1.0, 0.5)]
	for i in 4:
		var m := MeshInstance3D.new()
		m.mesh = Kit.box_mesh(Vector3(0.05, 0.9, 0.03))
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = colors[i]
		m.material_override = mat
		var xs := [-0.42, -0.36, 0.36, 0.42]
		m.position = Vector3(xs[i], 0.65, 0.24)
		add_child(m)
		_lights.append(m)
		_light_colors.append(colors[i])
	_label = Kit.add_label(self, "", 0.045, Vector3(0, 0.95, 0.275), 0.0, Color(1, 0.9, 0.6))
	_play_button = Button3D.new("Play", Vector2(0.2, 0.07), Color(0.2, 0.5, 0.3), _on_play)
	_play_button.position = Vector3(-0.12, 0.62, 0.27)
	_play_button.rotation.x = -0.3
	add_child(_play_button)
	var next := Button3D.new("Next song", Vector2(0.2, 0.07), Color(0.3, 0.3, 0.5), _on_next)
	next.position = Vector3(0.12, 0.62, 0.27)
	next.rotation.x = -0.3
	add_child(next)
	Kit.add_label(self, "JUKEBOX", 0.07, Vector3(0, 1.62, 0.05), 0.0, Color(1, 0.85, 0.5))
	_player = AudioStreamPlayer3D.new()
	_player.position = Vector3(0, 1.0, 0.2)
	_player.unit_size = 5.0
	_player.max_distance = 35.0
	_player.volume_db = -4.0
	add_child(_player)
	_refresh()
	# Have the first song ready before anyone presses Play.
	get_tree().create_timer(4.0).timeout.connect(_render_async.bind(0))


func _on_play() -> void:
	set_state(not playing, song)
	main.send({"t": "jb_s", "on": playing, "song": song})


func _on_next() -> void:
	set_state(true, (song + 1) % SONGS.size())
	main.send({"t": "jb_s", "on": playing, "song": song})


func set_state(on: bool, s: int) -> void:
	var changed := s != song
	playing = on
	song = clampi(s, 0, SONGS.size() - 1)
	if not playing:
		_stop_all()
	elif _streams.has(song):
		if changed or not _player.playing:
			_play_all(_streams[song])
	else:
		_stop_all()
		_render_async(song)
	_refresh()


func _play_all(stream: AudioStream) -> void:
	_player.stream = stream
	_player.play()
	for sp in _speakers:
		sp.stream = stream
		sp.play()


func _stop_all() -> void:
	_player.stop()
	for sp in _speakers:
		sp.stop()


## An outdoor speaker on a stand that plays whatever the jukebox plays, with its own
## Play/Next buttons. pos/yaw in world space, +z of the speaker faces its listeners.
func add_speaker(pos: Vector3, yaw: float) -> void:
	var p := Node3D.new()
	p.top_level = true
	add_child(p)
	p.global_transform = Transform3D(Basis(Vector3.UP, yaw), pos)
	var black := Kit.mat(Color(0.06, 0.06, 0.07), 0.6)
	var grey := Kit.mat(Color(0.18, 0.18, 0.2), 0.8)
	var metal := Kit.mat(Color(0.3, 0.3, 0.32), 0.4, 0.8)
	var before := Kit.vis_layers
	Kit.vis_layers = Kit.VIS_OUTDOOR
	# Tripod stand and pole.
	for i in 3:
		var a := TAU * i / 3.0
		var foot := Vector3(sin(a) * 0.38, 0.0, cos(a) * 0.38)
		var top := Vector3(0, 0.55, 0)
		var leg := MeshInstance3D.new()
		leg.mesh = Kit.tube_mesh([PackedVector3Array([foot, top])], 0.012, 6)
		leg.material_override = metal
		leg.layers = Kit.vis_layers
		p.add_child(leg)
	Kit.add_cylinder(p, 0.018, 0.75, Vector3(0, 0.82, 0), metal, 0, -1.0, 8)
	# Cabinet with two drivers and a power light.
	Kit.add_rbox(p, Vector3(0.36, 0.56, 0.3), Vector3(0, 1.45, 0), black, 0.03, Kit.LAYER_FURNITURE)
	Kit.add_rbox(p, Vector3(0.32, 0.5, 0.01), Vector3(0, 1.45, 0.151), Kit.tmat(Color(0.2, 0.2, 0.22), "fabric", 30.0, 0.95), 0.004)
	for c: Array in [[Vector3(0, 1.34, 0.158), 0.11], [Vector3(0, 1.6, 0.158), 0.05]]:
		Kit.add_cylinder(p, c[1], 0.012, c[0], grey, 0, float(c[1]) * 0.8, 20, Vector3(PI / 2, 0, 0))
		Kit.add_sphere(p, float(c[1]) * 0.3, c[0] + Vector3(0, 0, 0.004), black, 0, 10)
	Kit.add_sphere(p, 0.008, Vector3(0.13, 1.7, 0.155), Kit.flat(Color(0.3, 0.7, 1.0)), 0, 6)
	Kit.vis_layers = before
	var sp := AudioStreamPlayer3D.new()
	sp.position = Vector3(0, 1.45, 0.15)
	sp.unit_size = 6.0
	sp.max_distance = 45.0
	sp.volume_db = -3.0
	p.add_child(sp)
	_speakers.append(sp)
	var play := Button3D.new("Play / Stop", Vector2(0.2, 0.06), Color(0.2, 0.5, 0.3), _on_play)
	play.position = Vector3(-0.11, 1.08, 0.04)
	play.rotation.x = -0.5
	p.add_child(play)
	var next := Button3D.new("Next song", Vector2(0.2, 0.06), Color(0.3, 0.3, 0.5), _on_next)
	next.position = Vector3(0.11, 1.08, 0.04)
	next.rotation.x = -0.5
	p.add_child(next)
	_speaker_labels.append(Kit.add_label(p, "", 0.035, Vector3(0, 1.8, 0.0), 0.0, Color(1, 0.9, 0.6)))
	_refresh()


func _refresh() -> void:
	var title: String = SONGS[song][0]
	if playing and not _streams.has(song):
		_label.text = "Tuning up: %s..." % title
	elif playing:
		_label.text = "Now playing: %s" % title
	else:
		_label.text = "Press Play"
	_play_button.set_text("Stop" if playing else "Play")
	for l in _speaker_labels:
		l.text = _label.text if playing else "Outdoor speaker"


func _render_async(s: int) -> void:
	if _rendering.has(s):
		return
	_rendering[s] = WorkerThreadPool.add_task(func() -> void:
		var stream := render(s)
		_finished.call_deferred(s, stream))


func _exit_tree() -> void:
	# Quitting with a render still running hangs on exit, so wait for it.
	for s: int in _rendering:
		WorkerThreadPool.wait_for_task_completion(_rendering[s])
	_rendering.clear()


func _finished(s: int, stream: AudioStreamWAV) -> void:
	_rendering.erase(s)
	_streams[s] = stream
	if playing and song == s:
		_play_all(stream)
	_refresh()


func _process(delta: float) -> void:
	_t += delta
	for i in _lights.size():
		var mat: StandardMaterial3D = _lights[i].material_override
		var k := 0.55 + 0.45 * sin(_t * (2.0 + i) + i) if playing else 0.3
		var c: Color = _light_colors[i]
		mat.albedo_color = Color(c.r * k, c.g * k, c.b * k, 1.0)


func handle(msg: Dictionary, _from: int) -> void:
	if str(msg.get("t", "")) in ["jb_s", "jb_full"]:
		set_state(bool(msg.get("on", false)), int(msg.get("song", 0)))


func full_state() -> Dictionary:
	return {"t": "jb_full", "on": playing, "song": song}


func on_identity_changed(_old_id: int, _new_id: int) -> void:
	pass


func on_peer_left(_slot: int) -> void:
	pass


static func _midi(n: float) -> float:
	return 440.0 * pow(2.0, (n - 69.0) / 12.0)


## Renders one song (8 bars, looping) to a 16-bit mono WAV stream.
static func render(s: int) -> AudioStreamWAV:
	var info: Array = SONGS[s]
	var bpm: float = info[1]
	var chords: Array = info[2]
	var swing: float = info[3]
	var beat := 60.0 / bpm
	var bars := 8
	var total := int(bars * 4 * beat * RATE)
	var data := PackedByteArray()
	data.resize(total * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234 + s
	var lp := 0.0   # low-pass state for the hats
	for i in total:
		var t := float(i) / RATE
		var beat_pos := t / beat
		var bar := int(beat_pos / 4.0)
		var chord: Array = chords[(bar / 2) % chords.size()]
		var in_bar := fmod(beat_pos, 8.0)
		# Pad: chord tones (no root), slow swell each two bars.
		var swell := minf(in_bar / 1.5, 1.0) * (0.7 + 0.3 * sin(t * 0.7))
		var pad := 0.0
		for k in range(1, chord.size()):
			var f := _midi(float(chord[k]))
			pad += sin(TAU * f * t) + 0.3 * sin(TAU * f * 2.003 * t)
		pad *= 0.045 * swell
		# Bass: root on each beat, decaying.
		var bt := fmod(beat_pos, 1.0) * beat
		var bf := _midi(float(chord[0]))
		var bass := 0.22 * sin(TAU * bf * t) * exp(-bt * 3.0) * minf(bt * 200.0, 1.0)
		# Arpeggio: eighth notes up the chord, with swing.
		var eighth := beat_pos * 2.0
		var e_idx := int(eighth)
		var e_frac := fmod(eighth, 1.0)
		var offset := swing if (e_idx % 2) == 1 else 0.0
		var et := (e_frac - offset) * beat / 2.0
		var arp := 0.0
		if et >= 0.0:
			var note: int = chord[1 + (e_idx % (chord.size() - 1))] + (12 if (e_idx / 4) % 2 == 1 else 0)
			var af := _midi(float(note))
			arp = 0.08 * (sin(TAU * af * t) + 0.25 * sin(TAU * af * 3.0 * t)) * exp(-et * 6.0)
		# Hats on the off-beats: filtered noise bursts.
		var ht := fmod(beat_pos + 0.5, 1.0) * beat
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.6
		var hat := (rng.randf_range(-1.0, 1.0) - lp) * 0.05 * exp(-ht * 40.0)
		var v := clampf(pad + bass + arp + hat, -1.0, 1.0)
		data.encode_s16(i * 2, int(v * 30000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = total
	return w
