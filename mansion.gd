extends Node3D
## Sam and Dean Worldwide: the mansion, built from shapes in code. Floor is y = 0 everywhere;
## x is east, -z is north.
##
##                 Game Room            (air hockey, Connect Four, arcade, bar)
##                     |
##   Lounge ------ Grand Hall ------ Gym   (fireplace + jukebox | basketball)
##                     |
##                   Patio               (outdoors at sunset: pool, fire pit, BBQ, string
##                     |                  lights, speakers)
##                   Lawn                (cornhole)
##
## Surfaces get detail textures (Kit.tmat), furniture is built from rounded boxes, and
## repeated small things (balusters, bulbs, books, leaves, flowers) are MultiMeshes so they
## cost one draw call each.
##
## `structure` (walls, floors, ceilings, trim, the grounds, the pool) is hidden in "My room"
## mode, leaving the furniture and games standing in your real room through passthrough.

const Kit := preload("res://kit.gd")
const Fire := preload("res://fire.gd")

const NAME := "SAM AND DEAN WORLDWIDE"
const WALL_T := 0.2
const DOOR_W := 2.4
const DOOR_H := 3.0
const POOL := Rect2(2, 11, 6, 8)   # x, z, width, length
const WATER_Y := -0.12
const POOL_FLOOR := -1.3

