extends Node3D
## Two-player air hockey. Grab a mallet with the grip and it follows your hand on your half.
## The puck is simulated by whoever's half it is on (so your own hits respond instantly) and
## streamed to everyone else, who also run the same simulation in between updates.
## Table space: x across (±HALF_W), z along (±HALF_L); side 0 defends -z, side 1 defends +z.

const Kit := preload("res://kit.gd")
const Button3D := preload("res://button3d.gd")

const HALF_W := 0.6
const HALF_L := 1.1
const H := 0.8              # surface height
const PUCK_R := 0.04
const MALLET_R := 0.055
const GOAL_HALF := 0.17     # half width of each goal mouth
const MAX_SPEED := 7.0
const SEND_HZ := 30.0
const WIN := 7


class Handle extends Node3D:
	## The grabbable knob of one mallet.
	var game: Node
	var side := 0

	func grab_distance(p: Vector3) -> float:
		return global_position.distance_to(p)

	func on_grab(hand: Node) -> bool:
		return game.grab(side, hand)

	func on_release(hand: Node) -> void:
		game.release(side, hand)


var main: Node
var puck := Vector2(0, -0.4)
var puck_v := Vector2.ZERO
var mallets: Array[Vector2] = [Vector2(0, -0.9), Vector2(0, 0.9)]
var mallet_v: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
## Slot holding each mallet, or -1.
var holder: Array[int] = [-1, -1]
var score: Array[int] = [0, 0]

var _hands: Array = [null, null]          # local hand holding each mallet
var _remote: Array[Vector2] = [Vector2(0, -0.9), Vector2(0, 0.9)]
var _send_in := 0.0
var _quiet_for := 0.0
var _puck_node: Node3D
var _mallet_nodes: Array[Node3D] = []
var _handles: Array[Handle] = []
var _labels: Array[Label3D] = []
var _banner_until := 0.0
var _banner := ""


func _ready() -> void:
	var dark := Kit.mat(Color(0.12, 0.13, 0.16), 0.5)
	var rail := Kit.mat(Color(0.85, 0.15, 0.2), 0.4)
	# Body and legs.
	Kit.add_box(self, Vector3(HALF_W * 2 + 0.2, 0.25, HALF_L * 2 + 0.2), Vector3(0, H - 0.15, 0), dark, Kit.LAYER_FURNITURE)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			Kit.add_box(self, Vector3(0.1, H - 0.25, 0.1), Vector3(sx * 0.55, (H - 0.25) / 2.0, sz * 1.0), dark)
	# Playing surface and markings.
	Kit.add_box(self, Vector3(HALF_W * 2, 0.02, HALF_L * 2), Vector3(0, H - 0.01, 0), Kit.mat(Color(0.93, 0.95, 0.98), 0.25))
	Kit.add_box(self, Vector3(HALF_W * 2, 0.003, 0.02), Vector3(0, H + 0.001, 0), Kit.flat(Color(0.9, 0.2, 0.25)))
	Kit.add_cylinder(self, 0.16, 0.002, Vector3(0, H + 0.001, 0), Kit.flat(Color(0.35, 0.55, 0.95)), 0, -1.0, 32)
	Kit.add_cylinder(self, 0.15, 0.003, Vector3(0, H + 0.0015, 0), Kit.mat(Color(0.93, 0.95, 0.98), 0.25), 0, -1.0, 32)
	for s in [-1.0, 1.0]:
		Kit.add_box(self, Vector3(GOAL_HALF * 2, 0.004, 0.02), Vector3(0, H + 0.002, s * (HALF_L - 0.01)), Kit.flat(Color(0.2, 0.2, 0.25)))
	# Rails (with gaps at the goals).
	for sx in [-1.0, 1.0]:
		Kit.add_box(self, Vector3(0.05, 0.05, HALF_L * 2 + 0.1), Vector3(sx * (HALF_W + 0.025), H + 0.025, 0), rail)
	var end_len := HALF_W - GOAL_HALF
	for sz in [-1.0, 1.0]:
		for sx in [-1.0, 1.0]:
			Kit.add_box(self, Vector3(end_len, 0.05, 0.05), Vector3(sx * (GOAL_HALF + end_len / 2.0), H + 0.025, sz * (HALF_L + 0.025)), rail)
	# Puck and mallets.
	_puck_node = Kit.add_cylinder(self, PUCK_R, 0.012, Vector3.ZERO, Kit.mat(Color(0.1, 0.1, 0.1), 0.4), 0, -1.0, 20)
	var colors := [Color(0.25, 0.5, 1.0), Color(1.0, 0.35, 0.3)]
	for side in 2:
		var m := Node3D.new()
		add_child(m)
		Kit.add_cylinder(m, MALLET_R, 0.025, Vector3(0, 0.0125, 0), Kit.mat(colors[side], 0.4), 0, -1.0, 20)
		Kit.add_cylinder(m, 0.022, 0.05, Vector3(0, 0.05, 0), Kit.mat(colors[side].lightened(0.2), 0.4), 0, -1.0, 12)
		Kit.add_sphere(m, 0.03, Vector3(0, 0.08, 0), Kit.mat(colors[side].lightened(0.3), 0.4), 0, 12)
		_mallet_nodes.append(m)
		var h := Handle.new()
		h.game = self
		h.side = side
		h.position = Vector3(0, 0.07, 0)
		h.add_to_group("grabbable")
		m.add_child(h)
		_handles.append(h)
	# Score boards at each end, facing that end's player.
	for side in 2:
		# Back to back over the middle: side 0 reads it from the -z end, side 1 from +z.
		var l := Kit.add_label(self, "", 0.09, Vector3(0, H + 0.45, -0.02 if side == 0 else 0.02), PI if side == 0 else 0.0, Color(1, 1, 1))
		l.outline_size = 10
		l.outline_modulate = Color(0, 0, 0, 0.7)
		_labels.append(l)
	var reset := Button3D.new("New game", Vector2(0.22, 0.07), Color(0.2, 0.45, 0.3), _on_new_game)
	reset.position = Vector3(HALF_W + 0.25, H + 0.15, 0)
	reset.rotation = Vector3(-0.6, PI / 2, 0)
	add_child(reset)
	var reset2 := Button3D.new("New game", Vector2(0.22, 0.07), Color(0.2, 0.45, 0.3), _on_new_game)
	reset2.position = Vector3(-HALF_W - 0.25, H + 0.15, 0)
	reset2.rotation = Vector3(-0.6, -PI / 2, 0)
	add_child(reset2)
	Kit.add_label(self, "AIR HOCKEY - grab a mallet with the grip", 0.05, Vector3(0, H + 0.75, 0), 0.0, Color(0.9, 0.9, 1.0)).billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	_update_visuals()


