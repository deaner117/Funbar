extends RefCounted
## Shared pieces for the arcade machines: upright cabinets with lit marquees and side art,
## CRT-style screens (a SubViewport drawn by a Node2D, shown through a scanline shader) and
## little synthesized sound effects.

const Kit := preload("res://kit.gd")

const SCREEN_SHADER := """
shader_type spatial;
render_mode unshaded;
uniform sampler2D screen : source_color, filter_nearest;
uniform float lines = 240.0;
void fragment() {
	vec2 uv = UV;
	// A slight barrel bulge, scanlines and a vignette, like an old tube.
	vec2 c = uv - 0.5;
	uv = 0.5 + c * (1.0 + 0.06 * dot(c, c));
	vec3 col = texture(screen, uv).rgb;
	float scan = 0.82 + 0.18 * sin(uv.y * lines * 3.14159 * 2.0);
	float vig = smoothstep(0.75, 0.35, length(c));
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { col = vec3(0.0); }
	ALBEDO = col * scan * (0.55 + 0.45 * vig) * 1.15;
}
"""

const SIDE_ART_SHADER := """
shader_type spatial;
uniform vec4 col_a : source_color = vec4(1.0, 0.2, 0.6, 1.0);
uniform vec4 col_b : source_color = vec4(0.2, 0.8, 1.0, 1.0);
// Diagonal racing stripes and stars over a dark body, for cabinet sides.
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 uv = UV;
	vec3 col = vec3(0.03, 0.03, 0.06);
	float d = uv.x + uv.y * 0.6;
	float s1 = smoothstep(0.02, 0.0, abs(fract(d * 1.2) - 0.5) - 0.06);
	float s2 = smoothstep(0.02, 0.0, abs(fract(d * 1.2 + 0.18) - 0.5) - 0.025);
	col = mix(col, col_a.rgb, s1);
	col = mix(col, col_b.rgb, s2);
	vec2 g = floor(uv * vec2(14.0, 30.0));
	float st = step(0.93, hash(g)) * smoothstep(0.25, 0.0, length(fract(uv * vec2(14.0, 30.0)) - 0.5));
	col += vec3(st);
	ALBEDO = col;
	EMISSION = (col_a.rgb * s1 + col_b.rgb * s2) * 0.35;
	ROUGHNESS = 0.4;
}
"""

static var _shaders := {}


static func shader(code: String) -> Shader:
	if not _shaders.has(code):
		var s := Shader.new()
		s.code = code
		_shaders[code] = s
	return _shaders[code]


## A screen quad (size in metres) showing what `drawer` draws into a SubViewport of `res`
## pixels. Returns the SubViewport; set its render_target_update_mode to pause drawing.
static func screen(parent: Node3D, size: Vector2, res: Vector2i, drawer: Node, pos: Vector3, rot: Vector3) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = res
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.add_child(drawer)
	parent.add_child(vp)
	var mi := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = size
	mi.mesh = qm
	var m := ShaderMaterial.new()
	m.shader = shader(SCREEN_SHADER)
	m.set_shader_parameter("screen", vp.get_texture())
	m.set_shader_parameter("lines", float(res.y))
	mi.material_override = m
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return vp


