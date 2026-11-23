extends Node3D
## Things to pick up, throw and play with, plus the fixtures they live on:
##   cake (hall coffee table)        throw it hard and it splats; a fresh one appears
##   drinks (cooler on the patio)    bring one to your mouth: cheers
##   meat (BBQ grill)                on the grill it cooks: raw, browned, then charred
##   logs (woodpile by the fire pit) drop one in a fire and it burns away, the fire roars
##   marshmallows on sticks          hold in the fire to toast; too long and it catches fire
##                                   (shake it out); bring it to your mouth to eat it
##   cornhole bags (lawn)            through the hole scores
##
## Like the basketballs, each prop is simulated by whoever last grabbed it (the host for ones
## nobody has touched) and streamed to everyone else. That owner also decides events (burnt,
## splat, caught fire, eaten, scored) and sends them. Cooking is worked out by everyone from
## where things are, and synced whenever the prop moves.

const Kit := preload("res://kit.gd")
const Fire := preload("res://fire.gd")
const Button3D := preload("res://button3d.gd")

const SEND_HZ := 20.0
const THROW_BOOST := 1.05
const STICK_L := 0.9
const LOG_L := 0.45
const RAW := {"patty": Color(0.74, 0.34, 0.34), "sausage": Color(0.86, 0.56, 0.5), "steak": Color(0.66, 0.2, 0.22)}
const COOKED := Color(0.42, 0.24, 0.12)
const CHARRED := Color(0.09, 0.06, 0.05)
const CAN_COLORS := [Color(0.75, 0.08, 0.1), Color(0.15, 0.6, 0.25), Color(0.12, 0.35, 0.8), Color(0.95, 0.55, 0.1),
	Color(0.9, 0.85, 0.2), Color(0.55, 0.2, 0.6)]


class Prop extends RigidBody3D:
	var game: Node
	var index := 0
	var kind := ""
	var home := Transform3D.IDENTITY
	var owner_slot := 0
	var hand: Node = null
	var hold := Transform3D.IDENTITY
	var remote_held := false
	var target := Transform3D.IDENTITY
	var target_v := Vector3.ZERO
	var send_in := 0.0
	var moving_for := 0.0
	var reach := 0.08
	var touched := false
	var cook := 0.0
	var shown_cook := -1.0
	var cook_mat: StandardMaterial3D
	var marks: Node3D
	var on_fire := false
	var flame: GPUParticles3D
	var hot_for := 0.0
	var gone_until := 0.0
	var in_fire_for := 0.0
	var last_speed := 0.0
	var scored := true
	var cheers_at := 0.0

	func grab_distance(p: Vector3) -> float:
		if gone_until > 0.0:
			return INF
		if kind == "marsh" or kind == "log":
			var half := (STICK_L if kind == "marsh" else LOG_L) / 2.0
			var c := Geometry3D.get_closest_point_to_segment(p, to_global(Vector3(0, 0, -half)), to_global(Vector3(0, 0, half)))
			return c.distance_to(p) - 0.04
		return global_position.distance_to(p) - reach

	func on_grab(h: Node) -> bool:
		return game.grab(self, h)

	func on_release(h: Node) -> void:
		game.let_go(self, h)

	## Where a marshmallow is, on the end of its stick.
	func tip() -> Vector3:
		return to_global(Vector3(0, 0, -STICK_L / 2.0 + 0.03))


class Grill extends Node3D:
	## The BBQ's cooking surface as a heat source: hot just above the grate.
	var half := Vector2(0.36, 0.2)

	func _ready() -> void:
		add_to_group("heat")

	func heat_at(p: Vector3) -> float:
		var l := to_local(p)
		if absf(l.x) > half.x or absf(l.z) > half.y or l.y < -0.03 or l.y > 0.16:
			return 0.0
		return 1.0


var main: Node
var props: Array[Prop] = []

var _boards: Array[Node3D] = []
var _sizzle: AudioStreamPlayer3D
var _grill: Grill
var _shapes := {}


## anchors: the mansion's anchor dictionary (cake, bbq, cooler, woodpile, marsh_stand,
## cornhole_a, cornhole_b, pool).
func setup(anchors: Dictionary) -> void:
	var specs: Array = []   # [kind, home Transform3D, extra]
	var cake: Array = anchors["cake"]
	specs.append(["cake", Transform3D(Basis(Vector3.UP, cake[1]), cake[0]), null])
	# The fixtures are all outdoors, lit by the sun.
	var layers_before := Kit.vis_layers
	Kit.vis_layers = Kit.VIS_OUTDOOR
	specs += _build_bbq(_pivot(anchors["bbq"]))
	specs += _build_cooler(_pivot(anchors["cooler"]))
	specs += _build_woodpile(_pivot(anchors["woodpile"]))
	specs += _build_marsh_stand(_pivot(anchors["marsh_stand"]))
	specs += _build_cornhole(_pivot(anchors["cornhole_a"]), Color(0.78, 0.12, 0.12))
	specs += _build_cornhole(_pivot(anchors["cornhole_b"]), Color(0.12, 0.3, 0.75))
	Kit.vis_layers = layers_before
	# Merge the fixtures' meshes (before the props exist, so those stay separate).
	Kit.merge_static(self, [], func(_p: Vector3) -> String: return "out")
	for s: Array in specs:
		_make(s[0], s[1], s[2])
	_sizzle = AudioStreamPlayer3D.new()
	_sizzle.stream = Fire.crackle_stream()
	_sizzle.pitch_scale = 2.6
	_sizzle.unit_size = 1.5
	_sizzle.max_distance = 12.0
	_sizzle.volume_db = -60.0
	_grill.add_child(_sizzle)
	_apply_ownership()