# ---------------------------------------------------------------- grabbing

func grab(side: int, hand: Node) -> bool:
	var me: int = main.me()
	if holder[side] != -1 and holder[side] != me:
		return false   # a friend has it
	if _hands[side] != null and _hands[side] != hand:
		_hands[side].held = null
	_hands[side] = hand
	holder[side] = me
	main.send({"t": "ah_hold", "side": side, "h": me})
	return true


func release(side: int, hand: Node) -> void:
	if _hands[side] != hand:
		return
	_hands[side] = null
	holder[side] = -1
	mallet_v[side] = Vector2.ZERO
	main.send({"t": "ah_hold", "side": side, "h": -1})


# ---------------------------------------------------------------- simulation

func _authority() -> int:
	var side := 0 if puck.y < 0.0 else 1
	if holder[side] != -1:
		return holder[side]
	if holder[1 - side] != -1:
		return holder[1 - side]
	return main.host_slot()


func _physics_process(delta: float) -> void:
	var me: int = main.me()
	for side in 2:
		var hand: Node = _hands[side]
		var prev := mallets[side]
		if hand != null:
			var lp := to_local(hand.grab_point())
			mallets[side] = _clamp_mallet(side, Vector2(lp.x, lp.z))
		elif holder[side] != -1 and holder[side] != me:
			mallets[side] = prev.lerp(_remote[side], 1.0 - exp(-30.0 * delta))
		mallet_v[side] = ((mallets[side] - prev) / delta).limit_length(8.0) if holder[side] != -1 else Vector2.ZERO

	var steps := 4
	var dt := delta / steps
	for i in steps:
		_step(dt)

	var authority := _authority() == me
	if authority and absf(puck.y) > HALF_L + 0.06 and absf(puck.x) < GOAL_HALF + 0.02:
		_goal(1 if puck.y < 0.0 else 0)

	# Stream: our held mallets, plus the puck when we're simulating it and it's moving.
	var active := holder[0] == me or holder[1] == me or (authority and puck_v.length() > 0.01)
	_quiet_for = 0.0 if active else _quiet_for + delta
	_send_in -= delta
	if _send_in <= 0.0 and _quiet_for < 0.5 and main.has_friends():
		_send_in = 1.0 / SEND_HZ
		var msg := {"t": "ah_s"}
		for side in 2:
			if holder[side] == me:
				msg["m%d" % side] = [snappedf(mallets[side].x, 0.001), snappedf(mallets[side].y, 0.001)]
		if authority:
			msg["p"] = [snappedf(puck.x, 0.0001), snappedf(puck.y, 0.0001), snappedf(puck_v.x, 0.001), snappedf(puck_v.y, 0.001)]
		main.send(msg)
	_update_visuals()


func _clamp_mallet(side: int, p: Vector2) -> Vector2:
	var x := clampf(p.x, -HALF_W + MALLET_R, HALF_W - MALLET_R)
	var z := p.y
	if side == 0:
		z = clampf(z, -HALF_L + MALLET_R, -MALLET_R)
	else:
		z = clampf(z, MALLET_R, HALF_L - MALLET_R)
	return Vector2(x, z)


