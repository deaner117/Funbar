extends Node3D
## Sam and Dean Worldwide (project folder / package still "hangout-mansion"): a virtual mansion
## for friends in different places to hang out in together.
##
## Rooms: Grand Hall (sofas, a throwable cake), Game Room (air hockey, Connect Four), Gym
## (basketball), Lounge (fireplace, jukebox, card table), Patio (outdoors at sunset: pool, fire
## pit with marshmallows and firewood, BBQ, drinks cooler, string lights, speakers), Lawn
## (cornhole). Throwable props and their interactions live in props.gd.
## Everyone who enters the same room code shares the mansion: avatars (head, body, hands),
## voice chat and the games go through the relay server (server/src/index.js).
##
## Movement: left stick walks (relative to where you look), right stick snap- or smooth-turns;
## you can also walk around physically. Walls stop you. The menu (Y / menu button) has the room
## code, quick travel between rooms, your name and colour, and settings.
##
## Command line (after `--`), mostly for testing on the laptop:
##   --server=ws://127.0.0.1:8787  --room=1234  --name=Bot  --shots=<dir>  --solo

const Kit := preload("res://kit.gd")
const Mansion := preload("res://mansion.gd")
const Hand := preload("res://hand.gd")
const HandModel := preload("res://hand_model.gd")
const Net := preload("res://net.gd")
const Avatar := preload("res://avatar.gd")
const Voice := preload("res://voice.gd")
const Menu := preload("res://menu.gd")
const AirHockey := preload("res://air_hockey.gd")
const ConnectFour := preload("res://connect_four.gd")
const Basketball := preload("res://basketball.gd")
const Jukebox := preload("res://jukebox.gd")
const Props := preload("res://props.gd")

const DEFAULT_SERVER := "wss://hangout-mansion.usa-vs-vietnam-relay.workers.dev"
const SETTINGS_FILE := "user://settings.cfg"
const POSE_HZ := 15.0
const SPEEDS := [1.3, 2.2, 3.4]
const SNAP_ANGLE := PI / 6

var colors: Array = [Color("4f8cff"), Color("ff5d5d"), Color("3fcf7a"), Color("ffb02e"),
	Color("b46bff"), Color("ff6fb5"), Color("2ed6d6"), Color("f2f2f2")]

## Set by tests before adding to the tree: no XR, no settings file, no mouse capture.
var test_mode := false
var args := {}
var xr := false
var xr_interface: OpenXRInterface
var origin: XROrigin3D
var camera: XRCamera3D
var hands: Array = []
var body: CharacterBody3D
var net: Net
var voice: Voice
var menu: Menu
var env: Environment
var mansion: Mansion
var modules := {}    # message prefix -> game module
var avatars := {}    # slot -> Avatar

# Settings (saved to user://settings.cfg).
var player_name := "Guest"
var color_index := 0
var room_code := ""
var server := DEFAULT_SERVER
var client_id := ""
var snap_turn := true
var speed_index := 1
var passthrough := false

var my_slot := -1
var _pose_in := 0.0
var _turn_ready := true
var _body_snap := true
var _spawn_in := 8
var _notice: Label3D
var _notice_until := 0.0
var _pitch := 0.0
var _muted_on_load := false
var _spawned := false
var _height_checked := false
const STANDING_EYE := 1.65


func _ready() -> void:
	_parse_args()
	if not test_mode:
		load_settings()
	if args.has("name"):
		player_name = str(args["name"])
	if args.has("server"):
		server = str(args["server"])
	if args.has("room"):
		room_code = str(args["room"])
	if client_id == "":
		client_id = "%08x%08x" % [randi(), randi()]
		save_settings()
	if not test_mode:
		xr = _start_xr()
	_build_world()
	_build_rig()
	net = Net.new()
	add_child(net)
	net.welcomed.connect(_on_welcomed)
	net.peer_joined.connect(_on_peer_joined)
	net.peer_left.connect(_on_peer_left)
	net.received.connect(_on_received)
	net.received_bytes.connect(_on_bytes)
	net.state_changed.connect(_on_net_state)
	voice = Voice.new()
	voice.main = self
	voice.muted = _muted_on_load
	add_child(voice)
	_build_games()
	menu = Menu.new()
	menu.main = self
	add_child(menu)
	menu.visible = false
	_notice = Kit.label("", 0.035, Color.WHITE)
	_notice.outline_size = 10
	_notice.outline_modulate = Color(0, 0, 0, 0.8)
	_notice.no_depth_test = true
	_notice.render_priority = 10
	_notice.position = Vector3(0, -0.25, -1.2)
	camera.add_child(_notice)
	set_profile(player_name, color_index)
	if passthrough:
		set_passthrough(true)
	if xr and OS.get_name() == "Android":
		_request_mic()
	elif args.has("voice"):
		voice.start()
	if room_code != "" and not args.has("solo"):
		join_room(room_code)
	if args.has("shots"):
		_take_shots.call_deferred(str(args["shots"]))


