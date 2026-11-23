extends Node3D
## Connect Four on a standing board. Point at a column's arrow and pull the trigger to drop.
## The host's headset (lowest slot) referees: others send a request, the host applies it and
## broadcasts the whole board, so simultaneous moves can't desync. With a friend here you
## can't move twice in a row; alone you play both colours.

const Kit := preload("res://kit.gd")
const Button3D := preload("res://button3d.gd")

const COLS := 7
const ROWS := 6
const CELL := 0.11
const BOTTOM := 0.85         # height of the bottom row's centre
const PIECE_R := 0.045
const COLORS := [Color(0, 0, 0), Color(0.9, 0.15, 0.15), Color(1.0, 0.82, 0.1)]
const NAMES := ["", "Red", "Yellow"]

var main: Node
var grid: Array[int] = []    # c + r * COLS, r = 0 is the bottom; 0 empty, 1 red, 2 yellow
var turn := 1
var winner := 0              # 0 none, 1 red, 2 yellow, 3 draw
var last_mover := -1
var win_cells: Array[int] = []

var _pieces: Array[MeshInstance3D] = []
var _drop_cell := -1
var _drop_t := 1.0
var _status: Label3D
var _note := ""
var _note_until := 0.0
var _t := 0.0


## A disc you can pick up from a tray and drop into a column slot (local only: the move it
## makes is what's shared).
class TrayDisc extends Node3D:
	var game: Node
	var color := 1
	var home := Vector3.ZERO
	var hand: Node = null

	func grab_distance(p: Vector3) -> float:
		return global_position.distance_to(p) - PIECE_R

	func on_grab(h: Node) -> bool:
		hand = h
		return true

	func on_release(h: Node) -> void:
		if hand == h:
			hand = null
			game.disc_released(self)


const GAP := 0.024            # space between the two faces, where the discs slide
const FACE_T := 0.012

var _trays: Array[TrayDisc] = []


## A Connect Four disc: a raised rim, a recessed face with a ring, and a ribbed edge.
static func disc_mesh() -> ArrayMesh:
	var t := 0.009
	return Kit.lathe_mesh(PackedVector2Array([Vector2(0, t - 0.002), Vector2(0.022, t - 0.002), Vector2(0.025, t),
		Vector2(0.03, t), Vector2(0.033, t - 0.002), Vector2(0.038, t - 0.002), Vector2(0.041, t), Vector2(PIECE_R - 0.002, t),
		Vector2(PIECE_R, t - 0.002), Vector2(PIECE_R, -t + 0.002), Vector2(PIECE_R - 0.002, -t), Vector2(0.041, -t),
		Vector2(0.038, -t + 0.002), Vector2(0.033, -t + 0.002), Vector2(0.03, -t), Vector2(0.025, -t), Vector2(0.022, -t + 0.002),
		Vector2(0, -t + 0.002)]), 28)


func _disc_mat(v: int) -> StandardMaterial3D:
	return Kit.mat(COLORS[v], 0.28, 0.0)


