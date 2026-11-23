extends Node3D
## Basketball in the gym: a hoop on the east wall, a rack of balls, and a scoreboard of baskets
## per player. Each ball is simulated by its owner (whoever last grabbed it; the host for balls
## nobody has touched) and streamed to everyone else, who show it kinematically.
## The owner also judges baskets: the ball's centre dropping through the rim.

const Kit := preload("res://kit.gd")
const Button3D := preload("res://button3d.gd")

const BALLS := 4
const BALL_R := 0.12
const RIM_R := 0.23
const RIM_Y := 2.9          # a little under regulation (3.05 m), friendlier in VR
const RIM_OUT := 0.15 + RIM_R   # rim centre in front of the backboard
const SEND_HZ := 20.0
const THROW_BOOST := 1.05


class Ball extends RigidBody3D:
	var game: Node
	var index := 0
	var owner_slot := 0
	var hand: Node = null          # local hand holding it
	var remote_held := false
	var thrower := -1
	var target := Transform3D.IDENTITY
	var target_v := Vector3.ZERO
	var last_pos := Vector3.ZERO
	var send_in := 0.0
	var moving_for := 0.0

	func grab_distance(p: Vector3) -> float:
		return global_position.distance_to(p) - BALL_R

	func on_grab(h: Node) -> bool:
		return game.grab_ball(self, h)

	func on_release(h: Node) -> void:
		game.release_ball(self, h)


var main: Node
var balls: Array[Ball] = []
## slot -> baskets
var scores := {}
var rack_spots: Array[Vector3] = []
var hoop: Node3D

var _rim_center := Vector3.ZERO
var _board: Label3D
var _net_mesh: Node3D
var _swish := 0.0


func setup(hoop_anchor: Array, rack_anchor: Array) -> void:
	hoop = Node3D.new()
	hoop.position = hoop_anchor[0]
	hoop.rotation.y = hoop_anchor[1]
	add_child(hoop)
	_build_hoop()
	var rack := Node3D.new()
	rack.position = rack_anchor[0]
	rack.rotation.y = rack_anchor[1]
	add_child(rack)
	_build_rack(rack)
	_rim_center = hoop.to_global(Vector3(0, RIM_Y, RIM_OUT))
	var physics_mat := PhysicsMaterial.new()
	physics_mat.bounce = 0.72
	physics_mat.friction = 0.7
	var ball_mat := Kit.mat(Color(0.93, 0.45, 0.13), 0.7)
	var seam := Kit.mat(Color(0.1, 0.08, 0.06), 0.8)
	for i in BALLS:
		var b := Ball.new()
		b.game = self
		b.index = i
		b.mass = 0.6
		b.physics_material_override = physics_mat
		b.continuous_cd = true
		b.collision_layer = Kit.LAYER_BALL
		b.collision_mask = Kit.LAYER_STRUCTURE | Kit.LAYER_FURNITURE | Kit.LAYER_BALL
		b.linear_damp = 0.05
		b.angular_damp = 0.3
		b.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		var cs := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = BALL_R
		cs.shape = shape
		b.add_child(cs)
		var mi := MeshInstance3D.new()
		mi.mesh = Kit.sphere_mesh(BALL_R, 20)
		mi.material_override = ball_mat
		b.add_child(mi)
		for r in 2:   # two seam rings
			var ring := MeshInstance3D.new()
			var tm := TorusMesh.new()
			tm.inner_radius = BALL_R - 0.002
			tm.outer_radius = BALL_R + 0.003
			tm.rings = 24
			tm.ring_segments = 4
			ring.mesh = tm
			ring.material_override = seam
			ring.rotation = Vector3(PI / 2, 0, 0) if r == 0 else Vector3(0, 0, PI / 2)
			b.add_child(ring)
		b.add_to_group("grabbable")
		add_child(b)
		b.global_position = rack_spots[i]
		b.last_pos = rack_spots[i]
		b.target = b.global_transform
		balls.append(b)
	_apply_ownership()
	_refresh_board()


