extends Node3D
## Alley-roll lanes (skee-ball style): grab a wooden ball from the tray, roll it up the lane,
## it hops off the bump into the target rings: 10 to 50 points, 100 in the top corners. Nine
## balls a game. Balls are props (so throws are shared); whoever rolled a ball judges where it
## landed and sends the lane's score ("sk_" messages).
##
## Lane space: the player stands at +z, the lane runs to the target at -z.

const Kit := preload("res://kit.gd")
const AK := preload("res://arcade_kit.gd")
const Button3D := preload("res://button3d.gd")

const BALLS_PER_LANE := 6
const ROLLS := 9
const R := 0.045
## The target board: bottom edge and slope direction (45 degrees up and away).
const BOARD_P0 := Vector3(0, 0.8, -2.55)
const BOARD_S := Vector3(0, 0.70710678, -0.70710678)
const BOARD_N := Vector3(0, 0.70710678, 0.70710678)
const RING_V := 0.33       # rings' centre, metres up the board
const RINGS := [[0.055, 50], [0.11, 40], [0.165, 30], [0.22, 20]]

var main: Node
var lanes: Array = []     # per lane: {node, balls, score, rolls, hi, hi_name, player, label, playing}

var _ding: AudioStreamPlayer3D


func setup(anchors: Array) -> void:
	var pr: Node = main.modules["pr"]
	for li in anchors.size():
		var a: Array = anchors[li]
		var p := Node3D.new()
		p.position = a[0]
		p.rotation.y = a[1]
		add_child(p)
		var lane := {"node": p, "balls": [], "score": 0, "rolls": 0, "hi": 0, "hi_name": "", "player": "", "playing": false,
			"pending": {}}
		_build_lane(p, lane, li)
		AK.merge(p)
		for i in BALLS_PER_LANE:
			var home := p.global_transform * Transform3D(Basis.IDENTITY, Vector3(-0.25 + i * 0.1, 0.33 + R + 0.005, 0.09))
			lane["balls"].append(pr.add_prop("skee", home))
		lanes.append(lane)
		_refresh(li)


