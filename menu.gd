extends Node3D
## The floating menu (Y or the menu button opens/closes it; it appears in front of you).
## Pages: Home (room code + join/leave + who's here), Travel, Me (name + colour), Settings.

const Kit := preload("res://kit.gd")
const Button3D := preload("res://button3d.gd")

const W := 0.84
const H := 0.62
const TAB := Color(0.18, 0.22, 0.3)
const KEY := Color(0.24, 0.28, 0.36)
const GO := Color(0.16, 0.55, 0.32)
const STOP := Color(0.62, 0.22, 0.22)

var main: Node
var _pages := {}
var _tabs := {}
var _page := "Home"
var _code := ""
var _name := ""
# Labels and buttons the refresh updates.
var _status: Label3D
var _code_label: Label3D
var _people: Label3D
var _join: Button3D
var _leave: Button3D
var _name_label: Label3D
var _swatches: Array = []
var _turn_buttons: Array = []
var _speed_buttons: Array = []
var _view_buttons: Array = []
var _voice_buttons: Array = []
var _mic_bar: MeshInstance3D
var _mic_label: Label3D
var _friend_button: Button3D
var _where: Label3D


func _ready() -> void:
	# Panel background.
	var bg := MeshInstance3D.new()
	bg.mesh = Kit.box_mesh(Vector3(W, H, 0.01))
	# Opaque, so it's drawn before (behind) the alpha-blended text rather than over it.
	bg.material_override = Kit.flat(Color(0.07, 0.08, 0.11))
	bg.position.z = -0.012
	bg.layers = Kit.VIS_ALL
	add_child(bg)
	Kit.add_label(self, "SAM & DEAN WORLDWIDE", 0.032, Vector3(-W / 2 + 0.17, H / 2 - 0.035, 0), 0.0, Color(0.95, 0.8, 0.45))
	_button(self, "X", Vector2(0.06, 0.05), Vector3(W / 2 - 0.045, H / 2 - 0.04, 0), STOP, close)
	var names := ["Home", "Travel", "Me", "Settings"]
	for i in names.size():
		var n: String = names[i]
		_tabs[n] = _button(self, n, Vector2(0.17, 0.055), Vector3(-0.27 + i * 0.18, H / 2 - 0.105, 0), TAB, show_page.bind(n))
		var page := Node3D.new()
		add_child(page)
		_pages[n] = page
	_build_home(_pages["Home"])
	_build_travel(_pages["Travel"])
	_build_me(_pages["Me"])
	_build_settings(_pages["Settings"])
	show_page("Home")


func _button(parent: Node3D, text: String, size: Vector2, pos: Vector3, color: Color, cb: Callable) -> Button3D:
	var b := Button3D.new(text, size, color, cb)
	b.position = pos
	parent.add_child(b)
	return b


func _text(parent: Node3D, text: String, height: float, pos: Vector3, color := Color.WHITE, width := 0.0) -> Label3D:
	var l := Kit.add_label(parent, text, height, pos, 0.0, color)
	if width > 0.0:
		l.width = width / l.pixel_size
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func show_page(n: String) -> void:
	_page = n
	for k: String in _pages:
		(_pages[k] as Node3D).visible = k == n
		(_tabs[k] as Button3D).active = k == n
	refresh()


## Opens the menu in front of the head.
func open_at(head: Transform3D) -> void:
	var f := -head.basis.z
	f.y = 0
	if f.length_squared() < 0.001:
		f = Vector3.FORWARD
	f = f.normalized()
	var pos := head.origin + f * 0.65 + Vector3(0, -0.18, 0)
	# -Z points away from the viewer, so the front (+Z, where text reads) faces them.
	global_transform = Transform3D(Basis.looking_at(f, Vector3.UP), pos)
	# Tilt it back a little so it faces the eyes.
	rotate_object_local(Vector3.RIGHT, -0.25)
	_code = main.room_code
	_name = main.player_name
	visible = true
	refresh()


func close() -> void:
	visible = false


# ---------------------------------------------------------------- pages

