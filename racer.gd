extends Node3D
## Turbo Streak: a sit-down racing cabinet. Press Start, then steer with a thumbstick, right
## trigger for gas, left trigger to brake (arrow keys, space and shift on the laptop). Beat the
## clock: every lap adds time; dodge the traffic and stay on the road. Walking pauses while
## you drive.
##
## The screen is a classic pseudo-3D road (projected road segments with curves and hills)
## drawn into a SubViewport. The driver's headset runs the race and streams it ("rc_p"); the
## traffic moves on a shared race clock, so watchers see the same race.

const Kit := preload("res://kit.gd")
const AK := preload("res://arcade_kit.gd")
const Button3D := preload("res://button3d.gd")

const SW := 320
const SH := 200
const SEG := 200.0
const ROAD_W := 2000.0
const CAM_H := 1000.0
const DEPTH := 0.84
const DRAW := 90
const N := 1500
const MAX_SPEED := 12000.0
const START_TIME := 45.0
const LAP_BONUS := 28.0
const CARS := 18

var main: Node
var player_slot := -1
var player_name := ""
var best := 0.0
var best_name := ""

var pos := 0.0
var px := 0.0              # -1..1 across the road
var speed := 0.0
var steer := 0.0
var time_left := 0.0
var dist := 0.0            # metres travelled (score)
var rt := 0.0              # race clock (moves the traffic)
var running := false
var _bump := 0.0
var _bonus_t := 0.0

var _curve := PackedFloat32Array()
var _y := PackedFloat32Array()
var _car_z0 := PackedFloat32Array()
var _car_x := PackedFloat32Array()
var _car_v := PackedFloat32Array()
var _car_col: Array[Color] = []

var _vp: SubViewport
var _drawer: Node2D
var _wheel: Node3D
var _send_t := 0.0
var _draw_t := 0.0
var _engine: AudioStreamPlayer3D
var _sfx := {}


func _ready() -> void:
	_build_track()
	_build_cabinet()


func _build_track() -> void:
	_curve.resize(N)
	_y.resize(N)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	var i := 0
	var h := 0.0
	while i < N:
		var len := rng.randi_range(40, 110)
		var c := 0.0 if rng.randf() < 0.3 else rng.randf_range(-5.0, 5.0)
		var hill := 0.0 if rng.randf() < 0.4 else rng.randf_range(-40.0, 40.0)
		for k in len:
			if i >= N:
				break
			var t := float(k) / len
			# Ease the curve in and out.
			var e := sin(t * PI)
			_curve[i] = c * e
			h += hill * cos(t * PI) * 0.6
			_y[i] = h
			i += 1
	# Bring the end back to the start height so the loop is seamless.
	var drift := _y[N - 1]
	for k in N:
		_y[k] -= drift * float(k) / N
	var palette := [Color(0.2, 0.5, 1.0), Color(1.0, 0.85, 0.2), Color(0.3, 0.9, 0.4), Color(1.0, 1.0, 1.0), Color(0.9, 0.35, 1.0), Color(1.0, 0.5, 0.1)]
	for k in CARS:
		_car_z0.append(rng.randf() * N * SEG)
		_car_x.append([-0.6, -0.2, 0.2, 0.6][rng.randi() % 4])
		_car_v.append(rng.randf_range(0.25, 0.55) * MAX_SPEED)
		_car_col.append(palette[k % palette.size()])


