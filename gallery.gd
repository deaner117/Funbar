extends Node3D
## Star Ranch Shootout: a carnival shooting gallery. Pick up the red or blue blaster at the
## counter and shoot the tin critters riding the rails: geese on the bottom rail (10), rabbits
## in the middle (25), flying saucers up top (50). They flip down when hit and pop back up.
## Press Start for a 40-second round, red against blue. Whoever fires judges the hit and sends
## it ("sg_f"); the round and scores travel in "sg_s".
## Booth space: the counter is at z 0, the targets run across at -z.

const Kit := preload("res://kit.gd")
const AK := preload("res://arcade_kit.gd")
const Button3D := preload("res://button3d.gd")

const ROUND := 40.0
const WIDTH := 3.4
## Rails: [z, y, speed (m/s, sign = direction), count, points, kind]
const RAILS := [[-3.0, 1.15, 0.55, 6, 10, "goose"], [-4.2, 1.75, -0.8, 5, 25, "rabbit"], [-5.3, 2.4, 1.15, 4, 50, "saucer"]]
const HIT_R := 0.15
const DOWN_TIME := 3.0
const COOLDOWN := 0.22
const TEAM := ["RED", "BLUE"]
const TEAM_COL := [Color(1.0, 0.25, 0.25), Color(0.3, 0.55, 1.0)]

var main: Node
var blasters: Array = []
var targets: Array = []   # {node, rail, slot, down}
var scores := [0, 0]
var hi := 0
var hi_name := ""
var running := false
var time_left := 0.0

var _p: Node3D
var _mm: Array = []         # per rail: [[MultiMeshInstance3D, mesh offset], ...]
var _t := 0.0
var _board: Label3D
var _clock: Label3D
var _cool := [0.0, 0.0]
var _tracers: Array = []   # [MeshInstance3D, life]
var _pew: AudioStreamPlayer3D
var _hit: AudioStreamPlayer3D
var _horn: AudioStreamPlayer3D


func setup(anchor: Array) -> void:
	_p = Node3D.new()
	_p.position = anchor[0]
	_p.rotation.y = anchor[1]
	add_child(_p)
	_build_booth()
	_build_targets()
	var moving: Array = []
	for t: Dictionary in targets:
		moving.append(t["node"])
	AK.merge(_p, moving)
	var pr: Node = main.modules["pr"]
	for i in 2:
		var home := _p.global_transform * Transform3D(Basis(Vector3.UP, PI / 2), Vector3(-0.7 + i * 1.4, 1.17, -0.05))
		var b: Node3D = pr.add_prop("blaster", home)
		# Colour the body to match the team.
		for c in b.get_children():
			var mi := c as MeshInstance3D
			if mi and mi.material_override is StandardMaterial3D and (mi.material_override as StandardMaterial3D).albedo_color.is_equal_approx(Color(0.95, 0.45, 0.1)):
				mi.material_override = Kit.mat(TEAM_COL[i], 0.4)
		blasters.append(b)
	pr.trigger_handlers["blaster"] = _fire
	for i in 8:
		var mi := MeshInstance3D.new()
		mi.mesh = Kit.cylinder_mesh(0.006, 1.0, -1.0, 6)
		mi.visible = false
		add_child(mi)
		_tracers.append([mi, 0.0])
	_refresh()


