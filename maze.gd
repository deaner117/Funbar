extends Node3D
## Neon Nibbler: an upright maze-chase cabinet. You are a glow-blob eating seeds in a neon
## maze while four zap-bots hunt you; grab a lightning bolt and the bots short-circuit and can
## be eaten for a few seconds. Press Start and steer with either thumbstick (arrow keys on
## the laptop); walking pauses while you play.
##
## The player's headset runs the game and streams it ("mz_p" with newly eaten seeds); start,
## game over and high scores travel in "mz_g".

const Kit := preload("res://kit.gd")
const AK := preload("res://arcade_kit.gd")
const Button3D := preload("res://button3d.gd")

const MAP := [
	"###################",
	"#........#........#",
	"#*##.###.#.###.##*#",
	"#.................#",
	"#.##.#.#####.#.##.#",
	"#....#...#...#....#",
	"####.###.#.###.####",
	"####.#.......#.####",
	"####.#.##-##.#.####",
	"#......#BBB#......#",
	"####.#.#####.#.####",
	"####.#.......#.####",
	"####.#.#####.#.####",
	"#........#........#",
	"#.###.##.#.##.###.#",
	"#*..#....P....#..*#",
	"###.#.###.###.#.###",
	"#.....#.....#.....#",
	"#.###.#.###.#.###.#",
	"#.................#",
	"###################",
]
const W := 19
const H := 21
const TILE := 12
const DIRS := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
const BOT_COL := [Color(1.0, 0.25, 0.3), Color(1.0, 0.5, 0.9), Color(1.0, 0.65, 0.15), Color(0.6, 0.4, 1.0)]
const SCARED := 7.0

var main: Node
var player_slot := -1
var player_name := ""
var score := 0
var lives := 0
var level := 1
var hi := 0
var hi_name := ""

var seeds := {}          # Vector2i -> 1 seed, 2 bolt
var me_pos := Vector2(9, 15)
var me_dir := Vector2i(-1, 0)
var want_dir := Vector2i(-1, 0)
var bots: Array = []      # {pos: Vector2, dir: Vector2i, mode: 0 chase 1 scared 2 eyes, home: Vector2i}
var scared_t := 0.0
var chain := 0
var dying := 0.0
var ready_t := 0.0

var _vp: SubViewport
var _drawer: Node2D
var _eaten_new: Array = []
var _send_t := 0.0
var _draw_t := 0.0
var _t := 0.0
var _sfx := {}


func _ready() -> void:
	var d := AK.upright(self, "NEON NIBBLER", Color(0.2, 0.85, 1.0), Color(1.0, 0.3, 0.8))
	var panel: Node3D = d["panel"]
	AK.joystick(panel, Vector3(-0.12, 0, 0.02), Color(0.9, 0.1, 0.1))
	AK.button_cap(panel, Vector3(0.08, 0, 0.0), Color(0.2, 0.9, 0.4))
	AK.button_cap(panel, Vector3(0.16, 0, 0.03), Color(1.0, 0.85, 0.2))
	_drawer = Node2D.new()
	_drawer.draw.connect(_draw_screen)
	_vp = AK.screen(self, d["screen_size"], Vector2i(336, 256), _drawer, d["screen_pos"], d["screen_rot"])
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var start := Button3D.new("Start", Vector2(0.14, 0.055), Color(0.2, 0.5, 0.3), _on_start)
	start.position = Vector3(-0.14, 0.88, 0.37)
	start.rotation.x = -0.35
	add_child(start)
	var quit := Button3D.new("Quit", Vector2(0.1, 0.055), Color(0.5, 0.2, 0.2), _on_quit)
	quit.position = Vector3(0.12, 0.88, 0.37)
	quit.rotation.x = -0.35
	add_child(quit)
	for k: String in ["chomp", "coin", "boom", "ding", "blip"]:
		_sfx[k] = AK.player3d(self, Vector3(0, 1.4, 0.2), AK.sfx(k), -14.0 if k == "chomp" else -9.0)
	AK.merge(self)
	_reset_level()


func _cell(c: Vector2i) -> String:
	if c.y < 0 or c.y >= H or c.x < 0 or c.x >= W:
		return "#"
	return (MAP[c.y] as String)[c.x]


func _open(c: Vector2i, for_bot := false) -> bool:
	var ch := _cell(c)
	return ch != "#" and (ch != "-" or for_bot)


func _reset_level() -> void:
	seeds.clear()
	for y in H:
		for x in W:
			var ch := _cell(Vector2i(x, y))
			if ch == ".":
				seeds[Vector2i(x, y)] = 1
			elif ch == "*":
				seeds[Vector2i(x, y)] = 2
	_reset_actors()