func _build_cabinet() -> void:
	var black := Kit.mat(Color(0.03, 0.03, 0.05), 0.5)
	var red := Color(1.0, 0.2, 0.15)
	var art := AK.side_art(red, Color(1.0, 0.85, 0.2))
	var chrome := Kit.mat(Color(0.8, 0.82, 0.86), 0.2, 0.7)
	# Main body (screen hood) with art sides.
	for sx: float in [-0.5, 0.5]:
		var side := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.03, 1.95, 1.0)
		side.mesh = bm
		side.material_override = art
		side.position = Vector3(sx, 0.975, -0.15)
		add_child(side)
	Kit.add_box(self, Vector3(0.98, 1.95, 0.9), Vector3(0, 0.975, -0.2), black, Kit.LAYER_FURNITURE)
	Kit.add_box(self, Vector3(1.0, 0.3, 0.5), Vector3(0, 2.05, -0.05), black)
	Kit.add_box(self, Vector3(0.94, 0.24, 0.01), Vector3(0, 2.05, 0.205), Kit.flat(red.lerp(Color.WHITE, 0.1)))
	var t := Kit.add_label(self, "TURBO STREAK", 0.12, Vector3(0, 2.05, 0.212), 0.0, Color(1.0, 0.95, 0.5))
	t.outline_size = 16
	t.outline_modulate = Color(0.6, 0.05, 0.0, 0.7)
	# Screen.
	_drawer = Node2D.new()
	_drawer.draw.connect(_draw_screen)
	Kit.add_box(self, Vector3(0.86, 0.66, 0.04), Vector3(0, 1.38, 0.26), black, 0, Vector3(-0.15, 0, 0))
	_vp = AK.screen(self, Vector2(0.78, 0.5), Vector2i(SW, SH), _drawer, Vector3(0, 1.38, 0.285), Vector3(-0.15, 0, 0))
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	# Dash with the wheel, and the shifter.
	Kit.add_rbox(self, Vector3(0.98, 0.18, 0.4), Vector3(0, 0.98, 0.42), black, 0.04, Kit.LAYER_FURNITURE, Vector3(-0.3, 0, 0))
	_wheel = Node3D.new()
	_wheel.position = Vector3(0, 1.08, 0.62)
	_wheel.rotation.x = -1.0
	add_child(_wheel)
	var rim := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.14
	tm.outer_radius = 0.165
	tm.rings = 28
	rim.mesh = tm
	rim.material_override = Kit.mat(Color(0.08, 0.08, 0.08), 0.7)
	_wheel.add_child(rim)
	for a: float in [0.0, 2.1, -2.1]:
		Kit.add_box(_wheel, Vector3(0.15, 0.015, 0.03), Vector3(cos(a) * 0.075, 0, sin(a) * 0.075), chrome, 0, Vector3(0, -a, 0))
	Kit.add_cylinder(_wheel, 0.04, 0.03, Vector3.ZERO, Kit.mat(red, 0.4), 0, -1.0, 16)
	Kit.add_cylinder(self, 0.03, 0.2, Vector3(0, 1.03, 0.55), black, 0, -1.0, 10, Vector3(-1.0, 0, 0))
	Kit.add_cylinder(self, 0.01, 0.18, Vector3(0.34, 0.95, 0.62), chrome, 0, -1.0, 8)
	Kit.add_sphere(self, 0.03, Vector3(0.34, 1.05, 0.62), Kit.mat(Color(0.1, 0.1, 0.1), 0.3), 0, 12)
	# Pedals, and the bucket seat in front.
	Kit.add_rbox(self, Vector3(0.98, 0.25, 0.5), Vector3(0, 0.125, 0.75), black, 0.03, Kit.LAYER_FURNITURE)
	for sx: float in [-0.1, 0.1]:
		Kit.add_rbox(self, Vector3(0.08, 0.02, 0.14), Vector3(sx, 0.32, 0.72), chrome, 0.008, 0, Vector3(0.6, 0, 0))
	var seat := Kit.mat(Color(0.12, 0.12, 0.14), 0.6)
	Kit.add_rbox(self, Vector3(0.6, 0.45, 0.55), Vector3(0, 0.225, 1.45), Kit.mat(Color(0.03, 0.03, 0.05), 0.5), 0.03, Kit.LAYER_FURNITURE)
	Kit.add_rbox(self, Vector3(0.55, 0.12, 0.5), Vector3(0, 0.51, 1.43), seat, 0.05)
	Kit.add_rbox(self, Vector3(0.55, 0.7, 0.12), Vector3(0, 0.85, 1.7), seat, 0.05, 0, Vector3(-0.2, 0, 0))
	for sx: float in [-0.2, 0.2]:
		Kit.add_box(self, Vector3(0.06, 0.66, 0.01), Vector3(sx, 0.87, 1.635), Kit.mat(red, 0.5), 0, Vector3(-0.2, 0, 0))
	# Buttons.
	var start := Button3D.new("Start", Vector2(0.13, 0.055), Color(0.2, 0.5, 0.3), _on_start)
	start.position = Vector3(-0.32, 1.06, 0.5)
	start.rotation.x = -0.6
	add_child(start)
	var quit := Button3D.new("Quit", Vector2(0.1, 0.055), Color(0.5, 0.2, 0.2), _on_quit)
	quit.position = Vector3(-0.32, 0.99, 0.6)
	quit.rotation.x = -0.6
	add_child(quit)
	_engine = AK.player3d(self, Vector3(0, 1.0, 0.4), _engine_tone(), -14.0)
	for k: String in ["boom", "coin", "buzz", "hit"]:
		_sfx[k] = AK.player3d(self, Vector3(0, 1.3, 0.3), AK.sfx(k), -8.0)
	AK.merge(self, [_wheel])


