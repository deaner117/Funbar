extends Node3D
## Gym extras: a big LED scoreboard on the north wall that you run yourselves from a scorer's
## table on the sideline (HOME / GUEST points, a game clock with a buzzer, periods), and a
## gravity control panel on the south wall that changes gravity for the basketballs (Earth,
## Mars, Moon, Space, Jupiter). Low gravity makes long shots easy.
## Anyone can press the buttons; every change is broadcast ("gy_" messages) and the clock runs
## locally on each headset from the last start/stop message.

const Kit := preload("res://kit.gd")
const Button3D := preload("res://button3d.gd")

const PLANETS := [
	# name, m/s^2, planet colour, ring?
	["EARTH", 9.81, Color(0.25, 0.5, 0.95), false],
	["MARS", 3.71, Color(0.85, 0.38, 0.18), false],
	["MOON", 1.62, Color(0.75, 0.75, 0.72), false],
	["SPACE", 0.0, Color(0.1, 0.1, 0.2), false],
	["JUPITER", 24.8, Color(0.85, 0.65, 0.45), true],
]
const CLOCK_START := 300.0
const LED := Color(1.0, 0.55, 0.12)

var main: Node
var home := 0
var guest := 0
var period := 1
var clock := CLOCK_START
var running := false
var planet := 0

var _home_l: Label3D
var _guest_l: Label3D
var _clock_l: Label3D
var _period_l: Label3D
var _readout: Label3D
var _planet_node: Node3D
var _planet_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _planet_buttons: Array[Button3D] = []
var _start_button: Button3D
var _buzzer: AudioStreamPlayer3D
var _beep: AudioStreamPlayer3D
var _t := 0.0
var _flash := 0.0


func setup(board_anchor: Array, table_anchor: Array, panel_anchor: Array) -> void:
	_build_board(_pivot(board_anchor))
	_build_table(_pivot(table_anchor))
	_build_panel(_pivot(panel_anchor))
	_refresh()
	_apply_gravity()


func _pivot(a: Array) -> Node3D:
	var n := Node3D.new()
	n.position = a[0]
	n.rotation.y = a[1]
	add_child(n)
	return n


# ---------------------------------------------------------------- scoreboard

func _digits(parent: Node3D, pos: Vector3, h: float, ghost: String) -> Label3D:
	# Unlit "88" behind the live digits, like a real LED board.
	var g := Kit.add_label(parent, ghost, h, pos, 0.0, Color(0.13, 0.05, 0.02))
	g.font_size = 96
	g.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	g.pixel_size = h / 96.0
	var l := Kit.add_label(parent, ghost, h, pos + Vector3(0, 0, 0.004), 0.0, LED)
	l.font_size = 96
	l.pixel_size = h / 96.0
	l.outline_size = 18
	l.outline_modulate = Color(1.0, 0.35, 0.05, 0.35)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return l


func _build_board(p: Node3D) -> void:
	var frame := Kit.mat(Color(0.08, 0.08, 0.1), 0.35, 0.6)
	var face := Kit.mat(Color(0.015, 0.015, 0.02), 0.6)
	var steel := Kit.mat(Color(0.6, 0.62, 0.66), 0.3, 0.9)
	Kit.add_rbox(p, Vector3(4.4, 2.2, 0.3), Vector3(0, 0, 0.15), frame, 0.06)
	Kit.add_box(p, Vector3(4.2, 2.0, 0.02), Vector3(0, 0, 0.305), face)
	# Chrome trim, a header strip and two hanging rods to the ceiling.
	Kit.add_rbox(p, Vector3(4.46, 0.06, 0.34), Vector3(0, 1.1, 0.15), steel, 0.02)
	Kit.add_rbox(p, Vector3(4.46, 0.06, 0.34), Vector3(0, -1.1, 0.15), steel, 0.02)
	for sx: float in [-1.8, 1.8]:
		Kit.add_cylinder(p, 0.02, 2.0, Vector3(sx, 2.1, 0.15), steel, 0, -1.0, 8)
	var hdr := Kit.add_label(p, "WORLDWIDE GYM", 0.2, Vector3(0, 0.82, 0.32), 0.0, Color(0.95, 0.95, 1.0))
	hdr.outline_size = 8
	hdr.outline_modulate = Color(0.3, 0.5, 1.0, 0.5)
	for side in 2:
		var x := -1.35 if side == 0 else 1.35
		var t := Kit.add_label(p, "HOME" if side == 0 else "GUEST", 0.2, Vector3(x, 0.5, 0.32), 0.0, Color(1, 1, 1))
		t.outline_size = 6
		t.outline_modulate = Color(0.6, 0.8, 1.0, 0.4)
		var d := _digits(p, Vector3(x + 0.72, -0.2, 0.315), 0.85, "188")
		if side == 0:
			_home_l = d
		else:
			_guest_l = d
	_clock_l = _digits(p, Vector3(0.58, 0.12, 0.315), 0.42, "88:88")
	_clock_l.modulate = Color(1.0, 0.2, 0.15)
	Kit.add_label(p, "PERIOD", 0.11, Vector3(0, -0.4, 0.32), 0.0, Color(1, 1, 1))
	_period_l = _digits(p, Vector3(0.09, -0.68, 0.315), 0.32, "8")
	# The board lights the wall a little.
	var glow := Kit.omni(p, Vector3(0, 0, 0.9), Color(1.0, 0.6, 0.3), 0.25, 3.0)
	glow.light_cull_mask = Kit.VIS_INDOOR
	_buzzer = AudioStreamPlayer3D.new()
	_buzzer.stream = _tone([220.0, 277.0, 330.0], 1.3, 0.55, true)
	_buzzer.max_distance = 40.0
	_buzzer.unit_size = 12.0
	_buzzer.position = Vector3(0, 0, 0.4)
	p.add_child(_buzzer)