func _reset_actors() -> void:
	me_pos = Vector2(9, 15)
	me_dir = Vector2i(-1, 0)
	want_dir = me_dir
	bots.clear()
	var homes := [Vector2i(9, 7), Vector2i(8, 9), Vector2i(9, 9), Vector2i(10, 9)]
	for i in 4:
		bots.append({"pos": Vector2(homes[i]), "dir": Vector2i(-1, 0) if i == 0 else Vector2i(0, -1), "mode": 0,
			"release": i * 3.0})
	scared_t = 0.0
	ready_t = 1.5


func _on_start() -> void:
	if player_slot >= 0 and player_slot != main.me() and main.avatars.has(player_slot):
		main.notify("Someone is already playing")
		return
	player_slot = main.me()
	player_name = main.player_name
	score = 0
	lives = 3
	level = 1
	_reset_level()
	main.controls_captured = self
	_sfx["coin"].play()
	_send_game(true)


func _on_quit() -> void:
	if player_slot == main.me():
		_game_over()


func _game_over() -> void:
	if score > hi:
		hi = score
		hi_name = player_name
	player_slot = -1
	if main.controls_captured == self:
		main.controls_captured = null
	_send_game(false)


func _send_game(fresh: bool) -> void:
	main.send({"t": "mz_g", "ps": player_slot, "nm": player_name, "sc": score, "li": lives, "lv": level, "hi": hi, "hn": hi_name,
		"new": fresh})


# ---------------------------------------------------------------- simulation

func _process(delta: float) -> void:
	_t += delta
	var mine: bool = player_slot >= 0 and player_slot == main.me()
	if mine:
		_simulate(minf(delta, 0.05))
		_send_t -= delta
		if _send_t <= 0.0:
			_send_t = 0.066
			var bl := []
			for b: Dictionary in bots:
				bl.append([snappedf(b["pos"].x, 0.01), snappedf(b["pos"].y, 0.01), b["mode"]])
			main.send({"t": "mz_p", "p": [snappedf(me_pos.x, 0.01), snappedf(me_pos.y, 0.01), DIRS.find(me_dir)], "b": bl,
				"d": _eaten_new, "sc": score, "li": lives, "st": snappedf(scared_t, 0.1), "dy": snappedf(dying, 0.1)})
			_eaten_new = []
	# Redraw at 30 Hz, and only when someone could be looking.
	_draw_t -= delta
	if _draw_t <= 0.0 and main.camera and main.camera.global_position.distance_to(global_position) < 14.0:
		_draw_t = 0.033
		_drawer.queue_redraw()
		_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


func _simulate(dt: float) -> void:
	if ready_t > 0.0:
		ready_t -= dt
		return
	if dying > 0.0:
		dying -= dt
		if dying <= 0.0:
			lives -= 1
			if lives <= 0:
				_game_over()
			else:
				_reset_actors()
				_send_game(false)
		return
	var s: Vector2 = main.stick(0)
	var s2: Vector2 = main.stick(1)
	if s2.length() > s.length():
		s = s2
	if s.length() > 0.5:
		want_dir = Vector2i(signi(roundi(s.x)), 0) if absf(s.x) > absf(s.y) else Vector2i(0, -signi(roundi(s.y)))
	var speed := 5.0 + level * 0.3
	me_pos = _move(me_pos, dt * speed)
	# Eat.
	var c := Vector2i(roundi(me_pos.x), roundi(me_pos.y))
	if seeds.has(c) and me_pos.distance_to(Vector2(c)) < 0.35:
		var kind: int = seeds[c]
		seeds.erase(c)
		_eaten_new.append(c.y * W + c.x)
		if kind == 2:
			score += 50
			scared_t = SCARED
			chain = 0
			for b: Dictionary in bots:
				if b["mode"] == 0:
					b["mode"] = 1
					b["dir"] = -b["dir"]
			_sfx["ding"].play()
		else:
			score += 10
			_sfx["chomp"].play()
		if seeds.is_empty():
			level += 1
			_sfx["coin"].play()
			_reset_level()
			_send_game(false)
			return
	scared_t = maxf(scared_t - dt, 0.0)
	for i in bots.size():
		var b: Dictionary = bots[i]
		if scared_t <= 0.0 and b["mode"] == 1:
			b["mode"] = 0
		if b["release"] > 0.0:
			b["release"] -= dt
			continue
		var bs := (4.4 + level * 0.25) * (0.55 if b["mode"] == 1 else (2.2 if b["mode"] == 2 else 1.0))
		b["pos"] = _move_bot(b, i, dt * bs)
		if (b["pos"] as Vector2).distance_to(me_pos) < 0.6:
			if b["mode"] == 1:
				b["mode"] = 2
				chain += 1
				score += 100 * (1 << chain)
				_sfx["blip"].play()
			elif b["mode"] == 0:
				dying = 1.4
				_sfx["boom"].play()
				return