## A looping engine drone; its pitch follows the speed.
func _engine_tone() -> AudioStreamWAV:
	var rate := 22050
	var n := rate / 2
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / rate
		var v := (fmod(t * 60.0, 1.0) * 2.0 - 1.0) * 0.4 + sin(TAU * 120.0 * t) * 0.3 + sin(TAU * 30.0 * t) * 0.3
		data.encode_s16(i * 2, int(v * 0.5 * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_end = n
	return w


func _on_start() -> void:
	if player_slot >= 0 and player_slot != main.me() and main.avatars.has(player_slot):
		main.notify("Someone is already driving")
		return
	player_slot = main.me()
	player_name = main.player_name
	pos = 0.0
	px = 0.0
	speed = 0.0
	dist = 0.0
	rt = 0.0
	time_left = START_TIME
	running = true
	main.controls_captured = self
	_sfx["coin"].play()
	_engine.play()
	_send_game()


func _on_quit() -> void:
	if player_slot == main.me():
		_finish()


func _finish() -> void:
	running = false
	if dist > best:
		best = dist
		best_name = player_name
	player_slot = -1
	speed = 0.0
	_engine.stop()
	if main.controls_captured == self:
		main.controls_captured = null
	_send_game()


func _send_game() -> void:
	main.send({"t": "rc_g", "ps": player_slot, "nm": player_name, "on": running, "bs": snappedf(best, 1.0), "bn": best_name})


func _process(delta: float) -> void:
	var mine: bool = player_slot >= 0 and player_slot == main.me()
	if mine and running:
		_drive(minf(delta, 0.05))
		_send_t -= delta
		if _send_t <= 0.0:
			_send_t = 0.066
			main.send({"t": "rc_p", "z": snappedf(pos, 1.0), "x": snappedf(px, 0.001), "v": snappedf(speed, 1.0), "st": snappedf(steer, 0.01),
				"tl": snappedf(time_left, 0.1), "d": snappedf(dist, 1.0), "rt": snappedf(rt, 0.01)})
	elif running:
		# Watchers coast between updates.
		pos = fposmod(pos + speed * delta, N * SEG)
		rt += delta
	_bonus_t = maxf(_bonus_t - delta, 0.0)
	_bump = maxf(_bump - delta, 0.0)
	_wheel.rotation.z = lerpf(_wheel.rotation.z, -steer * 1.6, minf(1.0, delta * 10.0))
	if _engine.playing:
		_engine.pitch_scale = 0.6 + 1.4 * speed / MAX_SPEED
	elif running:
		_engine.play()
	_draw_t -= delta
	if _draw_t <= 0.0 and main.camera and main.camera.global_position.distance_to(global_position) < 14.0:
		_draw_t = 0.033
		_drawer.queue_redraw()
		_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


func _drive(dt: float) -> void:
	rt += dt
	var s0: Vector2 = main.stick(0)
	var s1: Vector2 = main.stick(1)
	var st := s0.x if absf(s0.x) > absf(s1.x) else s1.x
	steer = lerpf(steer, clampf(st, -1.0, 1.0), minf(1.0, dt * 8.0))
	var gas: float = main.trigger(1)
	var brake: float = main.trigger(0)
	if s0.y > 0.5 or s1.y > 0.5:
		gas = 1.0
	if s0.y < -0.5 or s1.y < -0.5:
		brake = 1.0
	var frac := speed / MAX_SPEED
	var seg := int(pos / SEG) % N
	px += steer * dt * 2.2 * frac
	px -= dt * 2.0 * frac * frac * _curve[seg] * 0.3
	if gas > 0.1:
		speed += MAX_SPEED / 5.0 * gas * dt
	elif brake > 0.1:
		speed -= MAX_SPEED * brake * dt
	else:
		speed -= MAX_SPEED / 5.0 * dt
	if absf(px) > 1.0 and speed > MAX_SPEED / 4.0:
		speed -= MAX_SPEED / 2.0 * dt     # off the road: slow down in the grass
	px = clampf(px, -2.0, 2.0)
	speed = clampf(speed, 0.0, MAX_SPEED)
	# Traffic: bump if we drive into a car.
	for k in CARS:
		var cz := fposmod(_car_z0[k] + _car_v[k] * rt, N * SEG)
		var gap := fposmod(cz - pos, N * SEG)
		if gap < SEG * 1.2 and absf(_car_x[k] - px) < 0.32 and speed > _car_v[k]:
			speed = _car_v[k] * 0.6
			pos = fposmod(cz - SEG * 1.3, N * SEG)
			_bump = 0.4
			_sfx["hit"].play()
			if main.has_method("_xr_buzz"):
				main._xr_buzz()
	var before := pos
	pos = fposmod(pos + speed * dt, N * SEG)
	dist += speed * dt / SEG * 5.0
	if pos < before:
		time_left += LAP_BONUS
		_bonus_t = 2.0
		_sfx["coin"].play()
	time_left -= dt
	if time_left <= 0.0:
		time_left = 0.0
		_sfx["buzz"].play()
		_finish()


# ---------------------------------------------------------------- drawing

func _project(wx: float, wy: float, wz: float, cx: float, cy: float, cz: float) -> Vector3:
	var z := wz - cz
	if z < 1.0:
		z = 1.0
	var sc := DEPTH / z
	return Vector3(SW / 2.0 + sc * (wx - cx) * SW / 2.0, SH / 2.0 - sc * (wy - cy) * SH / 2.0, sc * ROAD_W * SW / 2.0)


func _yat(z: float) -> float:
	var i := int(z / SEG)
	var f := fmod(z, SEG) / SEG
	return lerpf(_y[i % N], _y[(i + 1) % N], f)


func _draw_screen() -> void:
	var cv := AK.Batch.new()
	var base := int(pos / SEG) % N
	var basef := fmod(pos, SEG) / SEG
	var cam_y := CAM_H + _yat(pos + SEG * 2.0)
	# Sky, a striped sunset sun and mountains that drift with the curves.
	for i in 10:
		cv.draw_rect(Rect2(0, i * 10, SW, 10), Color(0.15, 0.05, 0.35).lerp(Color(1.0, 0.45, 0.35), i / 9.0))
	var drift := 0.0
	for k in 40:
		drift += _curve[(base + k) % N]
	var sun := Vector2(SW / 2.0 - drift * 0.6, 70)
	cv.draw_circle(sun, 34, Color(1.0, 0.75, 0.3))
	for k in 4:
		cv.draw_rect(Rect2(sun.x - 36, sun.y + 6 + k * 7, 72, 2 + k), Color(1.0, 0.5, 0.4).lerp(Color(1.0, 0.45, 0.35), 0.5))
	var mx := fposmod(-pos * 0.002 - drift * 2.0, SW)
	for layer in 2:
		var pts := PackedVector2Array()
		var col := Color(0.3, 0.12, 0.4) if layer == 0 else Color(0.18, 0.07, 0.25)
		pts.append(Vector2(-SW, 100))
		for k in 25:
			var x := -SW + k * 40.0 + fposmod(mx * (0.5 + layer * 0.5), 40.0)
			pts.append(Vector2(x, 100 - (18 + 14 * sin(k * 1.7 + layer)) * (1.0 - layer * 0.3)))
		pts.append(Vector2(SW * 2, 100))
		cv.draw_colored_polygon(pts, col)
	cv.draw_rect(Rect2(0, 100, SW, 100), Color(0.12, 0.45, 0.2))
	# Road, front to back with a clip line for hills.
	var x := 0.0
	var dx := -_curve[base] * basef
	var maxy := float(SH)
	var cam_x := px * ROAD_W
	var segs: Array = []
	for n in DRAW:
		var i := (base + n) % N
		var looped := (base + n) >= N
		var z1 := (base + n) * SEG
		var z2 := z1 + SEG
		var p1 := _project(0.0, _y[i], z1, cam_x - x, cam_y, pos)
		var p2 := _project(0.0, _y[(i + 1) % N], z2, cam_x - x - dx, cam_y, pos)
		x += dx
		dx += _curve[i]
		segs.append([p1, p2, maxy])
		if z1 - pos <= SEG * 0.5 or p2.y >= p1.y or p2.y >= maxy:
			continue
		var stripe := (i / 3) % 2 == 0
		var y1 := minf(p1.y, maxy)
		cv.draw_rect(Rect2(0, p2.y, SW, y1 - p2.y + 1), Color(0.14, 0.5, 0.22) if stripe else Color(0.11, 0.42, 0.19))
		_quad(cv, p1, p2, 1.18, Color(0.95, 0.95, 0.95) if stripe else Color(0.85, 0.1, 0.1))
		_quad(cv, p1, p2, 1.0, Color(0.42, 0.42, 0.45) if stripe else Color(0.38, 0.38, 0.41))
		if stripe:
			for lane: float in [-0.33, 0.33]:
				_lane(cv, p1, p2, lane, Color(0.95, 0.95, 0.9))
		maxy = p2.y
		if looped:
			pass
	# Traffic, far to near.
	var order: Array = []
	for k in CARS:
		var cz := fposmod(_car_z0[k] + _car_v[k] * rt, N * SEG)
		var gap := fposmod(cz - pos, N * SEG)
		if gap > SEG and gap < (DRAW - 2) * SEG:
			order.append([gap, k])
	order.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for e: Array in order:
		var n := int(e[0] / SEG)
		var s: Array = segs[n]
		var p1: Vector3 = s[0]
		var p2: Vector3 = s[1]
		var f := fmod(e[0], SEG) / SEG
		var sx := lerpf(p1.x, p2.x, f) + _car_x[e[1]] * lerpf(p1.z, p2.z, f)
		var sy := lerpf(p1.y, p2.y, f)
		if sy > s[2] + 2.0:
			continue
		_car(cv, Vector2(sx, sy), lerpf(p1.z, p2.z, f) / 160.0, _car_col[e[1]], 0.0)
	# The player's car and the HUD.
	if player_slot >= 0:
		var bob := sin(rt * 30.0) * (speed / MAX_SPEED) + (randf_range(-2, 2) if _bump > 0.0 else 0.0)
		_car(cv, Vector2(SW / 2.0, SH - 8 + bob), 1.1, Color(1.0, 0.15, 0.1), steer)
	cv.flush(_drawer)
	var font := ThemeDB.fallback_font
	if player_slot >= 0:
		_drawer.draw_string(font, Vector2(8, 16), "TIME", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 0.6))
		_drawer.draw_string(font, Vector2(8, 34), str(ceili(time_left)), HORIZONTAL_ALIGNMENT_LEFT, -1, 20,
			Color(1, 0.3, 0.2) if time_left < 10.0 else Color(1, 1, 1))
		_drawer.draw_string(font, Vector2(SW - 96, 16), "%d km/h" % int(speed / MAX_SPEED * 290.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1))
		_drawer.draw_string(font, Vector2(SW - 96, 32), "%.1f km" % (dist / 1000.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 1.0, 1.0))
		if _bonus_t > 0.0:
			_drawer.draw_string(font, Vector2(SW / 2.0 - 58, 60), "TIME BONUS +%d" % int(LAP_BONUS), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 1.0, 0.3))
	else:
		_drawer.draw_string(font, Vector2(SW / 2.0 - 70, 70), "TURBO STREAK", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1.0, 0.95, 0.4))
		if int(Time.get_ticks_msec() / 500) % 2 == 0:
			_drawer.draw_string(font, Vector2(SW / 2.0 - 44, 100), "PRESS START", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1))
		_drawer.draw_string(font, Vector2(SW / 2.0 - 80, 124), "BEST %.1f km  %s" % [best / 1000.0, best_name.left(10)], HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(0.6, 1.0, 1.0))
	cv.flush(_drawer)