func _ready() -> void:
	grid.resize(COLS * ROWS)
	grid.fill(0)
	# A giant yard-game board: two blue faces with real holes, the discs slide between them;
	# side posts on splayed feet and a release bar along the bottom.
	var blue := Kit.mat(Color(0.08, 0.26, 0.78), 0.3, 0.0)
	var blue_dark := Kit.mat(Color(0.05, 0.17, 0.55), 0.35)
	var w := COLS * CELL
	var h := ROWS * CELL
	var cy := BOTTOM + (ROWS - 1) * CELL / 2.0
	var panel := Kit.holed_panel_mesh(COLS, ROWS, CELL, PIECE_R + 0.006, FACE_T, 28)
	for face: float in [1.0, -1.0]:
		var mi := MeshInstance3D.new()
		mi.mesh = panel
		mi.material_override = blue
		mi.position = Vector3(0, cy, face * (GAP / 2.0 + FACE_T / 2.0))
		add_child(mi)
	# Side rails and the bottom closing the gap; slot dividers on top.
	var depth := GAP + FACE_T * 2.0
	for sx: float in [-1.0, 1.0]:
		Kit.add_rbox(self, Vector3(0.045, h + 0.06, depth + 0.01), Vector3(sx * (w / 2.0 + 0.0225), cy + 0.01, 0), blue, 0.012, Kit.LAYER_FURNITURE)
		# Posts down to the floor and splayed feet.
		Kit.add_rbox(self, Vector3(0.06, cy - h / 2.0 + 0.02, 0.07), Vector3(sx * (w / 2.0 + 0.03), (cy - h / 2.0) / 2.0, 0), blue_dark, 0.015)
		Kit.add_rbox(self, Vector3(0.08, 0.04, 0.62), Vector3(sx * (w / 2.0 + 0.03), 0.02, 0), blue_dark, 0.018)
		for sz: float in [-0.29, 0.29]:
			Kit.add_cylinder(self, 0.03, 0.012, Vector3(sx * (w / 2.0 + 0.03), 0.006, sz), Kit.mat(Color(0.1, 0.1, 0.1), 0.9), 0, -1.0, 12)
		Kit.add_rbox(self, Vector3(0.05, 0.3, 0.04), Vector3(sx * (w / 2.0 + 0.03), 0.17, 0.12), blue_dark, 0.01, 0, Vector3(0.75, 0, 0))
		Kit.add_rbox(self, Vector3(0.05, 0.3, 0.04), Vector3(sx * (w / 2.0 + 0.03), 0.17, -0.12), blue_dark, 0.01, 0, Vector3(-0.75, 0, 0))
	Kit.add_rbox(self, Vector3(w + 0.09, 0.05, depth + 0.01), Vector3(0, cy - h / 2.0 - 0.025, 0), blue, 0.012)
	# The release slider along the bottom, in yellow.
	Kit.add_rbox(self, Vector3(w * 0.9, 0.025, 0.02), Vector3(0, cy - h / 2.0 - 0.06, depth / 2.0 + 0.012), Kit.mat(Color(1.0, 0.78, 0.1), 0.35), 0.008)
	for c in COLS + 1:
		var x := (c - COLS / 2.0) * CELL
		Kit.add_rbox(self, Vector3(0.012, 0.035, depth + 0.004), Vector3(x, cy + h / 2.0 + 0.0175, 0), blue_dark, 0.004)
	# Logo plate.
	Kit.add_rbox(self, Vector3(0.34, 0.07, 0.006), Vector3(0, cy + h / 2.0 + 0.075, depth / 2.0 + 0.003), Kit.mat(Color(0.95, 0.95, 0.97), 0.4), 0.01)
	Kit.add_label(self, "CONNECT 4", 0.045, Vector3(0, cy + h / 2.0 + 0.075, depth / 2.0 + 0.008), 0.0, Color(0.85, 0.1, 0.12))
	var dm := disc_mesh()
	for r in ROWS:
		for c in COLS:
			var p := MeshInstance3D.new()
			p.mesh = dm
			p.rotation.x = PI / 2
			p.visible = false
			add_child(p)
			_pieces.append(p)
	for c in COLS:
		var b := Button3D.new("V", Vector2(0.08, 0.06), Color(0.25, 0.3, 0.45), _on_column.bind(c))
		b.position = _cell_pos(c, ROWS) + Vector3(0, 0.14, 0.0)
		add_child(b)
	var reset := Button3D.new("New game", Vector2(0.22, 0.07), Color(0.2, 0.45, 0.3), _on_new_game)
	reset.position = Vector3(0, cy - h / 2.0 - 0.17, depth / 2.0 + 0.02)
	add_child(reset)
	_status = Kit.add_label(self, "", 0.05, Vector3(0, BOTTOM + ROWS * CELL + 0.28, 0.0), 0.0, Color.WHITE)
	_status.outline_size = 10
	_status.outline_modulate = Color(0, 0, 0, 0.7)
	var help := Kit.add_label(self, "Grab a disc from the trays and drop it in a slot (or point at V and pull the trigger)", 0.022,
		Vector3(0, cy - h / 2.0 - 0.24, depth / 2.0 + 0.02), 0.0, Color(0.85, 0.9, 1.0))
	help.width = 0.9 / help.pixel_size
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Disc trays on stands either side: red on the left, yellow on the right.
	for side in 2:
		var sx := -1.0 if side == 0 else 1.0
		var tray := Vector3(sx * (w / 2.0 + 0.32), 0.95, 0.12)
		Kit.add_cylinder(self, 0.02, 0.93, Vector3(tray.x, 0.465, tray.z), Kit.mat(Color(0.7, 0.7, 0.72), 0.3, 0.9), 0, -1.0, 10)
		Kit.add_cylinder(self, 0.14, 0.02, Vector3(tray.x, 0.01, tray.z), blue_dark, 0, -1.0, 20)
		Kit.add_rbox(self, Vector3(0.3, 0.03, 0.22), tray - Vector3(0, 0.03, 0), blue_dark, 0.012)
		for k in 3:
			var d := TrayDisc.new()
			d.game = self
			d.color = side + 1
			var mi := MeshInstance3D.new()
			mi.mesh = dm
			mi.material_override = _disc_mat(side + 1)
			d.add_child(mi)
			d.rotation.x = PI / 2
			d.home = tray + Vector3(-0.09 + k * 0.09, PIECE_R - 0.02, 0)
			d.position = d.home
			d.add_to_group("grabbable")
			add_child(d)
			_trays.append(d)
	_refresh()