## The next tile centre at or ahead of pos when moving in dir.
func _ahead(pos: Vector2, dir: Vector2i) -> Vector2i:
	var x := roundi(pos.x)
	var y := roundi(pos.y)
	if dir.x > 0:
		x = ceili(pos.x - 0.0001)
	elif dir.x < 0:
		x = floori(pos.x + 0.0001)
	if dir.y > 0:
		y = ceili(pos.y - 0.0001)
	elif dir.y < 0:
		y = floori(pos.y + 0.0001)
	return Vector2i(x, y)


## Moves the blob along the grid: reverses at once, turns into want_dir at tile centres when
## that way is open, stops at walls.
func _move(pos: Vector2, dist: float) -> Vector2:
	var remaining := dist
	var guard := 0
	while remaining > 0.0001 and guard < 8:
		guard += 1
		if want_dir == -me_dir:
			me_dir = want_dir
		var c := _ahead(pos, me_dir)
		var along := (Vector2(c) - pos).dot(Vector2(me_dir))
		if along > 0.0001:
			var stepd := minf(along, remaining)
			pos += Vector2(me_dir) * stepd
			remaining -= stepd
			continue
		pos = Vector2(c)
		if _open(c + want_dir):
			me_dir = want_dir
		if not _open(c + me_dir):
			return pos
		var stepd2 := minf(0.5, remaining)
		pos += Vector2(me_dir) * stepd2
		remaining -= stepd2
	return pos


func _move_bot(b: Dictionary, i: int, dist: float) -> Vector2:
	var pos: Vector2 = b["pos"]
	var remaining := dist
	var guard := 0
	while remaining > 0.0001 and guard < 8:
		guard += 1
		var c := _ahead(pos, b["dir"])
		var along := (Vector2(c) - pos).dot(Vector2(b["dir"]))
		if along > 0.0001:
			var stepd := minf(along, remaining)
			pos += Vector2(b["dir"]) * stepd
			remaining -= stepd
			continue
		pos = Vector2(c)
		if b["mode"] == 2 and c == Vector2i(9, 9):
			b["mode"] = 0
		b["dir"] = _choose(b, i, c)
		var stepd2 := minf(0.5, remaining)
		pos += Vector2(b["dir"]) * stepd2
		remaining -= stepd2
	return pos


func _choose(b: Dictionary, i: int, c: Vector2i) -> Vector2i:
	var target := Vector2i(roundi(me_pos.x), roundi(me_pos.y))
	match i:
		1:
			target += me_dir * 3
		2:
			target = Vector2i(1, 1) if int(_t / 6.0) % 2 == 0 else target
		3:
			if Vector2(c).distance_to(me_pos) < 6.0:
				target = Vector2i(1, 19)
	var inside := _cell(c) == "B" or _cell(c) == "-"
	if b["mode"] == 2:
		target = Vector2i(9, 9)
	elif inside:
		target = Vector2i(9, 6)
	var options: Array[Vector2i] = []
	for d: Vector2i in DIRS:
		if d == -b["dir"] and b["mode"] != 2 and not inside:
			continue
		if _open(c + d, b["mode"] == 2 or _cell(c) == "B" or _cell(c) == "-"):
			options.append(d)
	if options.is_empty():
		return -b["dir"]
	if b["mode"] == 1:
		return options[randi() % options.size()]
	var best: Vector2i = options[0]
	var best_d := 1e9
	for d: Vector2i in options:
		var dd := Vector2(c + d).distance_squared_to(Vector2(target))
		if dd < best_d:
			best_d = dd
			best = d
	return best


# ---------------------------------------------------------------- drawing

