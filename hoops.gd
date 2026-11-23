extends Node3D
## Hoop Fever: an arcade basketball shooter. Press Start for a 45-second round; every basket is
## 2 points, 3 in the last 10 seconds. The net cage and sloped floor roll the balls back to the
## tray. Balls are props; whoever shot a ball judges the basket and sends the score ("hs_").
## Lane space: the player stands at +z, the hoop is at -z.

const Kit := preload("res://kit.gd")
const AK := preload("res://arcade_kit.gd")
const Button3D := preload("res://button3d.gd")

const ROUND := 45.0
const RIM := Vector3(0, 2.15, -2.3)
const RIM_R := 0.15
const BALL_R := 0.09

var main: Node
var balls: Array = []
var score := 0
var hi := 0
var hi_name := ""
var player := ""
var time_left := 0.0
var running := false

var _p: Node3D
var _label: Label3D
var _clock: Label3D
var _last := {}
var _horn: AudioStreamPlayer3D
var _swish: AudioStreamPlayer3D
var _net: Node3D
var _net_t := 0.0


func setup(anchor: Array) -> void:
	_p = Node3D.new()
	_p.position = anchor[0]
	_p.rotation.y = anchor[1]
	add_child(_p)
	_build()
	AK.merge(_p, [_net])
	var pr: Node = main.modules["pr"]
	for i in 4:
		var home := _p.global_transform * Transform3D(Basis.IDENTITY, Vector3(-0.2 + i * 0.133, 0.85 + BALL_R + 0.01, 0.12))
		balls.append(pr.add_prop("minibb", home))
	_refresh()


func _build() -> void:
	var black := Kit.mat(Color(0.04, 0.04, 0.06), 0.5)
	var net := Kit.mat(Color(0.9, 0.9, 1.0, 0.1), 0.6)
	var orange := Color(1.0, 0.45, 0.1)
	var art := AK.side_art(orange, Color(0.25, 0.7, 1.0))
	var steel := Kit.mat(Color(0.6, 0.62, 0.66), 0.3, 0.7)
	# Base cabinet and the cage.
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.24, 0.85, 3.0)
	base.mesh = bm
	base.material_override = art
	base.position = Vector3(0, 0.425, -1.2)
	_p.add_child(base)
	_slab(Vector3(1.2, 0.04, 2.65), Vector3(0, 1.065, -1.325), 0.144, Kit.tmat(Color(0.75, 0.5, 0.3), "planks", 2.0, 0.4))
	_slab(Vector3(1.2, 0.04, 0.38), Vector3(0, 0.83, 0.12), 0.0, black)
	_slab(Vector3(1.2, 0.18, 0.03), Vector3(0, 0.92, 0.3), 0.0, black)
	for sx: float in [-0.61, 0.61]:
		_slab(Vector3(0.03, 2.3, 3.05), Vector3(sx, 1.95, -1.2), 0.0, net)
		Kit.add_box(_p, Vector3(0.05, 0.05, 3.05), Vector3(sx, 3.1, -1.2), steel)
		for z: float in [0.3, -1.0, -2.7]:
			Kit.add_box(_p, Vector3(0.05, 2.3, 0.05), Vector3(sx, 1.95, z), steel)
	_slab(Vector3(1.24, 2.4, 0.04), Vector3(0, 1.9, -2.75), 0.0, black)
	_slab(Vector3(1.24, 0.03, 1.75), Vector3(0, 3.1, -1.85), 0.0, net)
	# Backboard, rim (collision spheres), a net that swishes.
	Kit.add_box(_p, Vector3(0.9, 0.62, 0.03), Vector3(0, RIM.y + 0.26, -2.6), Kit.mat(Color(0.95, 0.97, 1.0, 0.55), 0.1), Kit.LAYER_FURNITURE)
	Kit.add_box(_p, Vector3(0.34, 0.24, 0.005), Vector3(0, RIM.y + 0.16, -2.583), Kit.flat(orange))
	Kit.add_box(_p, Vector3(0.3, 0.2, 0.006), Vector3(0, RIM.y + 0.16, -2.582), Kit.mat(Color(0.95, 0.97, 1.0), 0.3))
	var rim := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = RIM_R - 0.008
	tm.outer_radius = RIM_R + 0.008
	tm.rings = 32
	rim.mesh = tm
	rim.material_override = Kit.mat(orange, 0.35, 0.5)
	rim.position = RIM
	_p.add_child(rim)
	var body := StaticBody3D.new()
	body.collision_layer = Kit.LAYER_FURNITURE
	body.position = RIM
	_p.add_child(body)
	for i in 14:
		var a := TAU * i / 14.0
		var cs := CollisionShape3D.new()
		var s := SphereShape3D.new()
		s.radius = 0.01
		cs.shape = s
		cs.position = Vector3(cos(a) * RIM_R, 0, sin(a) * RIM_R)
		body.add_child(cs)
	Kit.add_box(_p, Vector3(0.03, 0.02, 0.12), Vector3(0, RIM.y, -2.53), Kit.mat(orange, 0.35, 0.5))
	_net = Kit.add_cylinder(_p, 0.1, 0.26, RIM - Vector3(0, 0.13, 0), Kit.mat(Color(1, 1, 1, 0.45), 0.9), 0, RIM_R - 0.004, 14)
	# Marquee: title, score and clock.
	Kit.add_box(_p, Vector3(1.24, 0.55, 0.25), Vector3(0, 3.42, -2.65), black)
	Kit.add_box(_p, Vector3(1.16, 0.48, 0.01), Vector3(0, 3.42, -2.52), Kit.flat(Color(0.1, 0.03, 0.02)))
	var t := Kit.add_label(_p, "HOOP FEVER", 0.1, Vector3(0, 3.58, -2.51), 0.0, Color(1.0, 0.75, 0.3))
	t.outline_size = 16
	t.outline_modulate = Color(1.0, 0.3, 0.05, 0.5)
	_label = Kit.add_label(_p, "", 0.05, Vector3(-0.28, 3.37, -2.51), 0.0, Color(1.0, 0.9, 0.6))
	_clock = Kit.add_label(_p, "", 0.13, Vector3(0.33, 3.37, -2.51), 0.0, Color(1.0, 0.25, 0.15))
	_clock.outline_size = 12
	_clock.outline_modulate = Color(1.0, 0.1, 0.0, 0.3)
	var start := Button3D.new("Start  (45 s)", Vector2(0.26, 0.08), Color(0.2, 0.5, 0.3), _on_start)
	start.position = Vector3(0.0, 1.06, 0.33)
	start.rotation.x = -0.5
	_p.add_child(start)
	_horn = AK.player3d(_p, Vector3(0, 3.3, -2.4), AK.sfx("buzz"), -6.0)
	_swish = AK.player3d(_p, RIM, AK.sfx("coin"), -8.0)


