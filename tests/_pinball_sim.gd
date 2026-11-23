extends SceneTree
## Headless check of the pinball table physics: a full-power launch reaches the playfield,
## and a raised flipper sends a falling ball back up the table.

class FakeMain extends Node:
	var controls_captured: Node = null
	var avatars := {}
	var player_name := "Sim"
	func me() -> int: return 0
	func send(_m: Dictionary) -> void: pass
	func notify(_t: String) -> void: pass
	func trigger(_i: int) -> float: return 0.0
	func stick(_i: int) -> Vector2: return Vector2.ZERO


func _init() -> void:
	var fm := FakeMain.new()
	root.add_child(fm)
	var pb: Node3D = load("res://pinball.gd").new()
	pb.main = fm
	root.add_child(pb)
	await process_frame
	pb._on_start()
	pb._vel = Vector2(0, 1.5 + 1.4 * 1.0)
	var top := 0.0
	var entered := false
	var dt: float = 1.0 / 90.0 / 10.0
	var bumps := 0
	var start_score: int = pb.score
	for f in 90 * 8:
		for k in pb.SUBSTEPS:
			pb._step_flippers(false, false, dt)
			pb._step_ball(dt)
		top = maxf(top, pb._ball.y)
		if pb._ball.x < pb.LANE_X - 0.02 and pb._ball.y < 0.9:
			entered = true
		if pb._ball.y < -0.04:
			break
	print("launch: top v %.2f, entered playfield %s, scored %d, ended at %s" % [top, entered, pb.score - start_score, pb._ball])
	# Flipper: ball dropping onto the raised left flipper's middle.
	pb._ball = pb._pivot(0) + Vector2(0.045, 0.06)
	pb._vel = Vector2(0, -0.8)
	pb._ang = [pb.FLIP_REST, PI - pb.FLIP_REST]
	var best_up := 0.0
	for f in 40:
		for k in pb.SUBSTEPS:
			pb._step_flippers(f > 3, false, dt)
			pb._step_ball(dt)
		best_up = maxf(best_up, pb._vel.y)
	print("flip: best upward speed %.2f m/s, ball at %s" % [best_up, pb._ball])
	quit()
