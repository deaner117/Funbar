extends Node3D
## The jukebox in the lounge: a classic arched jukebox with bubble tubes up the sides and over
## the arch, a spinning record and tone arm behind glass, a chrome speaker grille, colour-cycling
## panels and lights that pulse with the beat. Point at a song on the selector and pull the
## trigger to play it.
##
## Music: real recordings bundled in res://music (Kevin MacLeod, incompetech.com, CC BY 4.0;
## see CREDITS.md), plus any MP3s you copy into the Quest's Music folder ("My music", which only
## plays on your own headset). Play/stop and the bundled song choice are shared, so everyone
## hears the same thing; outdoor speakers (add_speaker) play along.

const Kit := preload("res://kit.gd")
const Button3D := preload("res://button3d.gd")

## file (in res://music), title, style
const SONGS := [
	["Daily Beetle", "Daily Beetle", "50s rock and roll"],
	["Hep Cats", "Hep Cats", "swing"],
	["Funky Chunk", "Funky Chunk", "funk"],
	["Disco Medusae", "Disco Medusae", "disco"],
	["Werq", "Werq", "house"],
	["Night on the Docks - Sax", "Night on the Docks", "late-night sax"],
	["Blue Ska", "Blue Ska", "ska"],
	["Neon Laser Horizon", "Neon Laser Horizon", "synthwave"],
	["Hustle", "Hustle", "disco funk"],
	["Rollin at 5", "Rollin' at 5", "electro jazz"],
	["Local Forecast - Elevator", "Local Forecast", "lounge"],
	["Volatile Reaction", "Volatile Reaction", "rock"],
	["Hot Swing", "Hot Swing", "hot jazz"],
	["Vibe Ace", "Vibe Ace", "hip-hop groove"],
]
const MAX_LOCAL := 10