func _slab(size: Vector3, pos: Vector3, tilt: float, m: Material) -> void:
	Kit.add_box(_p, size, pos, m, Kit.LAYER_FURNITURE, Vector3(tilt, 0, 0))


func _on_start() -> void:
	score = 0
	time_left = ROUND
	running = true
	player = main.player_name
	_horn.play()
	var pr: Node = main.modules["pr"]
	for b: Node in balls:
		pr.send_home(b)
	_send()


func _physics_process(delta: float) -> void:
	if balls.is_empty():
		return
	var me: int = main.me()
	var rim := _p.to_global(RIM)
	for b: Node in balls:
		var pos: Vector3 = b.global_position
		var prev: Vector3 = _last.get(b, pos)
		_last[b] = pos
		if b.owner_slot != me or b.hand != null:
			continue
		if prev.y >= rim.y and pos.y < rim.y:
			var k := (prev.y - rim.y) / maxf(prev.y - pos.y, 0.0001)
			var cross := prev.lerp(pos, k)
			if Vector2(cross.x - rim.x, cross.z - rim.z).length() < RIM_R - 0.02:
				_basket()


func _basket() -> void:
	_net_t = 1.0
	_swish.play()
	if running:
		score += 3 if time_left <= 10.0 else 2
		_send()


func _process(delta: float) -> void:
	if running:
		var before := ceili(time_left)
		time_left = maxf(time_left - delta, 0.0)
		if time_left <= 0.0:
			running = false
			_horn.play()
			if score > hi:
				hi = score
				hi_name = player
			_refresh()
		elif ceili(time_left) != before:
			_refresh()
	_net_t = maxf(_net_t - delta * 2.0, 0.0)
	_net.scale = Vector3(1.0, 1.0 + 0.3 * sin(_net_t * 25.0) * _net_t, 1.0)


func _send() -> void:
	_refresh()
	main.send({"t": "hs_s", "sc": score, "tl": snappedf(time_left, 0.1), "on": running, "pl": player, "hi": hi, "hn": hi_name})


func _refresh() -> void:
	_label.text = "%s\nSCORE %d\nHIGH %d %s" % [player if player != "" else "PRESS START", score, hi, hi_name]
	_clock.text = "%02d" % ceili(time_left) if running or time_left > 0.0 else "--"
	if running and time_left <= 10.0:
		_clock.modulate = Color(1.0, 0.85, 0.2)
	else:
		_clock.modulate = Color(1.0, 0.25, 0.15)


func handle(msg: Dictionary, _from: int) -> void:
	if str(msg.get("t", "")) in ["hs_s", "hs_full"]:
		var was := score
		score = int(msg.get("sc", 0))
		time_left = float(msg.get("tl", 0.0))
		running = bool(msg.get("on", false))
		player = str(msg.get("pl", ""))
		hi = int(msg.get("hi", 0))
		hi_name = str(msg.get("hn", ""))
		if score > was:
			_net_t = 1.0
			_swish.play()
		_refresh()


func full_state() -> Dictionary:
	return {"t": "hs_full", "sc": score, "tl": snappedf(time_left, 0.1), "on": running, "pl": player, "hi": hi, "hn": hi_name}


func on_identity_changed(_old_id: int, _new_id: int) -> void:
	pass


func on_peer_left(_slot: int) -> void:
	pass
