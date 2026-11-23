extends Node3D
## Cosmic Carnival: a playable pinball machine. Press Start, then: triggers flip the flippers
## (left trigger left flipper, right trigger right), pull a thumbstick back and let go to
## launch (shift / space and the down arrow on the laptop). Walking pauses while you play.
##
## The table is simulated in 2D on the playfield plane (u across, v up the table, metres) with
## swept flippers and plenty of substeps: a 27 mm ball and fast flippers are too much for
## the general physics engine. The player's headset runs the table and streams the ball and
## flippers ("pb_b"); scores and lights travel in "pb_g".

const Kit := preload("res://kit.gd")
const AK := preload("res://arcade_kit.gd")
const Button3D := preload("res://button3d.gd")

const R := 0.0135                # ball radius
const G := 1.7                   # gravity down the table (m/s^2)
const TILT := 0.1134             # 6.5 degrees
const HALF_W := 0.3
const LANE_X := 0.245            # plunger lane separator
const C := -0.0275               # centre of the playing area
const FLIP_LEN := 0.082
const FLIP_R := 0.009
const FLIP_REST := -0.47
const FLIP_UP := 0.5
const BALLS := 3
const SUBSTEPS := 10

var main: Node
## Who is playing (slot), -1 when nobody.
var player_slot := -1
var player_name := ""
var score := 0
var ball_no := 0
var hi := 0
var hi_name := ""
var mult := 1

# Table state.
var _segs: Array = []         # [a, b, restitution, kick, tag, oneway]
var _bumpers: Array = []      # [centre, radius]
var _drops := [true, true, true]
var _rolls := [false, false, false]
var _ball := Vector2(0.2725, 0.04)
var _vel := Vector2.ZERO
var _in_play := false
var _ang := [FLIP_REST, PI - FLIP_REST]
var _w := [0.0, 0.0]
var _plunge := 0.0
var _charging := false
var _drop_reset := 0.0
var _send_t := 0.0

# Visuals.
var _cab: Node3D
var _pf: Node3D
var _ball_mi: Node3D
var _flip_n: Array[Node3D] = []
var _bump_m: Array[StandardMaterial3D] = []
var _bump_flash := [0.0, 0.0, 0.0]
var _drop_n: Array[Node3D] = []
var _roll_m: Array[StandardMaterial3D] = []
var _plunger: Node3D
var _dmd: Label3D
var _start: Node3D
var _remote_ball := Vector2(0.2725, 0.04)
var _sfx := {}


func _ready() -> void:
	_table()
	_build()
	_refresh()


func _table() -> void:
	var w := 0.5
	# Outer walls and the top arc.
	_seg(Vector2(-HALF_W, -0.05), Vector2(-HALF_W, 0.9), w)
	_seg(Vector2(HALF_W, -0.05), Vector2(HALF_W, 0.9), w)
	var n := 14
	for i in n:
		var a0 := PI * i / n
		var a1 := PI * (i + 1) / n
		_seg(Vector2(0, 0.9) + Vector2(cos(a0), sin(a0)) * HALF_W, Vector2(0, 0.9) + Vector2(cos(a1), sin(a1)) * HALF_W, w)
	# Plunger lane and its one-way gate.
	_seg(Vector2(LANE_X, -0.05), Vector2(LANE_X, 0.8), w)
	_segs.append([Vector2(HALF_W, 0.86), Vector2(LANE_X, 0.8), 0.3, 0.0, "", true])
	# Inlane guides down to the flippers.
	_seg(Vector2(-HALF_W, 0.27), Vector2(C - 0.118, 0.155), 0.3)
	_seg(Vector2(LANE_X, 0.27), Vector2(C + 0.118, 0.155), 0.3)
	# Slingshots: two passive edges and a kicking face each.
	for sgn: float in [-1.0, 1.0]:
		var a := Vector2(C + sgn * 0.175, 0.355)
		var b := Vector2(C + sgn * 0.175, 0.258)
		var d := Vector2(C + sgn * 0.105, 0.222)
		_seg(a, b, 0.4)
		_seg(b, d, 0.4)
		_segs.append([a, d, 0.5, 0.75, "sling", false])
	# Top rollover lane posts.
	for x: float in [-0.09, -0.03, 0.03, 0.09]:
		_seg(Vector2(C + x, 0.95), Vector2(C + x, 1.05), 0.4)
	# Pop bumpers.
	for p: Vector2 in [Vector2(C - 0.075, 0.71), Vector2(C + 0.075, 0.71), Vector2(C, 0.83)]:
		_bumpers.append([p, 0.028])
	# Drop targets (faces of the bank), tagged by index.
	for i in 3:
		var v := 0.47 + i * 0.065
		_segs.append([Vector2(0.205, v - 0.024), Vector2(0.205, v + 0.024), 0.4, 0.0, "drop%d" % i, false])


