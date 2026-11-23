extends SceneTree
## Two players in one process (each in its own SubViewport world) join the same room on a local
## relay and check that everything is shared: names, poses, Connect Four, air hockey, basketball,
## voice, the jukebox, and leaving.
##
##   (in server/) npx wrangler dev --port 8787
##   tools/Godot_v4.7.2-stable_win64_console.exe --headless --xr-mode off --path . -s tests/_multi.gd

const Main := preload("res://main.gd")
const Voice := preload("res://voice.gd")

var server := "ws://127.0.0.1:8787"
var passed := 0
var failed := 0


class FakeHand extends Node3D:
	var held: Node = null
	var velocity := Vector3.ZERO

	func grab_point() -> Vector3:
		return global_position

	func buzz(_a := 0.0, _b := 0.0) -> void:
		pass


func _initialize() -> void:
	_run.call_deferred()


func _make(n: String, room: String) -> Main:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(64, 64)
	root.add_child(vp)
	var m := Main.new()
	m.test_mode = true
	m.player_name = n
	m.server = server
	m.room_code = room
	vp.add_child(m)
	return m


func _hand(m: Main) -> FakeHand:
	var h := FakeHand.new()
	m.add_child(h)
	return h


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
		print("PASS  ", what)
	else:
		failed += 1
		print("FAIL  ", what)