const TUBE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform float len = 1.6;
uniform vec4 col_a : source_color = vec4(1.0, 0.15, 0.25, 1.0);
uniform vec4 col_b : source_color = vec4(1.0, 0.7, 0.1, 1.0);
uniform float on = 1.0;
uniform float pulse = 0.0;
void fragment() {
	float s = UV.x * len;
	float wave = 0.5 + 0.5 * sin(s * 3.5 - TIME * 1.1);
	vec3 col = mix(col_a.rgb, col_b.rgb, wave);
	float b = 0.0;
	for (int i = 0; i < 4; i++) {
		float fi = float(i);
		float spacing = 0.07 + 0.025 * fi;
		float ss = mod(s - TIME * (0.09 + 0.04 * fi) * on - fi * 0.031, spacing) - spacing * 0.5;
		float da = (fract(UV.y - fi * 0.27 + 0.5) - 0.5) * 0.2;
		float r = length(vec2(ss, da));
		float rad = 0.006 + 0.0025 * fi;
		float ring = smoothstep(rad, rad * 0.75, r) * (1.0 - 0.7 * smoothstep(rad * 0.7, rad * 0.2, r));
		b = max(b, ring);
	}
	float f = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float bright = mix(0.3, 1.0, on) * (0.9 + pulse * 0.5);
	col = mix(col, vec3(1.0), b * 0.85 * on);
	col *= 0.55 + 0.45 * f;
	col += vec3(pow(f, 18.0) * 0.6);
	ALBEDO = col * bright;
}
"""

const GLOW_SHADER := """
shader_type spatial;
render_mode unshaded;
uniform float on = 1.0;
uniform float pulse = 0.0;
uniform float phase = 0.0;
void fragment() {
	float t = TIME * 0.35 + phase;
	vec3 c = 0.55 + 0.45 * cos(6.2831 * (vec3(0.0, 0.33, 0.67) + t + UV.y * 0.6));
	float lines = 0.85 + 0.15 * sin(UV.y * 90.0);
	ALBEDO = c * lines * mix(0.25, 1.0, on) * (0.85 + pulse * 0.6);
}
"""

var main: Node
var playing := false
var song := 0
## Songs in the Quest's Music folder: [title, path].
var local_songs: Array = []
var local_index := -1         # >= 0 while one of my own songs is playing
var remote_local := ""        # a friend's own song (we can't hear it), by title

var _player: AudioStreamPlayer3D
var _streams := {}
var _label: Label3D
var _play_button: Button3D
var _song_buttons: Array[Button3D] = []
var _local_buttons: Array[Button3D] = []
var _tube_mats: Array[ShaderMaterial] = []
var _glow_mats: Array[ShaderMaterial] = []
var _record: Node3D
var _arm: Node3D
var _light: OmniLight3D
var _t := 0.0
var _volume := -4.0
var _speakers: Array[AudioStreamPlayer3D] = []
var _speaker_labels: Array[Label3D] = []
var _spectrum: AudioEffectSpectrumAnalyzerInstance
var _peak := 0.001
var _pulse := 0.0
var _ended_at := -1.0


func _ready() -> void:
	_setup_bus()
	_build_body()
	_build_selector()
	_player = AudioStreamPlayer3D.new()
	_player.position = Vector3(0, 0.45, 0.3)
	_player.unit_size = 6.0
	_player.max_distance = 40.0
	_player.volume_db = _volume
	_player.bus = &"Music"
	_player.finished.connect(_on_finished)
	add_child(_player)
	_refresh()
	_scan_local.call_deferred()


func _setup_bus() -> void:
	var idx := AudioServer.get_bus_index("Music")
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, "Music")
		AudioServer.set_bus_send(idx, "Master")
		var sa := AudioEffectSpectrumAnalyzer.new()
		sa.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		AudioServer.add_bus_effect(idx, sa)
	_spectrum = AudioServer.get_bus_effect_instance(idx, 0) as AudioEffectSpectrumAnalyzerInstance


# ---------------------------------------------------------------- the cabinet

## A tube along a path with UV.x running along it (0..1) and UV.y round it, for the bubble shader.
static func _tube_mesh(path: PackedVector3Array, radius: float, sides := 12) -> ArrayMesh:
	var total := 0.0
	var cum := PackedFloat32Array([0.0])
	for k in range(1, path.size()):
		total += path[k].distance_to(path[k - 1])
		cum.append(total)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array = []
	for k in path.size():
		var d := (path[mini(k + 1, path.size() - 1)] - path[maxi(k - 1, 0)]).normalized()
		var n1 := Vector3(0, 0, 1)
		var n2 := d.cross(n1).normalized()
		var ring: Array = []
		for s in sides + 1:
			var a := TAU * s / sides
			var n := n1 * cos(a) + n2 * sin(a)
			ring.append([path[k] + n * radius, n, Vector2(cum[k] / total, float(s) / sides)])
		rings.append(ring)
	for k in path.size() - 1:
		for s in sides:
			var q: Array = [rings[k][s], rings[k + 1][s], rings[k + 1][s + 1], rings[k][s + 1]]
			for idx: int in [0, 1, 2, 0, 2, 3]:
				st.set_normal(q[idx][1])
				st.set_uv(q[idx][2])
				st.add_vertex(q[idx][0])
	return st.commit()


func _build_body() -> void:
	var walnut := Kit.tmat(Color("4a2614"), "grain", 3.0, 0.3)
	var walnut_dark := Kit.tmat(Color("2c160b"), "grain", 3.0, 0.35)
	var chrome := Kit.mat(Color(0.88, 0.89, 0.93), 0.12, 0.65)
	var black := Kit.mat(Color(0.03, 0.03, 0.035), 0.4)
	var cream := Kit.mat(Color(0.96, 0.9, 0.78), 0.4)
	var W := 0.98
	var D := 0.62
	var arch_c := Vector3(0, 1.25, 0)
	var arch_r := 0.45
	# Plinth with a chrome kick plate and four ball feet.
	Kit.add_rbox(self, Vector3(W + 0.04, 0.09, D + 0.04), Vector3(0, 0.07, 0), walnut_dark, 0.02, Kit.LAYER_FURNITURE)
	Kit.add_rbox(self, Vector3(W - 0.06, 0.05, 0.015), Vector3(0, 0.07, D / 2.0 + 0.022), chrome, 0.01)
	var brand := Kit.add_label(self, "W O R L D W I D E", 0.028, Vector3(0, 0.07, D / 2.0 + 0.031), 0.0, Color(0.55, 0.08, 0.08))
	brand.font_size = 48
	for sx: float in [-0.44, 0.44]:
		for sz: float in [-0.26, 0.26]:
			Kit.add_sphere(self, 0.03, Vector3(sx, 0.025, sz), chrome, 0, 10)
	# Body: a box with a half-round arch on top, in walnut.
	Kit.add_rbox(self, Vector3(W, 1.14, D), Vector3(0, 0.68, 0), walnut, 0.03, Kit.LAYER_FURNITURE)
	Kit.add_cylinder(self, arch_r + 0.04, D, arch_c, walnut, 0, -1.0, 40, Vector3(PI / 2, 0, 0))
	# Bubble tubes: up each side and over the arch, meeting at the top.
	var tube_r := 0.034
	var tz := D / 2.0 + 0.005
	for side: float in [-1.0, 1.0]:
		var path := PackedVector3Array()
		var x := side * (W / 2.0 - 0.05)
		path.append(Vector3(x, 0.16, tz))
		path.append(Vector3(x, arch_c.y, tz))
		var r := absf(x)
		for i in range(1, 21):
			var a := PI / 2.0 * float(i) / 20.0
			path.append(Vector3(side * r * cos(a), arch_c.y + r * sin(a), tz))
		var mi := MeshInstance3D.new()
		mi.mesh = _tube_mesh(path, tube_r)
		var m := ShaderMaterial.new()
		m.shader = _shader(TUBE_SHADER)
		var total := 0.0
		for k in range(1, path.size()):
			total += path[k].distance_to(path[k - 1])
		m.set_shader_parameter("len", total)
		if side < 0.0:
			m.set_shader_parameter("col_a", Color(1.0, 0.12, 0.2))
			m.set_shader_parameter("col_b", Color(1.0, 0.65, 0.08))
		else:
			m.set_shader_parameter("col_a", Color(0.1, 0.45, 1.0))
			m.set_shader_parameter("col_b", Color(0.2, 1.0, 0.55))
		mi.material_override = m
		add_child(mi)
		_tube_mats.append(m)
		# Chrome tube clips and an inner chrome bead along the arch.
		for y: float in [0.3, 0.75, 1.15]:
			Kit.add_cylinder(self, tube_r + 0.008, 0.02, Vector3(x, y, tz), chrome, 0, -1.0, 14)
		var bead := PackedVector3Array()
		var ri := r - 0.07
		bead.append(Vector3(side * ri, 1.03, tz - 0.01))
		for i in 21:
			var a := PI / 2.0 * float(i) / 20.0
			bead.append(Vector3(side * ri * cos(a), arch_c.y + ri * sin(a), tz - 0.01))
		var bm := MeshInstance3D.new()
		bm.mesh = Kit.tube_mesh([bead], 0.012, 8)
		bm.material_override = chrome
		add_child(bm)
	# Crown: a chrome crest at the top of the arch.
	Kit.add_lathe(self, PackedVector2Array([Vector2(0, 0.08), Vector2(0.025, 0.07), Vector2(0.05, 0.03), Vector2(0.06, 0.0),
		Vector2(0, 0.0)]), arch_c + Vector3(0, arch_r + 0.02, D / 2.0 - 0.05), chrome, 16)
	# The record dome: a dark backing under the arch, a 45 spinning on a chrome platter with a
	# tone arm, all under a bulging glass dome with a chrome ring.
	var win_c := Vector3(0, 1.3, D / 2.0 + 0.003)
	Kit.add_cylinder(self, 0.29, 0.006, win_c, black, 0, -1.0, 32, Vector3(PI / 2, 0, 0))
	Kit.omni(self, win_c + Vector3(0, 0.12, 0.12), Color(1.0, 0.85, 0.6), 0.3, 0.6)
	var tt := Node3D.new()
	tt.position = Vector3(0, 1.28, D / 2.0 + 0.15)
	tt.rotation.x = 0.9
	add_child(tt)
	Kit.add_cylinder(tt, 0.112, 0.016, Vector3(0, -0.01, 0), chrome, 0, -1.0, 32)
	_record = Node3D.new()
	tt.add_child(_record)
	Kit.add_cylinder(_record, 0.1, 0.004, Vector3.ZERO, Kit.mat(Color(0.02, 0.02, 0.025), 0.25, 0.3), 0, -1.0, 40)
	for rr: float in [0.055, 0.072, 0.088]:
		Kit.add_cylinder(_record, rr, 0.0045, Vector3.ZERO, Kit.mat(Color(0.06, 0.06, 0.07), 0.15, 0.4), 0, rr - 0.0015, 40)
	Kit.add_cylinder(_record, 0.035, 0.005, Vector3.ZERO, Kit.mat(Color(0.85, 0.12, 0.12), 0.5), 0, -1.0, 24)
	Kit.add_cylinder(_record, 0.008, 0.0055, Vector3(0.02, 0, 0), cream, 0, -1.0, 8)
	Kit.add_cylinder(_record, 0.003, 0.02, Vector3.ZERO, chrome, 0, -1.0, 8)
	_arm = Node3D.new()
	_arm.position = Vector3(0.13, 0.008, -0.08)
	tt.add_child(_arm)
	Kit.add_cylinder(_arm, 0.014, 0.022, Vector3.ZERO, chrome, 0, -1.0, 12)
	var arm_mesh := MeshInstance3D.new()
	arm_mesh.mesh = Kit.tube_mesh([PackedVector3Array([Vector3(0, 0.014, 0), Vector3(-0.025, 0.018, 0.05), Vector3(-0.055, 0.014, 0.11)])], 0.004, 8)
	arm_mesh.material_override = chrome
	_arm.add_child(arm_mesh)
	Kit.add_box(_arm, Vector3(0.018, 0.009, 0.028), Vector3(-0.058, 0.011, 0.125), black)
	var dome := MeshInstance3D.new()
	dome.mesh = Kit.sphere_mesh(0.285, 32)
	dome.scale = Vector3(1, 1, 0.9)
	dome.position = win_c
	dome.material_override = Kit.mat(Color(0.8, 0.88, 1.0, 0.1), 0.04, 0.0)
	add_child(dome)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.28
	tm.outer_radius = 0.305
	tm.rings = 40
	tm.ring_segments = 8
	ring.mesh = tm
	ring.rotation.x = PI / 2
	ring.position = win_c + Vector3(0, 0, 0.005)
	ring.material_override = chrome
	add_child(ring)
	# Colour-cycling glass panels beside the grille.
	for side: float in [-1.0, 1.0]:
		_glow_panel(Vector3(0.08, 0.35, 0.01), Vector3(side * 0.35, 0.325, D / 2.0 + 0.006), side)
	# Speaker grille: fabric behind vertical chrome bars, with a chrome diamond emblem.
	Kit.add_box(self, Vector3(0.56, 0.35, 0.01), Vector3(0, 0.325, D / 2.0 + 0.004), Kit.tmat(Color(0.25, 0.1, 0.08), "fabric", 25.0, 0.95))
	for i in 11:
		var x := -0.25 + i * 0.05
		Kit.add_cylinder(self, 0.006, 0.35, Vector3(x, 0.325, D / 2.0 + 0.012), chrome, 0, -1.0, 8)
	Kit.add_rbox(self, Vector3(0.6, 0.025, 0.03), Vector3(0, 0.51, D / 2.0 + 0.012), chrome, 0.01)
	Kit.add_rbox(self, Vector3(0.6, 0.025, 0.03), Vector3(0, 0.14, D / 2.0 + 0.012), chrome, 0.01)
	Kit.add_rbox(self, Vector3(0.11, 0.11, 0.02), Vector3(0, 0.325, D / 2.0 + 0.02), chrome, 0.015, 0, Vector3(0, 0, PI / 4))
	Kit.add_rbox(self, Vector3(0.07, 0.07, 0.022), Vector3(0, 0.325, D / 2.0 + 0.024), Kit.mat(Color(0.75, 0.1, 0.12), 0.3), 0.01, 0, Vector3(0, 0, PI / 4))
	# A coloured light washing the floor and wall, pulsing with the music.
	_light = Kit.omni(self, Vector3(0, 0.9, 0.8), Color(1.0, 0.5, 0.3), 0.0, 4.0)


func _glow_panel(size: Vector3, pos: Vector3, phase: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := ShaderMaterial.new()
	m.shader = _shader(GLOW_SHADER)
	m.set_shader_parameter("phase", phase)
	mi.material_override = m
	mi.position = pos
	add_child(mi)
	_glow_mats.append(m)
	return mi


static var _shaders := {}


static func _shader(code: String) -> Shader:
	if not _shaders.has(code):
		var s := Shader.new()
		s.code = code
		_shaders[code] = s
	return _shaders[code]


## The title strip: one button per song in two columns, the now-playing line and the controls.
func _build_selector() -> void:
	var D := 0.62
	# One title-strip panel, leaning back: now playing, the songs, the controls and the credit.
	var panel := Node3D.new()
	panel.position = Vector3(0, 0.78, D / 2.0 + 0.115)
	panel.rotation.x = -0.45
	add_child(panel)
	Kit.add_rbox(panel, Vector3(0.86, 0.5, 0.05), Vector3(0, 0, -0.03), Kit.mat(Color(0.88, 0.89, 0.93), 0.12, 0.65), 0.015)
	Kit.add_box(panel, Vector3(0.82, 0.46, 0.01), Vector3(0, 0, 0.0), Kit.mat(Color(0.97, 0.94, 0.86), 0.6))
	Kit.add_box(panel, Vector3(0.82, 0.05, 0.012), Vector3(0, 0.205, 0.0), Kit.mat(Color(0.12, 0.08, 0.08), 0.5))
	_label = Kit.add_label(panel, "", 0.024, Vector3(0, 0.205, 0.008), 0.0, Color(1, 0.85, 0.5))
	var rows := ceili(SONGS.size() / 2.0)
	for i in SONGS.size():
		var col := i / rows
		var row := i % rows
		var b := Button3D.new("%s  ·  %s" % [SONGS[i][1], SONGS[i][2]], Vector2(0.39, 0.036), Color(0.55, 0.12, 0.12), _on_song.bind(i))
		b.position = Vector3(-0.2 + col * 0.4, 0.155 - row * 0.041, 0.008)
		panel.add_child(b)
		_song_buttons.append(b)
	var btns := [["Play", Color(0.2, 0.5, 0.3), _on_play], ["Next", Color(0.3, 0.3, 0.5), _on_next],
		["Vol -", Color(0.3, 0.3, 0.35), _on_volume.bind(-3.0)], ["Vol +", Color(0.3, 0.3, 0.35), _on_volume.bind(3.0)],
		["My music", Color(0.45, 0.25, 0.5), _on_my_music]]
	for i in btns.size():
		var b := Button3D.new(btns[i][0], Vector2(0.15, 0.048), btns[i][1], btns[i][2])
		b.position = Vector3(-0.32 + i * 0.16, -0.155, 0.008)
		panel.add_child(b)
		if i == 0:
			_play_button = b
	var credit := Kit.add_label(panel, "Music: Kevin MacLeod (incompetech.com), licensed CC BY 4.0", 0.014, Vector3(0, -0.212, 0.006), 0.0,
		Color(0.35, 0.25, 0.2))
	credit.font_size = 32


# ---------------------------------------------------------------- playing

func _stream(i: int) -> AudioStream:
	if not _streams.has(i):
		var s: AudioStream = load("res://music/%s.mp3" % SONGS[i][0])
		if s is AudioStreamMP3:
			(s as AudioStreamMP3).loop = false
		_streams[i] = s
	return _streams[i]


func _on_song(i: int) -> void:
	set_state(true, i)
	main.send({"t": "jb_s", "on": true, "song": song})


func _on_play() -> void:
	if local_index >= 0:
		local_index = -1
		set_state(false, song)
	else:
		set_state(not playing, song)
	main.send({"t": "jb_s", "on": playing, "song": song})


func _on_next() -> void:
	set_state(true, (song + 1) % SONGS.size())
	main.send({"t": "jb_s", "on": playing, "song": song})


func _on_volume(db: float) -> void:
	_volume = clampf(_volume + db, -24.0, 6.0)
	_player.volume_db = _volume
	for sp in _speakers:
		sp.volume_db = _volume + 1.0
	if main:
		main.notify("Music volume %+d dB" % roundi(_volume + 4.0))


## Plays the bundled song `s` (or stops), from `from_s` seconds in.
func set_state(on: bool, s: int, from_s := 0.0) -> void:
	var changed := s != song or local_index >= 0 or remote_local != ""
	local_index = -1
	remote_local = ""
	playing = on
	song = clampi(s, 0, SONGS.size() - 1)
	if not playing:
		_stop_all()
	elif changed or not _player.playing:
		_play_all(_stream(song), from_s)
	_refresh()


func _play_all(stream: AudioStream, from_s := 0.0) -> void:
	_player.stream = stream
	_player.play(from_s)
	for sp in _speakers:
		sp.stream = stream
		sp.play(from_s)


func _stop_all() -> void:
	_player.stop()
	for sp in _speakers:
		sp.stop()


## A song ended: the host moves everyone on to the next one.
func _on_finished() -> void:
	if not playing or local_index >= 0:
		if local_index >= 0:
			_play_local((local_index + 1) % local_songs.size())
		return
	if main.is_host():
		_on_next()


# ---------------------------------------------------------------- my own music

## Looks for MP3s in the Quest's Music folder (Android asks once for permission).
func _scan_local() -> void:
	if OS.get_name() == "Android":
		var perm := "android.permission.READ_MEDIA_AUDIO"
		if not perm in OS.get_granted_permissions() and not "android.permission.READ_EXTERNAL_STORAGE" in OS.get_granted_permissions():
			get_tree().on_request_permissions_result.connect(func(p: String, granted: bool) -> void:
				if granted and (p.ends_with("READ_MEDIA_AUDIO") or p.ends_with("READ_EXTERNAL_STORAGE")):
					_read_local_folder())
			OS.request_permission(perm)
			return
	_read_local_folder()


func _read_local_folder() -> void:
	local_songs.clear()
	var dirs := [OS.get_system_dir(OS.SYSTEM_DIR_MUSIC), OS.get_user_data_dir() + "/music"]
	for d: String in dirs:
		if d == "" or not DirAccess.dir_exists_absolute(d):
			continue
		for f: String in DirAccess.get_files_at(d):
			if f.get_extension().to_lower() == "mp3" and local_songs.size() < 40:
				local_songs.append([f.get_basename(), d.path_join(f)])
	print("Jukebox: %d songs in my music folder" % local_songs.size())


func _on_my_music() -> void:
	if local_songs.is_empty():
		_read_local_folder()
	if local_songs.is_empty():
		main.notify("Copy MP3s into the Quest's Music folder to play your own songs here")
		return
	_play_local((local_index + 1) % local_songs.size())


func _play_local(i: int) -> void:
	var path: String = local_songs[i][1]
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		main.notify("Couldn't read %s" % path.get_file())
		return
	var s := AudioStreamMP3.new()
	s.data = bytes
	local_index = i
	playing = true
	_play_all(s)
	main.send({"t": "jb_l", "title": local_songs[i][0]})
	_refresh()


# ---------------------------------------------------------------- display

func _refresh() -> void:
	var text := "Pick a song"
	if local_index >= 0:
		text = "My music: %s   (only you can hear this)" % local_songs[local_index][0]
	elif remote_local != "":
		text = "A friend is playing their own music: %s" % remote_local
	elif playing:
		text = "Now playing:  %s  (%s)" % [SONGS[song][1], SONGS[song][2]]
	_label.text = text
	_play_button.set_text("Stop" if playing or local_index >= 0 else "Play")
	for i in _song_buttons.size():
		_song_buttons[i].active = playing and local_index < 0 and remote_local == "" and i == song
	for l in _speaker_labels:
		l.text = text if playing else "Outdoor speaker"


func _process(delta: float) -> void:
	_t += delta
	var on := 1.0 if (playing or local_index >= 0) else 0.0
	# Beat: bass energy from the music bus, normalised by a slowly falling peak.
	var level := 0.0
	if _spectrum and on > 0.0:
		var m := _spectrum.get_magnitude_for_frequency_range(40.0, 160.0).length()
		_peak = maxf(_peak * (1.0 - delta * 0.25), m)
		level = clampf(m / maxf(_peak, 0.0001), 0.0, 1.0)
	_pulse = maxf(level, _pulse - delta * 4.0)
	for m in _tube_mats:
		m.set_shader_parameter("on", on)
		m.set_shader_parameter("pulse", _pulse)
	for m in _glow_mats:
		m.set_shader_parameter("on", on)
		m.set_shader_parameter("pulse", _pulse)
	var hue := fmod(_t * 0.05, 1.0)
	_light.light_color = Color.from_hsv(hue, 0.6, 1.0)
	_light.light_energy = on * (0.35 + 0.5 * _pulse)
	if on > 0.0:
		_record.rotation.y -= delta * TAU * 0.75
	_arm.rotation.y = lerpf(_arm.rotation.y, -0.45 * on, 1.0 - exp(-3.0 * delta))


# ---------------------------------------------------------------- outdoor speakers

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
	for i in 3:
		var a := TAU * i / 3.0
		var foot := Vector3(sin(a) * 0.38, 0.0, cos(a) * 0.38)
		var leg := MeshInstance3D.new()
		leg.mesh = Kit.tube_mesh([PackedVector3Array([foot, Vector3(0, 0.55, 0)])], 0.012, 6)
		leg.material_override = metal
		leg.layers = Kit.vis_layers
		p.add_child(leg)
	Kit.add_cylinder(p, 0.018, 0.75, Vector3(0, 0.82, 0), metal, 0, -1.0, 8)
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
	sp.volume_db = _volume + 1.0
	sp.bus = &"Music"
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


# ---------------------------------------------------------------- network

func handle(msg: Dictionary, _from: int) -> void:
	match str(msg.get("t", "")):
		"jb_s":
			set_state(bool(msg.get("on", false)), int(msg.get("song", 0)))
		"jb_full":
			set_state(bool(msg.get("on", false)), int(msg.get("song", 0)), float(msg.get("pos", 0.0)))
		"jb_l":
			# A friend plays a song only they have: stop ours and say what they're playing.
			if local_index < 0:
				playing = false
				_stop_all()
				remote_local = str(msg.get("title", "a song"))
				_refresh()


func full_state() -> Dictionary:
	var pos := _player.get_playback_position() + AudioServer.get_time_since_last_mix() if _player.playing else 0.0
	return {"t": "jb_full", "on": playing and local_index < 0, "song": song, "pos": snappedf(pos, 0.01)}


func on_identity_changed(_old_id: int, _new_id: int) -> void:
	pass


func on_peer_left(_slot: int) -> void:
	pass