func _step(dt: float) -> void:
	puck += puck_v * dt
	var lim_x := HALF_W - PUCK_R
	if absf(puck.x) > lim_x:
		puck.x = signf(puck.x) * lim_x
		puck_v.x = -puck_v.x * 0.9
	var lim_z := HALF_L - PUCK_R
	if absf(puck.y) > lim_z:
		var in_mouth := absf(puck.x) < GOAL_HALF - PUCK_R * 0.5
		if not in_mouth:
			puck.y = signf(puck.y) * lim_z
			puck_v.y = -puck_v.y * 0.9
		elif absf(puck.y) > HALF_L + 0.12:
			puck.y = signf(puck.y) * (HALF_L + 0.12)   # sits in the goal until the score arrives
			puck_v = Vector2.ZERO
	for side in 2:
		var d := puck - mallets[side]
		var dist := d.length()
		var reach := PUCK_R + MALLET_R
		if dist < reach and dist > 0.0001:
			var n := d / dist
			puck = mallets[side] + n * reach
			var rel := puck_v - mallet_v[side]
			var vn := rel.dot(n)
			if vn < 0.0:
				puck_v -= 1.85 * vn * n
	puck_v *= exp(-0.2 * dt)
	if puck_v.length() > MAX_SPEED:
		puck_v = puck_v.normalized() * MAX_SPEED


func _goal(scorer: int) -> void:
	score[scorer] += 1
	var conceded := 1 - scorer
	puck = Vector2(0, -0.35 if conceded == 0 else 0.35)
	puck_v = Vector2.ZERO
	_show_goal(scorer)
	main.send({"t": "ah_goal", "score": score.duplicate(), "p": [puck.x, puck.y]})


func _show_goal(scorer: int) -> void:
	var won := score[scorer] >= WIN
	_banner = ("BLUE" if scorer == 0 else "RED") + (" WINS!" if won else " SCORES!")
	_banner_until = Time.get_ticks_msec() / 1000.0 + (6.0 if won else 2.0)


func _on_new_game() -> void:
	_reset()
	main.send({"t": "ah_reset"})


func _reset() -> void:
	score = [0, 0]
	puck = Vector2(0, -0.35)
	puck_v = Vector2.ZERO
	_banner_until = 0.0


func _update_visuals() -> void:
	_puck_node.position = Vector3(puck.x, H + 0.006, puck.y)
	for side in 2:
		_mallet_nodes[side].position = Vector3(mallets[side].x, H, mallets[side].y)
	var text := "BLUE %d  -  %d RED" % [score[0], score[1]]
	if Time.get_ticks_msec() / 1000.0 < _banner_until:
		text = _banner + "\n" + text
	for l in _labels:
		l.text = text


# ---------------------------------------------------------------- network

func handle(msg: Dictionary, from: int) -> void:
	match str(msg.get("t", "")):
		"ah_hold":
			var side := clampi(int(msg.get("side", 0)), 0, 1)
			var h := int(msg.get("h", -1))
			if h == -1:
				if holder[side] == from:
					holder[side] = -1
			else:
				if _hands[side] != null:   # they grabbed it at the same moment: lower slot keeps it
					if from < main.me():
						_hands[side].held = null
						_hands[side] = null
					else:
						return
				holder[side] = from
				_remote[side] = mallets[side]
		"ah_s":
			for side in 2:
				var key := "m%d" % side
				if msg.has(key) and holder[side] == from:
					var a: Array = msg[key]
					_remote[side] = _clamp_mallet(side, Vector2(float(a[0]), float(a[1])))
			if msg.has("p") and _authority() != main.me():
				var p: Array = msg["p"]
				puck = Vector2(float(p[0]), float(p[1]))
				puck_v = Vector2(float(p[2]), float(p[3]))
		"ah_goal":
			var s: Array = msg.get("score", [0, 0])
			var before := score.duplicate()
			score = [int(s[0]), int(s[1])]
			var p: Array = msg.get("p", [0, 0])
			puck = Vector2(float(p[0]), float(p[1]))
			puck_v = Vector2.ZERO
			_show_goal(0 if score[0] > before[0] else 1)
		"ah_reset":
			_reset()
		"ah_full":
			var s: Array = msg.get("score", [0, 0])
			score = [int(s[0]), int(s[1])]
			var hs: Array = msg.get("holder", [-1, -1])
			for side in 2:
				if _hands[side] == null:
					holder[side] = int(hs[side])
			var p: Array = msg.get("p", [0, -0.35, 0, 0])
			puck = Vector2(float(p[0]), float(p[1]))
			puck_v = Vector2(float(p[2]), float(p[3]))


func full_state() -> Dictionary:
	return {"t": "ah_full", "score": score.duplicate(), "holder": holder.duplicate(), "p": [puck.x, puck.y, puck_v.x, puck_v.y]}


func on_identity_changed(old_id: int, new_id: int) -> void:
	for side in 2:
		holder[side] = new_id if _hands[side] != null else -1


func on_peer_left(slot: int) -> void:
	for side in 2:
		if holder[side] == slot:
			holder[side] = -1