func _seg(a: Vector2, b: Vector2, e: float) -> void:
	_segs.append([a, b, e, 0.0, "", false])


func _pivot(i: int) -> Vector2:
	return Vector2(C - 0.112, 0.145) if i == 0 else Vector2(C + 0.112, 0.145)


func _flip_tip(i: int) -> Vector2:
	return _pivot(i) + Vector2(cos(_ang[i]), sin(_ang[i])) * FLIP_LEN


# ---------------------------------------------------------------- build

func _pf_point(u: float, v: float, h := 0.0) -> Vector3:
	return Vector3(u, h, -v)


func _build() -> void:
	_cab = Node3D.new()
	add_child(_cab)
	var black := Kit.mat(Color(0.03, 0.03, 0.05), 0.4)
	var chrome := Kit.mat(Color(0.85, 0.87, 0.9), 0.15, 0.75)
	var art := AK.side_art(Color(0.6, 0.2, 1.0), Color(1.0, 0.75, 0.15))
	# Body: an art-wrapped box under the playfield, chrome legs, lockdown bar.
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.72, 0.34, 1.3)
	body.mesh = bm
	body.material_override = art
	body.position = Vector3(0, 0.74, 0.0)
	body.rotation.x = TILT
	_cab.add_child(body)
	# Collision only (no mesh, so the merge below cannot pick it up).
	var solid := Kit.add_box(_cab, Vector3(0.7, 0.9, 1.2), Vector3(0, 0.45, 0), black, Kit.LAYER_FURNITURE)
	for c in solid.get_children():
		if c is MeshInstance3D:
			c.free()
	for sx: float in [-0.32, 0.32]:
		for sz: float in [-0.58, 0.58]:
			var top := 0.6 + (0.07 if sz < 0 else -0.07)
			Kit.add_cylinder(_cab, 0.022, top, Vector3(sx, top / 2.0, sz), chrome, 0, -1.0, 10)
			Kit.add_cylinder(_cab, 0.04, 0.03, Vector3(sx, 0.015, sz), chrome, 0, -1.0, 12)
	Kit.add_rbox(_cab, Vector3(0.74, 0.04, 0.08), Vector3(0, 0.93, 0.64), chrome, 0.015)
	# Flipper buttons on the sides, and the plunger.
	for sx: float in [-0.365, 0.365]:
		Kit.add_cylinder(_cab, 0.016, 0.02, Vector3(sx, 0.86, 0.5), Kit.mat(Color(1.0, 0.2, 0.2), 0.3), 0, -1.0, 12, Vector3(0, 0, PI / 2))
	_plunger = Node3D.new()
	_plunger.position = Vector3(0.27, 0.87, 0.66)
	_cab.add_child(_plunger)
	Kit.add_cylinder(_plunger, 0.006, 0.1, Vector3(0, 0, 0.04), chrome, 0, -1.0, 8, Vector3(PI / 2, 0, 0))
	Kit.add_sphere(_plunger, 0.022, Vector3(0, 0, 0.1), Kit.mat(Color(0.9, 0.1, 0.15), 0.25), 0, 12)
	# Backbox: art backglass and the score display.
	Kit.add_box(_cab, Vector3(0.72, 0.8, 0.22), Vector3(0, 1.45, -0.6), black)
	var glass := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.64, 0.5)
	glass.mesh = qm
	var gm := ShaderMaterial.new()
	gm.shader = AK.shader(BACKGLASS_SHADER)
	glass.material_override = gm
	glass.position = Vector3(0, 1.57, -0.488)
	_cab.add_child(glass)
	var t := Kit.add_label(_cab, "COSMIC\nCARNIVAL", 0.085, Vector3(0, 1.6, -0.485), 0.0, Color(1.0, 0.92, 0.5))
	t.outline_size = 18
	t.outline_modulate = Color(0.8, 0.1, 0.6, 0.8)
	Kit.add_box(_cab, Vector3(0.6, 0.15, 0.01), Vector3(0, 1.18, -0.488), Kit.mat(Color(0.02, 0.01, 0.0), 0.6))
	_dmd = Kit.add_label(_cab, "", 0.045, Vector3(0, 1.18, -0.482), 0.0, Color(1.0, 0.55, 0.1))
	# Playfield.
	_pf = Node3D.new()
	_pf.position = Vector3(0, 0.9, 0.6)
	_pf.rotation.x = TILT
	_cab.add_child(_pf)
	var field := MeshInstance3D.new()
	var fq := QuadMesh.new()
	fq.size = Vector2(2.0 * HALF_W, 1.22)
	fq.orientation = PlaneMesh.FACE_Y
	field.mesh = fq
	var fm := ShaderMaterial.new()
	fm.shader = AK.shader(PLAYFIELD_SHADER)
	field.material_override = fm
	field.position = _pf_point(0, 0.56)
	_pf.add_child(field)
	var rail := Kit.mat(Color(0.75, 0.77, 0.82), 0.25, 0.7)
	var rubber := Kit.mat(Color(0.95, 0.95, 0.92), 0.6)
	for s: Array in _segs:
		var a: Vector2 = s[0]
		var b: Vector2 = s[1]
		var d := b - a
		var tag: String = s[4]
		if tag.begins_with("drop"):
			continue
		var m: Material = rubber if s[2] >= 0.4 and tag != "" or tag == "sling" else rail
		if s[5]:
			m = Kit.mat(Color(1.0, 0.85, 0.2), 0.3, 0.5)
		var mid := (a + b) / 2.0
		Kit.add_box(_pf, Vector3(d.length() + 0.008, 0.028, 0.008), _pf_point(mid.x, mid.y, 0.014), m, 0, Vector3(0, atan2(d.y, d.x), 0))
	# Sling plastics: lit triangles.
	for sgn: float in [-1.0, 1.0]:
		var tri := MeshInstance3D.new()
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for p: Vector2 in [Vector2(C + sgn * 0.175, 0.355), Vector2(C + sgn * 0.175, 0.258), Vector2(C + sgn * 0.105, 0.222)]:
			st.add_vertex(_pf_point(p.x, p.y, 0.03))
		tri.mesh = st.commit()
		var pm := Kit.flat(Color(1.0, 0.3, 0.55) if sgn < 0 else Color(0.3, 0.8, 1.0))
		pm.cull_mode = BaseMaterial3D.CULL_DISABLED
		tri.material_override = pm
		_pf.add_child(tri)
	# Bumpers: black skirt, lit cap.
	for bp: Array in _bumpers:
		var c: Vector2 = bp[0]
		Kit.add_cylinder(_pf, bp[1], 0.025, _pf_point(c.x, c.y, 0.0125), Kit.mat(Color(0.05, 0.05, 0.08), 0.4), 0, -1.0, 20)
		var cm := StandardMaterial3D.new()
		cm.albedo_color = Color(1.0, 0.85, 0.3)
		cm.emission_enabled = true
		cm.emission = Color(1.0, 0.6, 0.1)
		cm.emission_energy_multiplier = 0.4
		_bump_m.append(cm)
		Kit.add_cylinder(_pf, bp[1] * 1.05, 0.012, _pf_point(c.x, c.y, 0.031), cm, 0, bp[1] * 0.7, 20)
		Kit.add_cylinder(_pf, bp[1] * 1.15, 0.006, _pf_point(c.x, c.y, 0.02), Kit.flat(Color(1, 1, 1)), 0, -1.0, 20)
	# Flippers.
	for i in 2:
		var f := Node3D.new()
		var pv := _pivot(i)
		f.position = _pf_point(pv.x, pv.y)
		_pf.add_child(f)
		Kit.add_rbox(f, Vector3(FLIP_LEN + 0.006, 0.022, 0.017), Vector3(FLIP_LEN / 2.0, 0.013, 0), Kit.mat(Color(0.97, 0.97, 0.95), 0.4), 0.007)
		Kit.add_box(f, Vector3(FLIP_LEN - 0.01, 0.012, 0.02), Vector3(FLIP_LEN / 2.0, 0.013, 0), Kit.mat(Color(0.85, 0.1, 0.1), 0.6))
		Kit.add_cylinder(f, 0.006, 0.03, Vector3(0, 0.015, 0), chrome, 0, -1.0, 8)
		_flip_n.append(f)
	# Drop targets and rollover inserts.
	for i in 3:
		var v := 0.47 + i * 0.065
		var dt := Node3D.new()
		dt.position = _pf_point(0.208, v)
		_pf.add_child(dt)
		Kit.add_box(dt, Vector3(0.008, 0.035, 0.044), Vector3(0, 0.0175, 0), Kit.mat([Color(1.0, 0.2, 0.3), Color(1.0, 0.85, 0.2), Color(0.2, 0.8, 1.0)][i], 0.4))
		_drop_n.append(dt)
	for i in 3:
		var rm := StandardMaterial3D.new()
		rm.albedo_color = Color(0.2, 0.9, 0.4)
		rm.emission_enabled = true
		rm.emission = Color(0.2, 1.0, 0.4)
		rm.emission_energy_multiplier = 0.1
		_roll_m.append(rm)
		Kit.add_cylinder(_pf, 0.014, 0.002, _pf_point(C - 0.06 + i * 0.06, 1.0, 0.001), rm, 0, -1.0, 14)
	# The ball.
	_ball_mi = Kit.add_sphere(_pf, R, _pf_point(_ball.x, _ball.y, R), Kit.mat(Color(0.88, 0.9, 0.95), 0.12, 0.65), 0, 14)
	# Glass over the table (very light, catches a reflection of the lights).
	var gl := MeshInstance3D.new()
	var gq := QuadMesh.new()
	gq.size = Vector2(2.0 * HALF_W, 1.22)
	gq.orientation = PlaneMesh.FACE_Y
	gl.mesh = gq
	gl.material_override = Kit.mat(Color(0.8, 0.9, 1.0, 0.06), 0.02, 0.3)
	gl.position = _pf_point(0, 0.56, 0.06)
	_pf.add_child(gl)
	# Start button on the front.
	_start = Button3D.new("Start", Vector2(0.16, 0.06), Color(0.2, 0.5, 0.3), _on_start)
	_start.position = Vector3(-0.22, 0.75, 0.67)
	_cab.add_child(_start)
	var quit := Button3D.new("Quit", Vector2(0.12, 0.06), Color(0.5, 0.2, 0.2), _on_quit)
	quit.position = Vector3(0.05, 0.75, 0.67)
	_cab.add_child(quit)
	Kit.add_label(_cab, "Triggers: flippers  ·  pull stick back: launch", 0.025, Vector3(0, 0.69, 0.671), 0.0, Color(0.95, 0.9, 1.0))
	for k: String in ["hit", "ding", "boom", "coin", "blip", "buzz"]:
		_sfx[k] = AK.player3d(_cab, Vector3(0, 1.0, 0.2), AK.sfx(k), -10.0)
	var moving: Array = [_plunger, _ball_mi]
	moving.append_array(_flip_n)
	moving.append_array(_drop_n)
	AK.merge(_cab, moving)