func _pivot(a: Array) -> Node3D:
	var n := Node3D.new()
	n.position = a[0]
	n.rotation.y = a[1]
	add_child(n)
	return n


# ---------------------------------------------------------------- fixtures

func _build_bbq(p: Node3D) -> Array:
	var body := Kit.mat(Color(0.1, 0.1, 0.11), 0.45, 0.5)
	var steel := Kit.mat(Color(0.72, 0.72, 0.74), 0.3, 0.9)
	var black := Kit.mat(Color(0.04, 0.04, 0.04), 0.6)
	# Cart with doors, wheels and side shelves.
	Kit.add_rbox(p, Vector3(0.9, 0.6, 0.5), Vector3(0, 0.45, 0), body, 0.03, Kit.LAYER_FURNITURE)
	for sx: float in [-0.2, 0.2]:
		Kit.add_rbox(p, Vector3(0.38, 0.5, 0.02), Vector3(sx, 0.45, 0.255), Kit.mat(Color(0.16, 0.16, 0.17), 0.4, 0.5), 0.008)
		Kit.add_cylinder(p, 0.008, 0.22, Vector3(sx * 0.35, 0.5, 0.28), steel, 0, -1.0, 8)
	for sx: float in [-0.38, 0.38]:
		for sz: float in [-0.18, 0.18]:
			Kit.add_cylinder(p, 0.06, 0.04, Vector3(sx, 0.06, sz), black, 0, -1.0, 14, Vector3(0, 0, PI / 2))
	for sx: float in [-0.62, 0.62]:
		Kit.add_rbox(p, Vector3(0.32, 0.03, 0.46), Vector3(sx, 0.9, 0), steel, 0.01, Kit.LAYER_FURNITURE)
	# Firebox, glowing burners, grate (collides, so food sits on it).
	Kit.add_rbox(p, Vector3(0.84, 0.18, 0.48), Vector3(0, 0.84, 0), steel, 0.02)
	Kit.add_box(p, Vector3(0.74, 0.01, 0.4), Vector3(0, 0.915, 0), Kit.mat(Color(0.05, 0.04, 0.04)))
	for i in 3:
		Kit.add_box(p, Vector3(0.66, 0.012, 0.03), Vector3(0, 0.922, -0.12 + i * 0.12), Kit.mat(Color(1.0, 0.32, 0.06), 0.9, 0.0, 3.0))
	var bars: Array = []
	for i in 11:
		var z := -0.19 + i * 0.038
		bars.append(PackedVector3Array([Vector3(-0.37, 0.94, z), Vector3(0.37, 0.94, z)]))
	var grate := MeshInstance3D.new()
	grate.mesh = Kit.tube_mesh(bars, 0.005, 4)
	grate.material_override = Kit.mat(Color(0.18, 0.18, 0.18), 0.5, 0.7)
	grate.layers = Kit.vis_layers
	p.add_child(grate)
	var gb := StaticBody3D.new()
	gb.collision_layer = Kit.LAYER_FURNITURE
	gb.collision_mask = 0
	var gcs := CollisionShape3D.new()
	var gshape := BoxShape3D.new()
	gshape.size = Vector3(0.76, 0.02, 0.42)
	gcs.shape = gshape
	gcs.position = Vector3(0, 0.935, 0)
	gb.add_child(gcs)
	p.add_child(gb)
	# Open lid behind, with a handle; control knobs on the front.
	Kit.add_rbox(p, Vector3(0.84, 0.46, 0.05), Vector3(0, 1.17, -0.27), steel, 0.02, 0, Vector3(-0.2, 0, 0))
	var handle := MeshInstance3D.new()
	handle.mesh = Kit.tube_mesh([PackedVector3Array([Vector3(-0.25, 1.38, -0.28), Vector3(-0.25, 1.40, -0.36),
		Vector3(0.25, 1.40, -0.36), Vector3(0.25, 1.38, -0.28)])], 0.009, 6)
	handle.material_override = steel
	handle.layers = Kit.vis_layers
	p.add_child(handle)
	for i in 3:
		Kit.add_cylinder(p, 0.025, 0.03, Vector3(-0.22 + i * 0.22, 0.82, 0.255), black, 0, -1.0, 12, Vector3(PI / 2, 0, 0))
	_grill = Grill.new()
	_grill.position = Vector3(0, 0.945, 0)
	p.add_child(_grill)
	# A platter of meat on the right shelf, and a couple of patties already on.
	Kit.add_cylinder(p, 0.15, 0.012, Vector3(0.62, 0.921, 0), Kit.mat(Color(0.95, 0.95, 0.93), 0.3), 0, -1.0, 20)
	var specs: Array = []
	var shelf := Vector3(0.62, 0.94, 0)
	specs.append(["patty", p.transform * Transform3D(Basis.IDENTITY, shelf + Vector3(-0.05, 0, -0.06)), null])
	specs.append(["patty", p.transform * Transform3D(Basis.IDENTITY, shelf + Vector3(0.06, 0, -0.05)), null])
	specs.append(["sausage", p.transform * Transform3D(Basis(Vector3.UP, 0.2), shelf + Vector3(0, 0.005, 0.05)), null])
	specs.append(["sausage", p.transform * Transform3D(Basis(Vector3.UP, 0.1), shelf + Vector3(0.0, 0.005, 0.1)), null])
	specs.append(["steak", p.transform * Transform3D(Basis(Vector3.UP, -0.3), Vector3(-0.62, 0.94, 0.0)), null])
	specs.append(["patty", p.transform * Transform3D(Basis.IDENTITY, Vector3(-0.14, 0.965, -0.02)), null])
	specs.append(["patty", p.transform * Transform3D(Basis.IDENTITY, Vector3(0.1, 0.965, 0.04)), null])
	specs.append(["sausage", p.transform * Transform3D(Basis(Vector3.UP, 1.5), Vector3(0.28, 0.965, -0.05)), null])
	Kit.add_label(p, "BBQ - grab the meat, put it on the grill", 0.035, Vector3(0, 0.7, 0.27), 0.0, Color(1, 0.9, 0.7))
	return specs