func _build_hoop() -> void:
	var white := Kit.mat(Color(0.97, 0.97, 0.97), 0.4)
	var red := Kit.mat(Color(0.9, 0.25, 0.1), 0.35, 0.5)
	var steel := Kit.mat(Color(0.5, 0.52, 0.55), 0.4, 0.8)
	# Wall bracket and backboard (its face is the local z = 0.0 plane... set a little out).
	Kit.add_box(hoop, Vector3(0.12, 0.12, 0.15), Vector3(0, RIM_Y + 0.3, -0.05), steel)
	Kit.add_box(hoop, Vector3(1.8, 1.05, 0.05), Vector3(0, RIM_Y + 0.45, 0.025), white, Kit.LAYER_FURNITURE)
	Kit.add_box(hoop, Vector3(0.59, 0.45, 0.01), Vector3(0, RIM_Y + 0.2, 0.055), Kit.flat(Color(0.9, 0.25, 0.1)))
	Kit.add_box(hoop, Vector3(0.53, 0.39, 0.012), Vector3(0, RIM_Y + 0.2, 0.056), white)
	# Rim: a visible ring plus small spheres for collisions.
	var rim := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = RIM_R - 0.01
	tm.outer_radius = RIM_R + 0.01
	tm.rings = 32
	tm.ring_segments = 8
	rim.mesh = tm
	rim.material_override = red
	rim.position = Vector3(0, RIM_Y, RIM_OUT)
	hoop.add_child(rim)
	var body := StaticBody3D.new()
	body.collision_layer = Kit.LAYER_FURNITURE
	body.collision_mask = 0
	body.position = Vector3(0, RIM_Y, RIM_OUT)
	hoop.add_child(body)
	for i in 16:
		var a := TAU * i / 16.0
		var cs := CollisionShape3D.new()
		var s := SphereShape3D.new()
		s.radius = 0.012
		cs.shape = s
		cs.position = Vector3(cos(a) * RIM_R, 0, sin(a) * RIM_R)
		body.add_child(cs)
	Kit.add_box(hoop, Vector3(0.04, 0.02, 0.16), Vector3(0, RIM_Y, 0.11), red)
	# Net (just for looks).
	_net_mesh = Kit.add_cylinder(hoop, 0.15, 0.42, Vector3(0, RIM_Y - 0.21, RIM_OUT), Kit.mat(Color(1, 1, 1, 0.45), 0.9), 0, RIM_R - 0.005, 16)
	# Scoreboard above the backboard.
	_board = Kit.add_label(hoop, "", 0.16, Vector3(0, RIM_Y + 1.4, 0.06), 0.0, Color(1, 0.95, 0.8))
	_board.outline_size = 12
	_board.outline_modulate = Color(0, 0, 0, 0.8)
	_board.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM


func _build_rack(rack: Node3D) -> void:
	var steel := Kit.mat(Color(0.25, 0.27, 0.3), 0.4, 0.8)
	Kit.add_box(rack, Vector3(1.4, 0.04, 0.4), Vector3(0, 0.88, 0), steel, Kit.LAYER_FURNITURE)
	for sx: float in [-0.68, 0.68]:
		Kit.add_box(rack, Vector3(0.04, 0.9, 0.4), Vector3(sx, 0.45, 0), steel, Kit.LAYER_FURNITURE)
	# Little lips so the balls stay put.
	for sz: float in [-0.19, 0.19]:
		Kit.add_box(rack, Vector3(1.4, 0.06, 0.02), Vector3(0, 0.93, sz), steel, Kit.LAYER_FURNITURE)
	rack_spots.clear()
	for i in BALLS:
		rack_spots.append(rack.to_global(Vector3(-0.48 + i * 0.32, 0.9 + BALL_R + 0.01, 0)))
	var b := Button3D.new("Return balls", Vector2(0.26, 0.07), Color(0.2, 0.4, 0.6), _on_return)
	b.position = Vector3(-0.18, 1.25, 0.0)
	b.rotation.x = -0.4
	rack.add_child(b)
	var r := Button3D.new("Reset scores", Vector2(0.26, 0.07), Color(0.55, 0.3, 0.2), _on_reset_scores)
	r.position = Vector3(0.18, 1.25, 0.0)
	r.rotation.x = -0.4
	rack.add_child(r)
	Kit.add_label(rack, "BASKETBALL - grab a ball with the grip, throw and let go", 0.045, Vector3(0, 1.45, 0), 0.0, Color(0.95, 0.95, 1.0))