const PLAYFIELD_SHADER := """
shader_type spatial;
// Cosmic Carnival playfield art: deep space with swirls, lane arrows and stars.
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 p = vec2((UV.x - 0.5) * 0.6, (1.0 - UV.y) * 1.22 - 0.05);
	vec3 col = mix(vec3(0.05, 0.02, 0.15), vec3(0.15, 0.03, 0.25), smoothstep(0.0, 1.1, p.y));
	float r = length(p - vec2(-0.03, 0.75));
	float a = atan(p.y - 0.75, p.x + 0.03);
	col += vec3(0.5, 0.15, 0.6) * smoothstep(0.03, 0.0, abs(fract(r * 9.0 - a / 6.2831) - 0.5) - 0.2) * smoothstep(0.35, 0.05, r) * 0.5;
	vec2 g = floor(p * 90.0);
	col += vec3(step(0.97, hash(g))) * 0.6;
	// Arrows pointing up the left orbit and to the drop targets.
	for (int i = 0; i < 3; i++) {
		vec2 c = vec2(-0.2 + float(i) * 0.012, 0.42 + float(i) * 0.08);
		vec2 d = p - c;
		float tri = max(abs(d.x) * 1.7 + d.y, -d.y - 0.02);
		col = mix(col, vec3(1.0, 0.3, 0.6), smoothstep(0.012, 0.008, tri) * 0.9);
		vec2 c2 = vec2(0.14, 0.45 + float(i) * 0.065);
		vec2 d2 = p - c2;
		float tri2 = max(abs(d2.y) * 1.7 + d2.x, -d2.x - 0.02);
		col = mix(col, vec3(0.3, 0.9, 1.0), smoothstep(0.012, 0.008, tri2) * 0.9);
	}
	// A big star in the middle and the shoot-again insert.
	vec2 s = p - vec2(-0.03, 0.42);
	float sa = atan(s.y, s.x);
	float sr = 0.045 + 0.02 * cos(sa * 5.0);
	col = mix(col, vec3(1.0, 0.85, 0.2), smoothstep(0.003, 0.0, length(s) - sr));
	float ring = abs(length(p - vec2(-0.03, 0.07)) - 0.02);
	col = mix(col, vec3(1.0, 0.2, 0.2), smoothstep(0.004, 0.0, ring - 0.003));
	ALBEDO = col;
	EMISSION = col * 0.35;
	ROUGHNESS = 0.25;
}
"""