func _build_cooler(p: Node3D) -> Array:
	var shell := Kit.mat(Color(0.16, 0.42, 0.72), 0.5)
	var white := Kit.mat(Color(0.95, 0.95, 0.93), 0.5)
	var w := 0.62
	var d := 0.4
	var h := 0.4
	Kit.add_rbox(p, Vector3(w, 0.04, d), Vector3(0, 0.04, 0), shell, 0.015, Kit.LAYER_FURNITURE)
	for sz: float in [-1.0, 1.0]:
		Kit.add_rbox(p, Vector3(w, h, 0.04), Vector3(0, h / 2.0 + 0.02, sz * (d / 2.0 - 0.02)), shell, 0.015, Kit.LAYER_FURNITURE)
	for sx: float in [-1.0, 1.0]:
		Kit.add_rbox(p, Vector3(0.04, h, d), Vector3(sx * (w / 2.0 - 0.02), h / 2.0 + 0.02, 0), shell, 0.015, Kit.LAYER_FURNITURE)
		Kit.add_rbox(p, Vector3(0.04, 0.03, 0.16), Vector3(sx * (w / 2.0 + 0.01), h - 0.04, 0), white, 0.01)
	# Open lid leaning back, and ice.
	Kit.add_rbox(p, Vector3(w + 0.02, 0.05, d), Vector3(0, h + 0.17, -d / 2.0 - 0.04), white, 0.02, 0, Vector3(-1.35, 0, 0))
	Kit.add_box(p, Vector3(w - 0.08, 0.2, d - 0.08), Vector3(0, 0.16, 0), Kit.tmat(Color(0.85, 0.93, 0.98), "plaster", 6.0, 0.15), Kit.LAYER_FURNITURE)
	var specs: Array = []
	for i in 6:
		var x := -0.18 + (i % 3) * 0.18
		var z := -0.08 + (i / 3) * 0.16
		specs.append(["can", p.transform * Transform3D(Basis.IDENTITY, Vector3(x, 0.325, z)), CAN_COLORS[i]])
	var b := Button3D.new("Tidy up", Vector2(0.2, 0.065), Color(0.3, 0.45, 0.35), _on_tidy)
	b.position = Vector3(0, 0.32, d / 2.0 + 0.005)
	p.add_child(b)
	Kit.add_label(p, "DRINKS", 0.05, Vector3(0, 0.22, d / 2.0 + 0.005), 0.0, Color(1, 1, 1))
	return specs


func _build_woodpile(p: Node3D) -> Array:
	var wood := Kit.tmat(Color(0.36, 0.24, 0.15), "grain", 2.0, 0.8)
	Kit.add_rbox(p, Vector3(1.1, 0.06, 0.08), Vector3(0, 0.12, -0.12), wood, 0.01, Kit.LAYER_FURNITURE)
	Kit.add_rbox(p, Vector3(1.1, 0.06, 0.08), Vector3(0, 0.12, 0.12), wood, 0.01, Kit.LAYER_FURNITURE)
	for sx: float in [-0.55, 0.55]:
		Kit.add_rbox(p, Vector3(0.06, 0.7, 0.06), Vector3(sx, 0.35, -0.12), wood, 0.01, Kit.LAYER_FURNITURE)
		Kit.add_rbox(p, Vector3(0.06, 0.7, 0.06), Vector3(sx, 0.35, 0.12), wood, 0.01, Kit.LAYER_FURNITURE)
	var specs: Array = []
	var along := Basis(Vector3.UP, PI / 2)   # logs lie along the rack (local z of a log = rack x)
	for i in 7:
		var row := 0 if i < 4 else 1
		var col := i if row == 0 else i - 4
		var x := 0.0
		var y := 0.21 + row * 0.1
		var z := -0.165 + col * 0.11 if row == 0 else -0.11 + col * 0.11
		specs.append(["log", p.transform * Transform3D(along, Vector3(x, y, z)), null])
	Kit.add_label(p, "FIREWOOD - throw a log on the fire", 0.035, Vector3(0, 0.82, 0), 0.0, Color(1, 0.9, 0.7))
	return specs


func _build_marsh_stand(p: Node3D) -> Array:
	var wood := Kit.tmat(Color(0.45, 0.3, 0.18), "grain", 2.0, 0.7)
	Kit.add_rbox(p, Vector3(0.5, 0.03, 0.36), Vector3(0, 0.6, 0), wood, 0.01, Kit.LAYER_FURNITURE)
	for sx: float in [-0.21, 0.21]:
		for sz: float in [-0.14, 0.14]:
			Kit.add_cylinder(p, 0.018, 0.59, Vector3(sx, 0.295, sz), wood, 0, 0.014, 8)
	# A bag of marshmallows.
	Kit.add_rbox(p, Vector3(0.14, 0.18, 0.07), Vector3(0.15, 0.705, -0.08), Kit.mat(Color(0.95, 0.96, 1.0), 0.4), 0.025)
	Kit.add_label(p, "MARSHMALLOWS", 0.016, Vector3(0.15, 0.72, -0.044), 0.0, Color(0.2, 0.35, 0.8))
	var specs: Array = []
	for i in 3:
		specs.append(["marsh", p.transform * Transform3D(Basis.IDENTITY, Vector3(-0.15 + i * 0.1, 0.636, 0.05)), null])
	Kit.add_label(p, "Roast a marshmallow: hold it near the flames,\nthen bring it to your mouth", 0.025, Vector3(0, 0.75, 0.19), 0.0, Color(1, 0.95, 0.8))
	return specs


