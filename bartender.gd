extends Node3D
## The bartender: a realistic rigged woman (Microsoft Rocketbox "Female_Party_01", MIT) who
## works the arcade bar. She breathes, glances around and looks at whoever is nearest, wipes
## the counter, greets people by name when they come up, and serves them a cocktail: she
## walks along the bar to them, reaches under the counter, brings up a drink and sets it down
## in front of them (a real prop: pick it up, drink it, clink glasses).
##
## The model has no animations we can use, so she is posed in code: each frame the skeleton
## goes back to its rest pose and arms, spine and head are aimed at directions worked out
## from the rig itself. The host decides when to serve and greet ("bt_s", "bt_say"); everyone
## plays the same timeline, and the drink moves as a prop.

const Kit := preload("res://kit.gd")

const SCENE := "res://models/bartender/Female_Party_01.fbx"
const TEX := "res://models/bartender/"
const DRINKS := [Color(0.95, 0.35, 0.55), Color(0.3, 0.7, 1.0), Color(0.45, 0.9, 0.35), Color(1.0, 0.6, 0.15), Color(0.85, 0.2, 0.3), Color(0.95, 0.9, 0.5)]
## The bar in world space (z range she can walk, where customers stand, where drinks go).
const Z_MIN := -20.5
const Z_MAX := -13.5
const SERVE_X := -12.2
const SERVE_Y := 1.112
const CUSTOMER_X := Vector2(-11.9, -10.0)
const WALK := 0.9

var main: Node
var drinks: Array = []

var _home := Vector3.ZERO
var _yaw := 0.0
var _z := 0.0
var _target_z := 0.0
var _sk: Skeleton3D
var _model: Node3D
var _b := {}                  # bone name -> index
var _R := Vector3.RIGHT       # body frame in skeleton space
var _U := Vector3.UP
var _F := Vector3.BACK
var _t := 0.0
var _look := Vector3.ZERO     # smoothed look target (world)
var _arm := {}                # smoothed arm directions (skeleton space)
var _state := "idle"
var _st := 0.0                # time in state
var _serve_slot := -1
var _serve_drink := -1
var _serve_name := ""
var _walked := false
var _placed := false
var _glass: Node3D
var _bubble: Label3D
var _bubble_t := 0.0
var _greeted := {}            # slot -> time
var _served := {}             # slot -> time
var _think := 0.0
var _wipe := 0.0


func setup(anchor: Array) -> void:
	_home = anchor[0]
	_yaw = anchor[1]
	position = _home
	rotation.y = _yaw
	_z = _home.z
	_target_z = _z
	_build_model()
	_glass = Node3D.new()
	add_child(_glass)
	_glass_visual(_glass)
	_glass.visible = false
	_bubble = Kit.label("", 0.07, Color(1, 1, 1), true)
	_bubble.outline_size = 14
	_bubble.outline_modulate = Color(0.1, 0.05, 0.15, 0.9)
	_bubble.position = Vector3(0, 2.0, 0)
	_bubble.visible = false
	add_child(_bubble)
	var pr: Node = main.modules["pr"]
	for i in DRINKS.size():
		var home := Transform3D(Basis.IDENTITY, Vector3(-13.45, 0.945, -18.2 + i * 0.28))
		drinks.append(pr.add_prop("cocktail", home, DRINKS[i]))


func _build_model() -> void:
	var ps := load(SCENE) as PackedScene
	if ps == null:
		push_warning("Bartender model missing")
		return
	_model = ps.instantiate() as Node3D
	add_child(_model)
	_sk = _model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	for i in _sk.get_bone_count():
		_b[_sk.get_bone_name(i).trim_prefix("Bip01 ")] = i
	# Materials: skin and clothes, face, and hair / lashes (alpha-scissored, two-sided).
	var mi := _model.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var names := ["body", "head", "opacity"]
	for s in mi.mesh.get_surface_count():
		var nm: String = names[s] if s < names.size() else "body"
		var m := StandardMaterial3D.new()
		m.albedo_texture = load(TEX + "f010_%s_color.png" % nm)
		m.roughness = 0.62
		if ResourceLoader.exists(TEX + "f010_%s_normal.png" % nm):
			m.normal_enabled = true
			m.normal_texture = load(TEX + "f010_%s_normal.png" % nm)
			m.normal_scale = 0.8
		if nm == "opacity":
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			m.alpha_scissor_threshold = 0.45
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.roughness = 0.5
		mi.set_surface_override_material(s, m)
	mi.layers = Kit.VIS_INDOOR
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Her body frame from the rest pose: up from pelvis to head, right across the shoulders.
	var head := _rest("Head")
	var pelvis := _rest("Pelvis")
	_U = (head - pelvis).normalized()
	_R = (_rest("R UpperArm") - _rest("L UpperArm"))
	_R = (_R - _U * _R.dot(_U)).normalized()
	_F = _U.cross(_R)
	var eyes := (_rest("REye") + _rest("LEye")) / 2.0
	if (eyes - head).dot(_F) < 0.0:
		_F = -_F
		_R = -_R
	# Turn the model so her up is +y and she faces this node's +z.
	var frame := Basis(_R, _U, _F)
	_model.basis = Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)) * frame.inverse()
	# Stand her on the floor.
	var feet := minf(_rest("L Toe0").dot(_U), _rest("R Toe0").dot(_U))
	_model.position = Vector3(0, -feet + 0.0, 0)