func _build_lane(p: Node3D, lane: Dictionary, li: int) -> void:
	var wood := Kit.tmat(Color(0.78, 0.58, 0.36), "planks", 2.0, 0.3)
	var black := Kit.mat(Color(0.04, 0.04, 0.06), 0.5)
	var glass := Kit.mat(Color(0.7, 0.85, 1.0, 0.12), 0.05)
	var neon_a := Color(1.0, 0.3, 0.75) if li % 2 == 0 else Color(0.25, 0.9, 1.0)
	var art := AK.side_art(neon_a, Color(1.0, 0.85, 0.2))
	# Base cabinet under the lane, art sides.
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.76, 0.34, 3.4)
	base.mesh = bm
	base.material_override = art
	base.position = Vector3(0, 0.17, -1.45)
	p.add_child(base)
	# Collision bodies: the lane ramp, the bump, the target board, tray, sides, back.
	_slab(p, Vector3(0.62, 0.05, 2.25), Vector3(0, 0.54, -1.2), 0.144, wood)
	_slab(p, Vector3(0.62, 0.05, 0.18), Vector3(0, 0.74, -2.375), 0.49, wood)
	_slab(p, Vector3(0.66, 0.04, 0.75), BOARD_P0 + BOARD_S * 0.375 - BOARD_N * 0.02, PI / 4, Kit.mat(Color(0.08, 0.06, 0.1), 0.6))
	_slab(p, Vector3(0.62, 0.04, 0.34), Vector3(0, 0.31, 0.06), 0.0, wood)                   # tray floor
	_slab(p, Vector3(0.66, 0.16, 0.03), Vector3(0, 0.38, 0.235), 0.0, black)                 # tray lip
	_slab(p, Vector3(0.66, 0.5, 0.04), Vector3(0, 0.49, -2.5), 0.0, black)                   # gutter wall under the board
	for sx: float in [-0.33, 0.33]:
		_slab(p, Vector3(0.03, 1.35, 3.4), Vector3(sx, 0.95, -1.45), 0.0, glass)
		Kit.add_box(p, Vector3(0.05, 0.18, 3.4), Vector3(sx, 0.38, -1.45), black)
		Kit.add_box(p, Vector3(0.04, 0.02, 3.4), Vector3(sx, 1.63, -1.45), Kit.flat(neon_a))
	_slab(p, Vector3(0.66, 1.5, 0.04), Vector3(0, 0.95, -3.17), 0.0, black)
	_slab(p, Vector3(0.66, 0.04, 0.85), Vector3(0, 1.65, -2.75), 0.0, glass)
	# Target rings on the board (glowing rims) and the 100 pockets.
	var board := Node3D.new()
	board.position = BOARD_P0 + BOARD_S * RING_V
	board.basis = Basis(Vector3.RIGHT, PI / 4)
	p.add_child(board)
	var ring_colors := [Color(1.0, 0.85, 0.2), Color(1.0, 0.4, 0.2), Color(0.3, 1.0, 0.5), Color(0.3, 0.7, 1.0)]
	for i in RINGS.size():
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = RINGS[i][0] - 0.008
		tm.outer_radius = RINGS[i][0] + 0.006
		tm.rings = 40
		tm.ring_segments = 6
		ring.mesh = tm
		ring.material_override = Kit.flat(ring_colors[i])
		ring.position = Vector3(0, 0.005, 0)
		board.add_child(ring)
		var lab := Kit.add_label(board, str(RINGS[i][1]), 0.03, Vector3(0, 0.012, RINGS[i][0] - 0.03), 0.0, ring_colors[i])
		lab.rotation.x = -PI / 2
	Kit.add_cylinder(board, 0.04, 0.012, Vector3(0, 0.0, 0), Kit.mat(Color(0.02, 0.02, 0.02)), 0, -1.0, 20)
	for sx: float in [-0.24, 0.24]:
		Kit.add_cylinder(board, 0.045, 0.012, Vector3(sx, 0.0, -0.32), Kit.mat(Color(0.02, 0.02, 0.02)), 0, -1.0, 20)
		var r100 := MeshInstance3D.new()
		var t100 := TorusMesh.new()
		t100.inner_radius = 0.043
		t100.outer_radius = 0.055
		r100.mesh = t100
		r100.material_override = Kit.flat(Color(1.0, 0.2, 0.6))
		r100.position = Vector3(sx, 0.005, -0.32)
		board.add_child(r100)
		var l100 := Kit.add_label(board, "100", 0.025, Vector3(sx, 0.012, -0.26), 0.0, Color(1.0, 0.4, 0.8))
		l100.rotation.x = -PI / 2
	# Marquee with the score.
	Kit.add_box(p, Vector3(0.76, 0.5, 0.2), Vector3(0, 2.0, -3.1), black)
	Kit.add_box(p, Vector3(0.7, 0.44, 0.01), Vector3(0, 2.0, -2.995), Kit.flat(Color(0.08, 0.02, 0.12)))
	var title := Kit.add_label(p, "ALLEY ROLL", 0.08, Vector3(0, 2.15, -2.985), 0.0, neon_a.lerp(Color.WHITE, 0.3))
	title.outline_size = 14
	title.outline_modulate = neon_a.darkened(0.3)
	lane["label"] = Kit.add_label(p, "", 0.045, Vector3(0, 1.94, -2.985), 0.0, Color(1.0, 0.9, 0.5))
	var start: Node3D = Button3D.new("New game", Vector2(0.2, 0.07), Color(0.2, 0.5, 0.3), _on_start.bind(li))
	start.position = Vector3(0.0, 0.62, 0.26)
	start.rotation.x = -0.6
	p.add_child(start)
	_ding = AK.player3d(self, Vector3.ZERO, AK.sfx("ding"), -8.0)


## A static slab (furniture layer) tilted about x by `tilt`.
func _slab(p: Node3D, size: Vector3, pos: Vector3, tilt: float, m: Material) -> void:
	Kit.add_box(p, size, pos, m, Kit.LAYER_FURNITURE, Vector3(tilt, 0, 0))


func _on_start(li: int) -> void:
	var lane: Dictionary = lanes[li]
	lane["score"] = 0
	lane["rolls"] = 0
	lane["playing"] = true
	lane["player"] = main.player_name
	_send(li)
	var pr: Node = main.modules["pr"]
	for b: Node in lane["balls"]:
		pr.send_home(b)