func _build_cornhole(p: Node3D, bag_color: Color) -> Array:
	var wood := Kit.tmat(Color(0.82, 0.68, 0.48), "grain", 1.5, 0.7)
	var board := Node3D.new()
	board.position = Vector3(0, 0.19, 0)
	board.rotation.x = atan2(0.22, 1.2)
	p.add_child(board)
	Kit.add_rbox(board, Vector3(0.6, 0.025, 1.2), Vector3.ZERO, wood, 0.008)
	Kit.add_box(board, Vector3(0.5, 0.002, 0.1), Vector3(0, 0.0135, 0.35), Kit.mat(bag_color, 0.8))
	Kit.add_cylinder(board, 0.085, 0.003, Vector3(0, 0.0128, -0.37), Kit.mat(Color(0.02, 0.02, 0.02)), 0, -1.0, 24)
	for sx: float in [-0.29, 0.29]:
		Kit.add_rbox(board, Vector3(0.03, 0.08, 1.2), Vector3(sx, -0.04, 0), wood, 0.008)
	Kit.add_rbox(p, Vector3(0.04, 0.3, 0.04), Vector3(-0.25, 0.15, -0.55), wood, 0.008)
	Kit.add_rbox(p, Vector3(0.04, 0.3, 0.04), Vector3(0.25, 0.15, -0.55), wood, 0.008)
	# The board's surface collides as four pieces round a square hole, so bags can drop in.
	var body := StaticBody3D.new()
	body.collision_layer = Kit.LAYER_FURNITURE
	body.collision_mask = 0
	board.add_child(body)
	var hole := 0.09
	for piece: Array in [
		[Vector3(0.6, 0.025, 0.6 - (-0.37 + hole)), Vector3(0, 0, (0.6 + (-0.37 + hole)) / 2.0)],
		[Vector3(0.6, 0.025, (-0.37 - hole) + 0.6), Vector3(0, 0, (-0.6 + (-0.37 - hole)) / 2.0)],
		[Vector3(0.3 - hole, 0.025, hole * 2.0), Vector3(-(0.3 + hole) / 2.0, 0, -0.37)],
		[Vector3(0.3 - hole, 0.025, hole * 2.0), Vector3((0.3 + hole) / 2.0, 0, -0.37)],
	]:
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = piece[0]
		cs.shape = sh
		cs.position = piece[1]
		body.add_child(cs)
	_boards.append(board)
	var specs: Array = []
	for i in 4:
		specs.append(["bag", p.transform * Transform3D(Basis(Vector3.UP, i * 0.4), Vector3(0.5, 0.02 + i * 0.036, 0.75)), bag_color])
	return specs


# ---------------------------------------------------------------- the props themselves

func _make(kind: String, home: Transform3D, extra: Variant) -> void:
	var b := Prop.new()
	b.game = self
	b.index = props.size()
	b.kind = kind
	b.home = home
	b.collision_layer = Kit.LAYER_BALL
	b.collision_mask = Kit.LAYER_STRUCTURE | Kit.LAYER_FURNITURE | Kit.LAYER_BALL
	b.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	b.continuous_cd = true
	b.angular_damp = 0.5
	var pm := PhysicsMaterial.new()
	pm.friction = 0.9
	pm.bounce = 0.05
	b.physics_material_override = pm
	var shape: Shape3D
	var shape_rot := Vector3.ZERO
	var shape_pos := Vector3.ZERO
	match kind:
		"cake":
			b.mass = 1.2
			b.reach = 0.14
			shape = _cyl_shape(0.16, 0.15)
			shape_pos = Vector3(0, 0.075, 0)
			_cake_visual(b)
			b.contact_monitor = true
			b.max_contacts_reported = 2
			b.body_entered.connect(_on_cake_hit.bind(b))
		"can":
			b.mass = 0.35
			b.reach = 0.05
			pm.bounce = 0.2
			shape = _cyl_shape(0.033, 0.122)
			_can_visual(b, extra)
		"patty", "sausage", "steak":
			b.mass = 0.2
			b.reach = 0.07
			if kind == "patty":
				shape = _cyl_shape(0.055, 0.022)
			elif kind == "sausage":
				var cap := CapsuleShape3D.new()
				cap.radius = 0.018
				cap.height = 0.16
				shape = cap
				shape_rot = Vector3(0, 0, PI / 2)
			else:
				var bx := BoxShape3D.new()
				bx.size = Vector3(0.15, 0.022, 0.1)
				shape = bx
			_meat_visual(b)
		"log":
			b.mass = 1.2
			shape = _cyl_shape(0.055, LOG_L)
			shape_rot = Vector3(PI / 2, 0, 0)
			_log_visual(b)
		"marsh":
			b.mass = 0.25
			var cap := CapsuleShape3D.new()
			cap.radius = 0.02
			cap.height = STICK_L
			shape = cap
			shape_rot = Vector3(PI / 2, 0, 0)
			_marsh_visual(b)
		"bag":
			b.mass = 0.45
			b.reach = 0.08
			pm.friction = 1.0
			pm.bounce = 0.0
			b.angular_damp = 3.0
			b.linear_damp = 0.2
			var bx := BoxShape3D.new()
			bx.size = Vector3(0.15, 0.035, 0.15)
			shape = bx
			_bag_visual(b, extra)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.rotation = shape_rot
	cs.position = shape_pos
	b.add_child(cs)
	b.add_to_group("grabbable")
	add_child(b)
	b.global_transform = home
	b.target = home
	props.append(b)


