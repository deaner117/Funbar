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


func _ready() -> void:
	grid.resize(COLS * ROWS)
	grid.fill(0)
	var blue := Kit.mat(Color(0.12, 0.3, 0.8), 0.35)
	var w := COLS * CELL + 0.08
	var h := ROWS * CELL + 0.08
	var cy := BOTTOM + (ROWS - 1) * CELL / 2.0
	Kit.add_box(self, Vector3(w, h, 0.05), Vector3(0, cy, -0.01), blue, Kit.LAYER_FURNITURE)
	for sx in [-1.0, 1.0]:
		Kit.add_box(self, Vector3(0.06, cy + h / 2.0, 0.08), Vector3(sx * (w / 2.0 + 0.03), (cy + h / 2.0) / 2.0, -0.01), blue)
		Kit.add_box(self, Vector3(0.1, 0.03, 0.5), Vector3(sx * (w / 2.0 + 0.03), 0.015, -0.01), blue)
	var hole := Kit.mat(Color(0.05, 0.07, 0.14), 0.8)
	for r in ROWS:
		for c in COLS:
			Kit.add_cylinder(self, PIECE_R + 0.004, 0.004, _cell_pos(c, r) + Vector3(0, 0, 0.016), hole, 0, -1.0, 20, Vector3(PI / 2, 0, 0))
			var p := MeshInstance3D.new()
			p.mesh = Kit.cylinder_mesh(PIECE_R, 0.02, -1.0, 20)
			p.rotation.x = PI / 2
			p.visible = false
			add_child(p)
			_pieces.append(p)
	for c in COLS:
		var b := Button3D.new("V", Vector2(0.09, 0.07), Color(0.25, 0.3, 0.45), _on_column.bind(c))
		b.position = _cell_pos(c, ROWS) + Vector3(0, 0.03, 0.02)
		add_child(b)
	var reset := Button3D.new("New game", Vector2(0.22, 0.07), Color(0.2, 0.45, 0.3), _on_new_game)
	reset.position = Vector3(w / 2.0 - 0.11, BOTTOM - 0.2, 0.03)
	add_child(reset)
	_status = Kit.add_label(self, "", 0.05, Vector3(0, BOTTOM + ROWS * CELL + 0.14, 0.02), 0.0, Color.WHITE)
	_status.outline_size = 10
	_status.outline_modulate = Color(0, 0, 0, 0.7)
	Kit.add_label(self, "CONNECT FOUR", 0.06, Vector3(-0.15, BOTTOM - 0.2, 0.03), 0.0, Color(0.95, 0.85, 0.55))
	_refresh()


func _cell_pos(c: int, r: int) -> Vector3:
	return Vector3((c - (COLS - 1) / 2.0) * CELL, BOTTOM + r * CELL, 0.02)


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
			_pieces[i].material_override = Kit.mat(COLORS[v], 0.35)
			_pieces[i].position = _cell_pos(i % COLS, i / COLS) + Vector3(0, 0, 0.012)
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
		_pieces[_drop_cell].position = top.lerp(end, k) + Vector3(0, 0, 0.012)
	# Winning pieces pulse.
	for i in win_cells:
		var s := 1.0 + 0.15 * sin(_t * 8.0)
		_pieces[i].scale = Vector3(s, 1, s)


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
