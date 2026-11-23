extends SceneTree
## Auto-plays the pinball table (flips whenever the ball is near a flipper) for a few balls,
## to find places the ball gets stuck.

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
	var dt: float = 1.0 / 900.0
	seed(7)
	for game in 6:
		pb._on_start()
		pb._vel = Vector2(0, 1.5 + 1.4 * randf_range(0.6, 1.0))
		var t := 0.0
		var still := 0.0
		var hold := 0.0
		var cool := 0.0
		var stuck_at := Vector2.ZERO
		while t < 120.0:
			var near_l: bool = pb._ball.distance_to(pb._pivot(0)) < 0.1 and pb._ball.x < pb.C + 0.01
			var near_r: bool = pb._ball.distance_to(pb._pivot(1)) < 0.1 and pb._ball.x > pb.C - 0.01
			if (near_l or near_r) and cool <= 0.0:
				hold = 0.12
				cool = 0.45
			cool -= 1.0 / 90.0
			hold -= 1.0 / 90.0
			near_l = near_l and hold > 0.0
			near_r = near_r and hold > 0.0
			for k in 10:
				pb._step_flippers(near_l, near_r, dt)
				pb._step_ball(dt)
			t += 1.0 / 90.0
			if pb._vel.length() < 0.02 and not (pb._ball.x > pb.LANE_X and pb._ball.y < 0.1):
				still += 1.0 / 90.0
				if still > 3.0:
					stuck_at = pb._ball
					break
			else:
				still = 0.0
			if pb._ball.y < -0.04:
				break
		print("ball %d: %.1f s, score %d, %s" % [game, t, pb.score, "STUCK at %s" % stuck_at if stuck_at != Vector2.ZERO else "drained at x %.3f" % pb._ball.x])
		pb._game_over()
	quit()