## Scorer's table on the sideline: buttons for both teams and the clock.
func _build_table(p: Node3D) -> void:
	var wood := Kit.tmat(Color("2c3e66"), "grain", 2.0, 0.5)
	var top := Kit.mat(Color(0.12, 0.12, 0.14), 0.3, 0.3)
	var chrome := Kit.mat(Color(0.75, 0.76, 0.8), 0.2, 0.95)
	Kit.add_rbox(p, Vector3(2.6, 0.95, 0.6), Vector3(0, 0.475, 0), wood, 0.03, Kit.LAYER_FURNITURE)
	Kit.add_rbox(p, Vector3(2.7, 0.05, 0.7), Vector3(0, 0.97, 0), top, 0.02)
	Kit.add_rbox(p, Vector3(2.62, 0.04, 0.62), Vector3(0, 0.05, 0), chrome, 0.015)
	var front := Kit.add_label(p, "SCORER'S TABLE", 0.09, Vector3(0, 0.62, 0.305), 0.0, Color(1, 1, 1))
	front.outline_size = 6
	# A sloped control desk on top.
	var desk := Node3D.new()
	desk.position = Vector3(0, 1.1, -0.05)
	desk.rotation.x = -0.55
	p.add_child(desk)
	Kit.add_rbox(desk, Vector3(2.4, 0.42, 0.06), Vector3(0, 0, -0.035), Kit.mat(Color(0.05, 0.05, 0.06), 0.4, 0.4), 0.02)
	var green := Color(0.15, 0.45, 0.25)
	var red := Color(0.55, 0.15, 0.15)
	for side in 2:
		var x0 := -0.82 if side == 0 else 0.82
		var tl := Kit.add_label(desk, "HOME" if side == 0 else "GUEST", 0.05, Vector3(x0, 0.16, 0.005), 0.0, Color(1, 0.9, 0.7))
		tl.outline_size = 4
		var i := 0
		for pts: int in [1, 2, 3, -1]:
			var b := Button3D.new(("+%d" if pts > 0 else "%d") % pts, Vector2(0.15, 0.1), green if pts > 0 else red,
				_on_points.bind(side, pts))
			b.position = Vector3(x0 - 0.255 + i * 0.17, 0.03, 0.0)
			desk.add_child(b)
			i += 1
		var r := Button3D.new("Reset", Vector2(0.2, 0.07), Color(0.3, 0.3, 0.35), _on_reset_team.bind(side))
		r.position = Vector3(x0, -0.12, 0.0)
		desk.add_child(r)
	var cl := Kit.add_label(desk, "CLOCK", 0.05, Vector3(0, 0.16, 0.005), 0.0, Color(1, 0.6, 0.5))
	cl.outline_size = 4
	_start_button = Button3D.new("Start", Vector2(0.2, 0.1), Color(0.2, 0.4, 0.65), _on_start_stop)
	_start_button.position = Vector3(-0.11, 0.03, 0)
	desk.add_child(_start_button)
	var rc := Button3D.new("5:00", Vector2(0.2, 0.1), Color(0.3, 0.3, 0.35), _on_reset_clock)
	rc.position = Vector3(0.11, 0.03, 0)
	desk.add_child(rc)
	var per := Button3D.new("Period +", Vector2(0.2, 0.07), Color(0.3, 0.3, 0.35), _on_period)
	per.position = Vector3(-0.11, -0.12, 0)
	desk.add_child(per)
	var horn := Button3D.new("Horn", Vector2(0.2, 0.07), Color(0.6, 0.35, 0.1), _on_horn)
	horn.position = Vector3(0.11, -0.12, 0)
	desk.add_child(horn)
	_beep = AudioStreamPlayer3D.new()
	_beep.stream = _tone([880.0], 0.08, 0.3, false)
	_beep.position = Vector3(0, 1.1, 0)
	p.add_child(_beep)