func _cyl_shape(r: float, h: float) -> CylinderShape3D:
	var s := CylinderShape3D.new()
	s.radius = r
	s.height = h
	return s


func _vis(parent: Node3D, mesh: Mesh, m: Material, pos := Vector3.ZERO, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.position = pos
	mi.rotation = rot
	mi.layers = Kit.VIS_ALL
	parent.add_child(mi)
	return mi


func _cake_visual(b: Prop) -> void:
	var cream := Kit.mat(Color(0.98, 0.93, 0.84), 0.6)
	var pink := Kit.mat(Color(0.97, 0.66, 0.76), 0.5)
	_vis(b, Kit.cylinder_mesh(0.16, 0.01, -1.0, 28), Kit.mat(Color(0.92, 0.95, 0.98), 0.1, 0.2), Vector3(0, 0.005, 0))
	_vis(b, Kit.cylinder_mesh(0.13, 0.08, -1.0, 28), cream, Vector3(0, 0.05, 0))
	_vis(b, Kit.cylinder_mesh(0.085, 0.06, -1.0, 24), pink, Vector3(0, 0.12, 0))
	var drip := TorusMesh.new()
	drip.inner_radius = 0.118
	drip.outer_radius = 0.136
	drip.rings = 28
	drip.ring_segments = 6
	_vis(b, drip, pink, Vector3(0, 0.088, 0))
	var drip2 := TorusMesh.new()
	drip2.inner_radius = 0.075
	drip2.outer_radius = 0.09
	drip2.rings = 24
	drip2.ring_segments = 6
	_vis(b, drip2, cream, Vector3(0, 0.15, 0))
	for i in 6:
		var a := TAU * i / 6.0
		_vis(b, Kit.sphere_mesh(0.013, 8), Kit.mat(Color(0.85, 0.08, 0.12), 0.35), Vector3(cos(a) * 0.105, 0.098, sin(a) * 0.105))
	for i in 3:
		var a := TAU * i / 3.0 + 0.3
		var pos := Vector3(cos(a) * 0.04, 0.175, sin(a) * 0.04)
		_vis(b, Kit.cylinder_mesh(0.004, 0.05, -1.0, 6), Kit.mat(Color(0.5, 0.75, 1.0), 0.5), pos)
		var f := _vis(b, Kit.sphere_mesh(0.006, 6), Kit.mat(Color(1.0, 0.8, 0.35), 0.9, 0.0, 4.0), pos + Vector3(0, 0.033, 0))
		f.scale = Vector3(0.8, 1.6, 0.8)


func _can_visual(b: Prop, c: Color) -> void:
	var silver := Kit.mat(Color(0.8, 0.8, 0.82), 0.25, 0.9)
	_vis(b, Kit.cylinder_mesh(0.033, 0.1, -1.0, 18), Kit.mat(c, 0.3, 0.5))
	_vis(b, Kit.cylinder_mesh(0.0335, 0.03, -1.0, 18), Kit.mat(Color(0.97, 0.97, 0.95), 0.4), Vector3(0, 0.01, 0))
	_vis(b, Kit.cylinder_mesh(0.029, 0.011, 0.033, 18), silver, Vector3(0, 0.0555, 0))
	_vis(b, Kit.cylinder_mesh(0.033, 0.011, 0.029, 18), silver, Vector3(0, -0.0555, 0))
	_vis(b, Kit.box_mesh(Vector3(0.012, 0.002, 0.022)), silver, Vector3(0, 0.0615, 0.008))


func _meat_visual(b: Prop) -> void:
	b.cook_mat = StandardMaterial3D.new()
	b.cook_mat.albedo_color = RAW[b.kind]
	b.cook_mat.roughness = 0.6
	b.cook_mat.albedo_texture = Kit.tex("carpet")
	b.cook_mat.uv1_triplanar = true
	b.cook_mat.uv1_scale = Vector3(6, 6, 6)
	var top := 0.011
	match b.kind:
		"patty":
			_vis(b, Kit.cylinder_mesh(0.055, 0.022, 0.052, 18), b.cook_mat)
		"sausage":
			_vis(b, Kit.capsule_mesh(0.018, 0.16, 10), b.cook_mat, Vector3.ZERO, Vector3(0, 0, PI / 2))
			top = 0.017
		"steak":
			_vis(b, Kit.rbox_mesh(Vector3(0.15, 0.022, 0.1), 0.008), b.cook_mat)
	b.marks = Node3D.new()
	b.marks.visible = false
	b.add_child(b.marks)
	var mark := Kit.mat(Color(0.08, 0.05, 0.03), 0.8)
	for i in 3:
		_vis(b.marks, Kit.box_mesh(Vector3(0.008, 0.002, 0.08 if b.kind != "sausage" else 0.03)), mark,
			Vector3(-0.03 + i * 0.03, top, 0), Vector3(0, 0.5, 0))


func _log_visual(b: Prop) -> void:
	var bark := Kit.tmat(Color(0.34, 0.24, 0.16), "bark", 4.0, 0.95, 0.0, false)
	var end := Kit.tmat(Color(0.8, 0.65, 0.45), "grain", 8.0, 0.8, 0.0, false)
	_vis(b, Kit.cylinder_mesh(0.055, LOG_L, 0.05, 10), bark, Vector3.ZERO, Vector3(PI / 2, 0, 0))
	for sz: float in [-1.0, 1.0]:
		_vis(b, Kit.cylinder_mesh(0.05, 0.004, -1.0, 10), end, Vector3(0, 0, sz * (LOG_L / 2.0 + 0.001)), Vector3(PI / 2, 0, 0))


func _marsh_visual(b: Prop) -> void:
	var stick := Kit.mat(Color(0.55, 0.42, 0.28), 0.7)
	_vis(b, Kit.cylinder_mesh(0.005, STICK_L - 0.18, 0.004, 6), stick, Vector3(0, 0, -0.09), Vector3(PI / 2, 0, 0))
	_vis(b, Kit.capsule_mesh(0.013, 0.18, 8), Kit.tmat(Color(0.3, 0.2, 0.12), "bark", 6.0, 0.9, 0.0, false),
		Vector3(0, 0, STICK_L / 2.0 - 0.09), Vector3(PI / 2, 0, 0))
	b.cook_mat = StandardMaterial3D.new()
	b.cook_mat.albedo_color = _toast_color(0.0)
	b.cook_mat.roughness = 0.8
	var m := _vis(b, Kit.cylinder_mesh(0.018, 0.034, -1.0, 12), b.cook_mat, Vector3(0, 0, -STICK_L / 2.0 + 0.03), Vector3(PI / 2, 0, 0))
	b.marks = m


func _bag_visual(b: Prop, c: Color) -> void:
	_vis(b, Kit.rbox_mesh(Vector3(0.15, 0.035, 0.15), 0.016, 2), Kit.tmat(c, "fabric", 12.0, 0.95, 0.0, false))


static func _toast_color(t: float) -> Color:
	if t < 1.0:
		return Color(0.98, 0.97, 0.93).lerp(Color(0.88, 0.64, 0.3), t)
	if t < 1.6:
		return Color(0.88, 0.64, 0.3).lerp(Color(0.42, 0.24, 0.1), (t - 1.0) / 0.6)
	return Color(0.42, 0.24, 0.1).lerp(Color(0.06, 0.05, 0.04), clampf((t - 1.6) / 0.6, 0.0, 1.0))


# ---------------------------------------------------------------- grabbing

func _apply_ownership() -> void:
	var me: int = main.me()
	for b in props:
		if b.hand != null or b.gone_until > 0.0:
			b.freeze = true
		else:
			b.freeze = b.owner_slot != me
		if b.owner_slot != me:
			b.target = b.global_transform


func grab(b: Prop, hand: Node) -> bool:
	var me: int = main.me()
	if b.remote_held and b.owner_slot != me:
		return false
	if b.hand != null and b.hand != hand:
		b.hand.held = null
	b.hand = hand
	b.owner_slot = me
	b.remote_held = false
	b.freeze = true
	b.touched = true
	b.scored = false
	b.send_in = 0.0
	var ht: Transform3D = hand.global_transform
	if b.kind == "marsh":
		# Sticks go in the hand by the handle, pointing where the hand points.
		b.hold = Transform3D(Basis.IDENTITY, ht.affine_inverse() * hand.grab_point() - Vector3(0, 0, STICK_L / 2.0 - 0.08))
	else:
		b.hold = ht.affine_inverse() * b.global_transform
	_send(b)
	return true


func let_go(b: Prop, hand: Node) -> void:
	if b.hand != hand:
		return
	b.hand = null
	b.freeze = false
	var v: Vector3 = hand.velocity * THROW_BOOST
	b.linear_velocity = v.limit_length(14.0)
	b.angular_velocity = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) if b.kind != "bag" else Vector3.ZERO
	b.moving_for = 0.0
	_send(b)


