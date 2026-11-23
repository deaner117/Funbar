extends Node3D
## A human hand built from rounded pieces: palm, thumb pad, wrist, and five jointed fingers with
## nails. Fingers curl with the controller: grip curls middle/ring/pinky (and the thumb a
## little), trigger curls the index. A sleeve cuff at the wrist shows the player's colour.
##
## Modelled as a right hand, palm down, fingers along -Z, back of the hand +Y, thumb toward -X;
## a left hand is the mirror image. The whole hand is rolled so the palm faces in toward the
## controller grip, the way you actually hold one.

const Kit := preload("res://kit.gd")

## Light skin to start; more tones later (set_skin).
const SKIN := Color(0.95, 0.78, 0.66)
## [x, knuckle z, segment lengths, base radius] for index, middle, ring, pinky (right hand).
const FINGERS := [
	[-0.0285, -0.044, [0.041, 0.025, 0.021], 0.0093],
	[-0.0095, -0.047, [0.046, 0.028, 0.022], 0.0096],
	[0.0095, -0.045, [0.043, 0.027, 0.021], 0.0090],
	[0.0275, -0.039, [0.033, 0.021, 0.019], 0.0080],
]
## Bend per joint for a full curl (radians): knuckle, middle, tip.
const CURL := [1.35, 1.55, 1.0]
const REST := 0.18

var is_right := true
var skin_mat: StandardMaterial3D
var nail_mat: StandardMaterial3D
var cuff_mat: StandardMaterial3D
## Per finger (index, middle, ring, pinky, thumb): joint nodes, knuckle first.
var _joints: Array = []
var _grip := 0.0
var _trigger := 0.0
var _shown_grip := -1.0
var _shown_trigger := -1.0


func _init(right := true) -> void:
	is_right = right


func _ready() -> void:
	var s := 1.0 if is_right else -1.0
	skin_mat = StandardMaterial3D.new()
	skin_mat.albedo_color = SKIN
	skin_mat.roughness = 0.55
	skin_mat.rim_enabled = true
	skin_mat.rim = 0.25
	skin_mat.rim_tint = 0.6
	nail_mat = StandardMaterial3D.new()
	nail_mat.albedo_color = Color(0.98, 0.86, 0.82)
	nail_mat.roughness = 0.25
	cuff_mat = StandardMaterial3D.new()
	cuff_mat.albedo_color = Color(0.3, 0.55, 1.0)
	cuff_mat.roughness = 0.8

	var root := Node3D.new()
	# Palm turned in toward the grip, fingers pointing a little down the controller.
	root.rotation = Vector3(-0.25, 0.0, -1.05 * s)
	add_child(root)

	# Palm, thumb pad, wrist, sleeve.
	_mesh(root, Kit.rbox_mesh(Vector3(0.080, 0.027, 0.088), 0.0125, 3), skin_mat, Vector3(0, 0, 0))
	var pad := _mesh(root, Kit.sphere_mesh(0.02, 12), skin_mat, Vector3(-0.026 * s, -0.008, 0.016))
	pad.scale = Vector3(1.0, 0.75, 1.5)
	var heel := _mesh(root, Kit.sphere_mesh(0.02, 12), skin_mat, Vector3(0.018 * s, -0.007, 0.024))
	heel.scale = Vector3(1.3, 0.6, 1.0)
	var wrist := _mesh(root, Kit.capsule_mesh(0.024, 0.11, 14), skin_mat, Vector3(0, 0.0, 0.075))
	wrist.rotation.x = PI / 2
	wrist.scale = Vector3(1.25, 1.0, 0.8)
	# A wristband in the player's colour.
	var band := TorusMesh.new()
	band.inner_radius = 0.023
	band.outer_radius = 0.033
	band.rings = 20
	band.ring_segments = 8
	var cuff := _mesh(root, band, cuff_mat, Vector3(0, 0.0, 0.1))
	cuff.rotation.x = PI / 2
	cuff.scale = Vector3(1.25, 1.5, 0.82)

	# Fingers.
	for f: Array in FINGERS:
		var base := Node3D.new()
		base.position = Vector3(float(f[0]) * s, 0.002, float(f[1]))
		# Fingers fan out a touch.
		base.rotation.y = -float(f[0]) * 0.9 * s
		root.add_child(base)
		_joints.append(_finger(base, f[2], float(f[3])))

	# Thumb: from the base of the palm, out to the side and forward, rolled so it bends
	# across the palm.
	var tb := Node3D.new()
	tb.position = Vector3(-0.03 * s, -0.007, 0.02)
	tb.rotation = Vector3(-0.3, 0.62 * s, 1.15 * s)
	root.add_child(tb)
	_joints.append(_finger(tb, [0.036, 0.031, 0.026], 0.0118))
	set_curl(0.0, 0.0)


## A chain of capsule segments; returns the joint nodes. The last one gets a nail.
func _finger(base: Node3D, lengths: Array, radius: float) -> Array:
	var joints := []
	var parent := base
	var r := radius
	for k in lengths.size():
		var seg_len: float = lengths[k]
		var j := Node3D.new()
		if k > 0:
			j.position = Vector3(0, 0, -float(lengths[k - 1]))
		parent.add_child(j)
		var seg := _mesh(j, Kit.capsule_mesh(r, seg_len + r * 1.6, 10), skin_mat, Vector3(0, 0, -seg_len / 2.0))
		seg.rotation.x = -PI / 2
		seg.scale = Vector3(1.08, 1.0, 0.92)   # fingers are a little wider than deep
		if k == lengths.size() - 1:
			var nail := _mesh(j, Kit.sphere_mesh(r, 10), nail_mat, Vector3(0, r * 0.62, -seg_len * 0.62))
			nail.scale = Vector3(0.82, 0.38, 0.95)
		joints.append(j)
		parent = j
		r *= 0.9
	return joints


func _mesh(parent: Node3D, m: Mesh, material: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = material
	mi.position = pos
	mi.layers = Kit.VIS_ALL
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func set_cuff_color(c: Color) -> void:
	cuff_mat.albedo_color = c


func set_skin(c: Color) -> void:
	skin_mat.albedo_color = c


## grip and trigger 0..1 (only re-poses when they change).
func set_curl(grip: float, trigger: float) -> void:
	_grip = clampf(grip, 0.0, 1.0)
	_trigger = clampf(trigger, 0.0, 1.0)
	if absf(_grip - _shown_grip) < 0.01 and absf(_trigger - _shown_trigger) < 0.01:
		return
	_shown_grip = _grip
	_shown_trigger = _trigger
	for i in 4:
		var amount := _trigger if i == 0 else _grip
		var c := REST + (1.0 - REST) * amount
		if i == 0:
			c = REST * 0.6 + (0.85 - REST * 0.6) * amount   # index curls round the trigger
		var joints: Array = _joints[i]
		for k in 3:
			(joints[k] as Node3D).rotation.x = -CURL[k] * c
	var thumb: Array = _joints[4]
	var tc := 0.15 + 0.45 * _grip
	(thumb[0] as Node3D).rotation.x = -0.25 * tc
	(thumb[1] as Node3D).rotation.x = -0.8 * tc
	(thumb[2] as Node3D).rotation.x = -0.9 * tc