const WATER_SHADER := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque;
uniform vec4 deep : source_color = vec4(0.04, 0.36, 0.56, 1.0);
uniform vec4 shallow : source_color = vec4(0.22, 0.72, 0.82, 1.0);
void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += 0.01 * sin(w.x * 2.3 + TIME * 1.4) + 0.007 * sin(w.z * 3.1 - TIME * 1.1);
}
void fragment() {
	vec3 w = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float a = sin(w.x * 6.0 + TIME * 1.7) + sin(w.z * 7.3 - TIME * 1.3) + sin((w.x + w.z) * 4.1 + TIME * 2.1);
	float b = cos(w.x * 5.2 - TIME * 1.5) + cos(w.z * 6.1 + TIME * 1.9);
	vec3 n = normalize(vec3(a * 0.045, 1.0, b * 0.045));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	float sparkle = pow(abs(sin(a * 1.3) * sin(b * 1.7)), 8.0);
	ALBEDO = mix(shallow.rgb, deep.rgb, 0.5 + 0.15 * a) + vec3(sparkle * 0.3);
	ROUGHNESS = 0.04;
	SPECULAR = 0.9;
	ALPHA = mix(0.7, 0.96, fres);
}
"""

## Room name -> [standing spot, yaw] (yaw 0 faces north / -z).
var spawns := {
	"Grand Hall": [Vector3(0, 0, 4.0), 0.0],
	"Game Room": [Vector3(0, 0, -8.6), 0.0],
	"Gym": [Vector3(8.6, 0, 0), -PI / 2],
	"Lounge": [Vector3(-8.6, 0, 0), PI / 2],
	"Patio": [Vector3(0, 0, 8.6), PI],
}
## Where main puts the games and props: name -> [position, yaw] (yaw turns the thing's +z
## front), except "pool" -> [Rect2 (x, z), water height].
var anchors := {
	"air_hockey": [Vector3(-2.6, 0, -13.0), 0.0],
	"connect_four": [Vector3(4.6, 0, -13.0), -PI / 2],
	"hoop": [Vector3(20.75, 0, 0), -PI / 2],
	"ball_rack": [Vector3(15.5, 0, 5.2), PI],
	"jukebox": [Vector3(-11.0, 0, 6.55), PI],
	"cake": [Vector3(0, 0.425, -0.6), 0.3],
	"bbq": [Vector3(0.0, 0, 19.55), PI],
	"cooler": [Vector3(-1.35, 0, 20.25), PI],
	"woodpile": [Vector3(-8.9, 0, 11.6), PI / 2],
	"marsh_stand": [Vector3(-3.55, 0, 15.0), PI / 2],
	"cornhole_a": [Vector3(0, -0.05, 24.5), 0.0],
	"cornhole_b": [Vector3(0, -0.05, 31.5), PI],
	"speaker_l": [Vector3(-2.3, 0, 7.75), 0.0],
	"speaker_r": [Vector3(2.3, 0, 7.75), 0.0],
	"pool": [POOL, WATER_Y],
}
## Which room a point is in (by floor area), for "where's my friend".
var rooms := {
	"Grand Hall": Rect2(-7, -7, 14, 14),
	"Game Room": Rect2(-7, -19, 14, 12),
	"Gym": Rect2(7, -7, 14, 14),
	"Lounge": Rect2(-21, -7, 14, 14),
	"Patio": Rect2(-10, 7, 20, 14),
	"Lawn": Rect2(-14, 21, 28, 16),
}
var structure: Array[Node3D] = []
var _floats: Array[Node3D] = []
var _t := 0.0


func build() -> void:
	Kit.vis_layers = Kit.VIS_INDOOR
	_grand_hall()
	_game_room()
	_gym()
	_lounge()
	Kit.vis_layers = Kit.VIS_OUTDOOR
	_patio()
	_pool()
	_string_lights()
	_grounds()
	Kit.vis_layers = Kit.VIS_INDOOR
	# One mesh per material per room: the Quest is limited by draw calls, not triangles.
	var skip: Array = _floats.duplicate()
	for f in find_children("*", "Node3D", false, false):
		if f is Fire:
			skip.append(f)
	var merged := Kit.merge_static(self, skip, room_at, structure)
	print("Mansion: merged %d meshes" % merged)


func set_structure_visible(on: bool) -> void:
	for n in structure:
		n.visible = on


func room_at(p: Vector3) -> String:
	for rn: String in rooms:
		if (rooms[rn] as Rect2).has_point(Vector2(p.x, p.z)):
			return rn
	return "the grounds"


func _process(delta: float) -> void:
	_t += delta
	for i in _floats.size():
		var f := _floats[i]
		f.position.y = WATER_Y + 0.02 + 0.015 * sin(_t * 1.3 + i * 2.0)
		f.rotation.y += delta * 0.05 * (1.0 if i % 2 == 0 else -1.0)
		f.rotation.x = 0.04 * sin(_t * 1.1 + i)


# ---------------------------------------------------------------- building blocks

func _s(n: Node3D) -> Node3D:
	structure.append(n)
	return n


## A room: floor, ceiling, four walls inset inside the bounds, baseboards, crown moulding and
## door casings. doors: side ("n", "s", "w", "e") -> centre coordinate along that wall.
## wainscot: optional material for a panelled lower metre of wall.
func _room(x0: float, x1: float, z0: float, z1: float, h: float, floor_m: Material, wall_m: Material, ceil_m: Material,
		trim_m: Material, doors: Dictionary, wainscot: Material = null) -> void:
	var cx := (x0 + x1) / 2.0
	var cz := (z0 + z1) / 2.0
	_s(Kit.add_box(self, Vector3(x1 - x0, 0.1, z1 - z0), Vector3(cx, -0.05, cz), floor_m, Kit.LAYER_STRUCTURE))
	if ceil_m:
		_s(Kit.add_box(self, Vector3(x1 - x0, 0.1, z1 - z0), Vector3(cx, h + 0.05, cz), ceil_m, Kit.LAYER_STRUCTURE))
	var t := WALL_T / 2.0
	_wall_x(z0 + t, x0, x1, h, wall_m, doors.get("n", null))
	_wall_x(z1 - t, x0, x1, h, wall_m, doors.get("s", null))
	_wall_z(x0 + t, z0 + WALL_T, z1 - WALL_T, h, wall_m, doors.get("w", null))
	_wall_z(x1 - t, z0 + WALL_T, z1 - WALL_T, h, wall_m, doors.get("e", null))
	# Trim along the inner faces: [side, inner face coordinate, inward direction].
	var ix0 := x0 + WALL_T
	var ix1 := x1 - WALL_T
	var iz0 := z0 + WALL_T
	var iz1 := z1 - WALL_T
	for side: Array in [["n", iz0, 1.0], ["s", iz1, -1.0], ["w", ix0, 1.0], ["e", ix1, -1.0]]:
		var along_x: bool = side[0] == "n" or side[0] == "s"
		var a0 := ix0 if along_x else iz0
		var a1 := ix1 if along_x else iz1
		var face: float = side[1]
		var dir: float = side[2]
		var door: Variant = doors.get(side[0], null)
		for piece: Array in _spans(a0, a1, h, door, DOOR_W + 0.24):
			if piece[2] > 0.0 or piece[1] - piece[0] < 0.05:
				continue
			var mid: float = (piece[0] + piece[1]) / 2.0
			var length: float = piece[1] - piece[0]
			if wainscot:
				_trim(along_x, mid, length, face + dir * 0.012, 0.5, 1.0, 0.024, wainscot)
				_trim(along_x, mid, length, face + dir * 0.03, 1.0, 0.05, 0.06, trim_m)
			_trim(along_x, mid, length, face + dir * 0.02, 0.07, 0.14, 0.04, trim_m)
		_trim(along_x, (a0 + a1) / 2.0, a1 - a0, face + dir * 0.04, h - 0.07, 0.14, 0.08, trim_m)
		# Door casing (covers both sides of the doorway).
		if door != null:
			var d := float(door)
			var wall_c := face - dir * t
			for sx: float in [-1.0, 1.0]:
				var c := d + sx * (DOOR_W / 2.0 + 0.06)
				_trim(along_x, c, 0.12, wall_c, DOOR_H / 2.0, DOOR_H, WALL_T + 0.08, trim_m)
			_trim(along_x, d, DOOR_W + 0.24, wall_c, DOOR_H + 0.07, 0.14, WALL_T + 0.08, trim_m)


## A trim strip: centred at `mid` along the wall, `depth` out from the wall line `at`.
func _trim(along_x: bool, mid: float, length: float, at: float, y: float, height: float, depth: float, m: Material) -> void:
	var size := Vector3(length, height, depth) if along_x else Vector3(depth, height, length)
	var pos := Vector3(mid, y, at) if along_x else Vector3(at, y, mid)
	_s(Kit.add_box(self, size, pos, m))


## Wall pieces between a0 and a1 (along the wall), height h, leaving a doorway centred at `door`.
func _spans(a0: float, a1: float, h: float, door: Variant, door_w := DOOR_W, door_h := DOOR_H) -> Array:
	if door == null:
		return [[a0, a1, 0.0, h]]
	var d := float(door)
	return [[a0, d - door_w / 2.0, 0.0, h], [d + door_w / 2.0, a1, 0.0, h], [d - door_w / 2.0, d + door_w / 2.0, door_h, h]]


func _wall_x(z: float, x0: float, x1: float, h: float, m: Material, door: Variant, thick := WALL_T) -> void:
	for p: Array in _spans(x0, x1, h, door):
		if p[1] - p[0] > 0.01 and p[3] - p[2] > 0.01:
			_s(Kit.add_box(self, Vector3(p[1] - p[0], p[3] - p[2], thick), Vector3((p[0] + p[1]) / 2.0, (p[2] + p[3]) / 2.0, z), m, Kit.LAYER_STRUCTURE))


func _wall_z(x: float, z0: float, z1: float, h: float, m: Material, door: Variant, thick := WALL_T) -> void:
	for p: Array in _spans(z0, z1, h, door):
		if p[1] - p[0] > 0.01 and p[3] - p[2] > 0.01:
			_s(Kit.add_box(self, Vector3(thick, p[3] - p[2], p[1] - p[0]), Vector3(x, (p[2] + p[3]) / 2.0, (p[0] + p[1]) / 2.0), m, Kit.LAYER_STRUCTURE))


## A pivot node at pos turned by yaw, for building furniture in its own space (+z = front).
func _pivot(pos: Vector3, yaw: float) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	n.rotation.y = yaw
	add_child(n)
	return n


## An invisible collider (furniture layer, so balls and props bounce off it).
func _collider(parent: Node3D, size: Vector3, pos: Vector3, layer := Kit.LAYER_FURNITURE) -> void:
	var b := StaticBody3D.new()
	b.collision_layer = layer
	b.collision_mask = 0
	b.position = pos
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	b.add_child(cs)
	parent.add_child(b)


func _wood(color := Color("3b2618"), rough := 0.45) -> Material:
	return Kit.tmat(color, "grain", 2.0, rough)


func _fabric(color: Color) -> Material:
	return Kit.tmat(color, "fabric", 6.0, 0.95)


## Sofa facing +z (rotated by yaw), seat 0.45 high: rounded frame on wooden legs, plump
## seat and back cushions, and throw pillows on the longer ones.
func _sofa(pos: Vector3, yaw: float, color: Color, length := 2.1, pillow := Color(0, 0, 0, 0)) -> void:
	var p := _pivot(pos, yaw)
	var frame := _fabric(color)
	var cushion := _fabric(color.lightened(0.1))
	var legs := _wood(Color("2a1a10"), 0.4)
	Kit.add_rbox(p, Vector3(length, 0.22, 0.86), Vector3(0, 0.21, 0), frame, 0.05)
	Kit.add_rbox(p, Vector3(length, 0.56, 0.2), Vector3(0, 0.56, -0.33), frame, 0.08, 0, Vector3(-0.06, 0, 0))
	for side: float in [-1.0, 1.0]:
		Kit.add_rbox(p, Vector3(0.18, 0.32, 0.86), Vector3(side * (length / 2.0 - 0.09), 0.46, 0), frame, 0.07)
		for sz: float in [-0.36, 0.36]:
			Kit.add_cylinder(p, 0.024, 0.1, Vector3(side * (length / 2.0 - 0.08), 0.05, sz), legs, 0, 0.018, 8)
	var seats := 1 if length < 1.4 else (3 if length > 2.3 else 2)
	var seat_w := (length - 0.36) / seats
	for i in seats:
		var x := -(length - 0.36) / 2.0 + seat_w * (i + 0.5)
		Kit.add_rbox(p, Vector3(seat_w - 0.02, 0.14, 0.64), Vector3(x, 0.39, 0.08), cushion, 0.05)
		Kit.add_rbox(p, Vector3(seat_w - 0.03, 0.4, 0.14), Vector3(x, 0.66, -0.19), cushion, 0.06, 0, Vector3(-0.16, 0, 0))
	if length >= 1.6:
		var pc := pillow if pillow.a > 0.0 else color.lightened(0.45)
		for side: float in [-1.0, 1.0]:
			Kit.add_rbox(p, Vector3(0.36, 0.34, 0.1), Vector3(side * (length / 2.0 - 0.36), 0.64, -0.06), _fabric(pc), 0.045, 0,
				Vector3(-0.3, side * 0.35, side * 0.12))
	_collider(p, Vector3(length, 0.45, 0.9), Vector3(0, 0.22, 0))


func _armchair(pos: Vector3, yaw: float, color: Color) -> void:
	_sofa(pos, yaw, color, 1.0)


## Table with a rounded wooden top, an apron and tapered legs.
func _table(pos: Vector3, size: Vector3, top: Material, legs: Material) -> void:
	Kit.add_rbox(self, Vector3(size.x, 0.05, size.z), pos + Vector3(0, size.y - 0.025, 0), top, 0.018, Kit.LAYER_FURNITURE)
	Kit.add_rbox(self, Vector3(size.x - 0.14, 0.08, size.z - 0.14), pos + Vector3(0, size.y - 0.09, 0), legs, 0.01)
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			Kit.add_cylinder(self, 0.022, size.y - 0.05, pos + Vector3(sx * (size.x / 2.0 - 0.09), (size.y - 0.05) / 2.0, sz * (size.z / 2.0 - 0.09)),
				legs, 0, 0.032, 10)


## Dining-style chair facing +z.
func _chair(pos: Vector3, yaw: float, wood: Material, seat: Material) -> void:
	var p := _pivot(pos, yaw)
	Kit.add_rbox(p, Vector3(0.44, 0.06, 0.42), Vector3(0, 0.46, 0), seat, 0.02)
	for sx: float in [-0.18, 0.18]:
		for sz: float in [-0.17, 0.17]:
			Kit.add_cylinder(p, 0.017, 0.44, Vector3(sx, 0.22, sz), wood, 0, 0.014, 8)
		Kit.add_rbox(p, Vector3(0.035, 0.5, 0.035), Vector3(sx, 0.72, -0.19), wood, 0.012)
	Kit.add_rbox(p, Vector3(0.42, 0.16, 0.03), Vector3(0, 0.88, -0.19), wood, 0.012)
	Kit.add_rbox(p, Vector3(0.36, 0.05, 0.025), Vector3(0, 0.65, -0.19), wood, 0.01)


func _plant(pos: Vector3, size_k := 1.0) -> void:
	var s := size_k
	var pot := Kit.tmat(Color(0.62, 0.36, 0.25), "plaster", 3.0, 0.85)
	Kit.add_cylinder(self, 0.17 * s, 0.42 * s, pos + Vector3(0, 0.21 * s, 0), pot, Kit.LAYER_FURNITURE, 0.22 * s, 16)
	Kit.add_cylinder(self, 0.235 * s, 0.06 * s, pos + Vector3(0, 0.42 * s, 0), pot, 0, 0.235 * s, 16)
	Kit.add_cylinder(self, 0.2 * s, 0.02 * s, pos + Vector3(0, 0.44 * s, 0), Kit.mat(Color(0.18, 0.12, 0.08)), 0, -1.0, 14)
	# Stems and a crown of leaves (one MultiMesh).
	var rng := RandomNumberGenerator.new()
	rng.seed = int(pos.x * 100 + pos.z * 7)
	var xforms: Array[Transform3D] = []
	var colors: Array = []
	for i in 22:
		var a := rng.randf() * TAU
		var r := rng.randf_range(0.02, 0.3) * s
		var y := rng.randf_range(0.6, 1.4) * s
		var basis := Basis(Vector3.UP, a) * Basis(Vector3.RIGHT, rng.randf_range(-0.9, -0.2))
		basis = basis.scaled(Vector3(0.11, 0.02, 0.24) * s * rng.randf_range(0.8, 1.2))
		xforms.append(Transform3D(basis, pos + Vector3(cos(a) * r, y, sin(a) * r)))
		colors.append(Color(0.16, 0.42, 0.18).lerp(Color(0.3, 0.58, 0.24), rng.randf()))
	Kit.add_multimesh(self, Kit.sphere_mesh(1.0, 8), xforms, Kit.mm_mat(0.7), colors)
	var stems: Array = []
	for i in 5:
		var a := TAU * i / 5.0
		stems.append(PackedVector3Array([pos + Vector3(0, 0.44 * s, 0), pos + Vector3(cos(a) * 0.12 * s, 1.05 * s, sin(a) * 0.12 * s)]))
	var sm := MeshInstance3D.new()
	sm.mesh = Kit.tube_mesh(stems, 0.012 * s, 5)
	sm.material_override = Kit.mat(Color(0.25, 0.35, 0.15))
	sm.layers = Kit.vis_layers
	add_child(sm)


## A framed painting hung on a wall, facing along +z turned by yaw.
func _painting(pos: Vector3, yaw: float, size: Vector2, a: Color, b: Color) -> void:
	var p := _pivot(pos, yaw)
	var gold := Kit.mat(Color(0.75, 0.6, 0.2), 0.35, 0.8)
	Kit.add_rbox(p, Vector3(size.x + 0.16, size.y + 0.16, 0.05), Vector3.ZERO, gold, 0.02)
	Kit.add_box(p, Vector3(size.x + 0.04, size.y + 0.04, 0.02), Vector3(0, 0, 0.022), Kit.mat(Color(0.95, 0.93, 0.88)))
	Kit.add_box(p, Vector3(size.x, size.y, 0.02), Vector3(0, 0, 0.026), Kit.tmat(a, "fabric", 8.0, 0.9))
	Kit.add_box(p, Vector3(size.x * 0.45, size.y * 0.5, 0.01), Vector3(size.x * 0.12, -size.y * 0.1, 0.04), Kit.tmat(b, "fabric", 8.0, 0.9))
	Kit.add_sphere(p, size.y * 0.16, Vector3(-size.x * 0.22, size.y * 0.2, 0.035), Kit.mat(b.lightened(0.3), 0.9), 0, 12)


## A glowing window (it shows daylight; you can't see through it).
func _window(pos: Vector3, yaw: float, size: Vector2, glow := Color(0.75, 0.88, 1.0)) -> void:
	var p := _pivot(pos, yaw)
	Kit.add_box(p, Vector3(size.x, size.y, 0.03), Vector3.ZERO, Kit.flat(glow))
	var frame := Kit.mat(Color(0.95, 0.94, 0.9), 0.5)
	Kit.add_rbox(p, Vector3(size.x + 0.24, 0.07, 0.14), Vector3(0, -size.y / 2.0 - 0.05, 0.05), frame, 0.02)
	Kit.add_rbox(p, Vector3(size.x + 0.16, 0.09, 0.06), Vector3(0, size.y / 2.0, 0.02), frame, 0.02)
	Kit.add_box(p, Vector3(0.05, size.y, 0.05), Vector3(0, 0, 0.02), frame)
	Kit.add_box(p, Vector3(size.x, 0.04, 0.05), Vector3(0, 0, 0.02), frame)
	for side: float in [-1.0, 1.0]:
		Kit.add_rbox(p, Vector3(0.09, size.y + 0.04, 0.06), Vector3(side * size.x / 2.0, 0, 0.02), frame, 0.02)


func _sign(pos: Vector3, yaw: float, text: String, height := 0.22, color := Color(0.95, 0.85, 0.55)) -> Label3D:
	return Kit.add_label(self, text, height, pos, yaw, color)


func _floor_lamp(pos: Vector3, color := Color(1.0, 0.82, 0.6)) -> void:
	var metal := Kit.mat(Color(0.65, 0.5, 0.25), 0.35, 0.85)
	Kit.add_cylinder(self, 0.16, 0.03, pos + Vector3(0, 0.015, 0), metal, 0, 0.12, 20)
	Kit.add_cylinder(self, 0.013, 1.5, pos + Vector3(0, 0.77, 0), metal, 0, -1.0, 8)
	Kit.add_cylinder(self, 0.24, 0.3, pos + Vector3(0, 1.6, 0), Kit.tmat(color, "fabric", 8.0, 0.9), 0, 0.15, 20)
	Kit.add_sphere(self, 0.05, pos + Vector3(0, 1.52, 0), Kit.mat(color, 0.5, 0.0, 3.0), 0, 8)
	Kit.omni(self, pos + Vector3(0, 1.5, 0), color, 0.8, 5.0)


## A small table lamp standing on something at `pos`.
func _table_lamp(pos: Vector3, color := Color(1.0, 0.85, 0.65)) -> void:
	Kit.add_sphere(self, 0.09, pos + Vector3(0, 0.12, 0), Kit.mat(Color(0.2, 0.32, 0.45), 0.2, 0.2), 0, 14)
	Kit.add_cylinder(self, 0.01, 0.2, pos + Vector3(0, 0.3, 0), Kit.mat(Color(0.7, 0.55, 0.3), 0.3, 0.8), 0, -1.0, 6)
	Kit.add_cylinder(self, 0.16, 0.2, pos + Vector3(0, 0.45, 0), Kit.tmat(color.lightened(0.3), "fabric", 8.0, 0.9), 0, 0.1, 18)
	Kit.add_sphere(self, 0.035, pos + Vector3(0, 0.4, 0), Kit.mat(color, 0.5, 0.0, 3.0), 0, 8)


func _column(pos: Vector3, h: float, m: Material) -> void:
	Kit.add_rbox(self, Vector3(0.72, 0.3, 0.72), pos + Vector3(0, 0.15, 0), m, 0.03, Kit.LAYER_STRUCTURE)
	Kit.add_cylinder(self, 0.31, 0.1, pos + Vector3(0, 0.35, 0), m, 0, 0.27, 24)
	Kit.add_cylinder(self, 0.25, h - 0.8, pos + Vector3(0, h / 2.0, 0), m, Kit.LAYER_STRUCTURE, 0.23, 24)
	Kit.add_cylinder(self, 0.25, 0.1, pos + Vector3(0, h - 0.35, 0), m, 0, 0.31, 24)
	Kit.add_rbox(self, Vector3(0.72, 0.3, 0.72), pos + Vector3(0, h - 0.15, 0), m, 0.03)


## Little MultiMesh of books filling a shelf row from x0 to x1 (shelf top at y, spines facing +z).
func _books(parent: Node3D, x0: float, x1: float, y: float, z: float, rng: RandomNumberGenerator, xforms: Array[Transform3D], colors: Array) -> void:
	var palette := [Color("8c2f39"), Color("2f5fa8"), Color("e9b23b"), Color("2f9d62"), Color("efe7da"), Color("5a2340"),
		Color("1f3b5a"), Color("7a5230"), Color("3d6b5e")]
	var x := x0
	while x < x1 - 0.03:
		var w := rng.randf_range(0.025, 0.06)
		var h := rng.randf_range(0.24, 0.36)
		var lean := 0.0 if rng.randf() > 0.1 else rng.randf_range(-0.25, 0.25)
		var basis := Basis(Vector3.BACK, lean).scaled(Vector3(w, h, rng.randf_range(0.2, 0.26)))
		xforms.append(parent.transform * Transform3D(basis, Vector3(x + w / 2.0, y + h / 2.0, z)))
		colors.append((palette[rng.randi() % palette.size()] as Color).darkened(rng.randf_range(0.0, 0.3)))
		x += w + 0.003
		if rng.randf() < 0.05:
			x += 0.12


# ---------------------------------------------------------------- rooms
# Inner wall faces sit WALL_T inside each room's bounds (e.g. the hall's are at ±6.8), so
# things hung on walls go about 0.03 in front of that.

func _grand_hall() -> void:
	var marble := Kit.tmat(Color("e6ded2"), "tiles", 0.25, 0.22)
	var wall := Kit.tmat(Color("efe7da"), "plaster", 0.5, 0.9)
	var ceiling := Kit.tmat(Color("f6f1e8"), "plaster", 0.5, 0.9)
	var trim := Kit.mat(Color("faf7f0"), 0.5)
	_room(-7, 7, -7, 7, 6.0, marble, wall, ceiling, trim, {"n": 0.0, "s": 0.0, "w": 0.0, "e": 0.0})
	# Floor pattern: a dark marble border and a big rug with a border.
	var dark := Kit.tmat(Color("5f544a"), "tiles", 0.5, 0.22)
	for z: float in [-5.6, 5.6]:
		Kit.add_box(self, Vector3(11.2, 0.01, 0.25), Vector3(0, 0.005, z), dark)
	for x: float in [-5.6, 5.6]:
		Kit.add_box(self, Vector3(0.25, 0.01, 11.2), Vector3(x, 0.005, 0), dark)
	Kit.add_rbox(self, Vector3(6.0, 0.014, 4.2), Vector3(0, 0.007, -0.6), Kit.tmat(Color("6d1a27"), "carpet", 3.0, 1.0), 0.006)
	Kit.add_rbox(self, Vector3(5.5, 0.016, 3.7), Vector3(0, 0.008, -0.6), Kit.tmat(Color("9a2b3a"), "carpet", 3.0, 1.0), 0.006)
	Kit.add_box(self, Vector3(5.0, 0.017, 3.2), Vector3(0, 0.009, -0.6), Kit.tmat(Color("a8354a"), "carpet", 3.0, 1.0))
	var gold := Kit.mat(Color("c9a227"), 0.35, 0.8)
	for x: float in [-5.4, 5.4]:
		for z: float in [-5.4, 5.4]:
			_column(Vector3(x, 0, z), 6.0, Kit.tmat(Color("f2ede4"), "plaster", 1.0, 0.4))
	# Sofas facing each other round a coffee table (the cake sits on it), side tables and lamps.
	_sofa(Vector3(0, 0, -2.4), 0.0, Color("2f4a6d"), 2.1, Color("d9b45a"))
	_sofa(Vector3(0, 0, 1.2), PI, Color("2f4a6d"), 2.1, Color("d9b45a"))
	_armchair(Vector3(-2.3, 0, -0.6), PI / 2, Color("7a5230"))
	_armchair(Vector3(2.3, 0, -0.6), -PI / 2, Color("7a5230"))
	var walnut := _wood(Color("3a2518"), 0.35)
	_table(Vector3(0, 0, -0.6), Vector3(1.4, 0.42, 0.8), walnut, walnut)
	for x: float in [-1.45, 1.45]:
		_table(Vector3(x, 0, -2.45), Vector3(0.45, 0.55, 0.45), walnut, walnut)
		_table_lamp(Vector3(x, 0.55, -2.45))
	# Chandelier: arms out to candle bulbs, each with a glow.
	Kit.add_cylinder(self, 0.02, 1.2, Vector3(0, 5.4, 0), gold, 0, -1.0, 8)
	Kit.add_cylinder(self, 0.18, 0.3, Vector3(0, 4.75, 0), gold, 0, 0.08, 16)
	var arms: Array = []
	var bulbs: Array[Transform3D] = []
	for i in 8:
		var a := TAU * i / 8.0
		var tip := Vector3(cos(a) * 0.7, 4.85, sin(a) * 0.7)
		arms.append(PackedVector3Array([Vector3(0, 4.7, 0), Vector3(cos(a) * 0.35, 4.62, sin(a) * 0.35), tip - Vector3(0, 0.08, 0), tip]))
		Kit.add_cylinder(self, 0.04, 0.04, tip, gold, 0, 0.05, 10)
		Kit.add_cylinder(self, 0.015, 0.1, tip + Vector3(0, 0.07, 0), Kit.mat(Color(0.98, 0.97, 0.93)), 0, -1.0, 6)
		bulbs.append(Transform3D(Basis.IDENTITY.scaled(Vector3(0.8, 1.3, 0.8)), tip + Vector3(0, 0.15, 0)))
	var am := MeshInstance3D.new()
	am.mesh = Kit.tube_mesh(arms, 0.014, 6)
	am.material_override = gold
	am.layers = Kit.vis_layers
	add_child(am)
	Kit.add_multimesh(self, Kit.sphere_mesh(0.03, 8), bulbs, Kit.mat(Color(1.0, 0.85, 0.55), 0.5, 0.0, 4.0))
	var halos: Array[Transform3D] = []
	for b in bulbs:
		halos.append(Transform3D(Basis.IDENTITY, b.origin))
	Kit.add_multimesh(self, Kit.sphere_mesh(0.14, 12), halos, Kit.halo_mat(Color(1.0, 0.75, 0.4), 0.6))
	Kit.omni(self, Vector3(0, 4.4, 0), Color(1.0, 0.9, 0.75), 2.2, 13.0)
	Kit.omni(self, Vector3(0, 2.6, 5.0), Color(1.0, 0.92, 0.8), 0.7, 7.0)
	# Plants, paintings and windows.
	for p: Vector3 in [Vector3(-6.2, 0, -6.2), Vector3(6.2, 0, -6.2), Vector3(-6.2, 0, 6.2), Vector3(6.2, 0, 6.2)]:
		_plant(p, 1.2)
	_painting(Vector3(-3.8, 2.6, -6.77), 0.0, Vector2(1.6, 1.1), Color("21405e"), Color("e9a23b"))
	_painting(Vector3(3.8, 2.6, -6.77), 0.0, Vector2(1.6, 1.1), Color("5a2340"), Color("63c6b5"))
	_painting(Vector3(-6.77, 2.6, -3.8), PI / 2, Vector2(1.4, 1.0), Color("2f5d3a"), Color("f2d17c"))
	_painting(Vector3(6.77, 2.6, 3.8), -PI / 2, Vector2(1.4, 1.0), Color("4a3b6b"), Color("f08a5d"))
	_window(Vector3(-3.8, 2.6, 6.77), PI, Vector2(1.6, 2.2), Color(1.0, 0.82, 0.62))
	_window(Vector3(3.8, 2.6, 6.77), PI, Vector2(1.6, 2.2), Color(1.0, 0.82, 0.62))
	# Signs over the doorways, and the name.
	_sign(Vector3(0, 3.45, -6.76), 0.0, "GAME ROOM")
	_sign(Vector3(-6.76, 3.45, 0), PI / 2, "LOUNGE")
	_sign(Vector3(6.76, 3.45, 0), -PI / 2, "GYM")
	_sign(Vector3(0, 3.45, 6.76), PI, "PATIO + BACKYARD")
	var title := _sign(Vector3(0, 4.9, -6.76), 0.0, NAME, 0.42, Color(0.95, 0.75, 0.25))
	title.outline_size = 10
	title.outline_modulate = Color(0.3, 0.18, 0.05)
	# A welcome board facing the spawn spot.
	var board := _pivot(Vector3(-2.3, 0, 3.0), 0.75)
	Kit.add_rbox(board, Vector3(0.05, 1.1, 0.05), Vector3(0, 0.55, -0.02), _wood(Color(0.2, 0.15, 0.1)), 0.015)
	Kit.add_rbox(board, Vector3(1.36, 0.92, 0.05), Vector3(0, 1.45, -0.005), gold, 0.02)
	Kit.add_box(board, Vector3(1.28, 0.84, 0.04), Vector3(0, 1.45, 0), Kit.mat(Color(0.14, 0.18, 0.24), 0.6))
	var help := Kit.add_label(board, "WELCOME TO %s!\n\nLeft stick:  walk     Right stick:  turn\nGrip:  grab things     Trigger:  press buttons\nY / Menu button:  menu (room code, travel, voice)\n\nOut back: fire pit, BBQ, pool, cornhole, music.\nTry the cake on the table..." % NAME, 0.042, Vector3(0, 1.45, 0.025))
	help.width = 1.2 / help.pixel_size
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func _game_room() -> void:
	var carpet := Kit.tmat(Color("2a2e3d"), "carpet", 2.0, 1.0)
	var wall := Kit.tmat(Color("1d3a4a"), "plaster", 0.5, 0.9)
	var ceiling := Kit.mat(Color("181b22"), 0.9)
	_room(-7, 7, -19, -7, 4.0, carpet, wall, ceiling, Kit.mat(Color("101418"), 0.5), {"s": 0.0})
	# Neon trim and sign.
	for z: float in [-18.74, -7.26]:
		Kit.add_box(self, Vector3(13.4, 0.04, 0.03), Vector3(0, 3.6, z), Kit.flat(Color(0.2, 0.9, 1.0)))
	for x: float in [-6.74, 6.74]:
		Kit.add_box(self, Vector3(0.03, 0.04, 11.4), Vector3(x, 3.6, -13), Kit.flat(Color(1.0, 0.3, 0.8)))
	_sign(Vector3(0, 3.0, -18.76), 0.0, "GAME ROOM", 0.45, Color(1.0, 0.35, 0.85))
	# Arcade cabinets along the north wall (decoration).
	var screens := [Color(0.2, 0.9, 0.5), Color(1.0, 0.6, 0.2), Color(0.4, 0.6, 1.0), Color(1.0, 0.3, 0.4)]
	var cab := Kit.mat(Color(0.1, 0.1, 0.14), 0.4, 0.2)
	for i in 4:
		var p := _pivot(Vector3(-4.5 + i * 1.1, 0, -18.4), 0.0)
		var screen: Color = screens[i]
		Kit.add_rbox(p, Vector3(0.8, 1.15, 0.7), Vector3(0, 0.575, 0), cab, 0.03, Kit.LAYER_FURNITURE)
		Kit.add_rbox(p, Vector3(0.8, 0.75, 0.45), Vector3(0, 1.5, -0.12), cab, 0.03)
		Kit.add_box(p, Vector3(0.6, 0.45, 0.02), Vector3(0, 1.45, 0.11), Kit.flat(screen), 0, Vector3(-0.2, 0, 0))
		Kit.add_rbox(p, Vector3(0.74, 0.08, 0.32), Vector3(0, 1.1, 0.3), Kit.mat(Color(0.15, 0.15, 0.2)), 0.02, 0, Vector3(0.25, 0, 0))
		Kit.add_sphere(p, 0.025, Vector3(-0.15, 1.17, 0.3), Kit.mat(Color(0.9, 0.1, 0.1), 0.3), 0, 8)
		for b in 3:
			Kit.add_cylinder(p, 0.018, 0.02, Vector3(0.05 + b * 0.07, 1.155, 0.32), Kit.mat(screen, 0.3), 0, -1.0, 10)
		Kit.add_rbox(p, Vector3(0.82, 0.18, 0.5), Vector3(0, 1.95, -0.1), Kit.flat(screen.darkened(0.3)), 0.02)
	# A bar along the west wall with stools, bottles on a back shelf.
	var wood := _wood(Color("3b2618"), 0.4)
	Kit.add_rbox(self, Vector3(0.6, 1.05, 4.0), Vector3(-6.2, 0.525, -13.0), wood, 0.03, Kit.LAYER_FURNITURE)
	Kit.add_rbox(self, Vector3(0.78, 0.05, 4.1), Vector3(-6.15, 1.07, -13.0), Kit.mat(Color("111111"), 0.15, 0.3), 0.02)
	Kit.add_rbox(self, Vector3(0.25, 0.03, 3.4), Vector3(-6.66, 1.6, -13.0), wood, 0.01)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var bottle_x: Array[Transform3D] = []
	var bottle_c: Array = []
	for i in 14:
		var h := rng.randf_range(0.8, 1.2)
		bottle_x.append(Transform3D(Basis.IDENTITY.scaled(Vector3(1, h, 1)), Vector3(-6.66, 1.615 + 0.14 * h, -14.6 + i * 0.24)))
		bottle_c.append([Color(0.2, 0.5, 0.2, 1), Color(0.55, 0.3, 0.1, 1), Color(0.75, 0.75, 0.8, 1), Color(0.5, 0.1, 0.15, 1)][i % 4])
	Kit.add_multimesh(self, Kit.capsule_mesh(0.035, 0.28, 10), bottle_x, Kit.mm_mat(0.15), bottle_c)
	for i in 4:
		var z := -14.4 + i * 0.95
		Kit.add_cylinder(self, 0.03, 0.72, Vector3(-5.5, 0.36, z), Kit.mat(Color(0.7, 0.7, 0.72), 0.3, 0.9), 0, -1.0, 8)
		Kit.add_cylinder(self, 0.2, 0.025, Vector3(-5.5, 0.015, z), Kit.mat(Color(0.7, 0.7, 0.72), 0.3, 0.9), 0, -1.0, 16)
		Kit.add_rbox(self, Vector3(0.4, 0.08, 0.4), Vector3(-5.5, 0.76, z), _fabric(Color("b3283a")), 0.035)
	# A sofa to watch from.
	_sofa(Vector3(2.4, 0, -8.3), PI, Color("4b2a6b"), 1.6)
	Kit.omni(self, Vector3(-2.6, 3.4, -13.0), Color(0.9, 0.95, 1.0), 1.5, 8.0)
	Kit.omni(self, Vector3(3.8, 3.4, -13.0), Color(0.95, 0.9, 1.0), 1.3, 8.0)
	Kit.omni(self, Vector3(0, 3.0, -9.0), Color(1.0, 0.85, 0.95), 0.6, 6.0)


func _gym() -> void:
	var court := Kit.tmat(Color("c9955c"), "planks", 0.6, 0.35)
	var wall := Kit.tmat(Color("dfe3e8"), "bricks", 0.6, 0.9)
	var ceiling := Kit.mat(Color("8e98a3"), 0.9)
	_room(7, 21, -7, 7, 7.0, court, wall, ceiling, Kit.mat(Color("2f5fa8"), 0.6), {"w": 0.0})
	var line := Kit.mat(Color(0.97, 0.97, 0.97), 0.6)
	var paint := Kit.mat(Color("2f5fa8"), 0.5)
	# The key: from the baseline at x = 20.8 out to the free-throw line at x = 16.2.
	Kit.add_box(self, Vector3(4.6, 0.006, 4.0), Vector3(18.5, 0.003, 0), paint)
	Kit.add_box(self, Vector3(0.06, 0.008, 4.0), Vector3(16.2, 0.004, 0), line)
	for z: float in [-2.0, 2.0]:
		Kit.add_box(self, Vector3(4.6, 0.008, 0.06), Vector3(18.5, 0.004, z), line)
	for i in 24:   # free-throw circle and three-point arc, as dashes
		var a := PI * (i / 23.0) - PI / 2
		Kit.add_box(self, Vector3(0.06, 0.008, 0.2), Vector3(16.2 - cos(a) * 1.8, 0.004, sin(a) * 1.8), line, 0, Vector3(0, -a, 0))
	for i in 40:
		var a := PI * 0.86 * (i / 39.0) - PI * 0.43
		Kit.add_box(self, Vector3(0.06, 0.008, 0.3), Vector3(20.2 - cos(a) * 6.0, 0.004, sin(a) * 6.0), line, 0, Vector3(0, -a, 0))
	Kit.add_box(self, Vector3(0.06, 0.008, 13.6), Vector3(9.5, 0.004, 0), line)
	# Bleachers along the north wall.
	var bench := _wood(Color("8a5a2e"), 0.6)
	for row in 3:   # row 0 is the front (lowest) step
		var z := -6.45 + (2 - row) * 0.7
		Kit.add_rbox(self, Vector3(9.0, 0.45 * (row + 1), 0.7), Vector3(14.0, 0.225 * (row + 1), z), Kit.mat(Color("5a5f66"), 0.6, 0.4), 0.02, Kit.LAYER_FURNITURE)
		Kit.add_rbox(self, Vector3(9.0, 0.05, 0.4), Vector3(14.0, 0.45 * (row + 1) + 0.025, z + 0.12), bench, 0.02)
	# Banners and high windows.
	var banners := [Color("c62f3a"), Color("2f5fa8"), Color("e9b23b"), Color("2f9d62")]
	for i in 4:
		Kit.add_box(self, Vector3(1.0, 1.6, 0.02), Vector3(10.5 + i * 2.6, 5.2, 6.75), Kit.tmat(banners[i], "fabric", 6.0, 0.9))
		Kit.add_cylinder(self, 0.015, 1.15, Vector3(10.5 + i * 2.6, 6.02, 6.74), Kit.mat(Color(0.3, 0.3, 0.3), 0.4, 0.8), 0, -1.0, 6, Vector3(0, 0, PI / 2))
	for i in 4:
		_window(Vector3(10.0 + i * 3.2, 5.6, -6.77), 0.0, Vector2(2.0, 1.2))
	_sign(Vector3(13.5, 4.2, 6.76), PI, "WORLDWIDE GYM", 0.4, Color(0.15, 0.2, 0.3))
	Kit.omni(self, Vector3(11.0, 6.2, 0), Color(1, 1, 1), 1.6, 11.0)
	Kit.omni(self, Vector3(18.0, 6.2, 0), Color(1, 1, 1), 1.8, 11.0)


func _lounge() -> void:
	var floor_m := Kit.tmat(Color("6a4630"), "planks", 0.5, 0.45)
	var wall := Kit.tmat(Color("7a5444"), "plaster", 0.5, 0.9)
	var ceiling := Kit.mat(Color("3a2a20"), 0.9)
	var panel := Kit.tmat(Color("4a2f1f"), "planks", 1.0, 0.5)
	_room(-21, -7, -7, 7, 4.0, floor_m, wall, ceiling, _wood(Color("2e1c12"), 0.4), {"e": 0.0}, panel)
	# Fireplace on the west wall: a stone surround with a real opening, a sooty firebox behind,
	# a hearth in front and a wooden mantel. The fire burns inside.
	var stone := Kit.tmat(Color("8d877e"), "pavers", 1.2, 0.95)
	var soot := Kit.tmat(Color(0.12, 0.1, 0.09), "bricks", 1.5, 0.95)
	var face_x := -20.25   # front face of the surround
	Kit.add_rbox(self, Vector3(0.55, 2.4, 0.75), Vector3(face_x - 0.275, 1.2, -1.05), stone, 0.03, Kit.LAYER_FURNITURE)
	Kit.add_rbox(self, Vector3(0.55, 2.4, 0.75), Vector3(face_x - 0.275, 1.2, 1.05), stone, 0.03, Kit.LAYER_FURNITURE)
	Kit.add_rbox(self, Vector3(0.55, 1.4, 1.4), Vector3(face_x - 0.275, 1.7, 0), stone, 0.03, Kit.LAYER_FURNITURE)
	Kit.add_box(self, Vector3(0.04, 1.0, 1.4), Vector3(-20.78, 0.5, 0), soot)
	for sz: float in [-0.68, 0.68]:
		Kit.add_box(self, Vector3(0.55, 1.0, 0.04), Vector3(face_x - 0.275, 0.5, sz), soot)
	Kit.add_box(self, Vector3(0.6, 0.04, 1.4), Vector3(face_x - 0.27, 0.02, 0), Kit.mat(Color(0.08, 0.07, 0.06)), Kit.LAYER_FURNITURE)
	Kit.add_rbox(self, Vector3(0.75, 0.08, 2.4), Vector3(face_x + 0.32, 0.04, 0), stone, 0.02, Kit.LAYER_FURNITURE)
	var mantel := _wood(Color("3b2618"), 0.35)
	Kit.add_rbox(self, Vector3(0.36, 0.12, 2.9), Vector3(face_x + 0.05, 2.46, 0), mantel, 0.025)
	Kit.add_rbox(self, Vector3(0.24, 0.06, 2.7), Vector3(face_x + 0.02, 2.37, 0), mantel, 0.02)
	var brass := Kit.mat(Color(0.75, 0.6, 0.3), 0.3, 0.85)
	for sz: float in [-1.15, 1.15]:
		Kit.add_cylinder(self, 0.045, 0.03, Vector3(face_x + 0.05, 2.535, sz), brass, 0, 0.035, 12)
		Kit.add_cylinder(self, 0.014, 0.2, Vector3(face_x + 0.05, 2.65, sz), brass, 0, 0.012, 8)
		Kit.add_cylinder(self, 0.022, 0.16, Vector3(face_x + 0.05, 2.83, sz), Kit.mat(Color(0.97, 0.95, 0.9)), 0, -1.0, 10)
		Kit.add_sphere(self, 0.011, Vector3(face_x + 0.05, 2.93, sz), Kit.mat(Color(1.0, 0.8, 0.4), 0.9, 0.0, 4.0), 0, 6)
	# Mantel clock.
	Kit.add_rbox(self, Vector3(0.12, 0.24, 0.3), Vector3(face_x + 0.05, 2.64, 0), mantel, 0.04)
	Kit.add_cylinder(self, 0.09, 0.01, Vector3(face_x + 0.115, 2.66, 0), Kit.mat(Color(0.96, 0.94, 0.88)), 0, -1.0, 16, Vector3(0, 0, PI / 2))
	var fire := Fire.new(0.75, 2.0, false)
	fire.position = Vector3(face_x - 0.3, 0.04, 0)
	add_child(fire)
	_painting(Vector3(-20.77, 3.3, 0), PI / 2, Vector2(1.6, 0.8), Color("1c2b3a"), Color("d9822b"))
	# Seating round a rug facing the fire.
	Kit.add_rbox(self, Vector3(4.2, 0.014, 4.6), Vector3(-17.4, 0.007, 0), Kit.tmat(Color("2d4b3e"), "carpet", 3.0, 1.0), 0.006)
	Kit.add_box(self, Vector3(3.8, 0.016, 4.2), Vector3(-17.4, 0.008, 0), Kit.tmat(Color("3b6150"), "carpet", 3.0, 1.0))
	_sofa(Vector3(-15.6, 0, 0), -PI / 2, Color("8c2f39"), 2.6, Color("e0c27a"))
	_sofa(Vector3(-17.6, 0, -2.3), 0.0, Color("8c2f39"), 2.0, Color("e0c27a"))
	_sofa(Vector3(-17.6, 0, 2.3), PI, Color("8c2f39"), 2.0, Color("e0c27a"))
	_table(Vector3(-17.6, 0, 0), Vector3(1.2, 0.4, 1.4), mantel, mantel)
	# Bookshelves along the north wall, full of books.
	var shelf := _wood(Color("3b2618"), 0.5)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var book_x: Array[Transform3D] = []
	var book_c: Array = []
	for i in 3:
		var x := -19.0 + i * 2.2
		var p := _pivot(Vector3(x, 0, -6.55), 0.0)
		Kit.add_box(p, Vector3(2.0, 3.0, 0.04), Vector3(0, 1.5, -0.2), shelf)
		for sx: float in [-0.98, 0.98]:
			Kit.add_rbox(p, Vector3(0.05, 3.0, 0.42), Vector3(sx, 1.5, 0), shelf, 0.01, Kit.LAYER_FURNITURE)
		for row in 5:
			Kit.add_rbox(p, Vector3(1.92, 0.035, 0.4), Vector3(0, 0.1 + row * 0.68, 0), shelf, 0.008)
			if row < 4:
				_books(p, -0.92, 0.92, 0.12 + row * 0.68, 0.0, rng, book_x, book_c)
	Kit.add_multimesh(self, Kit.box_mesh(Vector3.ONE), book_x, Kit.mm_mat(0.8), book_c)
	# Card table with chairs, lamps, plants.
	var table_pos := Vector3(-11.5, 0, -4.0)
	_table(table_pos, Vector3(1.2, 0.75, 1.2), Kit.tmat(Color("1f5a3a"), "fabric", 6.0, 0.95), shelf)
	for a: float in [0.0, PI / 2, PI, -PI / 2]:
		var out := Vector3(sin(a), 0, cos(a))
		_chair(table_pos + out * 0.85, a + PI, shelf, _fabric(Color("6b2a30")))
	_floor_lamp(Vector3(-14.0, 0, -2.6))
	_floor_lamp(Vector3(-14.0, 0, 2.6))
	_plant(Vector3(-20.3, 0, -6.2))
	_plant(Vector3(-20.3, 0, 6.2))
	_window(Vector3(-15.0, 2.0, 6.77), PI, Vector2(1.8, 1.6), Color(1.0, 0.75, 0.5))
	Kit.omni(self, Vector3(-11.0, 3.4, 0), Color(1.0, 0.85, 0.7), 1.0, 9.0)
	Kit.omni(self, Vector3(-11.0, 3.0, 5.0), Color(1.0, 0.8, 0.6), 0.7, 5.0)


# ---------------------------------------------------------------- outdoors

func _patio() -> void:
	var pavers := Kit.tmat(Color("cbbfab"), "pavers", 0.4, 0.85)
	# Floor round the pool hole: [x0, x1, z0, z1].
	var px0 := POOL.position.x
	var px1 := POOL.end.x
	var pz0 := POOL.position.y
	var pz1 := POOL.end.y
	for r: Array in [[-10.0, px0, 7.0, 21.0], [px1, 10.0, 7.0, 21.0], [px0, px1, 7.0, pz0], [px0, px1, pz1, 21.0]]:
		_s(Kit.add_box(self, Vector3(r[1] - r[0], 0.1, r[3] - r[2]), Vector3((r[0] + r[1]) / 2.0, -0.05, (r[2] + r[3]) / 2.0), pavers, Kit.LAYER_STRUCTURE))
	_railing()
	# The house's back wall seen from outside: brick, lit windows with sills, a door frame,
	# wall lights beside the door, and the roof edge.
	var brick := Kit.tmat(Color("b5876a"), "bricks", 0.6, 0.95)
	_wall_x(7.06, -21.2, 21.2, 7.6, brick, 0.0, 0.08)
	for x: float in [-16.0, -12.0, -3.8, 3.8, 12.0, 16.0]:
		_window(Vector3(x, 2.6, 7.12), 0.0, Vector2(1.4, 2.0), Color(1.0, 0.85, 0.6))
	for x: float in [-16.0, -10.0, -4.0, 4.0, 10.0, 16.0]:
		_window(Vector3(x, 5.6, 7.12), 0.0, Vector2(1.2, 1.4), Color(1.0, 0.85, 0.6))
	var trim := Kit.mat(Color(0.95, 0.94, 0.9), 0.5)
	for sx: float in [-1.0, 1.0]:
		Kit.add_rbox(self, Vector3(0.16, DOOR_H + 0.1, 0.12), Vector3(sx * (DOOR_W / 2.0 + 0.08), DOOR_H / 2.0, 7.14), trim, 0.02)
		var lamp := Vector3(sx * (DOOR_W / 2.0 + 0.45), 2.4, 7.2)
		Kit.add_rbox(self, Vector3(0.14, 0.24, 0.1), lamp, Kit.mat(Color(0.08, 0.08, 0.08), 0.5, 0.5), 0.02)
		Kit.add_sphere(self, 0.05, lamp + Vector3(0, 0, 0.06), Kit.mat(Color(1.0, 0.82, 0.5), 0.5, 0.0, 4.0), 0, 10)
		Kit.add_sphere(self, 0.22, lamp + Vector3(0, 0, 0.06), Kit.halo_mat(Color(1.0, 0.7, 0.35), 0.5), 0, 12)
	Kit.add_rbox(self, Vector3(DOOR_W + 0.5, 0.18, 0.16), Vector3(0, DOOR_H + 0.1, 7.14), trim, 0.03)
	Kit.add_rbox(self, Vector3(43.0, 0.35, 0.8), Vector3(0, 7.65, 7.3), Kit.mat(Color("5c4a3c"), 0.8), 0.05)
	Kit.add_rbox(self, Vector3(43.0, 0.08, 0.3), Vector3(0, 0.04, 7.2), trim, 0.02)
	# Fire pit: a ring of rounded stones round a sunken bed, sofas round it.
	var fire_pos := Vector3(-5.0, 0, 15.0)
	var rock := Kit.tmat(Color("7a746c"), "plaster", 3.0, 0.95)
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	for i in 14:
		var a := TAU * i / 14.0
		var pos := fire_pos + Vector3(cos(a) * 0.82, 0.18, sin(a) * 0.82)
		Kit.add_rbox(self, Vector3(0.4, 0.36 + rng.randf_range(-0.04, 0.04), 0.26), pos, rock, 0.08, Kit.LAYER_FURNITURE,
			Vector3(rng.randf_range(-0.08, 0.08), -a + PI / 2, rng.randf_range(-0.06, 0.06)))
	Kit.add_cylinder(self, 0.7, 0.3, fire_pos + Vector3(0, 0.15, 0), Kit.tmat(Color(0.16, 0.15, 0.14), "plaster", 4.0, 1.0), Kit.LAYER_FURNITURE, -1.0, 20)
	var fire := Fire.new(0.9, 1.9)
	fire.position = fire_pos + Vector3(0, 0.3, 0)
	add_child(fire)
	for i in 3:
		var a := TAU * i / 3.0 + 0.5
		_sofa(fire_pos + Vector3(sin(a), 0, cos(a)) * 2.6, a + PI, Color("d9cbb5"), 2.0, Color("c0583a"))
	# Umbrella table and chairs in the corner by the house.
	var table_pos := Vector3(-7.3, 0, 9.7)
	var teak := _wood(Color("8a5a35"), 0.6)
	Kit.add_cylinder(self, 0.55, 0.04, table_pos + Vector3(0, 0.74, 0), teak, Kit.LAYER_FURNITURE, -1.0, 28)
	Kit.add_cylinder(self, 0.05, 0.72, table_pos + Vector3(0, 0.36, 0), teak, 0, 0.04, 10)
	Kit.add_cylinder(self, 0.3, 0.04, table_pos + Vector3(0, 0.02, 0), teak, 0, 0.25, 16)
	_umbrella(table_pos, Color("1f6f8b"))
	for k in 4:
		var a := TAU * k / 4.0 + PI / 4
		_chair(table_pos + Vector3(sin(a), 0, cos(a)) * 0.85, a + PI, teak, _fabric(Color("e8e2d4")))
	# Loungers along the pool, with an umbrella between two of them.
	for i in 3:
		_lounger(Vector3(0.75, 0, 12.4 + i * 2.25), PI / 2, i == 1)
	_umbrella(Vector3(0.9, 0, 13.55), Color("e8833a"))
	for p: Vector3 in [Vector3(-9.2, 0, 20.2), Vector3(9.2, 0, 20.2), Vector3(-9.2, 0, 7.9), Vector3(9.2, 0, 8.0), Vector3(9.2, 0, 14.0)]:
		_plant(p, 1.3)
	Kit.omni(self, Vector3(0, 3.0, 14.0), Color(1.0, 0.8, 0.55), 0.5, 10.0)


func _umbrella(pos: Vector3, color: Color) -> void:
	var pole := Kit.mat(Color(0.85, 0.85, 0.82), 0.4, 0.6)
	Kit.add_cylinder(self, 0.022, 2.4, pos + Vector3(0, 1.2, 0), pole, 0, -1.0, 8)
	var canopy := Kit.tmat(color, "fabric", 4.0, 0.9)
	Kit.add_cylinder(self, 1.3, 0.42, pos + Vector3(0, 2.25, 0), canopy, 0, 0.04, 8)
	Kit.add_cylinder(self, 1.3, 0.08, pos + Vector3(0, 2.0, 0), _fabric(color.lightened(0.5)), 0, 1.3, 8)
	Kit.add_sphere(self, 0.04, pos + Vector3(0, 2.5, 0), pole, 0, 8)
	var ribs: Array = []
	for i in 8:
		var a := TAU * (i + 0.5) / 8.0
		ribs.append(PackedVector3Array([pos + Vector3(0, 1.75, 0), pos + Vector3(cos(a) * 0.9, 2.08, sin(a) * 0.9)]))
	var rm := MeshInstance3D.new()
	rm.mesh = Kit.tube_mesh(ribs, 0.006, 4)
	rm.material_override = pole
	rm.layers = Kit.vis_layers
	add_child(rm)


## Sun lounger facing +z (feet end), backrest raised at -z.
func _lounger(pos: Vector3, yaw: float, towel := false) -> void:
	var p := _pivot(pos, yaw)
	var frame := Kit.mat(Color(0.93, 0.92, 0.88), 0.5)
	var pad := _fabric(Color("2fa6a0"))
	Kit.add_rbox(p, Vector3(0.68, 0.08, 1.9), Vector3(0, 0.3, 0), frame, 0.03)
	for sx: float in [-0.3, 0.3]:
		for sz: float in [-0.85, 0.85]:
			Kit.add_rbox(p, Vector3(0.05, 0.28, 0.05), Vector3(sx, 0.14, sz), frame, 0.015)
	Kit.add_rbox(p, Vector3(0.62, 0.08, 1.25), Vector3(0, 0.38, 0.3), pad, 0.035)
	Kit.add_rbox(p, Vector3(0.62, 0.08, 0.7), Vector3(0, 0.55, -0.6), pad, 0.035, 0, Vector3(0.65, 0, 0))
	Kit.add_rbox(p, Vector3(0.64, 0.05, 0.7), Vector3(0, 0.5, -0.64), frame, 0.02, 0, Vector3(0.65, 0, 0))
	if towel:
		Kit.add_rbox(p, Vector3(0.5, 0.015, 0.8), Vector3(0, 0.43, 0.35), _fabric(Color("f2c14e")), 0.006)
		for i in 3:
			Kit.add_box(p, Vector3(0.5, 0.017, 0.06), Vector3(0, 0.432, 0.05 + i * 0.25), Kit.mat(Color("e05a47"), 0.9))
	_collider(p, Vector3(0.7, 0.45, 1.9), Vector3(0, 0.22, 0))


## The patio railing: posts, top and bottom rails and balusters (a MultiMesh) round three
## sides, with a gap at the back leading down to the lawn. Invisible walls stop you.
func _railing() -> void:
	var white := Kit.mat(Color("f3eee6"), 0.55)
	var segs: Array = [   # [from, to] at floor level
		[Vector3(-10, 0, 7.2), Vector3(-10, 0, 21)],
		[Vector3(10, 0, 7.2), Vector3(10, 0, 21)],
		[Vector3(-10, 0, 21), Vector3(-1.4, 0, 21)],
		[Vector3(1.4, 0, 21), Vector3(10, 0, 21)],
	]
	var balusters: Array[Transform3D] = []
	for s: Array in segs:
		var a: Vector3 = s[0]
		var b: Vector3 = s[1]
		var length := a.distance_to(b)
		var mid := (a + b) / 2.0
		var along_x := absf(b.x - a.x) > absf(b.z - a.z)
		var size := Vector3(length, 0.07, 0.16) if along_x else Vector3(0.16, 0.07, length)
		_s(Kit.add_rbox(self, size, mid + Vector3(0, 1.0, 0), white, 0.025))
		_s(Kit.add_box(self, size * Vector3(1, 0.7, 0.6) if along_x else size * Vector3(0.6, 0.7, 1), mid + Vector3(0, 0.12, 0), white))
		var n := int(length / 0.16)
		for i in n:
			balusters.append(Transform3D(Basis.IDENTITY, a.lerp(b, (i + 0.5) / n) + Vector3(0, 0.56, 0)))
		var posts := int(ceil(length / 2.4))
		for i in posts + 1:
			var pp := a.lerp(b, float(i) / posts)
			_s(Kit.add_rbox(self, Vector3(0.16, 1.1, 0.16), pp + Vector3(0, 0.55, 0), white, 0.02))
			_s(Kit.add_sphere(self, 0.07, pp + Vector3(0, 1.16, 0), white, 0, 10))
		var wall := StaticBody3D.new()
		wall.collision_layer = Kit.LAYER_STRUCTURE
		wall.collision_mask = 0
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(length, 1.1, 0.15) if along_x else Vector3(0.15, 1.1, length)
		cs.shape = shape
		wall.position = mid + Vector3(0, 0.55, 0)
		wall.add_child(cs)
		add_child(wall)
	_s(Kit.add_multimesh(self, Kit.cylinder_mesh(0.028, 0.82, 0.022, 8), balusters, white))
	# Steps down to the lawn through the gap.
	for i in 2:
		_s(Kit.add_rbox(self, Vector3(2.8, 0.05, 0.4), Vector3(0, -0.03 - i * 0.02, 21.25 + i * 0.4), Kit.tmat(Color("cbbfab"), "pavers", 0.4, 0.85), 0.01))


func _pool() -> void:
	var c := Vector3(POOL.get_center().x, 0, POOL.get_center().y)
	var w := POOL.size.x
	var l := POOL.size.y
	var depth := -POOL_FLOOR
	var tile := Kit.tmat(Color(0.62, 0.86, 0.95), "tiles", 1.0, 0.3)
	var band := Kit.tmat(Color(0.12, 0.35, 0.6), "tiles", 4.0, 0.3)
	# Basin: floor and four walls, a band of dark tiles at the waterline.
	_s(Kit.add_box(self, Vector3(w, 0.1, l), c + Vector3(0, POOL_FLOOR - 0.05, 0), tile, Kit.LAYER_STRUCTURE))
	for side: Array in [[Vector3(w + 0.2, depth, 0.1), Vector3(0, -depth / 2.0, -l / 2.0 - 0.05)], [Vector3(w + 0.2, depth, 0.1), Vector3(0, -depth / 2.0, l / 2.0 + 0.05)],
			[Vector3(0.1, depth, l), Vector3(-w / 2.0 - 0.05, -depth / 2.0, 0)], [Vector3(0.1, depth, l), Vector3(w / 2.0 + 0.05, -depth / 2.0, 0)]]:
		_s(Kit.add_box(self, side[0], c + side[1], tile, Kit.LAYER_STRUCTURE))
	for side: Array in [[Vector3(w, 0.15, 0.01), Vector3(0, -0.1, -l / 2.0 + 0.005)], [Vector3(w, 0.15, 0.01), Vector3(0, -0.1, l / 2.0 - 0.005)],
			[Vector3(0.01, 0.15, l), Vector3(-w / 2.0 + 0.005, -0.1, 0)], [Vector3(0.01, 0.15, l), Vector3(w / 2.0 - 0.005, -0.1, 0)]]:
		_s(Kit.add_box(self, side[0], c + side[1], band))
	# Lane line and lights in the walls.
	_s(Kit.add_box(self, Vector3(0.2, 0.01, l - 1.0), c + Vector3(0, POOL_FLOOR + 0.006, 0), Kit.tmat(Color(0.1, 0.3, 0.55), "tiles", 4.0, 0.3)))
	for sz: float in [-1.0, 1.0]:
		var lp := c + Vector3(w / 2.0 - 0.005, -0.6, sz * 2.0)
		_s(Kit.add_cylinder(self, 0.1, 0.02, lp, Kit.mat(Color(0.7, 0.95, 1.0), 0.3, 0.0, 3.0), 0, -1.0, 16, Vector3(0, 0, PI / 2)))
	var under := Kit.omni(self, c + Vector3(0, -0.7, 0), Color(0.5, 0.9, 1.0), 1.2, 4.2)
	under.omni_attenuation = 2.0
	# Water.
	var water := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(w, l)
	plane.subdivide_width = 12
	plane.subdivide_depth = 16
	water.mesh = plane
	var sh := Shader.new()
	sh.code = WATER_SHADER
	var wm := ShaderMaterial.new()
	wm.shader = sh
	water.material_override = wm
	water.position = c + Vector3(0, WATER_Y, 0)
	water.layers = Kit.vis_layers
	add_child(water)
	_s(water)
	# Coping round the edge (balls and props land on it).
	var coping := Kit.tmat(Color("eee8de"), "pavers", 1.5, 0.7)
	for side: Array in [[Vector3(w + 0.7, 0.07, 0.35), Vector3(0, 0.035, -l / 2.0 - 0.175)], [Vector3(w + 0.7, 0.07, 0.35), Vector3(0, 0.035, l / 2.0 + 0.175)],
			[Vector3(0.35, 0.07, l), Vector3(-w / 2.0 - 0.175, 0.035, 0)], [Vector3(0.35, 0.07, l), Vector3(w / 2.0 + 0.175, 0.035, 0)]]:
		Kit.add_rbox(self, side[0], c + side[1], coping, 0.03, Kit.LAYER_FURNITURE)
	# You can't walk into the pool.
	_collider(self, Vector3(w + 0.3, 2.0, l + 0.3), c + Vector3(0, 1.0, 0), Kit.LAYER_BLOCKER)
	# Ladder on the west side: two bent rails and three treads.
	var steel := Kit.mat(Color(0.85, 0.86, 0.88), 0.2, 0.95)
	var rails: Array = []
	var lx := POOL.position.x
	for sz: float in [-0.25, 0.25]:
		var z := 13.0 + sz
		rails.append(PackedVector3Array([Vector3(lx - 0.3, 0.0, z), Vector3(lx - 0.3, 0.75, z), Vector3(lx - 0.22, 0.92, z),
			Vector3(lx - 0.05, 0.95, z), Vector3(lx + 0.1, 0.8, z), Vector3(lx + 0.14, 0.5, z), Vector3(lx + 0.14, -1.0, z)]))
	var lm := MeshInstance3D.new()
	lm.mesh = Kit.tube_mesh(rails, 0.022, 8)
	lm.material_override = steel
	lm.layers = Kit.vis_layers
	add_child(lm)
	for i in 3:
		Kit.add_rbox(self, Vector3(0.12, 0.03, 0.5), Vector3(lx + 0.12, -0.3 - i * 0.3, 13.0), steel, 0.01)
	# Floats bobbing on the water.
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.28
	torus.outer_radius = 0.5
	torus.rings = 24
	torus.ring_segments = 12
	ring.mesh = torus
	ring.material_override = Kit.mat(Color(1.0, 0.45, 0.55), 0.35)
	ring.position = c + Vector3(1.2, WATER_Y, -1.5)
	ring.layers = Kit.vis_layers
	add_child(ring)
	_floats.append(ring)
	# A beach ball: white with coloured bands.
	var ball := Node3D.new()
	ball.position = c + Vector3(-1.4, WATER_Y, 1.8)
	add_child(ball)
	Kit.add_sphere(ball, 0.2, Vector3(0, 0.12, 0), Kit.mat(Color(0.97, 0.97, 0.95), 0.3), 0, 16)
	var bands := [Color(0.95, 0.2, 0.2), Color(0.2, 0.45, 0.95), Color(1, 0.8, 0.15)]
	for i in 3:
		var band_mesh := TorusMesh.new()
		band_mesh.inner_radius = 0.17
		band_mesh.outer_radius = 0.205
		band_mesh.rings = 24
		band_mesh.ring_segments = 6
		var bm := MeshInstance3D.new()
		bm.mesh = band_mesh
		bm.material_override = Kit.mat(bands[i], 0.3)
		bm.position = Vector3(0, 0.12, 0)
		bm.rotation = Vector3(PI / 2, i * PI / 3, 0)
		bm.layers = Kit.vis_layers
		ball.add_child(bm)
	_floats.append(ball)


## Strings of warm bulbs on real wires: round the patio's edges between posts, and across it
## from hooks on the house. Each bulb hangs on a short drop from the wire in a socket and has
## a glow round it. Bulbs, sockets and glows are MultiMeshes.
func _string_lights() -> void:
	var wood := _wood(Color("4a3020"), 0.7)
	var h := 3.3
	var posts := [Vector3(-9.6, 0, 7.7), Vector3(-9.6, 0, 20.6), Vector3(-3.3, 0, 20.6), Vector3(3.3, 0, 20.6),
		Vector3(9.6, 0, 20.6), Vector3(9.6, 0, 7.7)]
	for p: Vector3 in posts:
		Kit.add_cylinder(self, 0.07, h + 0.15, p + Vector3(0, (h + 0.15) / 2.0, 0), wood, Kit.LAYER_FURNITURE, 0.055, 10)
		Kit.add_sphere(self, 0.07, p + Vector3(0, h + 0.17, 0), wood, 0, 8)
		Kit.add_cylinder(self, 0.2, 0.06, p + Vector3(0, 0.03, 0), Kit.mat(Color(0.3, 0.3, 0.3), 0.6, 0.4), 0, 0.12, 12)
	var hooks := [Vector3(-6.0, 3.6, 7.18), Vector3(-2.0, 3.6, 7.18), Vector3(2.0, 3.6, 7.18), Vector3(6.0, 3.6, 7.18)]
	for hk: Vector3 in hooks:
		Kit.add_cylinder(self, 0.015, 0.12, hk, Kit.mat(Color(0.1, 0.1, 0.1)), 0, -1.0, 6, Vector3(PI / 2, 0, 0))
	var top := Vector3(0, h, 0)
	var spans: Array = []   # [a, b, sag]
	for i in posts.size() - 1:
		var a: Vector3 = posts[i] + top
		var b: Vector3 = posts[i + 1] + top
		spans.append([a, b, 0.25 + a.distance_to(b) * 0.035])
	spans.append([hooks[0], posts[3] + top, 0.8])
	spans.append([hooks[3], posts[2] + top, 0.8])
	spans.append([hooks[1], posts[1] + top, 0.75])
	spans.append([hooks[2], posts[4] + top, 0.75])
	var wires: Array = []
	var bulbs: Array[Transform3D] = []
	var sockets: Array[Transform3D] = []
	var halos: Array[Transform3D] = []
	var tint: Array = []
	for s: Array in spans:
		var a: Vector3 = s[0]
		var b: Vector3 = s[1]
		var length := a.distance_to(b)
		var pts := Kit.catenary(a, b, s[2], maxi(int(length * 2.0), 8))
		wires.append(pts)
		var count := int(length / 0.9)
		for k in count:
			var t := (k + 0.5) / count
			var on := a.lerp(b, t)
			on.y -= s[2] * 4.0 * t * (1.0 - t)
			var drop := on - Vector3(0, 0.07, 0)
			wires.append(PackedVector3Array([on, drop]))
			sockets.append(Transform3D(Basis.IDENTITY, drop - Vector3(0, 0.02, 0)))
			var bulb := drop - Vector3(0, 0.075, 0)
			bulbs.append(Transform3D(Basis.IDENTITY.scaled(Vector3(1.0, 1.35, 1.0)), bulb))
			halos.append(Transform3D(Basis.IDENTITY, bulb))
			tint.append(Color(1.0, 0.86, 0.6).lerp(Color(1.0, 0.72, 0.42), randf()))
	var wm := MeshInstance3D.new()
	wm.mesh = Kit.tube_mesh(wires, 0.005, 4)
	wm.material_override = Kit.mat(Color(0.06, 0.06, 0.06), 0.6)
	wm.layers = Kit.vis_layers
	add_child(wm)
	Kit.add_multimesh(self, Kit.cylinder_mesh(0.017, 0.045, 0.014, 8), sockets, Kit.mat(Color(0.08, 0.08, 0.08), 0.5))
	var bulb_mat := StandardMaterial3D.new()
	bulb_mat.vertex_color_use_as_albedo = true
	bulb_mat.emission_enabled = true
	bulb_mat.emission = Color(1.0, 0.75, 0.45)
	bulb_mat.emission_energy_multiplier = 3.5
	bulb_mat.roughness = 0.3
	Kit.add_multimesh(self, Kit.sphere_mesh(0.032, 10), bulbs, bulb_mat, tint)
	Kit.add_multimesh(self, Kit.sphere_mesh(0.2, 12), halos, Kit.halo_mat(Color(1.0, 0.68, 0.32), 0.55))
	# A couple of soft lights so the bulbs actually light the patio.
	Kit.omni(self, Vector3(-5.0, 2.8, 11.0), Color(1.0, 0.75, 0.45), 0.6, 8.0)
	Kit.omni(self, Vector3(5.0, 2.8, 17.0), Color(1.0, 0.75, 0.45), 0.6, 8.0)


func _grounds() -> void:
	# The ground, in four pieces round the pool so you can see into it.
	var grass := Kit.tmat(Color("4f7d3b"), "grass", 0.3, 1.0)
	var px0 := POOL.position.x
	var px1 := POOL.end.x
	for r: Array in [[-80.0, px0, -50.0, 110.0], [px1, 80.0, -50.0, 110.0], [px0, px1, -50.0, POOL.position.y], [px0, px1, POOL.end.y, 110.0]]:
		_s(Kit.add_box(self, Vector3(r[1] - r[0], 0.1, r[3] - r[2]), Vector3((r[0] + r[1]) / 2.0, -0.1, (r[2] + r[3]) / 2.0), grass, Kit.LAYER_STRUCTURE))
	# Trees: trunks and leafy crowns of several overlapping balls, all MultiMeshes.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var trunks: Array[Transform3D] = []
	var crowns: Array[Transform3D] = []
	var crown_c: Array = []
	var placed := 0
	while placed < 26:
		var p := Vector3(rng.randf_range(-45, 45), -0.05, rng.randf_range(10, 70))
		if absf(p.x) < 15.0 and p.z < 38.0:
			continue
		var s := rng.randf_range(0.8, 1.6)
		trunks.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s)), p + Vector3(0, 1.5 * s, 0)))
		for k in 6:
			var off := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.4, 0.8), rng.randf_range(-1.0, 1.0)) * s
			var r := rng.randf_range(1.0, 1.6) * s
			crowns.append(Transform3D(Basis.IDENTITY.scaled(Vector3(r, r * 0.85, r)), p + Vector3(0, 3.6 * s, 0) + off))
			crown_c.append(Color(0.17, 0.36, 0.16).lerp(Color(0.3, 0.5, 0.22), rng.randf()))
		placed += 1
	_s(Kit.add_multimesh(self, Kit.cylinder_mesh(0.22, 3.0, 0.14, 8), trunks, Kit.tmat(Color("5a3d26"), "bark", 1.0, 1.0)))
	_s(Kit.add_multimesh(self, Kit.sphere_mesh(1.0, 10), crowns, Kit.mm_mat(0.95, "grass", 0.6), crown_c))
	# Hedges round the lawn, with flowers along the front, and a gap at the patio steps.
	var hedge := Kit.tmat(Color("2f5a2c"), "grass", 1.5, 1.0)
	var hedges := [[Vector3(-13, 0.6, 29.5), Vector3(0.9, 1.2, 17)], [Vector3(13, 0.6, 29.5), Vector3(0.9, 1.2, 17)],
		[Vector3(0, 0.6, 38.2), Vector3(26.9, 1.2, 0.9)], [Vector3(-11.4, 0.6, 14.5), Vector3(0.9, 1.1, 14.5)],
		[Vector3(11.4, 0.6, 14.5), Vector3(0.9, 1.1, 14.5)]]
	var flowers: Array[Transform3D] = []
	var flower_c: Array = []
	var palette := [Color(0.95, 0.3, 0.4), Color(1.0, 0.85, 0.3), Color(0.85, 0.5, 0.95), Color(1, 1, 1), Color(1.0, 0.55, 0.2)]
	for hd: Array in hedges:
		var pos: Vector3 = hd[0]
		var size: Vector3 = hd[1]
		_s(Kit.add_rbox(self, size, pos, hedge, 0.3))
		var long := maxf(size.x, size.z)
		for i in int(long * 3.0):
			var t := rng.randf_range(-0.5, 0.5) * long
			var side := 1.0 if rng.randf() > 0.5 else -1.0
			var fp := pos + (Vector3(t, 0, side * (size.z / 2.0 + 0.15)) if size.x > size.z else Vector3(side * (size.x / 2.0 + 0.15), 0, t))
			fp.y = rng.randf_range(0.05, 0.25)
			flowers.append(Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * rng.randf_range(0.7, 1.3)), fp))
			flower_c.append(palette[rng.randi() % palette.size()])
	_s(Kit.add_multimesh(self, Kit.sphere_mesh(0.06, 6), flowers, Kit.mm_mat(0.8), flower_c))
	# Stepping stones from the steps to the cornhole boards.
	var stones: Array[Transform3D] = []
	for i in 9:
		stones.append(Transform3D(Basis(Vector3.UP, rng.randf_range(-0.4, 0.4)), Vector3(-1.4 + 0.25 * sin(i * 1.7), -0.045, 22.4 + i * 1.0)))
	_s(Kit.add_multimesh(self, Kit.rbox_mesh(Vector3(0.6, 0.04, 0.45), 0.08), stones, Kit.tmat(Color("b3aa9c"), "plaster", 2.0, 0.9)))
	_sign(Vector3(0, 1.4, 20.95), PI, "CORNHOLE  (down the steps)", 0.16, Color(1, 0.95, 0.8))
	Kit.omni(self, Vector3(0, 3.0, 28.0), Color(1.0, 0.8, 0.55), 0.5, 9.0)