func _physics_process(delta: float) -> void:
	if lanes.is_empty():
		return
	var me: int = main.me()
	var pr: Node = main.modules["pr"]
	for li in lanes.size():
		var lane: Dictionary = lanes[li]
		var p: Node3D = lane["node"]
		var pending: Dictionary = lane["pending"]
		for b: Node in lane["balls"]:
			# A scored ball drops out of sight for a moment, then pops back in the tray.
			if pending.has(b):
				pending[b] -= delta
				if pending[b] <= 0.0:
					pending.erase(b)
					if b.owner_slot == me:
						pr.send_home(b)
				continue
			if b.owner_slot != me or b.hand != null or b.scored:
				continue
			var l := p.to_local(b.global_position)
			if l.z > -2.45 or absf(l.x) > 0.4:
				continue
			var rel := l - BOARD_P0
			var dist := rel.dot(BOARD_N)
			if l.y < 0.72:
				_landed(li, b, 0)        # dropped into the gutter
			elif dist < R + 0.025:
				var u := l.x
				var v := rel.dot(BOARD_S)
				var pts := 10
				if absf(absf(u) - 0.24) < 0.06 and absf(v - (RING_V + 0.32)) < 0.07:
					pts = 100
				else:
					var d := Vector2(u, v - RING_V).length()
					for ring: Array in RINGS:
						if d < ring[0]:
							pts = ring[1]
							break
				_landed(li, b, pts)


func _landed(li: int, b: Node, pts: int) -> void:
	b.scored = true
	var lane: Dictionary = lanes[li]
	lane["pending"][b] = 0.7
	if lane["playing"] and lane["rolls"] < ROLLS:
		lane["score"] += pts
		lane["rolls"] += 1
		if lane["rolls"] >= ROLLS:
			lane["playing"] = false
			if lane["score"] > lane["hi"]:
				lane["hi"] = lane["score"]
				lane["hi_name"] = lane["player"]
				main.notify("New high score: %d!" % lane["score"])
	if pts > 0:
		_ding.global_position = b.global_position
		_ding.pitch_scale = 0.8 + pts / 100.0
		_ding.play()
	_send(li, pts)


func _send(li: int, pts := -1) -> void:
	_refresh(li)
	var lane: Dictionary = lanes[li]
	main.send({"t": "sk_s", "l": li, "sc": lane["score"], "r": lane["rolls"], "pl": lane["player"], "on": lane["playing"],
		"hi": lane["hi"], "hn": lane["hi_name"], "pts": pts})


func _refresh(li: int) -> void:
	var lane: Dictionary = lanes[li]
	var text := "SCORE %d\nBALLS LEFT %d\nHIGH %d %s" % [lane["score"], ROLLS - lane["rolls"], lane["hi"], lane["hi_name"]]
	if not lane["playing"] and lane["rolls"] == 0:
		text = "PRESS NEW GAME\nHIGH %d %s" % [lane["hi"], lane["hi_name"]]
	elif not lane["playing"]:
		text = "GAME OVER  %d\nHIGH %d %s" % [lane["score"], lane["hi"], lane["hi_name"]]
	(lane["label"] as Label3D).text = text


func handle(msg: Dictionary, _from: int) -> void:
	match str(msg.get("t", "")):
		"sk_s":
			var li := int(msg.get("l", -1))
			if li < 0 or li >= lanes.size():
				return
			var lane: Dictionary = lanes[li]
			lane["score"] = int(msg.get("sc", 0))
			lane["rolls"] = int(msg.get("r", 0))
			lane["player"] = str(msg.get("pl", ""))
			lane["playing"] = bool(msg.get("on", false))
			lane["hi"] = int(msg.get("hi", 0))
			lane["hi_name"] = str(msg.get("hn", ""))
			if int(msg.get("pts", -1)) > 0:
				_ding.play()
			_refresh(li)
		"sk_full":
			for e: Dictionary in msg.get("lanes", []):
				handle(e, _from)


func full_state() -> Dictionary:
	var list := []
	for li in lanes.size():
		var lane: Dictionary = lanes[li]
		list.append({"t": "sk_s", "l": li, "sc": lane["score"], "r": lane["rolls"], "pl": lane["player"], "on": lane["playing"],
			"hi": lane["hi"], "hn": lane["hi_name"]})
	return {"t": "sk_full", "lanes": list}


func on_identity_changed(_old_id: int, _new_id: int) -> void:
	pass


func on_peer_left(_slot: int) -> void:
	pass
