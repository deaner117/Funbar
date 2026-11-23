extends Node3D
## Furniture you can move: grab a chair anywhere with the grip and pull it out, slide it round
## and turn it; it stays where you leave it, upright on the floor. Whoever is moving a chair
## streams it ("fu_" messages); the last position is part of the full state for late joiners.

const Kit := preload("res://kit.gd")

const SEND_HZ := 15.0


class Chair extends Node3D:
	var game: Node
	var index := 0
	var hand: Node = null
	var remote := false
	var target := Transform3D.IDENTITY
	var grab_yaw := 0.0
	var start_yaw := 0.0
	var offset := Vector3.ZERO
	var send_in := 0.0

	func grab_distance(p: Vector3) -> float:
		var l := to_local(p)
		var q := Vector3(maxf(absf(l.x) - 0.24, 0.0), maxf(absf(l.y - 0.5) - 0.48, 0.0), maxf(absf(l.z) - 0.24, 0.0))
		return q.length() + 0.02

	func on_grab(h: Node) -> bool:
		return game.grab(self, h)

	func on_release(h: Node) -> void:
		game.let_go(self, h)


var main: Node
var chairs: Array[Chair] = []


static func _yaw_of(b: Basis) -> float:
	var f := -b.z
	return atan2(-f.x, -f.z)


## Builds the movable chairs: anchors is a list of [position, yaw, wood Material, seat Material].
func setup(list: Array) -> void:
	for i in list.size():
		var a: Array = list[i]
		var c := Chair.new()
		c.game = self
		c.index = i
		c.position = a[0]
		c.rotation.y = a[1]
		add_child(c)
		_build_chair(c, a[2], a[3])
		c.target = c.transform
		c.add_to_group("grabbable")
		chairs.append(c)


## A dining chair facing +z: turned legs with stretchers, a padded seat with piping, and a
## back of curved rails and spindles.
func _build_chair(p: Node3D, wood: Material, seat: Material) -> void:
	var leg := PackedVector2Array([Vector2(0, 0), Vector2(0.014, 0), Vector2(0.016, 0.012), Vector2(0.013, 0.05),
		Vector2(0.016, 0.16), Vector2(0.019, 0.3), Vector2(0.016, 0.33), Vector2(0.02, 0.35), Vector2(0.02, 0.43),
		Vector2(0, 0.43)])
	for sx: float in [-0.19, 0.19]:
		for sz: float in [-0.18, 0.18]:
			Kit.add_lathe(p, leg, Vector3(sx, 0, sz), wood, 10)
	# Stretchers between the legs.
	for sx: float in [-0.19, 0.19]:
		Kit.add_cylinder(p, 0.009, 0.36, Vector3(sx, 0.13, 0), wood, 0, -1.0, 6, Vector3(PI / 2, 0, 0))
	Kit.add_cylinder(p, 0.009, 0.38, Vector3(0, 0.1, 0), wood, 0, -1.0, 6, Vector3(0, 0, PI / 2))
	# Seat frame (apron), cushion and piping.
	Kit.add_rbox(p, Vector3(0.44, 0.06, 0.42), Vector3(0, 0.43, 0), wood, 0.012)
	Kit.add_rbox(p, Vector3(0.44, 0.07, 0.42), Vector3(0, 0.49, 0.005), seat, 0.03)
	Kit.add_rbox(p, Vector3(0.45, 0.012, 0.43), Vector3(0, 0.46, 0.005), wood, 0.005)
	# Back: two tall back posts, a curved top rail, a lower rail and spindles.
	for sx: float in [-0.19, 0.19]:
		Kit.add_rbox(p, Vector3(0.036, 0.52, 0.036), Vector3(sx, 0.71, -0.19), wood, 0.012, 0, Vector3(-0.08, 0, 0))
		Kit.add_sphere(p, 0.022, Vector3(sx, 0.98, -0.21), wood, 0, 10)
	Kit.add_rbox(p, Vector3(0.42, 0.09, 0.035), Vector3(0, 0.91, -0.205), wood, 0.016, 0, Vector3(-0.08, 0, 0))
	Kit.add_rbox(p, Vector3(0.38, 0.035, 0.03), Vector3(0, 0.6, -0.185), wood, 0.01, 0, Vector3(-0.08, 0, 0))
	for k in 4:
		Kit.add_cylinder(p, 0.008, 0.27, Vector3(-0.105 + k * 0.07, 0.745, -0.195), wood, 0, -1.0, 6, Vector3(-0.08, 0, 0))
	# Collider so balls and thrown things bounce off it.
	var b := StaticBody3D.new()
	b.collision_layer = Kit.LAYER_FURNITURE
	b.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.44, 0.5, 0.42)
	cs.shape = shape
	cs.position = Vector3(0, 0.25, 0)
	b.add_child(cs)
	p.add_child(b)
	Kit.merge_static(p, [], func(_q: Vector3) -> String: return "chair")