func _build_home(p: Node3D) -> void:
	_status = _text(p, "", 0.026, Vector3(0, 0.135, 0), Color(0.75, 0.85, 1.0), W - 0.06)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_text(p, "Room code (same code = same mansion):", 0.022, Vector3(-0.2, 0.09, 0), Color(0.7, 0.7, 0.75))
	_code_label = _text(p, "", 0.05, Vector3(-0.2, 0.04, 0), Color(1, 1, 1))
	var keys := ["1", "2", "3", "4", "5", "6", "7", "8", "9", "DEL", "0", "CLR"]
	for i in keys.size():
		var k: String = keys[i]
		var pos := Vector3(-0.31 + (i % 3) * 0.11, -0.03 - (i / 3) * 0.065, 0)
		_button(p, k, Vector2(0.1, 0.055), pos, KEY, _on_key.bind(k))
	_join = _button(p, "Join room", Vector2(0.3, 0.07), Vector3(0.2, 0.03, 0), GO, _on_join)
	_leave = _button(p, "Leave (play solo)", Vector2(0.3, 0.07), Vector3(0.2, -0.05, 0), STOP, _on_leave)
	_people = _text(p, "", 0.026, Vector3(0.2, -0.18, 0), Color(0.9, 0.9, 0.9), 0.34)
	_people.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _build_travel(p: Node3D) -> void:
	_text(p, "Go to a room:", 0.026, Vector3(0, 0.15, 0), Color(0.7, 0.7, 0.75))
	var rooms := ["Grand Hall", "Game Room", "Gym", "Lounge", "Patio"]
	for i in rooms.size():
		var pos := Vector3(-0.19 + (i % 2) * 0.38, 0.08 - (i / 2) * 0.085, 0)
		_button(p, rooms[i], Vector2(0.34, 0.07), pos, KEY, _on_travel.bind(rooms[i]))
	_friend_button = _button(p, "Go to my friend", Vector2(0.34, 0.07), Vector3(0.19, -0.09, 0), GO, _on_friend)
	_where = _text(p, "", 0.024, Vector3(0, -0.19, 0), Color(0.85, 0.85, 0.9), W - 0.08)
	_where.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _build_me(p: Node3D) -> void:
	_name_label = _text(p, "", 0.04, Vector3(0, 0.15, 0), Color.WHITE)
	var rows := ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"]
	for r in rows.size():
		var row: String = rows[r]
		for i in row.length():
			var x := -0.36 + i * 0.08 + r * 0.03
			_button(p, row[i], Vector2(0.07, 0.055), Vector3(x, 0.08 - r * 0.065, 0), KEY, _on_letter.bind(row[i]))
	_button(p, "DEL", Vector2(0.1, 0.055), Vector3(0.28, -0.05, 0), KEY, _on_letter.bind("DEL"))
	_button(p, "SPACE", Vector2(0.16, 0.055), Vector3(-0.32, -0.05, 0), KEY, _on_letter.bind(" "))
	_text(p, "Colour:", 0.024, Vector3(-0.34, -0.13, 0), Color(0.7, 0.7, 0.75))
	var colors: Array = main.colors
	for i in colors.size():
		var b := _button(p, "", Vector2(0.055, 0.055), Vector3(-0.24 + i * 0.07, -0.13, 0), colors[i], _on_color.bind(i))
		_swatches.append(b)
	_button(p, "Save name", Vector2(0.22, 0.06), Vector3(0.0, -0.22, 0), GO, _on_save_name)


func _build_settings(p: Node3D) -> void:
	var rows := [
		["Turning", ["Snap", "Smooth"], _turn_buttons, _on_turn],
		["Walk speed", ["Slow", "Normal", "Fast"], _speed_buttons, _on_speed],
		["Surroundings", ["Mansion", "My room"], _view_buttons, _on_view],
		["Voice chat", ["Mic on", "Muted"], _voice_buttons, _on_voice],
	]
	for r in rows.size():
		var y := 0.14 - r * 0.08
		_text(p, rows[r][0], 0.026, Vector3(-0.29, y, 0), Color(0.8, 0.8, 0.85))
		var opts: Array = rows[r][1]
		for i in opts.size():
			var b := _button(p, opts[i], Vector2(0.16, 0.06), Vector3(-0.06 + i * 0.17, y, 0), KEY, (rows[r][3] as Callable).bind(i))
			(rows[r][2] as Array).append(b)
	var hy := 0.14 - rows.size() * 0.08
	_text(p, "Eye height", 0.026, Vector3(-0.29, hy, 0), Color(0.8, 0.8, 0.85))
	_button(p, "Lower", Vector2(0.16, 0.06), Vector3(-0.06, hy, 0), KEY, func() -> void: main.nudge_view_height(-0.1))
	_button(p, "Standing", Vector2(0.16, 0.06), Vector3(0.11, hy, 0), KEY, func() -> void: main.reset_view_height())
	_button(p, "Higher", Vector2(0.16, 0.06), Vector3(0.28, hy, 0), KEY, func() -> void: main.nudge_view_height(0.1))
	_mic_label = _text(p, "Mic", 0.022, Vector3(-0.29, -0.245, 0), Color(0.7, 0.7, 0.75))
	_mic_bar = MeshInstance3D.new()
	_mic_bar.mesh = Kit.box_mesh(Vector3(0.4, 0.02, 0.005))
	_mic_bar.material_override = Kit.flat(Color(0.3, 0.9, 0.4))
	_mic_bar.position = Vector3(0.05, -0.245, 0)
	p.add_child(_mic_bar)
	var hint := _text(p, "\"My room\" = passthrough, with the furniture and games in your real room.", 0.017, Vector3(0, -0.285, 0), Color(0.6, 0.6, 0.65), W - 0.1)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