func _rest(bone: String) -> Vector3:
	return _sk.get_bone_global_rest(_b[bone]).origin


## A copy of the cocktail glass for her hand.
func _glass_visual(p: Node3D) -> void:
	var glass := Kit.mat(Color(0.85, 0.92, 1.0, 0.3), 0.05)
	Kit.add_cylinder(p, 0.032, 0.006, Vector3(0, 0.003, 0), glass, 0, -1.0, 16)
	Kit.add_cylinder(p, 0.004, 0.08, Vector3(0, 0.045, 0), glass, 0, -1.0, 8)
	Kit.add_cylinder(p, 0.008, 0.075, Vector3(0, 0.12, 0), glass, 0, 0.045, 16)
	p.set_meta("liquid", Kit.add_cylinder(p, 0.008, 0.06, Vector3(0, 0.112, 0), Kit.mat(Color(0.95, 0.4, 0.5, 0.85), 0.1), 0, 0.039, 16))


# ---------------------------------------------------------------- behaviour

func _process(delta: float) -> void:
	if _sk == null:
		return
	_t += delta
	_st += delta
	_bubble_t -= delta
	_bubble.visible = _bubble_t > 0.0
	if main.is_host():
		_think -= delta
		if _think <= 0.0:
			_think = 0.5
			_decide()
	_run_state(delta)
	# Walk along the bar.
	var dz := _target_z - _z
	_z += clampf(dz, -WALK * delta, WALK * delta)
	position = Vector3(_home.x, _home.y, _z)
	_pose(delta, absf(dz) > 0.02)


## Everyone near the bar: [slot, name, head position].
func _people() -> Array:
	var out := []
	if main.camera:
		out.append([main.me(), main.player_name, main.camera.global_position])
	for s: int in main.avatars:
		out.append([s, main.avatars[s].display_name, main.avatars[s].head_position()])
	return out


func _decide() -> void:
	if _state != "idle":
		return
	var now := _t
	for p: Array in _people():
		var pos: Vector3 = p[2]
		var d := pos.distance_to(global_position + Vector3(0, 1.6, 0))
		if d < 4.5 and now - float(_greeted.get(p[0], -999.0)) > 90.0:
			_greeted[p[0]] = now
			_say_all(["Hey %s! What can I get you?", "Hi %s! Thirsty?", "Welcome back, %s!"][randi() % 3] % p[1])
			return
		var at_bar: bool = pos.x > CUSTOMER_X.x and pos.x < CUSTOMER_X.y and pos.z > Z_MIN - 0.5 and pos.z < Z_MAX + 0.5
		if not at_bar or now - float(_served.get(p[0], -999.0)) < 25.0:
			continue
		if _has_drink_near(pos):
			continue
		var di := _free_drink(pos)
		if di < 0:
			continue
		_served[p[0]] = now
		var msg := {"t": "bt_s", "z": snappedf(clampf(pos.z, Z_MIN, Z_MAX), 0.01), "sl": p[0], "nm": p[1], "d": di}
		main.send(msg)
		_start_serve(msg)
		(main.modules["pr"]).take_for_serving(drinks[di])
		return


func _has_drink_near(pos: Vector3) -> bool:
	for b: Node3D in drinks:
		if b.visible and Vector2(b.global_position.x - pos.x, b.global_position.z - pos.z).length() < 1.0:
			return true
	return false