# ---------------------------------------------------------------- gravity panel

func _build_panel(p: Node3D) -> void:
	var metal := Kit.mat(Color(0.16, 0.17, 0.2), 0.35, 0.8)
	var dark := Kit.mat(Color(0.02, 0.03, 0.05), 0.5)
	var cyan := Color(0.3, 0.9, 1.0)
	# Wall unit: a brushed metal housing with a recessed screen and glowing edge strips.
	Kit.add_rbox(p, Vector3(1.5, 1.9, 0.14), Vector3(0, 1.55, 0.07), metal, 0.04)
	Kit.add_box(p, Vector3(1.32, 1.72, 0.02), Vector3(0, 1.55, 0.141), dark)
	for sx: float in [-0.7, 0.7]:
		Kit.add_box(p, Vector3(0.015, 1.7, 0.02), Vector3(sx, 1.55, 0.145), Kit.flat(cyan))
	for bolt: Vector2 in [Vector2(-0.68, 2.44), Vector2(0.68, 2.44), Vector2(-0.68, 0.66), Vector2(0.68, 0.66)]:
		Kit.add_cylinder(p, 0.018, 0.02, Vector3(bolt.x, bolt.y, 0.145), Kit.mat(Color(0.7, 0.7, 0.75), 0.2, 0.9), 0, -1.0, 10,
			Vector3(PI / 2, 0, 0))
	var title := Kit.add_label(p, "GRAVITY CONTROL", 0.085, Vector3(0, 2.32, 0.16), 0.0, cyan)
	title.outline_size = 10
	title.outline_modulate = Color(0.2, 0.7, 1.0, 0.4)
	Kit.add_label(p, "affects the basketballs in this gym", 0.035, Vector3(0, 2.22, 0.16), 0.0, Color(0.6, 0.8, 0.9))
	# A holographic planet spinning in a glass dome above the readout.
	_planet_node = Node3D.new()
	_planet_node.position = Vector3(0, 1.93, 0.3)
	p.add_child(_planet_node)
	_planet_mat = StandardMaterial3D.new()
	_planet_mat.albedo_texture = Kit.tex("plaster")
	_planet_mat.emission_enabled = true
	_planet_mat.emission_energy_multiplier = 0.6
	_planet_mat.roughness = 0.7
	var ball := MeshInstance3D.new()
	ball.mesh = Kit.sphere_mesh(0.13, 24)
	ball.material_override = _planet_mat
	_planet_node.add_child(ball)
	_ring = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.17
	tm.outer_radius = 0.22
	tm.rings = 32
	tm.ring_segments = 3
	_ring.mesh = tm
	_ring.scale = Vector3(1, 0.08, 1)
	_ring.rotation.x = 0.35
	_ring.material_override = Kit.mat(Color(0.85, 0.75, 0.55, 0.7), 0.6)
	_planet_node.add_child(_ring)
	Kit.add_cylinder(p, 0.2, 0.04, Vector3(0, 1.73, 0.3), metal, 0, 0.17, 24)
	Kit.add_cylinder(p, 0.17, 0.01, Vector3(0, 1.755, 0.3), Kit.flat(cyan.darkened(0.3)), 0, -1.0, 24)
	Kit.add_box(p, Vector3(0.06, 0.04, 0.2), Vector3(0, 1.73, 0.2), metal)
	_readout = Kit.add_label(p, "", 0.075, Vector3(0, 1.58, 0.16), 0.0, Color(0.6, 1.0, 0.9))
	_readout.outline_size = 8
	_readout.outline_modulate = Color(0.1, 0.6, 0.6, 0.4)
	for i in PLANETS.size():
		var pl: Array = PLANETS[i]
		var b := Button3D.new("%s\n%.1f g" % [pl[0], pl[1] / 9.81] if pl[1] > 0.0 else "SPACE\nzero g", Vector2(0.38, 0.13),
			(pl[2] as Color).darkened(0.35), _on_planet.bind(i))
		b.position = Vector3(-0.21 + (i % 2) * 0.42, 1.33 - (i / 2) * 0.16, 0.16)
		if i == PLANETS.size() - 1:
			b.position.x = 0.0
		p.add_child(b)
		_planet_buttons.append(b)
	var light := Kit.omni(p, Vector3(0, 1.9, 0.6), cyan, 0.3, 2.5)
	light.light_cull_mask = Kit.VIS_INDOOR