# ---------------------------------------------------------------- ownership

func _apply_ownership() -> void:
	var me: int = main.me()
	for b in balls:
		var mine := b.owner_slot == me
		if b.hand != null:
			b.freeze = true
		else:
			b.freeze = not mine
		if not mine:
			b.target = b.global_transform


func grab_ball(b: Ball, hand: Node) -> bool:
	var me: int = main.me()
	if b.remote_held and b.owner_slot != me:
		return false
	if b.hand != null and b.hand != hand:
		b.hand.held = null
	b.hand = hand
	b.owner_slot = me
	b.remote_held = false
	b.freeze = true
	b.send_in = 0.0
	_send_ball(b)
	return true


func release_ball(b: Ball, hand: Node) -> void:
	if b.hand != hand:
		return
	b.hand = null
	b.freeze = false
	b.thrower = main.me()
	var v: Vector3 = hand.velocity * THROW_BOOST
	b.linear_velocity = v.limit_length(14.0)
	b.angular_velocity = Vector3(randf_range(-2, 2), randf_range(-2, 2), randf_range(-2, 2))
	b.moving_for = 0.0
	_send_ball(b)


func _send_ball(b: Ball) -> void:
	main.send({"t": "bb_b", "i": b.index, "p": Kit.pack_tf(b.global_transform), "v": Kit.pack_v3(b.linear_velocity),
		"held": b.hand != null, "th": b.thrower})


# ---------------------------------------------------------------- simulation

func _physics_process(delta: float) -> void:
	var me: int = main.me()
	for b in balls:
		var prev := b.last_pos
		if b.hand != null:
			var t: Transform3D = b.hand.global_transform
			b.global_transform = Transform3D(t.basis, b.hand.grab_point() + t.basis * Vector3(0, -0.02, -0.06))
		elif b.owner_slot != me:
			# Someone else's: glide toward their latest update (extrapolated a little).
			b.target.origin += b.target_v * delta if not b.remote_held else Vector3.ZERO
			b.global_transform = b.global_transform.interpolate_with(b.target, 1.0 - exp(-20.0 * delta))
		var pos := b.global_position
		b.last_pos = pos
		if b.owner_slot != me:
			continue
		# Ours: judge baskets, rescue lost balls, and stream while it moves.
		if b.hand == null and prev.y >= _rim_center.y and pos.y < _rim_center.y:
			var k := (prev.y - _rim_center.y) / maxf(prev.y - pos.y, 0.0001)
			var cross := prev.lerp(pos, k)
			if Vector2(cross.x - _rim_center.x, cross.z - _rim_center.z).length() < RIM_R - 0.03:
				_score(b.thrower if b.thrower >= 0 else me)
		if pos.y < -2.0 or pos.distance_to(_rim_center) > 60.0:
			_put_on_rack(b)
		var moving := b.hand != null or (not b.freeze and b.linear_velocity.length() > 0.03)
		b.moving_for = 0.0 if moving else b.moving_for + delta
		b.send_in -= delta
		if b.send_in <= 0.0 and b.moving_for < 0.4 and main.has_friends():
			b.send_in = 1.0 / SEND_HZ
			_send_ball(b)
	_swish = maxf(_swish - delta, 0.0)
	_net_mesh.scale = Vector3(1.0, 1.0 + 0.25 * sin(_swish * 30.0) * _swish, 1.0)


## Gravity for the balls as a fraction of Earth's (set by the gym's gravity panel).
func set_gravity(k: float) -> void:
	for b in balls:
		b.gravity_scale = k
		b.linear_damp = 0.05 if k > 0.05 else 0.25   # in "space" they drift to a stop
		b.sleeping = false