## A drink nobody is using: one at home on the back bar first, else the one left alone longest
## away from everybody.
func _free_drink(customer: Vector3) -> int:
	var best := -1
	var best_score := -INF
	for i in drinks.size():
		var b: Node3D = drinks[i]
		if b.get("hand") != null or not b.visible:
			continue
		var near_someone := false
		for p: Array in _people():
			if (p[2] as Vector3).distance_to(b.global_position) < 1.2:
				near_someone = true
		if near_someone:
			continue
		var at_home: bool = b.global_position.distance_to((b.get("home") as Transform3D).origin) < 0.15
		var score := (100.0 if at_home else 0.0) + b.global_position.distance_to(customer)
		if score > best_score:
			best_score = score
			best = i
	return best


func _start_serve(msg: Dictionary) -> void:
	_state = "serve"
	_st = 0.0
	_target_z = float(msg.get("z", _z))
	_serve_slot = int(msg.get("sl", -1))
	_serve_name = str(msg.get("nm", ""))
	_serve_drink = int(msg.get("d", 0))
	_walked = false
	_placed = false
	var liquid: Node = _glass.get_meta("liquid")
	(liquid as MeshInstance3D).material_override = Kit.mat(Color(DRINKS[_serve_drink % DRINKS.size()], 0.85), 0.1)
	_say(["Coming right up!", "One sec, %s!" % _serve_name, "You got it!"][randi() % 3])


func _run_state(delta: float) -> void:
	match _state:
		"idle":
			_wipe = maxf(_wipe - delta, 0.0)
			if _wipe <= 0.0 and randf() < delta / 9.0:
				_wipe = 3.0
		"serve":
			if not _walked:
				if absf(_target_z - _z) < 0.03:
					_walked = true
					_st = 0.0
				return
			if _st > 0.7 and not _placed:
				_glass.visible = true
			if _st > 1.6 and not _placed:
				_placed = true
				_glass.visible = false
				if main.is_host() and _serve_drink >= 0 and _serve_drink < drinks.size():
					var xf := Transform3D(Basis.IDENTITY, Vector3(SERVE_X, SERVE_Y, _target_z))
					(main.modules["pr"]).place(drinks[_serve_drink], xf)
				_say(["Here you go, %s!" % _serve_name, "Enjoy!", "Cheers, %s!" % _serve_name][randi() % 3])
			if _st > 2.3:
				_state = "idle"
				_target_z = clampf(lerpf(_z, _home.z, 0.5), Z_MIN, Z_MAX)


func _say_all(text: String) -> void:
	main.send({"t": "bt_say", "x": text})
	_say(text)


func _say(text: String) -> void:
	_bubble.text = text
	_bubble_t = 3.5


# ---------------------------------------------------------------- posing

## Aims bone so the direction to its child points along dir (skeleton space). Called parent
## before child, from the rest pose.
func _aim(bone: String, child: String, dir: Vector3) -> void:
	var b: int = _b[bone]
	var g := _sk.get_bone_global_pose(b)
	var c := _sk.get_bone_global_pose(_b[child]).origin
	var cur := (c - g.origin).normalized()
	var want := dir.normalized()
	if cur.dot(want) > 0.9999:
		return
	var q := Quaternion(cur, want)
	var parent := _sk.get_bone_parent(b)
	var pg := _sk.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	var local := pg.inverse() * (Basis(q) * g.basis)
	_sk.set_bone_pose_rotation(b, local.get_rotation_quaternion())


## Rotates a bone by q about its own position, in skeleton space.
func _turn(bone: String, q: Quaternion) -> void:
	var b: int = _b[bone]
	var g := _sk.get_bone_global_pose(b)
	var parent := _sk.get_bone_parent(b)
	var pg := _sk.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	_sk.set_bone_pose_rotation(b, (pg.inverse() * (Basis(q) * g.basis)).get_rotation_quaternion())


func _smooth(key: String, v: Vector3, delta: float, rate := 6.0) -> Vector3:
	var cur: Vector3 = _arm.get(key, v)
	cur = cur.lerp(v, minf(1.0, delta * rate))
	_arm[key] = cur
	return cur