func _quad(cv: AK.Batch, p1: Vector3, p2: Vector3, k: float, col: Color) -> void:
	cv.draw_colored_polygon(PackedVector2Array([Vector2(p1.x - p1.z * k, p1.y), Vector2(p1.x + p1.z * k, p1.y),
		Vector2(p2.x + p2.z * k, p2.y), Vector2(p2.x - p2.z * k, p2.y)]), col)


func _lane(cv: AK.Batch, p1: Vector3, p2: Vector3, at: float, col: Color) -> void:
	var w1 := p1.z * 0.02
	var w2 := p2.z * 0.02
	var c1 := p1.x + p1.z * at
	var c2 := p2.x + p2.z * at
	cv.draw_colored_polygon(PackedVector2Array([Vector2(c1 - w1, p1.y), Vector2(c1 + w1, p1.y), Vector2(c2 + w2, p2.y), Vector2(c2 - w2, p2.y)]), col)


## A sports car seen from behind, bottom-centre at p.
func _car(cv: AK.Batch, p: Vector2, s: float, col: Color, lean: float) -> void:
	s = clampf(s, 0.05, 1.6)
	var w := 58.0 * s
	var h := 26.0 * s
	var sk := lean * 6.0 * s
	cv.draw_rect(Rect2(p.x - w * 0.5, p.y - h * 0.25, w * 0.16, h * 0.25), Color(0.05, 0.05, 0.05))
	cv.draw_rect(Rect2(p.x + w * 0.34, p.y - h * 0.25, w * 0.16, h * 0.25), Color(0.05, 0.05, 0.05))
	cv.draw_colored_polygon(PackedVector2Array([Vector2(p.x - w * 0.5, p.y - h * 0.2), Vector2(p.x + w * 0.5, p.y - h * 0.2),
		Vector2(p.x + w * 0.46 + sk, p.y - h * 0.62), Vector2(p.x - w * 0.46 + sk, p.y - h * 0.62)]), col)
	cv.draw_colored_polygon(PackedVector2Array([Vector2(p.x - w * 0.36 + sk, p.y - h * 0.62), Vector2(p.x + w * 0.36 + sk, p.y - h * 0.62),
		Vector2(p.x + w * 0.26 + sk * 1.4, p.y - h), Vector2(p.x - w * 0.26 + sk * 1.4, p.y - h)]), col.darkened(0.25))
	cv.draw_colored_polygon(PackedVector2Array([Vector2(p.x - w * 0.3 + sk, p.y - h * 0.66), Vector2(p.x + w * 0.3 + sk, p.y - h * 0.66),
		Vector2(p.x + w * 0.23 + sk * 1.4, p.y - h * 0.94), Vector2(p.x - w * 0.23 + sk * 1.4, p.y - h * 0.94)]), Color(0.15, 0.2, 0.3))
	cv.draw_rect(Rect2(p.x - w * 0.44 + sk, p.y - h * 0.5, w * 0.16, h * 0.1), Color(1.0, 0.15, 0.1))
	cv.draw_rect(Rect2(p.x + w * 0.28 + sk, p.y - h * 0.5, w * 0.16, h * 0.1), Color(1.0, 0.15, 0.1))
	cv.draw_rect(Rect2(p.x - w * 0.12 + sk, p.y - h * 0.42, w * 0.24, h * 0.1), Color(0.9, 0.9, 0.95))