# ---------------------------------------------------------------- actions

func _on_points(side: int, pts: int) -> void:
	if side == 0:
		home = clampi(home + pts, 0, 199)
	else:
		guest = clampi(guest + pts, 0, 199)
	_beep.play()
	_flash = 0.5
	_send_score()


func _on_reset_team(side: int) -> void:
	if side == 0:
		home = 0
	else:
		guest = 0
	_send_score()


func _on_start_stop() -> void:
	if clock <= 0.0:
		clock = CLOCK_START
	running = not running
	_send_score()


func _on_reset_clock() -> void:
	running = false
	clock = CLOCK_START
	_send_score()


func _on_period() -> void:
	period = period % 4 + 1
	_send_score()


func _on_horn() -> void:
	_buzzer.play()
	main.send({"t": "gy_horn"})


func _on_planet(i: int) -> void:
	planet = i
	_apply_gravity()
	main.send({"t": "gy_g", "g": planet})


func _send_score() -> void:
	_refresh()
	main.send(_score_msg())


func _score_msg() -> Dictionary:
	return {"t": "gy_s", "h": home, "g": guest, "p": period, "c": snappedf(clock, 0.1), "r": running}


func _apply_gravity() -> void:
	var pl: Array = PLANETS[planet]
	var g: float = pl[1]
	if main and main.modules.has("bb"):
		main.modules["bb"].set_gravity(g / 9.81)
	_readout.text = "%s\n%.2f m/s²" % [pl[0], g] if g > 0.0 else "SPACE\nzero gravity"
	var c: Color = pl[2]
	_planet_mat.albedo_color = c
	_planet_mat.emission = c.darkened(0.3) if planet != 3 else Color(0.3, 0.35, 0.6)
	_ring.visible = pl[3]
	for i in _planet_buttons.size():
		_planet_buttons[i].active = i == planet


func _refresh() -> void:
	_home_l.text = str(home)
	_guest_l.text = str(guest)
	var s := ceili(clock)
	_clock_l.text = "%02d:%02d" % [s / 60, s % 60]
	_period_l.text = str(period)
	_start_button.set_text("Stop" if running else "Start")


func _process(delta: float) -> void:
	_t += delta
	_planet_node.rotation.y += delta * (0.6 if planet != 3 else 0.15)
	_planet_node.position.y = 1.93 + 0.012 * sin(_t * 1.7)
	if running:
		var before := ceili(clock)
		clock = maxf(clock - delta, 0.0)
		if clock <= 0.0:
			running = false
			_buzzer.play()
			_refresh()
		elif ceili(clock) != before:
			_refresh()
	# Score digits pulse briefly after a change.
	if _flash > 0.0:
		_flash = maxf(_flash - delta, 0.0)
		var k := 1.0 + _flash * 0.6
		_home_l.modulate = Color(LED.r * k, LED.g * k, LED.b * k)
		_guest_l.modulate = _home_l.modulate


# ---------------------------------------------------------------- sounds

## A short synthesized tone (chord) as a 16-bit WAV.
static func _tone(freqs: Array, seconds: float, vol: float, harsh: bool) -> AudioStreamWAV:
	var rate := 22050
	var n := int(seconds * rate)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / rate
		var v := 0.0
		for f: float in freqs:
			var ph := fmod(t * f, 1.0)
			v += (1.0 if ph < 0.5 else -1.0) * 0.6 + sin(TAU * f * t) * 0.4 if harsh else sin(TAU * f * t)
		v /= freqs.size()
		var env := minf(1.0, t * 80.0) * minf(1.0, (seconds - t) * 20.0)
		data.encode_s16(i * 2, int(clampf(v * env * vol, -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = data
	return w


# ---------------------------------------------------------------- network

func handle(msg: Dictionary, _from: int) -> void:
	match str(msg.get("t", "")):
		"gy_s":
			home = int(msg.get("h", home))
			guest = int(msg.get("g", guest))
			period = int(msg.get("p", period))
			clock = float(msg.get("c", clock))
			running = bool(msg.get("r", running))
			_flash = 0.5
			_refresh()
		"gy_g":
			planet = clampi(int(msg.get("g", 0)), 0, PLANETS.size() - 1)
			_apply_gravity()
		"gy_horn":
			_buzzer.play()
		"gy_full":
			handle(msg.get("sc", {}), _from)
			planet = clampi(int(msg.get("g", 0)), 0, PLANETS.size() - 1)
			_apply_gravity()


func full_state() -> Dictionary:
	return {"t": "gy_full", "sc": _score_msg(), "g": planet}


func on_identity_changed(_old_id: int, _new_id: int) -> void:
	pass


func on_peer_left(_slot: int) -> void:
	pass