func _draw_screen() -> void:
	var cv := AK.Batch.new()
	cv.draw_rect(Rect2(0, 0, 336, 256), Color(0, 0, 0))
	var ox := 6
	var oy := 2
	var wall := Color(0.15, 0.75, 1.0)
	for y in H:
		for x in W:
			var ch := _cell(Vector2i(x, y))
			var r := Rect2(ox + x * TILE, oy + y * TILE, TILE, TILE)
			if ch == "#":
				cv.draw_rect(r, Color(0.02, 0.05, 0.15))
				for k in 4:
					var n: Vector2i = Vector2i(x, y) + DIRS[k]
					if _cell(n) != "#":
						var a := r.position
						match k:
							0: cv.draw_line(a + Vector2(TILE - 1, 0), a + Vector2(TILE - 1, TILE), wall, 2.0)
							1: cv.draw_line(a + Vector2(0, TILE - 1), a + Vector2(TILE, TILE - 1), wall, 2.0)
							2: cv.draw_line(a + Vector2(1, 0), a + Vector2(1, TILE), wall, 2.0)
							3: cv.draw_line(a + Vector2(0, 1), a + Vector2(TILE, 1), wall, 2.0)
			elif ch == "-":
				cv.draw_rect(Rect2(r.position + Vector2(0, 5), Vector2(TILE, 2)), Color(1.0, 0.5, 0.9))
	for c: Vector2i in seeds:
		var p := Vector2(ox + c.x * TILE + TILE / 2.0, oy + c.y * TILE + TILE / 2.0)
		if seeds[c] == 1:
			cv.draw_rect(Rect2(p - Vector2(1.5, 1.5), Vector2(3, 3)), Color(1.0, 0.9, 0.6))
		else:
			var pulse := 0.6 + 0.4 * sin(_t * 8.0)
			_bolt(cv, p, Color(1.0, 0.95, 0.2) * pulse + Color(0, 0, 0, 1))
	var playing := player_slot >= 0
	if playing:
		# The blob: wobbling green body with eyes looking where it goes.
		var p := Vector2(ox + me_pos.x * TILE + TILE / 2.0, oy + me_pos.y * TILE + TILE / 2.0)
		var wob := sin(_t * 18.0) * 0.8
		var rad := 5.6 if dying <= 0.0 else 5.6 * dying / 1.4
		cv.draw_circle(p + Vector2(0, 0.5), rad + 1.0, Color(0.1, 0.6, 0.2))
		cv.draw_circle(p, rad + wob * 0.3, Color(0.35, 1.0, 0.45))
		cv.draw_circle(p + Vector2(-1.5, -1.8), 1.6, Color(0.8, 1.0, 0.85))
		var look := Vector2(me_dir) * 1.2
		for ex: float in [-2.2, 2.2]:
			cv.draw_circle(p + Vector2(ex, -1.0), 1.8, Color(1, 1, 1))
			cv.draw_circle(p + Vector2(ex, -1.0) + look, 0.9, Color(0, 0, 0))
		for i in bots.size():
			var b: Dictionary = bots[i]
			_bot(cv, Vector2(ox + b["pos"].x * TILE + TILE / 2.0, oy + b["pos"].y * TILE + TILE / 2.0), i, int(b["mode"]), b["dir"])
	# Side panel.
	cv.flush(_drawer)
	var font := ThemeDB.fallback_font
	var px := 240
	_drawer.draw_string(font, Vector2(px, 22), "NEON", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.3, 0.9, 1.0))
	_drawer.draw_string(font, Vector2(px, 40), "NIBBLER", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1.0, 0.4, 0.85))
	_drawer.draw_string(font, Vector2(px, 72), "SCORE", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.8, 0.8, 0.8))
	_drawer.draw_string(font, Vector2(px, 90), str(score), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1))
	_drawer.draw_string(font, Vector2(px, 116), "HIGH", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.8, 0.8, 0.8))
	_drawer.draw_string(font, Vector2(px, 134), str(hi), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 0.85, 0.3))
	_drawer.draw_string(font, Vector2(px, 150), hi_name.left(10), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.85, 0.3))
	_drawer.draw_string(font, Vector2(px, 176), "LEVEL %d" % level, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 1.0, 0.6))
	for i in maxi(lives - 1, 0):
		cv.draw_circle(Vector2(px + 8 + i * 16, 196), 5.0, Color(0.35, 1.0, 0.45))
	if not playing:
		if int(_t * 2.0) % 2 == 0:
			_drawer.draw_string(font, Vector2(54, 128), "PRESS  START", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 1.0, 0.4))
		_drawer.draw_string(font, Vector2(px, 230), "GAME OVER" if score > 0 else "INSERT FUN", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 0.4, 0.4))
	elif ready_t > 0.0:
		_drawer.draw_string(font, Vector2(90, 128), "READY!", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 1.0, 0.4))
	cv.flush(_drawer)