func _build_booth() -> void:
	var wood := Kit.tmat(Color(0.55, 0.3, 0.16), "planks", 2.0, 0.6)
	var red := Kit.mat(Color(0.75, 0.08, 0.1), 0.7)
	var cream := Kit.mat(Color(0.95, 0.9, 0.78), 0.7)
	var black := Kit.mat(Color(0.04, 0.04, 0.06), 0.5)
	var brass := Kit.mat(Color(0.85, 0.65, 0.3), 0.3, 0.6)
	var hw := WIDTH / 2.0 + 0.3
	# Counter with striped front panels and a padded rail.
	Kit.add_rbox(_p, Vector3(WIDTH + 0.6, 1.0, 0.5), Vector3(0, 0.5, 0.1), wood, 0.02, Kit.LAYER_FURNITURE)
	for i in 8:
		var x := -hw + 0.2 + i * (2.0 * hw - 0.4) / 7.0
		Kit.add_box(_p, Vector3(0.22, 0.8, 0.01), Vector3(x, 0.5, 0.355), red if i % 2 == 0 else cream)
	Kit.add_rbox(_p, Vector3(WIDTH + 0.7, 0.07, 0.6), Vector3(0, 1.035, 0.1), Kit.mat(Color(0.35, 0.1, 0.08), 0.5), 0.03)
	for i in 2:
		Kit.add_box(_p, Vector3(0.5, 0.012, 0.25), Vector3(-0.7 + i * 1.4, 1.075, -0.05), Kit.mat(TEAM_COL[i].darkened(0.4), 0.6))
		var l := Kit.add_label(_p, TEAM[i], 0.05, Vector3(-0.7 + i * 1.4, 1.083, 0.15), 0.0, TEAM_COL[i])
		l.rotation.x = -PI / 2
	# Side walls, back wall with a painted night sky, rail tracks.
	for sx: float in [-hw, hw]:
		Kit.add_box(_p, Vector3(0.08, 3.2, 6.2), Vector3(sx, 1.6, -3.0), wood, Kit.LAYER_FURNITURE)
		for k in 7:
			Kit.add_sphere(_p, 0.04, Vector3(sx * 0.985, 3.05, -0.1 - k * 0.95), Kit.flat(Color(1.0, 0.85, 0.5)), 0, 8)
	var sky := ShaderMaterial.new()
	sky.shader = AK.shader(SKY_SHADER)
	var back := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(2.0 * hw, 3.2)
	back.mesh = qm
	back.material_override = sky
	back.position = Vector3(0, 1.6, -6.05)
	_p.add_child(back)
	Kit.add_box(_p, Vector3(2.0 * hw, 3.2, 0.06), Vector3(0, 1.6, -6.12), black, Kit.LAYER_FURNITURE)
	# Cut-out hills and cactus in front of the sky.
	for i in 5:
		var x := -hw + 0.4 + i * 0.85
		Kit.add_sphere(_p, 0.55, Vector3(x, 0.25, -5.9), Kit.mat(Color(0.12, 0.2, 0.12) if i % 2 == 0 else Color(0.16, 0.26, 0.15), 0.9), 0, 12)
	for r: Array in RAILS:
		Kit.add_box(_p, Vector3(2.0 * hw, 0.05, 0.05), Vector3(0, r[1] - 0.2, r[0]), brass)
		Kit.add_box(_p, Vector3(2.0 * hw, 0.18, 0.04), Vector3(0, r[1] - 0.3, r[0] + 0.06), Kit.mat(Color(0.2, 0.1, 0.06), 0.6))
	# A floor so dropped things stay in the booth.
	Kit.add_box(_p, Vector3(2.0 * hw, 0.02, 6.0), Vector3(0, 0.01, -3.0), Kit.mat(Color(0.18, 0.1, 0.06), 0.8))
	# Striped awning and the lit sign.
	for i in 10:
		var x := -hw + (i + 0.5) * (2.0 * hw) / 10.0
		Kit.add_box(_p, Vector3(2.0 * hw / 10.0, 0.03, 0.9), Vector3(x, 3.1, 0.1), red if i % 2 == 0 else cream, 0, Vector3(-0.35, 0, 0))
		Kit.add_sphere(_p, (2.0 * hw / 20.0), Vector3(x, 2.94, 0.53), red if i % 2 == 0 else cream, 0, 10)
	Kit.add_box(_p, Vector3(2.4, 0.5, 0.08), Vector3(0, 3.55, -0.2), black)
	var title := Kit.add_label(_p, "STAR RANCH SHOOTOUT", 0.11, Vector3(0, 3.62, -0.15), 0.0, Color(1.0, 0.85, 0.35))
	title.outline_size = 16
	title.outline_modulate = Color(1.0, 0.4, 0.0, 0.45)
	_board = Kit.add_label(_p, "", 0.06, Vector3(-0.55, 3.42, -0.15), 0.0, Color(1, 1, 1))
	_clock = Kit.add_label(_p, "", 0.12, Vector3(0.85, 3.43, -0.15), 0.0, Color(1.0, 0.3, 0.2))
	var start := Button3D.new("Start  (40 s)", Vector2(0.26, 0.08), Color(0.2, 0.5, 0.3), _on_start)
	start.position = Vector3(0, 1.09, 0.25)
	start.rotation.x = -PI / 2 + 0.3
	_p.add_child(start)
	Kit.add_label(_p, "Grab a blaster · pull the trigger", 0.035, Vector3(0, 1.0, 0.405), 0.0, Color(1.0, 0.95, 0.8))
	_pew = AK.player3d(_p, Vector3(0, 1.2, 0), AK.sfx("pew"), -10.0)
	_hit = AK.player3d(_p, Vector3(0, 1.8, -4.0), AK.sfx("hit"), -4.0)
	_horn = AK.player3d(_p, Vector3(0, 3.4, -0.2), AK.sfx("buzz"), -6.0)
	var l := Kit.omni(_p, Vector3(0, 2.8, -2.5), Color(1.0, 0.85, 0.6), 1.2, 6.0)
	l.light_cull_mask = Kit.VIS_INDOOR