# ---------------------------------------------------------------- refresh

func refresh() -> void:
	if not is_inside_tree() or main == null:
		return
	var friends: int = main.avatars.size()
	match main.net.state:
		"online":
			if friends > 0:
				_status.text = "In room %s with %d %s" % [main.room_code, friends, "friend" if friends == 1 else "friends"]
			else:
				_status.text = "In room %s, waiting for friends to join..." % main.room_code
		"connecting":
			_status.text = "Connecting to room %s..." % main.room_code
		"error":
			_status.text = "Couldn't join: %s" % main.net.detail
		_:
			_status.text = "Playing solo - enter a code your friend also enters, then Join"
	_code_label.text = _code if _code != "" else "----"
	_join.enabled = _code.length() >= 3
	_join.set_text("Rejoin room" if main.net.state != "offline" and _code == main.room_code else "Join room")
	_leave.enabled = main.net.state != "offline"
	var names := PackedStringArray(["%s (you)" % main.player_name])
	for s: int in main.avatars:
		names.append(main.avatars[s].display_name)
	_people.text = "Here: " + ", ".join(names)
	_name_label.text = "Name: %s_" % _name
	for i in _swatches.size():
		(_swatches[i] as Button3D).active = i == main.color_index
		(_swatches[i] as Button3D).set_text("*" if i == main.color_index else "")
	for i in _turn_buttons.size():
		(_turn_buttons[i] as Button3D).active = (i == 0) == main.snap_turn
	for i in _speed_buttons.size():
		(_speed_buttons[i] as Button3D).active = i == main.speed_index
	for i in _view_buttons.size():
		(_view_buttons[i] as Button3D).active = (i == 1) == main.passthrough
		(_view_buttons[i] as Button3D).enabled = i == 0 or main.passthrough_available()
	for i in _voice_buttons.size():
		(_voice_buttons[i] as Button3D).active = (i == 1) == main.voice.muted
	_friend_button.enabled = friends > 0
	_where.text = main.friends_whereabouts()


func _process(_delta: float) -> void:
	if visible and _page == "Settings":
		var lvl: float = 0.0 if main.voice.muted else main.voice.level
		_mic_bar.scale.x = maxf(lvl, 0.02)
		_mic_bar.position.x = 0.05 - 0.2 + 0.2 * _mic_bar.scale.x
		_mic_label.text = "Mic" if main.voice.started else "Mic (off)"


# ---------------------------------------------------------------- actions

func _on_key(k: String) -> void:
	match k:
		"DEL":
			_code = _code.left(-1)
		"CLR":
			_code = ""
		_:
			if _code.length() < 6:
				_code += k
	refresh()


func _on_join() -> void:
	main.join_room(_code)
	refresh()


func _on_leave() -> void:
	main.leave_room()
	refresh()


func _on_travel(room: String) -> void:
	main.travel(room)


func _on_friend() -> void:
	main.travel_to_friend()


func _on_letter(c: String) -> void:
	if c == "DEL":
		_name = _name.left(-1)
	elif _name.length() < 14:
		_name += c if _name.length() == 0 else c.to_lower()
	refresh()


func _on_save_name() -> void:
	main.set_profile(_name, main.color_index)
	refresh()


func _on_color(i: int) -> void:
	main.set_profile(_name if _name.strip_edges() != "" else main.player_name, i)
	refresh()


func _on_turn(i: int) -> void:
	main.snap_turn = i == 0
	main.save_settings()
	refresh()


func _on_speed(i: int) -> void:
	main.speed_index = i
	main.save_settings()
	refresh()


func _on_view(i: int) -> void:
	main.set_passthrough(i == 1)
	refresh()


func _on_voice(i: int) -> void:
	main.voice.muted = i == 1
	main.save_settings()
	refresh()