func _bolt(cv: AK.Batch, p: Vector2, c: Color) -> void:
	var pts := PackedVector2Array([p + Vector2(1, -5), p + Vector2(-3, 1), p + Vector2(0, 1), p + Vector2(-1, 5), p + Vector2(3, -1), p + Vector2(0, -1)])
	cv.draw_colored_polygon(pts, c)


## A zap-bot: a boxy robot with an antenna and visor eyes.
func _bot(cv: AK.Batch, p: Vector2, i: int, mode: int, dir: Vector2i) -> void:
	var col: Color = BOT_COL[i]
	if mode == 1:
		col = Color(0.2, 0.3, 1.0) if scared_t > 2.0 or int(_t * 8.0) % 2 == 0 else Color(0.95, 0.95, 1.0)
	if mode != 2:
		cv.draw_rect(Rect2(p + Vector2(-5, -4), Vector2(10, 9)), col)
		cv.draw_rect(Rect2(p + Vector2(-4, -6), Vector2(8, 3)), col.darkened(0.2))
		cv.draw_line(p + Vector2(0, -6), p + Vector2(0, -9), col.lightened(0.3), 1.0)
		cv.draw_circle(p + Vector2(0, -9.5), 1.3, Color(1.0, 1.0, 0.5) if int(_t * 6.0 + i) % 2 == 0 else col)
		for k in 3:
			cv.draw_rect(Rect2(p + Vector2(-5 + k * 4, 5), Vector2(2, 2)), col.darkened(0.4))
	if mode == 1:
		for k in 4:
			cv.draw_line(p + Vector2(-4 + k * 2, 2 + (k % 2)), p + Vector2(-2 + k * 2, 2 + ((k + 1) % 2)), Color(1, 1, 1), 1.0)
	var look := Vector2(dir) * 1.0
	cv.draw_rect(Rect2(p + Vector2(-4, -3), Vector2(8, 3.5)), Color(0.05, 0.05, 0.1))
	for ex: float in [-2.0, 2.0]:
		cv.draw_circle(p + Vector2(ex, -1.3) + look, 1.1, Color(0.4, 1.0, 1.0) if mode != 1 else Color(1, 0.4, 0.4))


# ---------------------------------------------------------------- network

func handle(msg: Dictionary, _from: int) -> void:
	match str(msg.get("t", "")):
		"mz_p":
			if player_slot == main.me():
				return
			var p: Array = msg.get("p", [9, 15, 2])
			me_pos = Vector2(float(p[0]), float(p[1]))
			me_dir = DIRS[clampi(int(p[2]), 0, 3)]
			var bl: Array = msg.get("b", [])
			for i in mini(bl.size(), bots.size()):
				bots[i]["pos"] = Vector2(float(bl[i][0]), float(bl[i][1]))
				bots[i]["mode"] = int(bl[i][2])
			for idx: Variant in msg.get("d", []):
				seeds.erase(Vector2i(int(idx) % W, int(idx) / W))
			score = int(msg.get("sc", score))
			lives = int(msg.get("li", lives))
			scared_t = float(msg.get("st", 0.0))
			dying = float(msg.get("dy", 0.0))
		"mz_g", "mz_full":
			var was_mine: bool = player_slot >= 0 and player_slot == main.me()
			player_slot = int(msg.get("ps", -1))
			if was_mine and player_slot != main.me() and main.controls_captured == self:
				main.controls_captured = null
			player_name = str(msg.get("nm", ""))
			score = int(msg.get("sc", 0))
			lives = int(msg.get("li", 0))
			var lv := int(msg.get("lv", 1))
			if lv != level or bool(msg.get("new", false)):
				level = lv
				_reset_level()
			hi = int(msg.get("hi", 0))
			hi_name = str(msg.get("hn", ""))
			if msg.has("eaten"):
				for idx: Variant in msg["eaten"]:
					seeds.erase(Vector2i(int(idx) % W, int(idx) / W))


func full_state() -> Dictionary:
	var eaten := []
	for y in H:
		for x in W:
			var ch := _cell(Vector2i(x, y))
			if (ch == "." or ch == "*") and not seeds.has(Vector2i(x, y)):
				eaten.append(y * W + x)
	return {"t": "mz_full", "ps": player_slot, "nm": player_name, "sc": score, "li": lives, "lv": level, "hi": hi, "hn": hi_name,
		"new": true, "eaten": eaten}


func on_identity_changed(old_id: int, new_id: int) -> void:
	if player_slot == old_id and old_id >= 0:
		player_slot = new_id


func on_peer_left(slot: int) -> void:
	if slot == player_slot:
		player_slot = -1