static func side_art(a: Color, b: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader(SIDE_ART_SHADER)
	m.set_shader_parameter("col_a", a)
	m.set_shader_parameter("col_b", b)
	return m


## A classic upright cabinet facing +z: art-covered sides, a black body, a lit marquee with
## the title, a screen bezel tilted back, a control panel and a coin door. Returns where the
## screen goes: {"screen_pos", "screen_rot", "screen_size", "panel" (Node3D on the control
## panel surface)}.
static func upright(p: Node3D, title: String, a: Color, b: Color) -> Dictionary:
	var black := Kit.mat(Color(0.03, 0.03, 0.04), 0.5)
	var trim := Kit.mat(a.darkened(0.2), 0.4)
	var art := side_art(a, b)
	# Sides (art panels), the body between them.
	for sx: float in [-0.39, 0.39]:
		var side := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.025, 1.9, 0.78)
		side.mesh = bm
		side.material_override = art
		side.position = Vector3(sx, 0.95, -0.05)
		p.add_child(side)
		Kit.add_box(p, Vector3(0.03, 1.9, 0.02), Vector3(sx, 0.95, 0.345), trim)
	Kit.add_box(p, Vector3(0.76, 0.95, 0.66), Vector3(0, 0.475, -0.08), black, Kit.LAYER_FURNITURE)
	Kit.add_box(p, Vector3(0.76, 0.85, 0.5), Vector3(0, 1.42, -0.2), black)
	# Coin door with two lit slots.
	Kit.add_rbox(p, Vector3(0.32, 0.36, 0.02), Vector3(0, 0.45, 0.255), Kit.mat(Color(0.25, 0.25, 0.28), 0.35, 0.7), 0.01)
	for sx: float in [-0.07, 0.07]:
		Kit.add_box(p, Vector3(0.05, 0.07, 0.01), Vector3(sx, 0.52, 0.268), Kit.flat(Color(1.0, 0.25, 0.2)))
	# Control panel: sloped, with the panel surface as a node for joysticks and buttons.
	var panel := Node3D.new()
	panel.position = Vector3(0, 0.98, 0.18)
	panel.rotation.x = -0.25
	p.add_child(panel)
	Kit.add_rbox(panel, Vector3(0.76, 0.05, 0.34), Vector3(0, 0, 0), Kit.mat(Color(0.08, 0.08, 0.1), 0.5), 0.015)
	Kit.add_box(panel, Vector3(0.74, 0.004, 0.3), Vector3(0, 0.026, 0), art)
	# Screen bezel, tilted back.
	Kit.add_box(p, Vector3(0.74, 0.6, 0.04), Vector3(0, 1.43, 0.06), black, 0, Vector3(-0.22, 0, 0))
	# Marquee: a lit box with the title.
	Kit.add_box(p, Vector3(0.78, 0.26, 0.42), Vector3(0, 1.98, -0.12), black)
	Kit.add_box(p, Vector3(0.72, 0.2, 0.01), Vector3(0, 1.98, 0.095), Kit.flat(a.lerp(Color.WHITE, 0.15)))
	var t := Kit.add_label(p, title, 0.11, Vector3(0, 1.98, 0.102), 0.0, Color(1, 1, 1))
	t.outline_size = 14
	t.outline_modulate = b.darkened(0.4)
	return {"screen_pos": Vector3(0, 1.435, 0.085), "screen_rot": Vector3(-0.22, 0, 0), "screen_size": Vector2(0.62, 0.48), "panel": panel}


## A ball-top joystick and round buttons on a control panel node.
static func joystick(panel: Node3D, pos: Vector3, ball: Color) -> Node3D:
	var j := Node3D.new()
	j.position = pos + Vector3(0, 0.025, 0)
	panel.add_child(j)
	Kit.add_cylinder(j, 0.006, 0.07, Vector3(0, 0.035, 0), Kit.mat(Color(0.7, 0.7, 0.72), 0.3, 0.8), 0, -1.0, 8)
	Kit.add_sphere(j, 0.022, Vector3(0, 0.075, 0), Kit.mat(ball, 0.25), 0, 14)
	Kit.add_cylinder(panel, 0.03, 0.004, pos + Vector3(0, 0.027, 0), Kit.mat(Color(0.05, 0.05, 0.05), 0.5), 0, -1.0, 16)
	return j


static func button_cap(panel: Node3D, pos: Vector3, c: Color) -> void:
	Kit.add_cylinder(panel, 0.022, 0.012, pos + Vector3(0, 0.03, 0), Kit.mat(c, 0.25), 0, 0.02, 16)
	Kit.add_cylinder(panel, 0.027, 0.004, pos + Vector3(0, 0.026, 0), Kit.mat(Color(0.85, 0.85, 0.88), 0.3, 0.6), 0, -1.0, 16)