func _send(b: Prop) -> void:
	main.send({"t": "pr_b", "i": b.index, "p": Kit.pack_tf(b.global_transform), "v": Kit.pack_v3(b.linear_velocity),
		"held": b.hand != null, "c": snappedf(b.cook, 0.01)})


func _event(b: Prop, e: String) -> void:
	main.send({"t": "pr_e", "i": b.index, "e": e})
	_apply_event(b, e, main.me())


# ---------------------------------------------------------------- simulation

func _physics_process(delta: float) -> void:
	var me: int = main.me()
	var now := Time.get_ticks_msec() / 1000.0
	var sizzling := 0
	var heats := _heat_sources()
	for b in props:
		# Hidden (burnt, splatted) for a while, then back home.
		if b.gone_until > 0.0:
			if now >= b.gone_until:
				_restore(b)
				if b.owner_slot == me:
					_send(b)
			continue
		if b.hand != null:
			b.global_transform = (b.hand.global_transform as Transform3D) * b.hold
		elif b.owner_slot != me:
			b.target.origin += b.target_v * delta if not b.remote_held else Vector3.ZERO
			b.global_transform = b.global_transform.interpolate_with(b.target, 1.0 - exp(-20.0 * delta))
		# Heat: cooking, toasting, burning.
		var hot := 0.0
		var at := b.tip() if b.kind == "marsh" else b.global_position
		if b.kind in ["patty", "sausage", "steak", "marsh"]:
			for h: Node in heats:
				hot = maxf(hot, h.heat_at(at))
		match b.kind:
			"patty", "sausage", "steak":
				if hot > 0.3:
					sizzling += 1
					b.cook = minf(b.cook + hot * delta / 25.0, 2.2 if b.touched else 0.9)
			"marsh":
				if b.on_fire:
					b.cook = minf(b.cook + delta * 0.35, 2.5)
				else:
					b.cook = minf(b.cook + hot * delta * 0.15, 2.5)
		_show_cook(b)
		if b.owner_slot != me:
			continue
		# Ours: events, rescue, and streaming while it moves.
		var speed := b.linear_velocity.length()
		match b.kind:
			"log":
				var in_fire := false
				if b.hand == null:
					for h: Node in heats:
						if h.has_method("contains") and h.contains(b.global_position):
							in_fire = true
				if in_fire:
					b.in_fire_for += delta
					if b.in_fire_for > 0.5:
						b.in_fire_for = 0.0
						_event(b, "burn")
						continue
				else:
					b.in_fire_for = 0.0
			"marsh":
				if not b.on_fire:
					b.hot_for = b.hot_for + delta if hot > 0.75 else 0.0
					if b.hot_for > 3.0 or b.cook > 1.75:
						_event(b, "ignite")
				elif b.hand != null and (b.hand.velocity as Vector3).length() > 2.6:
					_event(b, "out")
				if b.hand != null and b.tip().distance_to(_mouth()) < 0.1 and not b.on_fire:
					_eat(b)
			"can":
				if b.hand != null and now > b.cheers_at and b.global_position.distance_to(_mouth()) < 0.12 \
						and b.global_transform.basis.y.y < 0.5:
					b.cheers_at = now + 4.0
					main.notify("Cheers!")
					b.hand.buzz(0.3, 0.15)
			"bag":
				if not b.scored and b.hand == null:
					for board in _boards:
						var l := board.to_local(b.global_position)
						if absf(l.x) < 0.09 and absf(l.z + 0.37) < 0.09 and l.y < -0.03 and l.y > -0.4:
							b.scored = true
							_event(b, "hole")
		if b.hand == null and not b.freeze:
			_pool_float(b)
		if b.global_position.y < -3.0 or b.global_position.distance_to(b.home.origin) > 80.0:
			_restore(b)
			_send(b)
			continue
		var moving := b.hand != null or (not b.freeze and speed > 0.03)
		b.moving_for = 0.0 if moving else b.moving_for + delta
		b.last_speed = speed
		b.send_in -= delta
		if b.send_in <= 0.0 and b.moving_for < 0.4 and main.has_friends():
			b.send_in = 1.0 / SEND_HZ
			_send(b)
	if _sizzle:
		var want := -60.0 if sizzling == 0 else -14.0 + 2.0 * minf(sizzling, 5)
		_sizzle.volume_db = lerpf(_sizzle.volume_db, want, minf(delta * 4.0, 1.0))
		if want > -59.0 and not _sizzle.playing:
			_sizzle.play()
		elif sizzling == 0 and _sizzle.playing and _sizzle.volume_db < -50.0:
			_sizzle.stop()


