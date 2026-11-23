extends XRController3D
## One tracked controller (aim pose: -Z points where the controller points). Draws a glove,
## points a laser at buttons (trigger presses them), grabs things with the grip, and measures
## how fast the hand is moving for throws.

signal menu_pressed

const Kit := preload("res://kit.gd")
const HandModel := preload("res://hand_model.gd")
const RAY_LENGTH := 5.0
## Where the palm is, in aim-pose space: grabbing happens around here.
const GRAB_OFFSET := Vector3(0, -0.03, 0.05)
## The glove mesh, in aim-pose space.
const GLOVE_OFFSET := Vector3(0, -0.025, 0.075)
const PRESS := 0.6
const LET_GO := 0.35

var main: Node
## The thing this hand holds (a node in the "grabbable" group), or null.
var held: Node = null
## Smoothed world-space speed of the grab point (m/s), for throws.
var velocity := Vector3.ZERO

## The visible hand; friends see the same model, posed from `curl_values()`.
var model: HandModel
var _laser: MeshInstance3D
var _dot: MeshInstance3D
var _hover: Node = null
var _samples: Array = []   # [time_s, grab point]
var _trigger := false
var _grip := false


func _ready() -> void:
	add_to_group("player_hands")
	model = HandModel.new(tracker == &"right_hand")
	model.position = GLOVE_OFFSET
	add_child(model)

	_laser = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.0015
	cyl.bottom_radius = 0.0015
	cyl.height = 1.0
	cyl.radial_segments = 6
	_laser.mesh = cyl
	_laser.material_override = Kit.flat(Color(0.6, 0.85, 1.0, 0.7))
	_laser.rotation.x = -PI / 2
	_laser.visible = false
	add_child(_laser)
	_dot = MeshInstance3D.new()
	_dot.mesh = Kit.sphere_mesh(0.008, 8)
	_dot.material_override = Kit.flat(Color(1, 1, 1))
	_dot.top_level = true
	_dot.visible = false
	add_child(_dot)
	button_pressed.connect(_on_button_pressed)


func set_color(c: Color) -> void:
	model.set_cuff_color(c)


## [grip, trigger] as 0..9, for friends' copies of this hand.
func curl_values() -> Array:
	return [roundi(get_float("grip") * 9.0), roundi(get_float("trigger") * 9.0)]


func grab_point() -> Vector3:
	return global_transform * GRAB_OFFSET


## The glove's pose, sent to friends so they see this hand.
func glove_transform() -> Transform3D:
	return global_transform * Transform3D(Basis.IDENTITY, GLOVE_OFFSET)


func buzz(strength := 0.3, seconds := 0.04) -> void:
	trigger_haptic_pulse("haptic", 0.0, strength, seconds, 0.0)


func _on_button_pressed(button_name: String) -> void:
	if button_name in ["by_button", "menu_button"]:
		menu_pressed.emit()


func _physics_process(_delta: float) -> void:
	# Hand speed over the last ~80 ms.
	var now := Time.get_ticks_msec() / 1000.0
	var p := grab_point()
	_samples.append([now, p])
	while _samples.size() > 2 and now - float(_samples[0][0]) > 0.08:
		_samples.pop_front()
	var dt := now - float(_samples[0][0])
	if dt > 0.005:
		velocity = (p - (_samples[0][1] as Vector3)) / dt

	# Trigger and grip with hysteresis (their analog values are more reliable than clicks).
	var t := get_float("trigger")
	if not _trigger and t > PRESS:
		_trigger = true
		if held != null and held.has_method("on_trigger"):
			held.on_trigger(self)
		elif _hover and _hover.has_method("press") and _hover.press():
			buzz(0.25, 0.03)
	elif _trigger and t < LET_GO:
		_trigger = false
	var g := get_float("grip")
	# Holding something keeps the fingers wrapped round it.
	model.set_curl(maxf(g, 0.75 if held != null else 0.0), t)
	if not _grip and g > PRESS:
		_grip = true
		if main and held == null:
			main.try_grab(self)
	elif _grip and g < LET_GO:
		_grip = false
		if main and held != null:
			main.release(self)

	_update_laser()


func _update_laser() -> void:
	_hover = null
	var hit := {}
	if held == null and get_has_tracking_data():
		var from := global_position
		var to := from - global_transform.basis.z * RAY_LENGTH
		var q := PhysicsRayQueryParameters3D.create(from, to, Kit.LAYER_UI)
		hit = get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or not (hit.collider as Node3D).is_visible_in_tree():
		_laser.visible = false
		_dot.visible = false
		return
	_hover = hit.collider
	if _hover.has_method("hover"):
		_hover.hover()
	var length := global_position.distance_to(hit.position)
	_laser.visible = true
	_laser.scale = Vector3(1, length, 1)
	_laser.position = Vector3(0, 0, -length / 2.0)
	_dot.visible = true
	_dot.global_position = hit.position