## Short synthesized effects. kind: "blip", "coin", "hit", "boom", "pew", "ding", "buzz".
static func sfx(kind: String) -> AudioStreamWAV:
	var rate := 22050
	var dur := {"blip": 0.06, "coin": 0.35, "hit": 0.08, "boom": 0.5, "pew": 0.18, "ding": 0.45, "buzz": 0.5, "chomp": 0.09}.get(kind, 0.1) as float
	var n := int(dur * rate)
	var data := PackedByteArray()
	data.resize(n * 2)
	var ph := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = kind.hash()
	for i in n:
		var t := float(i) / rate
		var k := t / dur
		var f := 440.0
		var v := 0.0
		match kind:
			"blip":
				f = 880.0
			"coin":
				f = 988.0 if t < 0.08 else 1319.0
			"hit":
				f = 220.0 - 120.0 * k
			"boom":
				v = rng.randf_range(-1, 1) * (1.0 - k) * (1.0 - k)
			"pew":
				f = 1400.0 - 1100.0 * k
			"ding":
				f = 1568.0
			"buzz":
				f = 110.0
			"chomp":
				f = 300.0 + 300.0 * sin(k * PI)
		ph += f / rate
		if kind != "boom":
			var sq := 1.0 if fmod(ph, 1.0) < 0.5 else -1.0
			v = sin(TAU * ph) * 0.6 + sq * 0.25 if kind in ["ding", "coin"] else sq * 0.5 + sin(TAU * ph) * 0.3
		var env := minf(1.0, t * 300.0) * (1.0 - k) if kind != "ding" else minf(1.0, t * 300.0) * exp(-k * 4.0)
		data.encode_s16(i * 2, int(clampf(v * env * 0.6, -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = data
	return w


static func player3d(parent: Node3D, pos: Vector3, stream: AudioStream, db := -6.0) -> AudioStreamPlayer3D:
	var a := AudioStreamPlayer3D.new()
	a.stream = stream
	a.position = pos
	a.volume_db = db
	a.unit_size = 3.0
	a.max_distance = 20.0
	a.max_polyphony = 4
	parent.add_child(a)
	return a


## Merges a machine's static meshes per material (the Quest is draw-call bound). Buttons and
## anything in `skip` (moving parts) are left alone.
static func merge(root: Node3D, skip: Array = []) -> int:
	var s := skip.duplicate()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.has_method("press"):
			s.append(n)
			continue
		for c in n.get_children():
			stack.append(c)
	var merged := Kit.merge_static(root, s, func(_p: Vector3) -> String: return "")
	cull_small(root)
	return merged


## Small details (knobs, labels, trim) stop drawing beyond a few metres: you cannot see them
## from across the room, and every one is a draw call.
static func cull_small(root: Node, far := 7.0) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var gi := n as GeometryInstance3D
		if gi == null or gi is MultiMeshInstance3D or gi.visibility_range_end > 0.0:
			continue
		if gi is Label3D:
			if (gi as Label3D).pixel_size * (gi as Label3D).font_size < 0.09:
				gi.visibility_range_end = far
		elif gi.get_aabb().size.length() < 0.25:
			gi.visibility_range_end = far


## Collects 2D shapes as coloured triangles and draws them all in one call (a screen full of
## rects and polygons would otherwise be hundreds of draw calls). Same method names as Node2D,
## so drawing code reads the same. Call flush() before drawing text that must sit on top.
class Batch:
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()

	func draw_rect(r: Rect2, c: Color) -> void:
		_quad(r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), c)

	func draw_line(a: Vector2, b: Vector2, c: Color, w := 1.0) -> void:
		var d := (b - a)
		if d.length() < 0.0001:
			return
		var n := Vector2(-d.y, d.x).normalized() * (w / 2.0)
		_quad(a + n, b + n, b - n, a - n, c)

	func draw_circle(p: Vector2, r: float, c: Color) -> void:
		var seg := clampi(int(r * 1.5) + 6, 6, 20)
		var base := pts.size()
		pts.append(p)
		cols.append(c)
		for i in seg:
			var a := TAU * i / seg
			pts.append(p + Vector2(cos(a), sin(a)) * r)
			cols.append(c)
		for i in seg:
			idx.append_array([base, base + 1 + i, base + 1 + (i + 1) % seg])

	func draw_colored_polygon(poly: PackedVector2Array, c: Color) -> void:
		var tri := Geometry2D.triangulate_polygon(poly)
		var base := pts.size()
		pts.append_array(poly)
		for i in poly.size():
			cols.append(c)
		for i in tri:
			idx.append(base + i)

	func _quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, col: Color) -> void:
		var i := pts.size()
		pts.append_array([a, b, c, d])
		cols.append_array([col, col, col, col])
		idx.append_array([i, i + 1, i + 2, i, i + 2, i + 3])

	func flush(canvas: CanvasItem) -> void:
		if not idx.is_empty():
			RenderingServer.canvas_item_add_triangle_array(canvas.get_canvas_item(), idx, pts, cols)
		pts = PackedVector2Array()
		cols = PackedColorArray()
		idx = PackedInt32Array()