func _pose(delta: float, walking: bool) -> void:
	_sk.reset_bone_poses()
	var R := _R
	var U := _U
	var F := _F
	# Who to look at: the person being served, else the nearest person within 6 m.
	var look_at := global_position + global_basis.z * 2.0 + Vector3(0, 1.6, 0)
	var best := 6.0
	for p: Array in _people():
		var pos: Vector3 = p[2]
		if _state == "serve" and p[0] == _serve_slot:
			look_at = pos
			break
		var d := pos.distance_to(global_position)
		if d < best:
			best = d
			look_at = pos
	_look = look_at if _look == Vector3.ZERO else _look.lerp(look_at, minf(1.0, delta * 3.0))
	# Turn her whole body a little toward the person (she faces the room by default).
	var to := _look - global_position
	var want_yaw := _yaw + clampf(wrapf(atan2(to.x, to.z) - _yaw, -PI, PI), -0.7, 0.7)
	if _state == "serve" and _walked and _st < 0.7:
		want_yaw = _yaw   # facing the counter to reach under it
	rotation.y = lerp_angle(rotation.y, want_yaw, minf(1.0, delta * 3.0))
	# Breathing and a slight sway.
	var breath := sin(_t * 1.7)
	_turn("Spine1", Quaternion(R, 0.015 * breath) * Quaternion(U, 0.03 * sin(_t * 0.37)))
	if walking:
		_turn("Pelvis", Quaternion(U, 0.08 * sin(_t * 7.0)))
	# Arms. Defaults: relaxed, hands resting on the bar top in front of her.
	var lu := -U * 0.9 - R * 0.22 + F * 0.28
	var ru := -U * 0.9 + R * 0.22 + F * 0.28
	var lf := -U * 0.3 + F * 0.9 + R * 0.12
	var rf := -U * 0.3 + F * 0.9 - R * 0.12
	if _state == "idle" and _wipe > 0.0:
		# Wiping the counter in circles with her right hand.
		rf = -U * 0.45 + F * 0.85 + R * (0.35 * sin(_t * 5.0)) + U * 0.1 * cos(_t * 5.0)
		ru = -U * 0.8 + R * 0.25 + F * 0.45
	elif _state == "serve" and _walked:
		if _st < 0.7:
			# Reaching under the counter.
			lu = -U * 1.0 + F * 0.35 - R * 0.1
			ru = -U * 1.0 + F * 0.35 + R * 0.1
			lf = -U * 1.0 + F * 0.2
			rf = -U * 1.0 + F * 0.2
		elif _st < 1.8:
			# Holding the drink out over the bar.
			ru = -U * 0.45 + F * 0.9 + R * 0.15
			rf = -U * 0.25 + F * 1.0 - R * 0.05
		else:
			ru = -U * 0.75 + F * 0.6 + R * 0.2
	elif _bubble_t > 2.5 and _state == "idle":
		# A little wave while saying hi.
		ru = U * 0.2 + R * 0.9 + F * 0.2
		rf = U * 1.0 + R * 0.35 * sin(_t * 9.0)
	_aim("L UpperArm", "L Forearm", _smooth("lu", lu, delta))
	_aim("R UpperArm", "R Forearm", _smooth("ru", ru, delta))
	_aim("L Forearm", "L Hand", _smooth("lf", lf, delta))
	_aim("R Forearm", "R Hand", _smooth("rf", rf, delta))
	# Head toward whoever she looks at, within a comfortable range.
	var to_s := _sk.global_transform.affine_inverse().basis * (_look - _sk.global_transform * _sk.get_bone_global_pose(_b["Head"]).origin)
	var cur_f := (_sk.get_bone_global_pose(_b["Head"]).basis * _sk.get_bone_global_rest(_b["Head"]).basis.inverse()) * F
	var want_f := to_s.normalized()
	var ang := cur_f.angle_to(want_f)
	if ang > 0.001:
		var axis := cur_f.cross(want_f).normalized()
		_turn("Head", Quaternion(axis, minf(ang, 0.9) * 0.8))
	# The drink copy rides in her right hand.
	if _glass.visible:
		var hand := _sk.global_transform * _sk.get_bone_global_pose(_b["R Hand"]).origin
		var fing := _sk.global_transform * _sk.get_bone_global_pose(_b["R Finger2"]).origin
		_glass.global_transform = Transform3D(Basis.IDENTITY, hand.lerp(fing, 0.6) + Vector3(0, -0.06, 0))


# ---------------------------------------------------------------- network

func handle(msg: Dictionary, _from: int) -> void:
	match str(msg.get("t", "")):
		"bt_s":
			_start_serve(msg)
		"bt_say":
			_say(str(msg.get("x", "")))


func full_state() -> Dictionary:
	return {"t": "bt_full"}


func on_identity_changed(_old_id: int, _new_id: int) -> void:
	pass


func on_peer_left(slot: int) -> void:
	_greeted.erase(slot)
	_served.erase(slot)
