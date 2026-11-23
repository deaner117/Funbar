extends Node3D
## A friend in the mansion: head (with visor), body, two gloves and a name tag, moved smoothly
## toward the poses they send (~15 a second). Their voice plays from `voice_player` on the head.

const Kit := preload("res://kit.gd")
const HandModel := preload("res://hand_model.gd")
const SMOOTH := 16.0
const SPEAKING_HOLD := 0.3

var slot := -1
var display_name := "Friend"
var color := Color(1.0, 0.6, 0.2)
var voice_player: AudioStreamPlayer3D
var speaking_until := 0.0

var head: Node3D
var hands: Array = []   # HandModel: left, right
var _torso: MeshInstance3D
var _tag: Label3D
var _mat: StandardMaterial3D
var _visor_mat: StandardMaterial3D
var _targets: Array = [null, null, null]   # head, left, right (Transform3D or null)
var _seen: Array = [false, false, false]
var _hand_age: Array = [99.0, 99.0]


func _ready() -> void:
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = color
	_mat.roughness = 0.55
	_visor_mat = StandardMaterial3D.new()
	_visor_mat.albedo_color = Color(0.05, 0.06, 0.08)
	_visor_mat.metallic = 0.6
	_visor_mat.roughness = 0.2

	head = Node3D.new()
	add_child(head)
	_mesh(head, Kit.sphere_mesh(0.115, 20), _mat, Vector3(0, 0, 0.02))
	var visor := _mesh(head, Kit.box_mesh(Vector3(0.19, 0.075, 0.08)), _visor_mat, Vector3(0, 0.01, -0.07))
	visor.scale = Vector3(1, 1, 1)
	_torso = _mesh(self, null, _mat, Vector3.ZERO)
	var cap := CapsuleMesh.new()
	cap.radius = 0.17
	cap.height = 0.62
	cap.radial_segments = 16
	cap.rings = 4
	_torso.mesh = cap
	for i in 2:   # 0 left, 1 right
		var h := HandModel.new(i == 1)
		h.visible = false
		add_child(h)
		h.set_cuff_color(color)
		hands.append(h)
	_tag = Kit.label(display_name, 0.07, Color.WHITE, true)
	_tag.outline_size = 12
	_tag.outline_modulate = Color(0, 0, 0, 0.8)
	_tag.position = Vector3(0, 0.25, 0)
	head.add_child(_tag)

	voice_player = AudioStreamPlayer3D.new()
	voice_player.unit_size = 4.0
	voice_player.max_distance = 60.0
	voice_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC
	head.add_child(voice_player)
	visible = false


func _mesh(parent: Node3D, m: Mesh, material: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = material
	mi.position = pos
	mi.layers = Kit.VIS_ALL
	parent.add_child(mi)
	return mi


func set_profile(n: String, c: Color) -> void:
	display_name = n if n.strip_edges() != "" else "Friend"
	color = c
	if _mat:
		_mat.albedo_color = c
		_tag.text = display_name
		for h: Variant in hands:
			h.set_cuff_color(c)


func apply_pose(msg: Dictionary) -> void:
	var keys := ["h", "l", "r"]
	for i in 3:
		if msg.has(keys[i]):
			_targets[i] = Kit.unpack_tf(msg[keys[i]])
			if i > 0:
				_hand_age[i - 1] = 0.0
	# Finger curls: [left grip, left trigger, right grip, right trigger], 0..9.
	var g: Variant = msg.get("g")
	if g is Array and (g as Array).size() == 4:
		for i in 2:
			hands[i].set_curl(float(g[i * 2]) / 9.0, float(g[i * 2 + 1]) / 9.0)
	visible = _targets[0] != null


func head_position() -> Vector3:
	return head.global_position


func is_speaking() -> bool:
	return Time.get_ticks_msec() / 1000.0 < speaking_until


func _process(delta: float) -> void:
	var k := 1.0 - exp(-SMOOTH * delta)
	var nodes: Array[Node3D] = [head, hands[0], hands[1]]
	for i in 3:
		if _targets[i] == null:
			continue
		var t: Transform3D = _targets[i]
		if not _seen[i]:
			nodes[i].global_transform = t
			_seen[i] = true
		else:
			nodes[i].global_transform = nodes[i].global_transform.interpolate_with(t, k)
	for i in 2:
		_hand_age[i] += delta
		hands[i].visible = _seen[i + 1] and _hand_age[i] < 1.0
	# Body hangs below the head, turned with it (yaw only).
	if _seen[0]:
		var hp := head.global_position
		var f := -head.global_transform.basis.z
		f.y = 0
		var yaw := atan2(-f.x, -f.z) if f.length_squared() > 0.0001 else 0.0
		_torso.global_transform = Transform3D(Basis(Vector3.UP, yaw), hp + Vector3(0, -0.5, 0.05).rotated(Vector3.UP, yaw))
	# A soft glow while they talk.
	_mat.emission_enabled = is_speaking()
	if _mat.emission_enabled:
		_mat.emission = color
		_mat.emission_energy_multiplier = 0.35