func _run() -> void:
	var room := "T%d" % (randi() % 1000000)
	var a := _make("Alice", room)
	await _wait(1.0)
	var b := _make("Bob", room)
	for i in 50:
		await _wait(0.2)
		if a.has_friends() and b.has_friends():
			break
	check(a.has_friends() and b.has_friends(), "both joined room %s (slots %d, %d)" % [room, a.my_slot, b.my_slot])
	await _wait(0.5)
	check(a.name_of(b.my_slot) == "Bob" and b.name_of(a.my_slot) == "Alice", "names exchanged")
	var host := a if a.is_host() else b
	var guest := b if host == a else a
	check(host.is_host() and not guest.is_host(), "exactly one host (slot %d)" % host.my_slot)

	# Poses.
	a.place_at(Vector3(2.0, 0, 3.0), 0.0)
	await _wait(0.6)
	var seen: Vector3 = b.avatars[a.my_slot].head_position()
	check(seen.distance_to(a.camera.global_position) < 0.05, "Bob sees Alice's head where it is (%s vs %s)" % [seen, a.camera.global_position])
	check(b.friends_whereabouts().contains("Grand Hall"), "whereabouts: " + b.friends_whereabouts())

	# Connect Four: host moves, guest moves through the host, guest can't move twice.
	var hc: Node = host.modules["c4"]
	var gc: Node = guest.modules["c4"]
	hc._on_column(3)
	await _wait(0.4)
	gc._on_column(4)
	await _wait(0.6)
	check(hc.grid[3] == 1 and hc.grid[4] == 2, "c4: host board has both moves")
	check(gc.grid == hc.grid, "c4: boards match")
	gc._on_column(4)
	await _wait(0.6)
	check(hc.grid[4 + 7] == 0, "c4: guest can't move twice in a row")
	hc._on_new_game()
	await _wait(0.4)
	check(not gc.grid.has(1) and not gc.grid.has(2), "c4: new game clears both boards")

	# Air hockey: Bob takes the red mallet, so he simulates the puck on both halves.
	var aa: Node = a.modules["ah"]
	var ba: Node = b.modules["ah"]
	var bh := _hand(b)
	bh.global_position = ba._handles[1].global_position
	b.try_grab(bh)
	check(bh.held == ba._handles[1], "ah: Bob grabbed the red mallet")
	await _wait(0.3)
	check(aa.holder[1] == b.my_slot, "ah: Alice sees Bob holding red")
	bh.global_position = ba.to_global(Vector3(0.3, 0.9, 0.7))
	ba.puck = Vector2(0, 0.4)
	ba.puck_v = Vector2(0.4, -1.5)
	await _wait(0.6)
	check(aa.puck.distance_to(ba.puck) < 0.12, "ah: puck in sync (%s vs %s)" % [aa.puck, ba.puck])
	check(aa.mallets[1].distance_to(Vector2(0.3, 0.7)) < 0.05, "ah: Alice sees Bob's mallet move (%s)" % aa.mallets[1])
	# Alice grabs Bob's mallet: refused.
	var ah := _hand(a)
	ah.global_position = aa._handles[1].global_position
	a.try_grab(ah)
	check(ah.held == null, "ah: can't grab a mallet a friend holds")
	b.release(bh)
	await _wait(0.3)
	check(aa.holder[1] == -1, "ah: release seen")

	# Basketball: Alice grabs ball 0, holds it over the rim and drops it.
	var abb: Node = a.modules["bb"]
	var bbb: Node = b.modules["bb"]
	ah.global_position = abb.balls[0].global_position
	a.try_grab(ah)
	check(ah.held == abb.balls[0], "bb: Alice grabbed ball 0")
	ah.global_position = abb._rim_center + Vector3(0, 0.6, 0)
	await _wait(0.4)
	check(bbb.balls[0].owner_slot == a.my_slot and bbb.balls[0].global_position.distance_to(abb.balls[0].global_position) < 0.15, "bb: Bob sees Alice's ball")
	ah.velocity = Vector3.ZERO
	a.release(ah)
	await _wait(1.5)
	check(int(abb.scores.get(a.my_slot, 0)) == 1, "bb: dropping it through the rim scores (%s)" % [abb.scores])
	check(int(bbb.scores.get(a.my_slot, 0)) == 1, "bb: Bob's scoreboard agrees (%s)" % [bbb.scores])
	check(bbb._board.text.contains("Alice  1"), "bb: board text: " + bbb._board.text.replace("\n", " | "))

	# Voice: μ-law round trip and packets reaching the other side.
	var worst := 0.0
	for x: float in [-0.9, -0.3, -0.01, 0.0, 0.02, 0.25, 0.8]:
		worst = maxf(worst, absf(Voice.ulaw_decode(Voice.ulaw_encode(x)) - x))
	check(worst < 0.03, "voice: μ-law error %.4f" % worst)
	var rate := AudioServer.get_mix_rate()
	var buf := PackedVector2Array()
	for i in int(rate * 0.6):
		var v := 0.3 * sin(TAU * 300.0 * i / rate)
		buf.append(Vector2(v, v))
	a.voice.feed(buf)
	await _wait(0.6)
	check(a.voice.packets_sent >= 8 and b.voice.packets_received == a.voice.packets_sent, "voice: %d sent, %d received" % [a.voice.packets_sent, b.voice.packets_received])
	var quiet := PackedVector2Array()
	quiet.resize(int(rate * 1.5))
	var before: int = a.voice.packets_sent
	a.voice.feed(quiet)
	check(a.voice.packets_sent - before <= 10, "voice: silence mostly not sent (%d packets)" % (a.voice.packets_sent - before))

	# Jukebox.
	a.modules["jb"]._on_play()
	await _wait(0.5)
	check(b.modules["jb"].playing, "jukebox: Bob's starts too")
	check(a.modules["jb"]._streams.get(0) is AudioStreamMP3, "jukebox: bundled song loaded")
	a.modules["jb"]._on_song(3)
	await _wait(0.5)
	check(b.modules["jb"].song == 3 and b.modules["jb"].playing, "jukebox: picking a song plays it for Bob too")

	# Gym: scoreboard and gravity are shared.
	a.modules["gy"]._on_points(0, 3)
	a.modules["gy"]._on_planet(2)
	await _wait(0.5)
	check(b.modules["gy"].home == 3, "gym: Bob's scoreboard shows HOME 3")
	check(b.modules["gy"].planet == 2 and is_equal_approx(b.modules["bb"].balls[0].gravity_scale, 1.62 / 9.81), "gym: Moon gravity on Bob's balls")

	# Chairs: a moved chair moves for Bob.
	var ch: Node = a.modules["fu"].chairs[0]
	ch.position = Vector3(-12.0, 0, -2.5)
	a.modules["fu"]._send(ch, false)
	await _wait(0.8)
	check(b.modules["fu"].chairs[0].position.distance_to(Vector3(-12.0, 0, -2.5)) < 0.05, "chairs: Bob sees the chair moved")

	# Arcade: scores and games are shared.
	var ask: Node = a.modules["sk"]
	ask._on_start(1)
	await _wait(0.4)
	ask._landed(1, ask.lanes[1]["balls"][0], 50)
	await _wait(0.5)
	check(b.modules["sk"].lanes[1]["score"] == 50 and b.modules["sk"].lanes[1]["rolls"] == 1, "skee-ball: Bob sees 50 on lane 2")
	a.modules["hs"]._on_start()
	await _wait(0.3)
	a.modules["hs"]._basket()
	await _wait(0.5)
	check(b.modules["hs"].score == 2 and b.modules["hs"].running, "hoops: Bob sees the basket")
	var asg: Node = a.modules["sg"]
	asg._on_start()
	var ti := -1
	for i in asg.targets.size():
		if asg.targets[i]["node"].visible and asg.targets[i]["rail"] == 1:
			ti = i
			break
	var tpos: Vector3 = asg.targets[ti]["node"].global_position + Vector3(0, 0.05, 0)
	var blaster: Node3D = asg.blasters[0]
	blaster.freeze = true
	blaster.global_transform = Transform3D(Basis.looking_at(Vector3(0, 0, -1)), tpos + Vector3(0, -0.05, 2.45))
	asg._fire(blaster, null)
	await _wait(0.5)
	check(asg.scores[0] == 25 and b.modules["sg"].scores[0] == 25, "gallery: a rabbit hit scores 25 for red on both")
	check(b.modules["sg"].targets[ti]["down"] > 0.0, "gallery: the rabbit flips down for Bob")
	var apb: Node = a.modules["pb"]
	apb._on_start()
	await _wait(0.6)
	check(b.modules["pb"].player_slot == a.me() and a.controls_captured == apb, "pinball: Bob sees Alice playing; her walking pauses")
	check(b.modules["pb"]._remote_ball.distance_to(apb._ball) < 0.01, "pinball: ball position streams to Bob")
	apb._on_quit()
	await _wait(0.4)
	check(b.modules["pb"].player_slot == -1 and a.controls_captured == null, "pinball: quitting frees the machine and walking")
	var amz: Node = a.modules["mz"]
	amz._on_start()
	await _wait(2.5)
	check(b.modules["mz"].player_slot == a.me() and b.modules["mz"].me_pos.distance_to(amz.me_pos) < 0.6, "maze: Bob's screen follows Alice's game")
	check(b.modules["mz"].seeds.size() == amz.seeds.size(), "maze: eaten seeds match (%d / %d)" % [b.modules["mz"].seeds.size(), amz.seeds.size()])
	amz._on_quit()
	var arc: Node = a.modules["rc"]
	arc._on_start()
	await _wait(0.5)
	check(b.modules["rc"].running and b.modules["rc"].player_name == arc.player_name, "racer: Bob sees Alice driving")
	arc._on_quit()
	await _wait(0.4)
	check(not b.modules["rc"].running and a.controls_captured == null, "racer: quit frees the cabinet")

	# Bartender: Alice walks up to the bar and gets served; Bob sees the drink on the counter.
	a.place_at(Vector3(-11.0, 0, -16.4), PI / 2)
	await _wait(6.0)
	var served := false
	for d: Node3D in b.modules["bt"].drinks:
		if d.visible and d.global_position.distance_to(Vector3(-12.2, 1.11, -16.4)) < 0.3:
			served = true
	check(served, "bartender: Alice got a drink, and Bob sees it on the bar")
	a.place_at(Vector3(0, 0, 4.0), 0.0)

	# Props: index lookups by kind.
	var apr: Node = a.modules["pr"]
	var bpr: Node = b.modules["pr"]
	var first := func(kind: String) -> int:
		for p: Node in apr.props:
			if p.kind == kind:
				return p.index
		return -1
	var fire_pit := Vector3(-5.0, 0.3, 15.0)
	var pit_fire: Node = null
	for h: Node in a.get_tree().get_nodes_in_group("heat"):
		if h.has_method("stoke") and a.is_ancestor_of(h) and (h as Node3D).global_position.distance_to(fire_pit) < 0.5:
			pit_fire = h
	check(pit_fire != null, "props: found the fire pit")
	# Log into the fire pit: it burns away (on both sides) and the fire flares.
	var li: int = first.call("log")
	ah.global_position = apr.props[li].global_position
	a.try_grab(ah)
	check(ah.held == apr.props[li], "props: Alice grabbed a log")
	ah.global_position = fire_pit + Vector3(0, 0.5, 0)
	await _wait(0.3)
	ah.velocity = Vector3.ZERO
	a.release(ah)
	await _wait(2.0)
	check(not apr.props[li].visible and not bpr.props[li].visible, "props: the log burnt away for both")
	check(pit_fire.intensity > 1.2, "props: the fire flared (intensity %.2f)" % pit_fire.intensity)
	# Meat on the grill cooks, and Bob sees it cooking too.
	var mi: int = first.call("patty")
	var grill_top: Vector3 = apr._grill.global_position
	ah.global_position = apr.props[mi].global_position
	a.try_grab(ah)
	ah.global_position = grill_top + Vector3(0.15, 0.08, 0.0)
	await _wait(0.3)
	a.release(ah)
	await _wait(3.0)
	check(apr.props[mi].cook > 0.05 and bpr.props[mi].cook > 0.05, "props: patty cooking (%.2f / %.2f)" % [apr.props[mi].cook, bpr.props[mi].cook])
	# Marshmallow: held in the flames it toasts and catches fire; shaking puts it out; eating resets it.
	var si: int = first.call("marsh")
	ah.global_position = apr.props[si].to_global(Vector3(0, 0, 0.37))
	a.try_grab(ah)
	check(ah.held == apr.props[si], "props: Alice picked up a marshmallow stick")
	await _wait(0.1)
	var tip_offset: Vector3 = apr.props[si].tip() - ah.global_position
	ah.global_position = fire_pit + Vector3(0, 0.35, 0) - tip_offset
	await _wait(4.0)
	check(apr.props[si].cook > 0.3, "props: marshmallow toasting (%.2f)" % apr.props[si].cook)
	check(apr.props[si].on_fire and bpr.props[si].on_fire, "props: left in the flames it caught fire (both see it)")
	ah.global_position += Vector3(0, 0, -1.5)
	ah.velocity = Vector3(4, 0, 0)
	await _wait(0.2)
	ah.velocity = Vector3.ZERO
	check(not apr.props[si].on_fire and not bpr.props[si].on_fire, "props: shaking puts it out")
	var mouth: Vector3 = apr._mouth()
	ah.global_position = mouth - (apr.props[si].tip() - ah.global_position)
	await _wait(0.3)
	check(apr.props[si].cook < 0.05 and bpr.props[si].cook < 0.05, "props: eaten (fresh one on the stick)")
	a.release(ah)
	# Cake thrown hard splats and comes back.
	var ci: int = first.call("cake")
	ah.global_position = apr.props[ci].global_position + Vector3(0, 0.05, 0)
	a.try_grab(ah)
	ah.global_position = Vector3(0, 2.0, -0.5)
	await _wait(0.3)
	ah.velocity = Vector3(0, -2, -7)
	a.release(ah)
	ah.velocity = Vector3.ZERO
	await _wait(1.0)
	check(not apr.props[ci].visible and not bpr.props[ci].visible, "props: cake splatted for both")
	await _wait(3.0)
	check(apr.props[ci].visible and apr.props[ci].global_position.distance_to(apr.props[ci].home.origin) < 0.1, "props: fresh cake back on the table")
	# Cornhole: a bag dropped into the hole scores.
	var gi: int = first.call("bag")
	ah.global_position = apr.props[gi].global_position
	a.try_grab(ah)
	var hole: Vector3 = apr._boards[0].to_global(Vector3(0, 0, -0.37))
	ah.global_position = hole + Vector3(0, 0.25, 0)
	await _wait(0.3)
	a.release(ah)
	await _wait(1.5)
	check(apr.props[gi].scored, "props: bag through the hole scored")
	check(bpr.props[gi].global_position.distance_to(apr.props[gi].global_position) < 0.2, "props: Bob sees the bag where it landed")

	# Bob leaves.
	var bob_slot := b.my_slot
	b.leave_room()
	await _wait(1.0)
	check(a.avatars.is_empty() and not a.has_friends(), "Alice sees Bob leave")
	check(a.is_host(), "Alice is host when alone")
	check(not abb.scores.has(bob_slot), "Bob's basketball score dropped")
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