func _parse_args() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else true


# ---------------------------------------------------------------- XR and the world

func _start_xr() -> bool:
	xr_interface = XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr_interface == null or not xr_interface.is_initialized():
		print("OpenXR is not running: desktop mode (WASD + mouse).")
		return false
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_viewport().use_xr = true
	xr_interface.session_begun.connect(_on_session_begun)
	xr_interface.pose_recentered.connect(func() -> void:
		_body_snap = true
		_height_checked = false)
	return true


## The app asks for a floor-level tracking space, but if the runtime falls back to a
## head-relative one, y = 0 is wherever the head was and your eyes end up at floor level
## (inside the floor). Then lift the world so the head sits at standing height.
func _check_height() -> void:
	var head_y := camera.position.y
	print("Height: head is %.2f m above the tracking origin" % head_y)
	# Floor-level tracking puts the head well above 0 (even a headset resting on a low table);
	# a head-relative space starts it at ~0.
	if head_y < 0.25:
		set_view_height(STANDING_EYE)
		print("Height: tracking isn't floor-level; raised the view to %.2f m" % STANDING_EYE)


## Shifts the world vertically so the head is `eye` metres above the mansion floor.
func set_view_height(eye: float) -> void:
	origin.position.y = eye - camera.position.y


func reset_view_height() -> void:
	set_view_height(STANDING_EYE)
	notify("Eye height %.2f m" % STANDING_EYE)


func nudge_view_height(dy: float) -> void:
	origin.position.y += dy
	notify("Eye height %.2f m" % camera.global_position.y)


func _on_session_begun() -> void:
	var rates := xr_interface.get_available_display_refresh_rates()
	var hz := 90.0 if 90.0 in rates else xr_interface.get_display_refresh_rate()
	if hz > 0.0:
		xr_interface.display_refresh_rate = hz
		Engine.physics_ticks_per_second = roundi(hz)
	print("Refresh rate: %s (available %s)" % [hz, rates])


func passthrough_available() -> bool:
	return xr and XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in xr_interface.get_supported_environment_blend_modes()


## "My room" mode: hide the mansion's walls/floors/grounds and show the real room behind the
## furniture and games.
func set_passthrough(on: bool) -> void:
	if on and not passthrough_available() and not test_mode:
		on = false
		notify("Passthrough isn't available here")
	passthrough = on
	if xr:
		get_viewport().transparent_bg = on
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND if on else XRInterface.XR_ENV_BLEND_MODE_OPAQUE
	env.background_mode = Environment.BG_COLOR if on else Environment.BG_SKY
	env.background_color = Color(0, 0, 0, 0)
	mansion.set_structure_visible(not on)
	save_settings()


func _build_world() -> void:
	env = Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.32, 0.6)
	sky_mat.sky_horizon_color = Color(0.98, 0.62, 0.38)
	sky_mat.ground_horizon_color = Color(0.6, 0.45, 0.35)
	sky_mat.ground_bottom_color = Color(0.2, 0.22, 0.18)
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1.0, 0.93, 0.85)
	env.ambient_light_energy = 0.45
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	# A low evening sun that only lights the outdoors (it casts no shadows, so it would
	# otherwise shine through the roofs).
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-18), deg_to_rad(200), 0)
	sun.light_color = Color(1.0, 0.75, 0.55)
	sun.light_energy = 1.1
	sun.light_cull_mask = Kit.VIS_OUTDOOR
	sun.shadow_enabled = false
	add_child(sun)
	mansion = Mansion.new()
	add_child(mansion)
	mansion.build()


func _build_rig() -> void:
	origin = XROrigin3D.new()
	add_child(origin)
	camera = XRCamera3D.new()
	camera.near = 0.05
	camera.far = 250.0
	origin.add_child(camera)
	if not xr:
		camera.position.y = 1.6
	camera.current = true
	for t: StringName in [&"left_hand", &"right_hand"]:
		var h := Hand.new()
		h.tracker = t
		h.pose = &"aim"
		h.main = self
		h.visible = xr
		origin.add_child(h)
		h.menu_pressed.connect(toggle_menu)
		hands.append(h)
	body = CharacterBody3D.new()
	body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	body.collision_layer = 0
	body.collision_mask = Kit.LAYER_STRUCTURE | Kit.LAYER_BLOCKER
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.2
	cap.height = 1.2
	cs.shape = cap
	cs.position.y = 1.0
	body.add_child(cs)
	add_child(body)