func _mouth() -> Vector3:
	var cam: Node3D = main.camera
	return cam.global_transform * Vector3(0, -0.07, -0.06)


func _show_cook(b: Prop) -> void:
	if b.cook_mat == null or absf(b.cook - b.shown_cook) < 0.01:
		return
	b.shown_cook = b.cook
	if b.kind == "marsh":
		b.cook_mat.albedo_color = _toast_color(b.cook)
		return
	var raw: Color = RAW[b.kind]
	b.cook_mat.albedo_color = raw.lerp(COOKED, clampf(b.cook, 0.0, 1.0)) if b.cook <= 1.0 \
		else COOKED.lerp(CHARRED, clampf(b.cook - 1.0, 0.0, 1.0))
	b.marks.visible = b.cook > 0.35


## Things that land in the pool bob on the surface.
func _pool_float(b: Prop) -> void:
	var pool: Array = main.mansion.anchors["pool"]
	var r: Rect2 = pool[0]
	var water_y: float = pool[1]
	var p := b.global_position
	if r.has_point(Vector2(p.x, p.z)) and p.y < water_y + 0.02:
		var depth := clampf((water_y + 0.02 - p.y) / 0.1, 0.0, 1.0)
		b.apply_central_force(Vector3.UP * b.mass * 9.8 * (0.6 + 1.2 * depth))
		b.linear_velocity *= 0.96
		b.angular_velocity *= 0.95
		if b.on_fire:
			_event(b, "out")


func _eat(b: Prop) -> void:
	var t := b.cook
	var msg := "Raw marshmallow. Toast it near the flames first!"
	if t > 1.9:
		msg = "Charcoal! Crunchy..."
	elif t > 1.3:
		msg = "Nice and crispy"
	elif t > 0.6:
		msg = "Perfectly golden. Mmm!"
	elif t > 0.2:
		msg = "Lightly toasted. Not bad!"
	main.notify(msg + "\n(another one's on the stick)")
	b.hand.buzz(0.4, 0.2)
	_event(b, "eat")


## Fires and the grill in this player's world (tests run two worlds in one tree).
func _heat_sources() -> Array:
	var out := []
	for h in get_tree().get_nodes_in_group("heat"):
		if main.is_ancestor_of(h):
			out.append(h)
	return out