const BACKGLASS_SHADER := """
shader_type spatial;
render_mode unshaded;
void fragment() {
	vec2 p = UV - vec2(0.5, 0.55);
	float r = length(p);
	float a = atan(p.y, p.x);
	vec3 col = mix(vec3(0.35, 0.05, 0.45), vec3(0.03, 0.02, 0.12), smoothstep(0.0, 0.6, r));
	float rays = smoothstep(0.3, 0.0, abs(fract(a * 3.0 / 3.14159 + TIME * 0.05) - 0.5)) * smoothstep(0.7, 0.1, r);
	col += vec3(1.0, 0.5, 0.2) * rays * 0.35;
	float planet = smoothstep(0.13, 0.125, length(p - vec2(0.3, -0.28)));
	col = mix(col, vec3(0.2, 0.7, 0.9), planet);
	float ring = smoothstep(0.01, 0.0, abs(length((p - vec2(0.3, -0.28)) * vec2(1.0, 3.0)) - 0.2));
	col = mix(col, vec3(1.0, 0.85, 0.4), ring);
	ALBEDO = col;
}
"""


# ---------------------------------------------------------------- game

func _on_start() -> void:
	if player_slot >= 0 and player_slot != main.me() and main.avatars.has(player_slot):
		main.notify("Someone is already playing")
		return
	player_slot = main.me()
	player_name = main.player_name
	score = 0
	ball_no = 1
	mult = 1
	_drops = [true, true, true]
	_rolls = [false, false, false]
	_serve()
	main.controls_captured = self
	_sfx["coin"].play()
	_send_game()