func _build_games() -> void:
	var a: Array = mansion.anchors["air_hockey"]
	var ah := AirHockey.new()
	ah.main = self
	ah.position = a[0]
	ah.rotation.y = a[1]
	add_child(ah)
	modules["ah"] = ah
	a = mansion.anchors["connect_four"]
	var c4 := ConnectFour.new()
	c4.main = self
	c4.position = a[0]
	c4.rotation.y = a[1]
	add_child(c4)
	modules["c4"] = c4
	var bb := Basketball.new()
	bb.main = self
	add_child(bb)
	bb.setup(mansion.anchors["hoop"], mansion.anchors["ball_rack"])
	modules["bb"] = bb
	a = mansion.anchors["jukebox"]
	var jb := Jukebox.new()
	jb.main = self
	jb.position = a[0]
	jb.rotation.y = a[1]
	add_child(jb)
	modules["jb"] = jb
	for k: String in ["speaker_l", "speaker_r"]:
		jb.add_speaker(mansion.anchors[k][0], mansion.anchors[k][1])
	var pr := Props.new()
	pr.main = self
	add_child(pr)
	pr.setup(mansion.anchors)
	modules["pr"] = pr


func _request_mic() -> void:
	if "android.permission.RECORD_AUDIO" in OS.get_granted_permissions():
		voice.start()
		return
	get_tree().on_request_permissions_result.connect(func(permission: String, granted: bool) -> void:
		if permission.ends_with("RECORD_AUDIO") and granted:
			voice.start())
	OS.request_permission("android.permission.RECORD_AUDIO")


# ---------------------------------------------------------------- moving around

func _physics_process(delta: float) -> void:
	# Start in the Grand Hall once the headset is tracking (or after a few seconds regardless).
	var tracking := not xr or camera.transform != Transform3D.IDENTITY
	if xr and tracking and not _height_checked:
		_height_checked = true
		_check_height()
	if not _spawned:
		_spawn_in -= 1
		if _spawn_in <= 0 and (tracking or Time.get_ticks_msec() > 8000):
			_spawned = true
			travel("Grand Hall")
	_locomotion(delta)
	_pose_in -= delta
	if _pose_in <= 0.0 and has_friends():
		_pose_in = 1.0 / POSE_HZ
		_send_pose()


func _locomotion(delta: float) -> void:
	var stick := Vector2.ZERO
	var turn := 0.0
	if xr:
		stick = hands[0].get_vector2("primary")
		turn = hands[1].get_vector2("primary").x
	elif not test_mode:
		stick = Vector2(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
			float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S)))
		turn = float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q))
	if snap_turn and xr:
		if absf(turn) > 0.7 and _turn_ready:
			_turn(-signf(turn) * SNAP_ANGLE)
			_turn_ready = false
		elif absf(turn) < 0.3:
			_turn_ready = true
	elif absf(turn) > 0.2:
		_turn(-turn * 2.0 * delta)

	var b := camera.global_transform.basis
	var fwd := -b.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = b.y   # looking straight down: "up" on screen is forward
		fwd.y = 0.0
	fwd = fwd.normalized()
	var right := Vector3(-fwd.z, 0, fwd.x)
	if stick.length() < 0.15:
		stick = Vector2.ZERO
	var move: Vector3 = (fwd * stick.y + right * stick.x).limit_length(1.0) * float(SPEEDS[speed_index])

	# The body follows the head on the floor; walls stop it, and the world is shifted back by
	# however much it was stopped, so you can't walk (or lean) through walls.
	var cam := camera.global_position
	var target := Vector3(cam.x, 0.0, cam.z)
	if _body_snap or body.global_position.distance_to(target) > 1.0:
		body.global_position = target
		_body_snap = false
	body.velocity = (target - body.global_position) / delta + move
	body.velocity.y = 0.0
	body.move_and_slide()
	var after := body.global_position
	after.y = 0.0
	body.global_position = after
	origin.global_position += Vector3(after.x - cam.x, 0.0, after.z - cam.z)