const SKY_SHADER := """
shader_type spatial;
render_mode unshaded;
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 uv = UV;
	vec3 top = vec3(0.04, 0.03, 0.18);
	vec3 low = vec3(0.45, 0.12, 0.35);
	vec3 col = mix(low, top, smoothstep(1.0, 0.25, uv.y));
	vec2 g = floor(uv * vec2(60.0, 50.0));
	float s = step(0.965, hash(g)) * smoothstep(0.3, 0.0, length(fract(uv * vec2(60.0, 50.0)) - 0.5));
	col += vec3(s) * smoothstep(0.8, 0.2, uv.y);
	float moon = smoothstep(0.1, 0.095, length((uv - vec2(0.78, 0.22)) * vec2(1.6, 1.0)));
	float bite = smoothstep(0.1, 0.095, length((uv - vec2(0.81, 0.2)) * vec2(1.6, 1.0)));
	col = mix(col, vec3(1.0, 0.95, 0.75), moon * (1.0 - bite));
	ALBEDO = col;
}
"""


## Each rail's critters are drawn as MultiMeshes (one per material) instead of a dozen meshes
## each: the targets keep plain nodes for position and the flip, and _process copies their
## transforms into the instances.
func _build_targets() -> void:
	for ri in RAILS.size():
		var r: Array = RAILS[ri]
		var tmpl := Node3D.new()
		_p.add_child(tmpl)
		_target_visual(tmpl, str(r[5]))
		Kit.merge_static(tmpl, [], func(_v: Vector3) -> String: return "")
		var list: Array = []
		for c in tmpl.get_children():
			var mi := c as MeshInstance3D
			if mi == null or mi.is_queued_for_deletion():
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mi.mesh
			mm.instance_count = int(r[3])
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = mi.material_override
			mmi.layers = Kit.vis_layers
			_p.add_child(mmi)
			list.append([mmi, mi.transform])
		_mm.append(list)
		tmpl.queue_free()
		for k in int(r[3]):
			var node := Node3D.new()
			_p.add_child(node)
			var hinge := Node3D.new()      # flips back when hit
			hinge.position = Vector3(0, -0.2, 0)
			node.add_child(hinge)
			targets.append({"node": node, "hinge": hinge, "rail": ri, "slot": k, "down": 0.0})