func _on_quit() -> void:
	if player_slot == main.me():
		_game_over()


func _serve() -> void:
	_ball = Vector2(0.2725, 0.035)
	_vel = Vector2.ZERO
	_in_play = true
	_plunge = 0.0


func _game_over() -> void:
	_in_play = false
	if score > hi:
		hi = score
		hi_name = player_name
	player_slot = -1
	ball_no = 0
	if main.controls_captured == self:
		main.controls_captured = null
	_sfx["buzz"].play()
	_send_game()


func _physics_process(delta: float) -> void:
	var mine: bool = player_slot >= 0 and player_slot == main.me()
	if mine and _in_play:
		var left: bool = main.trigger(0) > 0.5
		var right: bool = main.trigger(1) > 0.5
		var pull := maxf(-main.stick(0).y, -main.stick(1).y)
		if pull > 0.3 and _ball.x > LANE_X and _ball.y < 0.1:
			_charging = true
			_plunge = maxf(_plunge, clampf(pull, 0.0, 1.0))
		elif _charging:
			_charging = false
			if _ball.x > LANE_X and _ball.y < 0.1:
				_vel = Vector2(0, 1.5 + 1.4 * _plunge)
				_sfx["blip"].play()
			_plunge = 0.0
		var sub := delta / SUBSTEPS
		for k in SUBSTEPS:
			_step_flippers(left, right, sub)
			_step_ball(sub)
		if _ball.y < -0.04:
			_drain()
		_send_t -= delta
		if _send_t <= 0.0:
			_send_t = 0.05
			main.send({"t": "pb_b", "u": snappedf(_ball.x, 0.0005), "v": snappedf(_ball.y, 0.0005), "l": snappedf(_ang[0], 0.01),
				"r": snappedf(_ang[1], 0.01), "pl": snappedf(_plunge, 0.05)})
		if _drop_reset > 0.0:
			_drop_reset -= delta
			if _drop_reset <= 0.0:
				_drops = [true, true, true]
				_send_game()
	elif not mine:
		_ball = _ball.lerp(_remote_ball, minf(1.0, delta * 15.0))
	_draw_table(delta)