func _cell_pos(c: int, r: int) -> Vector3:
	return Vector3((c - (COLS - 1) / 2.0) * CELL, BOTTOM + r * CELL, 0.0)


## A tray disc was let go: over a column's slot it plays there, otherwise it goes back.
func disc_released(d: TrayDisc) -> void:
	var local := to_local(d.global_position)
	var top := BOTTOM + ROWS * CELL - CELL / 2.0
	var c := roundi(local.x / CELL + (COLS - 1) / 2.0)
	if c >= 0 and c < COLS and absf(local.z) < 0.16 and local.y > top - 0.06 and local.y < top + 0.3:
		if winner == 0 and d.color != turn:
			_say("It's %s's turn" % NAMES[turn])
		else:
			_on_column(c)
	d.position = d.home
	d.rotation = Vector3(PI / 2, 0, 0)


func _on_column(c: int) -> void:
	if main.is_host():
		var err := try_move(c, main.me())
		if err != "":
			_say(err)
	else:
		main.send({"t": "c4_req", "c": c})


func _on_new_game() -> void:
	if main.is_host():
		_reset()
		_broadcast(-1)
	else:
		main.send({"t": "c4_reset"})


## Host only. Returns "" on success, or why the move isn't allowed.
func try_move(c: int, who: int) -> String:
	if winner != 0:
		return "Game over - press New game"
	if c < 0 or c >= COLS:
		return "?"
	if main.has_friends() and who == last_mover:
		return "Wait for the other player"
	var r := 0
	while r < ROWS and grid[c + r * COLS] != 0:
		r += 1
	if r >= ROWS:
		return "That column is full"
	grid[c + r * COLS] = turn
	last_mover = who
	_check_win(c, r)
	if winner == 0:
		turn = 3 - turn
	_start_drop(c + r * COLS)
	_refresh()
	_broadcast(c + r * COLS)
	return ""


func _check_win(c: int, r: int) -> void:
	var me := grid[c + r * COLS]
	for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, -1)]:
		var line: Array[int] = [c + r * COLS]
		for s: int in [-1, 1]:
			var cc := c + d.x * s
			var rr := r + d.y * s
			while cc >= 0 and cc < COLS and rr >= 0 and rr < ROWS and grid[cc + rr * COLS] == me:
				line.append(cc + rr * COLS)
				cc += d.x * s
				rr += d.y * s
		if line.size() >= 4:
			winner = me
			win_cells = line
			return
	if not grid.has(0):
		winner = 3