func _target_visual(h: Node3D, kind: String) -> void:
	var tin := Kit.mat(Color(0.75, 0.75, 0.78), 0.35, 0.7)
	match kind:
		"goose":
			var white := Kit.mat(Color(0.96, 0.96, 0.92), 0.5)
			Kit.add_sphere(h, 0.11, Vector3(0, 0.2, 0), white, 0, 12).scale = Vector3(1.4, 0.8, 0.3)
			Kit.add_sphere(h, 0.055, Vector3(0.14, 0.34, 0), white, 0, 10).scale = Vector3(1, 1, 0.5)
			Kit.add_box(h, Vector3(0.03, 0.12, 0.02), Vector3(0.12, 0.27, 0), white)
			Kit.add_box(h, Vector3(0.07, 0.025, 0.02), Vector3(0.21, 0.34, 0), Kit.mat(Color(1.0, 0.6, 0.1), 0.5))
			Kit.add_sphere(h, 0.01, Vector3(0.16, 0.36, 0.022), Kit.flat(Color(0, 0, 0)), 0, 6)
			Kit.add_box(h, Vector3(0.12, 0.05, 0.035), Vector3(-0.02, 0.22, 0.0), Kit.mat(Color(0.85, 0.85, 0.8), 0.5))
		"rabbit":
			var brown := Kit.mat(Color(0.6, 0.42, 0.28), 0.6)
			Kit.add_sphere(h, 0.1, Vector3(0, 0.18, 0), brown, 0, 12).scale = Vector3(1, 1.1, 0.3)
			Kit.add_sphere(h, 0.065, Vector3(0, 0.33, 0), brown, 0, 10).scale = Vector3(1, 1, 0.5)
			for sx: float in [-0.03, 0.03]:
				Kit.add_box(h, Vector3(0.03, 0.13, 0.015), Vector3(sx, 0.45, 0), brown, 0, Vector3(0, 0, sx * 5.0))
				Kit.add_sphere(h, 0.01, Vector3(sx * 0.8, 0.345, 0.03), Kit.flat(Color(0, 0, 0)), 0, 6)
			Kit.add_sphere(h, 0.03, Vector3(0.0, 0.1, 0.025), Kit.mat(Color(1, 1, 1), 0.6), 0, 8)
		"saucer":
			Kit.add_sphere(h, 0.17, Vector3(0, 0.22, 0), tin, 0, 16).scale = Vector3(1, 0.25, 1)
			Kit.add_sphere(h, 0.07, Vector3(0, 0.27, 0), Kit.mat(Color(0.4, 1.0, 0.6, 0.7), 0.1), 0, 12)
			for k in 6:
				var a := TAU * k / 6.0
				Kit.add_sphere(h, 0.015, Vector3(cos(a) * 0.15, 0.215, sin(a) * 0.15), Kit.flat([Color(1, 0.3, 0.3), Color(1, 0.9, 0.3), Color(0.3, 0.9, 1)][k % 3]), 0, 6)
	# Bullseye plate on the post.
	Kit.add_cylinder(h, 0.01, 0.2, Vector3(0, 0.1, -0.02), tin, 0, -1.0, 6)


func _target_pos(t: Dictionary) -> Vector3:
	var r: Array = RAILS[t["rail"]]
	var spacing := (WIDTH + 0.6) / float(r[3])
	var x := fposmod(_t * float(r[2]) + t["slot"] * spacing, WIDTH + 0.6) - (WIDTH + 0.6) / 2.0
	return Vector3(x, r[1], r[0])


func _process(delta: float) -> void:
	if _p == null:
		return
	_t += delta
	for t: Dictionary in targets:
		var lp := _target_pos(t)
		var node: Node3D = t["node"]
		node.position = lp
		# Off the ends of the rail they dip out of sight behind the side walls.
		node.visible = absf(lp.x) < WIDTH / 2.0 + 0.15
		t["down"] = maxf(float(t["down"]) - delta, 0.0)
		var hinge: Node3D = t["hinge"]
		var want := -PI / 2 if t["down"] > 0.3 else 0.0
		hinge.rotation.x = lerpf(hinge.rotation.x, want, minf(1.0, delta * 14.0))
		var xf := node.transform * hinge.transform if node.visible else Transform3D(Basis.from_scale(Vector3.ZERO), lp)
		for e: Array in _mm[t["rail"]]:
			(e[0] as MultiMeshInstance3D).multimesh.set_instance_transform(t["slot"], xf * (e[1] as Transform3D))
	for i in 2:
		_cool[i] = maxf(_cool[i] - delta, 0.0)
	for tr: Array in _tracers:
		if tr[1] > 0.0:
			tr[1] -= delta
			(tr[0] as MeshInstance3D).visible = tr[1] > 0.0
	if running:
		var before := ceili(time_left)
		time_left = maxf(time_left - delta, 0.0)
		if time_left <= 0.0:
			running = false
			_horn.play()
			var best := maxi(scores[0], scores[1])
			if best > hi:
				hi = best
				hi_name = TEAM[0] if scores[0] >= scores[1] else TEAM[1]
			_refresh()
		elif ceili(time_left) != before:
			_refresh()