func grab(c: Chair, hand: Node) -> bool:
	if c.remote:
		return false
	if c.hand != null and c.hand != hand:
		c.hand.held = null
	c.hand = hand
	var hp: Vector3 = hand.grab_point()
	c.grab_yaw = _yaw_of(hand.global_transform.basis)
	c.start_yaw = c.rotation.y
	c.offset = c.global_position - Vector3(hp.x, 0, hp.z)
	c.send_in = 0.0
	return true


func let_go(c: Chair, hand: Node) -> void:
	if c.hand != hand:
		return
	c.hand = null
	_send(c, false)


func _send(c: Chair, held: bool) -> void:
	main.send({"t": "fu_c", "i": c.index, "x": snappedf(c.position.x, 0.001), "z": snappedf(c.position.z, 0.001),
		"y": snappedf(c.rotation.y, 0.001), "h": held})


func _process(delta: float) -> void:
	for c in chairs:
		if c.hand != null:
			var hp: Vector3 = c.hand.grab_point()
			var d := wrapf(_yaw_of(c.hand.global_transform.basis) - c.grab_yaw, -PI, PI)
			var p := Vector3(hp.x, 0, hp.z) + c.offset.rotated(Vector3.UP, d)
			c.global_position = Vector3(p.x, 0.0, p.z)
			c.rotation.y = c.start_yaw + d
			c.send_in -= delta
			if c.send_in <= 0.0 and main.has_friends():
				c.send_in = 1.0 / SEND_HZ
				_send(c, true)
		elif c.remote or not c.transform.is_equal_approx(c.target):
			c.transform = c.transform.interpolate_with(c.target, 1.0 - exp(-15.0 * delta))
			if not c.remote and c.transform.origin.distance_to(c.target.origin) < 0.001:
				c.transform = c.target
		if c.hand != null:
			c.target = c.transform


func handle(msg: Dictionary, _from: int) -> void:
	match str(msg.get("t", "")):
		"fu_c":
			var i := int(msg.get("i", -1))
			if i < 0 or i >= chairs.size():
				return
			var c := chairs[i]
			if c.hand != null:
				c.hand.held = null
				c.hand = null
			c.remote = bool(msg.get("h", false))
			c.target = Transform3D(Basis(Vector3.UP, float(msg.get("y", 0.0))), Vector3(float(msg.get("x", 0.0)), 0, float(msg.get("z", 0.0))))
		"fu_full":
			var list: Array = msg.get("c", [])
			for i in mini(list.size(), chairs.size()):
				var e: Array = list[i]
				chairs[i].target = Transform3D(Basis(Vector3.UP, float(e[2])), Vector3(float(e[0]), 0, float(e[1])))
				chairs[i].remote = false


func full_state() -> Dictionary:
	var list := []
	for c in chairs:
		list.append([snappedf(c.position.x, 0.001), snappedf(c.position.z, 0.001), snappedf(c.rotation.y, 0.001)])
	return {"t": "fu_full", "c": list}


func on_identity_changed(_old_id: int, _new_id: int) -> void:
	pass


func on_peer_left(_slot: int) -> void:
	for c in chairs:
		c.remote = false