func _reset() -> void:
	grid.fill(0)
	turn = 1
	winner = 0
	last_mover = -1
	win_cells = []
	_drop_cell = -1
	for p in _pieces:
		p.scale = Vector3.ONE
	_refresh()


func _broadcast(dropped: int) -> void:
	main.send(_state_msg(dropped))


func _state_msg(dropped: int) -> Dictionary:
	return {"t": "c4_s", "g": grid.duplicate(), "turn": turn, "w": winner, "lm": last_mover, "wc": win_cells.duplicate(), "d": dropped}


func _start_drop(cell: int) -> void:
	_drop_cell = cell
	_drop_t = 0.0


func _say(text: String) -> void:
	_note = text
	_note_until = _t + 2.0
	_refresh()


func _refresh() -> void:
	for i in _pieces.size():
		var v := grid[i]
		_pieces[i].visible = v != 0
		if v != 0:
			_pieces[i].material_override = _disc_mat(v)
			_pieces[i].position = _cell_pos(i % COLS, i / COLS)
	var text := ""
	match winner:
		0:
			text = "%s's turn" % NAMES[turn]
		3:
			text = "It's a draw!"
		_:
			text = "%s wins!" % NAMES[winner]
	if _t < _note_until:
		text = _note
	_status.text = text


func _process(delta: float) -> void:
	_t += delta
	if _note_until > 0.0 and _t >= _note_until:
		_note_until = 0.0
		_refresh()
	if _drop_cell >= 0 and _drop_t < 1.0:
		_drop_t = minf(_drop_t + delta * 2.5, 1.0)
		var c := _drop_cell % COLS
		var r := _drop_cell / COLS
		var top := _cell_pos(c, ROWS)
		var end := _cell_pos(c, r)
		var k := _drop_t * _drop_t
		_pieces[_drop_cell].position = top.lerp(end, k)
	# Winning pieces pulse.
	for i in win_cells:
		var s := 1.0 + 0.15 * sin(_t * 8.0)
		_pieces[i].scale = Vector3(s, 1, s)
	# Tray discs follow the hand holding them, upright like you'd post them.
	for d in _trays:
		if d.hand != null:
			var t: Transform3D = d.hand.global_transform
			d.global_position = d.hand.grab_point() + t.basis * Vector3(0, -0.01, -0.04)
			d.global_rotation = Vector3(PI / 2, global_rotation.y, 0)


func handle(msg: Dictionary, from: int) -> void:
	match str(msg.get("t", "")):
		"c4_req":
			if main.is_host():
				var err := try_move(int(msg.get("c", -1)), from)
				if err != "":
					main.send({"t": "c4_no", "to": from, "why": err})
		"c4_reset":
			if main.is_host():
				_reset()
				_broadcast(-1)
		"c4_no":
			if int(msg.get("to", -1)) == main.me():
				_say(str(msg.get("why", "")))
		"c4_s":
			var g: Array = msg.get("g", [])
			if g.size() != COLS * ROWS:
				return
			for i in g.size():
				grid[i] = int(g[i])
			turn = int(msg.get("turn", 1))
			winner = int(msg.get("w", 0))
			last_mover = int(msg.get("lm", -1))
			for i in _pieces.size():
				_pieces[i].scale = Vector3.ONE
			win_cells.clear()
			for i: Variant in msg.get("wc", []):
				win_cells.append(int(i))
			var d := int(msg.get("d", -1))
			_refresh()
			if d >= 0:
				_start_drop(d)


func full_state() -> Dictionary:
	return _state_msg(-1)


func on_identity_changed(old_id: int, new_id: int) -> void:
	if last_mover == old_id:
		last_mover = new_id


func on_peer_left(slot: int) -> void:
	if last_mover == slot:
		last_mover = -1