func _turn(angle: float) -> void:
	var pivot := camera.global_position
	var t := origin.global_transform
	t.origin -= pivot
	t = Transform3D(Basis(Vector3.UP, angle), Vector3.ZERO) * t
	t.origin += pivot
	origin.global_transform = t


func _unhandled_input(event: InputEvent) -> void:
	if xr or test_mode:
		return
	# Desktop mode: click to capture the mouse, Esc to release, M for the menu.
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventKey and event.pressed and event.physical_keycode == KEY_M:
		toggle_menu()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_turn(-event.relative.x * 0.003)
		_pitch = clampf(_pitch - event.relative.y * 0.003, -1.4, 1.4)
		camera.rotation.x = _pitch


## Stands you at a spot facing `yaw` (0 = north / -z).
func place_at(pos: Vector3, yaw: float) -> void:
	var f := -camera.global_transform.basis.z
	var cam_yaw := atan2(-f.x, -f.z)
	_turn(yaw - cam_yaw)
	var cam := camera.global_position
	origin.global_position += Vector3(pos.x - cam.x, 0.0, pos.z - cam.z)
	_body_snap = true


func travel(room: String) -> void:
	var sp: Array = mansion.spawns.get(room, mansion.spawns["Grand Hall"])
	place_at(sp[0], sp[1])
	menu.close()


func travel_to_friend() -> void:
	if avatars.is_empty():
		return
	var av: Node = avatars.values()[0]
	var their: Vector3 = av.head_position()
	var space := get_world_3d().direct_space_state
	var f := -(av.head.global_transform.basis.z as Vector3)
	f.y = 0.0
	var face_yaw := atan2(-f.x, -f.z) if f.length_squared() > 0.001 else 0.0
	# Try spots round them, starting in front of their face, that a wall doesn't separate.
	for i in 8:
		var a := face_yaw + i * TAU / 8.0
		var spot := their + Vector3(-sin(a), 0.0, -cos(a)) * 1.2
		spot.y = 1.0
		var from := Vector3(their.x, 1.0, their.z)
		var q := PhysicsRayQueryParameters3D.create(from, spot + (spot - from).normalized() * 0.3, Kit.LAYER_STRUCTURE)
		if space.intersect_ray(q).is_empty():
			var look := their - spot
			place_at(Vector3(spot.x, 0, spot.z), atan2(-look.x, -look.z))
			menu.close()
			return
	place_at(Vector3(their.x, 0, their.z + 0.8), 0.0)
	menu.close()


func friends_whereabouts() -> String:
	if avatars.is_empty():
		return "No friends here yet."
	var parts := PackedStringArray()
	for s: int in avatars:
		var av: Node = avatars[s]
		parts.append("%s is in the %s" % [av.display_name, mansion.room_at(av.head_position())])
	return ", ".join(parts)


func toggle_menu() -> void:
	if menu.visible:
		menu.close()
	else:
		menu.open_at(camera.global_transform)


## A short message floating in front of you for a few seconds.
func notify(text: String) -> void:
	if _notice == null:
		return
	_notice.text = text
	_notice_until = Time.get_ticks_msec() / 1000.0 + 3.0
	print("Notice: ", text)


func _process(delta: float) -> void:
	if _notice and _notice.text != "" and Time.get_ticks_msec() / 1000.0 > _notice_until:
		_notice.text = ""
	# Diagnostics in the log (adb logcat -s godot) every 2 s.
	_stats_in -= delta
	if _stats_in <= 0.0:
		_stats_in = 2.0
		print("Stats: fps %d, draw calls %d, objects %d, head (tracking) %s, cam %s, origin %s, room %s, spawned %s" % [
			Engine.get_frames_per_second(),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
			camera.position.snapped(Vector3.ONE * 0.01),
			camera.global_position.snapped(Vector3.ONE * 0.01), origin.global_position.snapped(Vector3.ONE * 0.01),
			mansion.room_at(camera.global_position), _spawned])


var _stats_in := 2.0


# ---------------------------------------------------------------- grabbing

func try_grab(hand: Node) -> void:
	var p: Vector3 = hand.grab_point()
	var best: Node = null
	var best_d := 0.16
	for g in get_tree().get_nodes_in_group("grabbable"):
		if not is_ancestor_of(g):
			continue
		var d: float = g.grab_distance(p)
		if d < best_d:
			best = g
			best_d = d
	if best and best.on_grab(hand):
		hand.held = best
		hand.buzz(0.4, 0.05)


func release(hand: Node) -> void:
	var g: Node = hand.held
	hand.held = null
	if g:
		g.on_release(hand)


