extends StaticBody3D
## A flat button the hand lasers can point at and press with the trigger. Its collider turns off
## while it (or a parent) is hidden, so hidden menu pages can't be pressed.

const Kit := preload("res://kit.gd")

var on_press: Callable
var base_color: Color
## Drawn lit up, e.g. the selected choice in a row of options.
var active := false:
	set(v):
		active = v
		_refresh()
var enabled := true:
	set(v):
		enabled = v
		_refresh()

var _mat: StandardMaterial3D
var _label: Label3D
var _hover_frame := -100
var _hovered := false
var _flash := 0.0


func _init(text := "", size := Vector2(0.12, 0.06), color := Color(0.22, 0.27, 0.36), callback := Callable()) -> void:
	collision_layer = Kit.LAYER_UI
	collision_mask = 0
	on_press = callback
	base_color = color
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, size.y, 0.02)
	cs.shape = shape
	add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(size.x, size.y, 0.012)
	mi.mesh = bm
	mi.layers = Kit.VIS_ALL
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = _mat
	add_child(mi)
	_label = Kit.label(text, minf(size.y * 0.5, 0.04))
	_label.position.z = 0.008
	_label.width = size.x / _label.pixel_size
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_label)
	_refresh()


func set_text(t: String) -> void:
	_label.text = t


func get_text() -> String:
	return _label.text


## Called every physics frame a laser is on it.
func hover() -> void:
	_hover_frame = Engine.get_physics_frames()


func press() -> bool:
	if not enabled or not is_visible_in_tree():
		return false
	_flash = 0.12
	_refresh()
	if on_press.is_valid():
		on_press.call()
	return true


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		collision_layer = Kit.LAYER_UI if is_visible_in_tree() else 0


func _process(delta: float) -> void:
	var h := Engine.get_physics_frames() - _hover_frame <= 2
	if h != _hovered or _flash > 0.0:
		_hovered = h
		_flash = maxf(_flash - delta, 0.0)
		_refresh()


func _refresh() -> void:
	if _mat == null:
		return
	var c := base_color
	if active:
		c = c.lightened(0.45)
	if _hovered:
		c = c.lightened(0.25)
	if not enabled:
		c = c.darkened(0.55)
	if _flash > 0.0:
		c = Color(1, 1, 1)
	_mat.albedo_color = c
	if _label:
		_label.modulate = Color(0.1, 0.1, 0.12) if (_flash > 0.0 or c.get_luminance() > 0.6) else Color.WHITE