func _fire(b: Node3D, hand: Node) -> void:
	var bi := blasters.find(b)
	if bi < 0 or _cool[bi] > 0.0:
		return
	_cool[bi] = COOLDOWN
	var from := b.global_transform * Vector3(0, 0.05, -0.45)
	var dir := -b.global_transform.basis.z.normalized()
	var best := -1
	var best_d := 30.0
	for i in targets.size():
		var t: Dictionary = targets[i]
		var node: Node3D = t["node"]
		if t["down"] > 0.0 or not node.visible:
			continue
		var c := node.global_position + Vector3(0, 0.05, 0)
		var along := (c - from).dot(dir)
		if along <= 0.0 or along > best_d:
			continue
		if (from + dir * along).distance_to(c) < HIT_R:
			best = i
			best_d = along
	var to := from + dir * (best_d if best >= 0 else 8.0)
	if hand and hand.has_method("buzz"):
		hand.buzz(0.4, 0.05)
	var pts := 0
	if best >= 0:
		pts = int(RAILS[targets[best]["rail"]][4])
		if running:
			scores[bi] += pts
	_shot(bi, from, to, best)
	main.send({"t": "sg_f", "b": bi, "o": [from.x, from.y, from.z], "d": [to.x, to.y, to.z], "i": best, "sc": scores})


func _shot(bi: int, from: Vector3, to: Vector3, ti: int) -> void:
	_pew.global_position = from
	_pew.play()
	for tr: Array in _tracers:
		if tr[1] <= 0.0:
			var mi: MeshInstance3D = tr[0]
			mi.material_override = Kit.flat(TEAM_COL[bi].lerp(Color.WHITE, 0.4))
			var len := from.distance_to(to)
			mi.global_transform = Transform3D(Basis.looking_at(to - from, Vector3.UP) * Basis(Vector3.RIGHT, PI / 2) * Basis.from_scale(Vector3(1, len, 1)), (from + to) / 2.0)
			mi.visible = true
			tr[1] = 0.08
			break
	if ti >= 0 and ti < targets.size():
		targets[ti]["down"] = DOWN_TIME
		_hit.global_position = to
		_hit.play()
	_refresh()


func _on_start() -> void:
	scores = [0, 0]
	time_left = ROUND
	running = true
	_horn.play()
	_send()


func _send() -> void:
	_refresh()
	main.send({"t": "sg_s", "sc": scores, "tl": snappedf(time_left, 0.1), "on": running, "hi": hi, "hn": hi_name})


func _refresh() -> void:
	if _board == null:
		return
	_board.text = "RED %d   BLUE %d\nHIGH %d %s" % [scores[0], scores[1], hi, hi_name]
	_clock.text = "%02d" % ceili(time_left) if running else "--"


func handle(msg: Dictionary, _from: int) -> void:
	match str(msg.get("t", "")):
		"sg_f":
			var o: Array = msg.get("o", [0, 0, 0])
			var d: Array = msg.get("d", [0, 0, 0])
			var sc: Array = msg.get("sc", scores)
			scores = [int(sc[0]), int(sc[1])]
			_shot(clampi(int(msg.get("b", 0)), 0, 1), Vector3(o[0], o[1], o[2]), Vector3(d[0], d[1], d[2]), int(msg.get("i", -1)))
		"sg_s", "sg_full":
			var sc: Array = msg.get("sc", [0, 0])
			scores = [int(sc[0]), int(sc[1])]
			time_left = float(msg.get("tl", 0.0))
			running = bool(msg.get("on", false))
			hi = int(msg.get("hi", 0))
			hi_name = str(msg.get("hn", ""))
			if running and str(msg.get("t")) == "sg_s" and time_left >= ROUND - 0.5:
				_horn.play()
			_refresh()


func full_state() -> Dictionary:
	return {"t": "sg_full", "sc": scores, "tl": snappedf(time_left, 0.1), "on": running, "hi": hi, "hn": hi_name}


func on_identity_changed(_old_id: int, _new_id: int) -> void:
	pass


func on_peer_left(_slot: int) -> void:
	pass