# ---------------------------------------------------------------- profile and settings

func set_profile(n: String, c: int) -> void:
	player_name = n.strip_edges().left(14) if n.strip_edges() != "" else "Guest"
	color_index = clampi(c, 0, colors.size() - 1)
	for h: Node in hands:
		h.set_color(colors[color_index])
	save_settings()
	_send_hello()
	if menu:
		menu.refresh()


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) != OK:
		return
	player_name = str(cfg.get_value("player", "name", player_name))
	color_index = int(cfg.get_value("player", "color", color_index))
	room_code = str(cfg.get_value("net", "room", room_code))
	server = str(cfg.get_value("net", "server", server))
	client_id = str(cfg.get_value("net", "id", client_id))
	snap_turn = bool(cfg.get_value("comfort", "snap_turn", snap_turn))
	speed_index = clampi(int(cfg.get_value("comfort", "speed", speed_index)), 0, SPEEDS.size() - 1)
	passthrough = bool(cfg.get_value("view", "passthrough", passthrough))
	_muted_on_load = bool(cfg.get_value("voice", "muted", false))


func save_settings() -> void:
	if test_mode:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", player_name)
	cfg.set_value("player", "color", color_index)
	cfg.set_value("net", "room", room_code)
	cfg.set_value("net", "server", server)
	cfg.set_value("net", "id", client_id)
	cfg.set_value("comfort", "snap_turn", snap_turn)
	cfg.set_value("comfort", "speed", speed_index)
	cfg.set_value("view", "passthrough", passthrough)
	cfg.set_value("voice", "muted", voice.muted if voice else _muted_on_load)
	cfg.save(SETTINGS_FILE)


# ---------------------------------------------------------------- network

## This player's id in shared state: the relay slot, or 0 when playing solo.
func me() -> int:
	return my_slot if my_slot >= 0 else 0


func has_friends() -> bool:
	return my_slot >= 0 and not avatars.is_empty()


## The player whose headset referees shared things: the lowest slot in the room.
func host_slot() -> int:
	var h := me()
	for s: int in avatars:
		h = mini(h, s)
	return h


func is_host() -> bool:
	return host_slot() == me()


func name_of(slot: int) -> String:
	if slot == me():
		return player_name
	if avatars.has(slot):
		return avatars[slot].display_name
	return "Player %d" % (slot + 1)


func send(msg: Dictionary) -> void:
	if my_slot < 0:
		return
	msg["s"] = my_slot
	net.send(msg)


func join_room(code: String) -> void:
	code = code.strip_edges()
	if code.length() < 3:
		return
	room_code = code
	save_settings()
	net.open(server, code, client_id)
	notify("Joining room %s..." % code)


func leave_room() -> void:
	net.close()
	notify("Playing solo")


func _on_net_state(state: String, detail: String) -> void:
	if state != "online" and my_slot >= 0:
		_drop_everyone()
	if state == "error":
		notify("Couldn't join: %s" % detail)
	if menu:
		menu.refresh()


func _drop_everyone() -> void:
	for s: int in avatars.keys():
		_remove_avatar(s)
	var old := me()
	my_slot = -1
	for m: Node in modules.values():
		m.on_identity_changed(old, me())


func _on_welcomed(slot: int, peers: Array) -> void:
	for s: int in avatars.keys():
		_remove_avatar(s)
	var old := me()
	my_slot = slot
	for m: Node in modules.values():
		m.on_identity_changed(old, me())
	for p: int in peers:
		_add_avatar(p)
	_send_hello()
	notify("In room %s" % room_code if peers.is_empty() else "Joined room %s" % room_code)
	menu.refresh()


func _on_peer_joined(slot: int) -> void:
	_add_avatar(slot)
	_send_hello()
	if is_host():
		for m: Node in modules.values():
			var st: Dictionary = m.full_state()
			if not st.is_empty():
				send(st)
	notify("A friend joined!")
	menu.refresh()


func _on_peer_left(slot: int) -> void:
	if not avatars.has(slot):
		return
	var who: String = avatars[slot].display_name
	_remove_avatar(slot)
	for m: Node in modules.values():
		m.on_peer_left(slot)
	notify("%s left" % who)
	menu.refresh()


func _add_avatar(slot: int) -> void:
	if slot < 0 or slot == my_slot or avatars.has(slot):
		return
	var av := Avatar.new()
	av.slot = slot
	av.display_name = "Player %d" % (slot + 1)
	add_child(av)
	avatars[slot] = av
	if modules.has("bb"):
		modules["bb"].on_roster_changed()