func _put_on_rack(b: Ball) -> void:
	b.global_transform = Transform3D(Basis.IDENTITY, rack_spots[b.index])
	b.linear_velocity = Vector3.ZERO
	b.angular_velocity = Vector3.ZERO
	b.moving_for = 0.0
	b.send_in = 0.0
	_send_ball(b)


func _score(slot: int) -> void:
	scores[slot] = int(scores.get(slot, 0)) + 1
	_swish = 1.0
	_refresh_board()
	main.send({"t": "bb_score", "slot": slot, "n": scores[slot]})


func _on_return() -> void:
	var me: int = main.me()
	for b in balls:
		if b.hand != null or (b.remote_held and b.owner_slot != me):
			continue
		b.owner_slot = me
		b.remote_held = false
		b.freeze = false
		_put_on_rack(b)


func _on_reset_scores() -> void:
	scores.clear()
	_refresh_board()
	main.send({"t": "bb_reset"})


func _refresh_board() -> void:
	var lines := PackedStringArray(["BASKETS"])
	var me: int = main.me()
	var slots: Array = scores.keys()
	if not slots.has(me):
		slots.append(me)
	slots.sort()
	for s: int in slots:
		lines.append("%s  %d" % [main.name_of(s), int(scores.get(s, 0))])
	_board.text = "\n".join(lines)


# ---------------------------------------------------------------- network

func handle(msg: Dictionary, from: int) -> void:
	match str(msg.get("t", "")):
		"bb_b":
			var i := int(msg.get("i", -1))
			if i < 0 or i >= BALLS:
				return
			var b := balls[i]
			if b.hand != null:
				if from < main.me():   # grabbed at the same moment: lower slot keeps it
					b.hand.held = null
					b.hand = null
				else:
					return
			b.owner_slot = from
			b.remote_held = bool(msg.get("held", false))
			b.thrower = int(msg.get("th", -1))
			b.target = Kit.unpack_tf(msg.get("p"), b.global_transform)
			b.target_v = Kit.unpack_v3(msg.get("v"))
			b.freeze = true
		"bb_score":
			scores[int(msg.get("slot", from))] = int(msg.get("n", 0))
			_swish = 1.0
			_refresh_board()
		"bb_reset":
			scores.clear()
			_refresh_board()
		"bb_full":
			var s: Dictionary = msg.get("scores", {})
			scores.clear()
			for k: Variant in s:
				scores[int(k)] = int(s[k])
			var list: Array = msg.get("balls", [])
			for i in mini(list.size(), BALLS):
				var e: Array = list[i]
				var b := balls[i]
				if b.hand != null:
					continue
				b.owner_slot = int(e[0])
				b.remote_held = bool(e[2])
				b.target = Kit.unpack_tf(e[1], b.global_transform)
				b.global_transform = b.target
				b.target_v = Vector3.ZERO
			_apply_ownership()
			_refresh_board()


func full_state() -> Dictionary:
	var list := []
	for b in balls:
		list.append([b.owner_slot, Kit.pack_tf(b.global_transform), b.hand != null or b.remote_held])
	var s := {}
	for k: int in scores:
		s[str(k)] = scores[k]
	return {"t": "bb_full", "scores": s, "balls": list}


func on_identity_changed(old_id: int, new_id: int) -> void:
	for b in balls:
		if b.hand != null or b.owner_slot == old_id:
			b.owner_slot = new_id
		else:
			b.owner_slot = main.host_slot()
		b.remote_held = false
	if scores.has(old_id) and old_id != new_id:
		scores[new_id] = scores[old_id]
		scores.erase(old_id)
	_apply_ownership()
	_refresh_board()


func on_peer_left(slot: int) -> void:
	var host: int = main.host_slot()
	for b in balls:
		if b.owner_slot == slot:
			b.owner_slot = host
			b.remote_held = false
	scores.erase(slot)
	_apply_ownership()
	_refresh_board()


func on_roster_changed() -> void:
	_refresh_board()