# ---------------------------------------------------------------- network

func handle(msg: Dictionary, _from: int) -> void:
	match str(msg.get("t", "")):
		"rc_p":
			if player_slot == main.me():
				return
			pos = float(msg.get("z", 0.0))
			px = float(msg.get("x", 0.0))
			speed = float(msg.get("v", 0.0))
			steer = float(msg.get("st", 0.0))
			time_left = float(msg.get("tl", 0.0))
			dist = float(msg.get("d", 0.0))
			rt = float(msg.get("rt", 0.0))
		"rc_g", "rc_full":
			var was_mine: bool = player_slot >= 0 and player_slot == main.me()
			player_slot = int(msg.get("ps", -1))
			if was_mine and player_slot != main.me() and main.controls_captured == self:
				main.controls_captured = null
			player_name = str(msg.get("nm", ""))
			running = bool(msg.get("on", false))
			best = float(msg.get("bs", 0.0))
			best_name = str(msg.get("bn", ""))
			if not running:
				speed = 0.0
				_engine.stop()


func full_state() -> Dictionary:
	return {"t": "rc_full", "ps": player_slot, "nm": player_name, "on": running, "bs": snappedf(best, 1.0), "bn": best_name}


func on_identity_changed(old_id: int, new_id: int) -> void:
	if player_slot == old_id and old_id >= 0:
		player_slot = new_id


func on_peer_left(slot: int) -> void:
	if slot == player_slot:
		player_slot = -1
		running = false
		speed = 0.0
		_engine.stop()