func _remove_avatar(slot: int) -> void:
	if avatars.has(slot):
		avatars[slot].queue_free()
		avatars.erase(slot)


func _send_hello() -> void:
	send({"t": "hello", "n": player_name, "c": color_index})


func _send_pose() -> void:
	var msg := {"t": "p", "h": Kit.pack_tf(camera.global_transform)}
	if xr:
		var keys := ["l", "r"]
		for i in 2:
			if hands[i].get_has_tracking_data():
				msg[keys[i]] = Kit.pack_tf(hands[i].glove_transform())
		msg["g"] = hands[0].curl_values() + hands[1].curl_values()
	send(msg)


func _on_received(msg: Dictionary) -> void:
	var from := int(msg.get("s", -1))
	if from < 0 or from == my_slot:
		return
	if not avatars.has(from):
		_add_avatar(from)
	var t := str(msg.get("t", ""))
	match t:
		"p":
			avatars[from].apply_pose(msg)
		"hello":
			var first: bool = avatars[from].display_name.begins_with("Player ")
			avatars[from].set_profile(str(msg.get("n", "Friend")), colors[clampi(int(msg.get("c", 0)), 0, colors.size() - 1)])
			if first:
				notify("%s is here" % avatars[from].display_name)
			if modules.has("bb"):
				modules["bb"].on_roster_changed()
			menu.refresh()
		_:
			var prefix := t.get_slice("_", 0)
			if modules.has(prefix):
				modules[prefix].handle(msg, from)


func _on_bytes(data: PackedByteArray) -> void:
	if data.size() > 4 and data[1] == 1:
		voice.receive(data)


# ---------------------------------------------------------------- screenshots (desktop mode)

func _take_shots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for i in 12:
		await get_tree().process_frame
	var views := [
		["hall", Vector3(0, 0, 5.5), 0.0, -0.05],
		["hall_back", Vector3(0, 0, -4.5), PI, -0.05],
		["game_room", Vector3(1.0, 0, -8.6), 0.25, -0.2],
		["air_hockey", Vector3(-2.6, 0, -15.2), PI, -0.45],
		["connect_four", Vector3(3.3, 0, -13.0), -PI / 2, -0.1],
		["gym", Vector3(12.0, 0, 2.5), -PI / 2 - 0.2, 0.1],
		["lounge", Vector3(-12.0, 0, 3.0), PI / 2 - 0.3, -0.1],
		["patio", Vector3(-2.0, 0, 8.8), PI - 0.2, -0.05],
		["patio_back", Vector3(-1.0, 0, 18.0), 0.2, 0.05],
		["fire_pit", Vector3(-3.0, 0, 13.2), PI * 0.75, -0.55],
		["bbq", Vector3(0.0, 0, 18.3), PI, -0.6],
		["pool", Vector3(1.2, 0, 10.0), PI * 0.8, -0.4],
		["lights", Vector3(0, 0, 9.0), PI, 0.45],
		["fireplace", Vector3(-17.5, 0, 0.8), PI / 2 + 0.2, -0.3],
		["lawn", Vector3(-1.0, 0, 22.0), PI, -0.15],
		["cake", Vector3(0, 0, 0.6), 0.0, -0.75],
		["hands", Vector3(0, 0, 4.0), 0.0, 0.0],
		["menu", Vector3(0, 0, 4.0), 0.0, 0.0],
	]
	var hand_demo: Array[Node3D] = []
	for v: Array in views:
		var shot: String = v[0]
		camera.rotation.x = 0.0
		place_at(v[1], v[2])
		_pitch = v[3]
		camera.rotation.x = _pitch
		if shot == "menu":
			menu.open_at(camera.global_transform)
		if shot == "hands":
			# Both hand models in front of the camera, palms toward each other as if holding
			# controllers: left one open, right one making a fist.
			for i in 2:
				var hm := HandModel.new(i == 1)
				add_child(hm)
				hm.global_transform = camera.global_transform * Transform3D(Basis.IDENTITY, Vector3(-0.13 + i * 0.26, -0.1, -0.45))
				hm.set_curl(0.0 if i == 0 else 1.0, 0.0 if i == 0 else 1.0)
				hand_demo.append(hm)
		for i in 6:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/%s.png" % [dir, shot])
		menu.close()
		for hm in hand_demo:
			hm.queue_free()
		hand_demo.clear()
	print("Screenshots saved to ", dir)
	get_tree().quit()