func _step_flippers(left: bool, right: bool, dt: float) -> void:
	for i in 2:
		var up := left if i == 0 else right
		var rest := FLIP_REST if i == 0 else PI - FLIP_REST
		var top := FLIP_UP if i == 0 else PI - FLIP_UP
		var target := top if up else rest
		var speed := 30.0 if up else 14.0
		var before: float = _ang[i]
		_ang[i] = move_toward(_ang[i], target, speed * dt)
		_w[i] = (_ang[i] - before) / dt


func _step_ball(dt: float) -> void:
	_vel.y -= G * dt
	_vel *= 1.0 - 0.05 * dt
	if _vel.length() > 4.5:
		_vel = _vel.normalized() * 4.5
	# The plunger holds the ball in the lane.
	if _ball.x > LANE_X and _ball.y < 0.035 and _vel.y < 0.0:
		_ball.y = 0.035
		_vel = Vector2.ZERO
	var prev := _ball
	_ball += _vel * dt
	# Flippers first: walls then put the ball back on the side it came from if a flipper
	# shoved it into one.
	for i in 2:
		_collide_flipper(i)
	for s: Array in _segs:
		var tag: String = s[4]
		if tag.begins_with("drop") and not _drops[int(tag.substr(4))]:
			continue
		_collide_seg(s[0], s[1], 0.004, s[2], s[3], tag, s[5], prev)
	for i in _bumpers.size():
		var c: Vector2 = _bumpers[i][0]
		var d := _ball - c
		var rr: float = _bumpers[i][1] + R
		if d.length() < rr:
			var n := d.normalized()
			_ball = c + n * rr
			_vel = _vel - 2.0 * minf(_vel.dot(n), 0.0) * n
			_vel += n * 1.1
			_bump_flash[i] = 1.0
			_add(100, "hit", i)
	# Top rollovers.
	for i in 3:
		if not _rolls[i] and _ball.distance_to(Vector2(C - 0.06 + i * 0.06, 1.0)) < 0.015:
			_rolls[i] = true
			if _rolls[0] and _rolls[1] and _rolls[2]:
				_rolls = [false, false, false]
				mult = mini(mult + 1, 5)
				_add(500, "coin")
			else:
				_add(50, "blip")


func _collide_seg(a: Vector2, b: Vector2, thick: float, e: float, kick: float, tag: String, oneway: bool, prev: Vector2) -> void:
	var ab := b - a
	var raw := (_ball - a).dot(ab) / ab.length_squared()
	var t := clampf(raw, 0.0, 1.0)
	var q := a + ab * t
	var d := _ball - q
	var dist := d.length()
	if dist >= R + thick:
		return
	var n := d / dist if dist > 0.000001 else Vector2.UP
	if raw > 0.0 and raw < 1.0:
		# Along the wall: push out on the side the ball was on before this step.
		var perp := Vector2(-ab.y, ab.x).normalized()
		if (prev - a).dot(perp) < 0.0:
			perp = -perp
		n = perp
	if oneway:
		var nn := Vector2(-ab.y, ab.x).normalized()
		if (prev - a).dot(nn) > 0.0:
			return
	_ball = q + n * (R + thick)
	var vn := _vel.dot(n)
	if vn < 0.0:
		_vel -= (1.0 + e) * vn * n
		if kick > 0.0 and -vn > 0.05:
			_vel += n * kick
			_add(10, "hit")
		elif tag.begins_with("drop"):
			var i := int(tag.substr(4))
			_drops[i] = false
			if not (_drops[0] or _drops[1] or _drops[2]):
				_drop_reset = 1.2
				_add(2000, "coin")
			else:
				_add(250, "ding")