func _restore(b: Prop) -> void:
	b.last_speed = 0.0
	b.gone_until = 0.0
	b.visible = true
	b.collision_layer = Kit.LAYER_BALL
	b.global_transform = b.home
	b.target = b.home
	b.target_v = Vector3.ZERO
	b.linear_velocity = Vector3.ZERO
	b.angular_velocity = Vector3.ZERO
	b.moving_for = 0.0
	b.send_in = 0.0
	b.touched = false
	b.cook = 0.0
	b.hot_for = 0.0
	_set_fire(b, false)
	if b.hand == null:
		b.freeze = b.owner_slot != main.me()


func _hide(b: Prop, seconds: float) -> void:
	if b.hand != null:
		b.hand.held = null
		b.hand = null
	b.gone_until = Time.get_ticks_msec() / 1000.0 + seconds
	b.visible = false
	b.freeze = true
	b.collision_layer = 0
	_set_fire(b, false)


func _set_fire(b: Prop, on: bool) -> void:
	b.on_fire = on
	if on and b.flame == null:
		var n := Node3D.new()
		n.position = Vector3(0, 0, -STICK_L / 2.0 + 0.03)
		b.add_child(n)
		b.flame = Fire.small_flame(n, 0.22)
	if b.flame:
		b.flame.emitting = on
	b.hot_for = 0.0


func _apply_event(b: Prop, e: String, from: int) -> void:
	match e:
		"burn":
			var best: Node = null
			var best_d := INF
			for h in _heat_sources():
				if h.has_method("stoke"):
					var d: float = (h as Node3D).global_position.distance_to(b.global_position)
					if d < best_d:
						best = h
						best_d = d
			if best and best_d < 3.0:
				best.stoke()
			_hide(b, 10.0)
		"splat":
			_crumbs(b.global_position)
			_hide(b, 3.0)
		"ignite":
			_set_fire(b, true)
		"out":
			_set_fire(b, false)
		"eat":
			b.cook = 0.0
			_set_fire(b, false)
		"hole":
			main.notify("%s: in the hole!" % main.name_of(from))


func _on_cake_hit(_other: Node, b: Prop) -> void:
	if b.owner_slot == main.me() and b.hand == null and b.gone_until == 0.0 and b.last_speed > 3.0:
		_event(b, "splat")


func _crumbs(at: Vector3) -> void:
	var p := GPUParticles3D.new()
	p.amount = 40
	p.lifetime = 1.3
	p.one_shot = true
	p.explosiveness = 0.95
	p.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 80.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 3.0
	pm.gravity = Vector3(0, -9.8, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.5
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray([Color(0.98, 0.93, 0.84), Color(0.97, 0.66, 0.76), Color(0.98, 0.93, 0.84)])
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_initial_ramp = gt
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.035, 0.035)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = Kit.soft_texture()
	q.material = m
	p.draw_pass_1 = q
	p.layers = Kit.VIS_ALL
	add_child(p)
	p.global_position = at
	p.emitting = true
	p.finished.connect(p.queue_free)
	main.notify("SPLAT!")


func _on_tidy() -> void:
	var me: int = main.me()
	for b in props:
		if b.hand != null or (b.remote_held and b.owner_slot != me):
			continue
		b.owner_slot = me
		b.remote_held = false
		_restore(b)
		b.freeze = false
		_send(b)


# ---------------------------------------------------------------- network

func handle(msg: Dictionary, from: int) -> void:
	var i := int(msg.get("i", -1))
	match str(msg.get("t", "")):
		"pr_b":
			if i < 0 or i >= props.size():
				return
			var b := props[i]
			if b.hand != null:
				if from < main.me():
					b.hand.held = null
					b.hand = null
				else:
					return
			if b.gone_until > 0.0:
				_restore(b)
			b.owner_slot = from
			b.remote_held = bool(msg.get("held", false))
			b.target = Kit.unpack_tf(msg.get("p"), b.global_transform)
			b.target_v = Kit.unpack_v3(msg.get("v"))
			if msg.has("c"):
				b.cook = float(msg["c"])
			b.freeze = true
		"pr_e":
			if i >= 0 and i < props.size():
				_apply_event(props[i], str(msg.get("e", "")), from)
		"pr_full":
			var list: Array = msg.get("props", [])
			for k in mini(list.size(), props.size()):
				var e: Array = list[k]
				var b := props[k]
				if b.hand != null:
					continue
				b.owner_slot = int(e[0])
				b.remote_held = bool(e[2])
				b.target = Kit.unpack_tf(e[1], b.global_transform)
				b.global_transform = b.target
				b.target_v = Vector3.ZERO
				b.cook = float(e[3])
				if float(e[4]) > 0.0:
					_hide(b, float(e[4]))
				_set_fire(b, bool(e[5]))
			_apply_ownership()


func full_state() -> Dictionary:
	var now := Time.get_ticks_msec() / 1000.0
	var list := []
	for b in props:
		list.append([b.owner_slot, Kit.pack_tf(b.global_transform), b.hand != null or b.remote_held, snappedf(b.cook, 0.01),
			maxf(b.gone_until - now, 0.0) if b.gone_until > 0.0 else 0.0, b.on_fire])
	return {"t": "pr_full", "props": list}


func on_identity_changed(old_id: int, new_id: int) -> void:
	for b in props:
		if b.hand != null or b.owner_slot == old_id:
			b.owner_slot = new_id
		else:
			b.owner_slot = main.host_slot()
		b.remote_held = false
	_apply_ownership()


func on_peer_left(slot: int) -> void:
	var host: int = main.host_slot()
	for b in props:
		if b.owner_slot == slot:
			b.owner_slot = host
			b.remote_held = false
	_apply_ownership()