func _collide_flipper(i: int) -> void:
	var a := _pivot(i)
	var b := _flip_tip(i)
	var ab := b - a
	var t := clampf((_ball - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	var q := a + ab * t
	var d := _ball - q
	var dist := d.length()
	var rad := lerpf(FLIP_R, FLIP_R * 0.65, t)
	if dist >= R + rad or dist < 0.000001:
		return
	var n := d / dist
	_ball = q + n * (R + rad)
	var r := q - a
	var vc: Vector2 = Vector2(-r.y, r.x) * float(_w[i])
	var rel: Vector2 = _vel - vc
	var vn: float = rel.dot(n)
	if vn < 0.0:
		_vel -= (1.0 + 0.35) * vn * n


func _drain() -> void:
	_sfx["boom"].play()
	ball_no += 1
	if ball_no > BALLS:
		_game_over()
	else:
		_serve()
		_send_game()


func _add(points: int, sound: String, bumper := -1) -> void:
	score += points * mult
	if _sfx.has(sound):
		_sfx[sound].play()
	_send_game(bumper)


func _send_game(bumper := -1) -> void:
	_refresh()
	main.send({"t": "pb_g", "ps": player_slot, "nm": player_name, "sc": score, "bl": ball_no, "hi": hi, "hn": hi_name,
		"dt": _drops, "ro": _rolls, "mu": mult, "fx": bumper})


func _refresh() -> void:
	if _dmd == null:
		return
	if player_slot < 0:
		_dmd.text = "PRESS START   HIGH %d %s" % [hi, hi_name] if score == 0 else "GAME OVER  %d   HIGH %d %s" % [score, hi, hi_name]
	else:
		_dmd.text = "%s   BALL %d   x%d\n%d" % [player_name, ball_no, mult, score]


func _draw_table(delta: float) -> void:
	if _pf == null:
		return
	_ball_mi.position = _pf_point(_ball.x, _ball.y, R)
	_ball_mi.visible = player_slot >= 0
	for i in 2:
		_flip_n[i].rotation.y = _ang[i]
	for i in 3:
		_bump_flash[i] = maxf(_bump_flash[i] - delta * 5.0, 0.0)
		_bump_m[i].emission_energy_multiplier = 0.4 + 3.0 * _bump_flash[i]
		_drop_n[i].position.y = 0.0 if _drops[i] else -0.04
		_roll_m[i].emission_energy_multiplier = 2.0 if _rolls[i] else 0.1
	_plunger.position.z = 0.66 + 0.06 * _plunge


func handle(msg: Dictionary, _from: int) -> void:
	match str(msg.get("t", "")):
		"pb_b":
			_remote_ball = Vector2(float(msg.get("u", 0.0)), float(msg.get("v", 0.0)))
			_ang = [float(msg.get("l", FLIP_REST)), float(msg.get("r", PI - FLIP_REST))]
			_plunge = float(msg.get("pl", 0.0))
		"pb_g", "pb_full":
			var was_mine: bool = player_slot == main.me() and player_slot >= 0
			player_slot = int(msg.get("ps", -1))
			if was_mine and player_slot != main.me():
				_in_play = false
				if main.controls_captured == self:
					main.controls_captured = null
			player_name = str(msg.get("nm", ""))
			score = int(msg.get("sc", 0))
			ball_no = int(msg.get("bl", 0))
			hi = int(msg.get("hi", 0))
			hi_name = str(msg.get("hn", ""))
			mult = int(msg.get("mu", 1))
			var dt: Array = msg.get("dt", [true, true, true])
			var ro: Array = msg.get("ro", [false, false, false])
			for i in 3:
				_drops[i] = bool(dt[i])
				_rolls[i] = bool(ro[i])
			var fx := int(msg.get("fx", -1))
			if fx >= 0 and fx < 3:
				_bump_flash[fx] = 1.0
				_sfx["hit"].play()
			if player_slot < 0:
				_ang = [FLIP_REST, PI - FLIP_REST]
			_refresh()


func full_state() -> Dictionary:
	return {"t": "pb_full", "ps": player_slot, "nm": player_name, "sc": score, "bl": ball_no, "hi": hi, "hn": hi_name,
		"dt": _drops, "ro": _rolls, "mu": mult, "fx": -1}


func on_identity_changed(old_id: int, new_id: int) -> void:
	if player_slot == old_id and old_id >= 0:
		player_slot = new_id


func on_peer_left(slot: int) -> void:
	if slot == player_slot:
		player_slot = -1
		ball_no = 0
		_refresh()
