extends RefCounted
## Shared helpers: physics/visual layers, cached materials and meshes, and quick builders for
## boxes, cylinders, spheres and labels.

const LAYER_STRUCTURE := 1   # walls, floors, railings: the player's body collides with these
const LAYER_FURNITURE := 2   # tables, sofas, hoop: balls bounce off these
const LAYER_BALL := 4
const LAYER_UI := 8          # buttons the hand lasers can press
const LAYER_BLOCKER := 16    # invisible: stops the player's body only (e.g. walking into the pool)

const VIS_INDOOR := 1
const VIS_OUTDOOR := 2       # the sun only lights this visual layer (it has no shadows)
const VIS_ALL := 3

## Visual layers given to meshes made by the add_* helpers.
static var vis_layers := VIS_INDOOR
static var _mats := {}
static var _meshes := {}


static func mat(color: Color, rough := 0.85, metal := 0.0, emission := 0.0) -> StandardMaterial3D:
	var key := "m|%s|%.2f|%.2f|%.2f" % [color.to_html(), rough, metal, emission]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mats[key] = m
	return m


## Unshaded (always full brightness): screens, neon, UI.
static func flat(color: Color) -> StandardMaterial3D:
	var key := "f|%s" % color.to_html()
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mats[key] = m
	return m


static func box_mesh(size: Vector3) -> BoxMesh:
	var key := "b|%s" % size
	if not _meshes.has(key):
		var bm := BoxMesh.new()
		bm.size = size
		_meshes[key] = bm
	return _meshes[key]


static func cylinder_mesh(radius: float, height: float, top_radius := -1.0, sides := 24) -> CylinderMesh:
	var top := radius if top_radius < 0.0 else top_radius
	var key := "c|%.3f|%.3f|%.3f|%d" % [radius, height, top, sides]
	if not _meshes.has(key):
		var cm := CylinderMesh.new()
		cm.bottom_radius = radius
		cm.top_radius = top
		cm.height = height
		cm.radial_segments = sides
		cm.rings = 1
		_meshes[key] = cm
	return _meshes[key]


static func sphere_mesh(radius: float, segments := 16) -> SphereMesh:
	var key := "s|%.3f|%d" % [radius, segments]
	if not _meshes.has(key):
		var sm := SphereMesh.new()
		sm.radius = radius
		sm.height = radius * 2.0
		sm.radial_segments = segments
		sm.rings = maxi(segments / 2, 4)
		_meshes[key] = sm
	return _meshes[key]


## Puts a mesh in the scene; with a collision layer it becomes a StaticBody3D with that shape.
static func _place(parent: Node, mesh: Mesh, shape: Shape3D, pos: Vector3, m: Material, layer: int, rot: Vector3) -> Node3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.layers = vis_layers
	if layer == 0:
		mi.position = pos
		mi.rotation = rot
		parent.add_child(mi)
		return mi
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	body.position = pos
	body.rotation = rot
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	body.add_child(mi)
	parent.add_child(body)
	return body


static func add_box(parent: Node, size: Vector3, pos: Vector3, m: Material, layer := 0, rot := Vector3.ZERO) -> Node3D:
	var shape: BoxShape3D = null
	if layer != 0:
		shape = BoxShape3D.new()
		shape.size = size
	return _place(parent, box_mesh(size), shape, pos, m, layer, rot)


static func add_cylinder(parent: Node, radius: float, height: float, pos: Vector3, m: Material, layer := 0, top_radius := -1.0, sides := 24, rot := Vector3.ZERO) -> Node3D:
	var shape: CylinderShape3D = null
	if layer != 0:
		shape = CylinderShape3D.new()
		shape.radius = maxf(radius, top_radius)
		shape.height = height
	return _place(parent, cylinder_mesh(radius, height, top_radius, sides), shape, pos, m, layer, rot)


static func add_sphere(parent: Node, radius: float, pos: Vector3, m: Material, layer := 0, segments := 16) -> Node3D:
	var shape: SphereShape3D = null
	if layer != 0:
		shape = SphereShape3D.new()
		shape.radius = radius
	return _place(parent, sphere_mesh(radius, segments), shape, pos, m, layer, Vector3.ZERO)


## A text label about `height` metres tall per line, reading from +Z.
static func label(text: String, height: float, color := Color.WHITE, billboard := false) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = 64
	l.pixel_size = height / 64.0
	l.modulate = color
	l.outline_size = 0
	l.shaded = false
	l.double_sided = false
	if billboard:
		l.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		l.double_sided = true
	return l


static func add_label(parent: Node, text: String, height: float, pos: Vector3, yaw := 0.0, color := Color.WHITE) -> Label3D:
	var l := label(text, height, color)
	l.position = pos
	l.rotation.y = yaw
	parent.add_child(l)
	return l


static func omni(parent: Node, pos: Vector3, color: Color, energy := 1.0, light_range := 8.0) -> OmniLight3D:
	var o := OmniLight3D.new()
	o.position = pos
	o.light_color = color
	o.light_energy = energy
	o.omni_range = light_range
	o.omni_attenuation = 1.2
	o.shadow_enabled = false
	parent.add_child(o)
	return o


# ---------------------------------------------------------------- rounded shapes, tubes

## A box with rounded edges and corners (radius r): furniture looks far less blocky.
static func rbox_mesh(size: Vector3, radius: float, steps := 2) -> ArrayMesh:
	var key := "rb|%s|%.4f|%d" % [size, radius, steps]
	if _meshes.has(key):
		return _meshes[key]
	var h := size / 2.0
	var r := minf(radius, minf(h.x, minf(h.y, h.z)))
	var inner := h - Vector3(r, r, r)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in 6:
		var axis := face / 2
		var sgn := 1.0 if face % 2 == 0 else -1.0
		var ua := (axis + 1) % 3
		var va := (axis + 2) % 3
		var us := _bevel_coords(inner[ua], r, steps)
		var vs := _bevel_coords(inner[va], r, steps)
		var pts: Array[Vector3] = []
		var nrm: Array[Vector3] = []
		for j in vs.size():
			for i in us.size():
				var p := Vector3.ZERO
				p[axis] = sgn * h[axis]
				p[ua] = us[i]
				p[va] = vs[j]
				var c := p.clamp(-inner, inner)
				var n := (p - c).normalized()
				pts.append(c + n * r)
				nrm.append(n)
		var w := us.size()
		for j in vs.size() - 1:
			for i in w - 1:
				var a := j * w + i
				_tri(st, pts, nrm, a, a + 1, a + w + 1)
				_tri(st, pts, nrm, a, a + w + 1, a + w)
	var mesh := st.commit()
	_meshes[key] = mesh
	return mesh


## Face-plane coordinates from -(inner + r) to +(inner + r), denser in the rounded bands so
## the bevel's angles come out even.
static func _bevel_coords(inner: float, r: float, steps: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for k in steps + 1:
		out.append(-inner - r * tan(PI / 4.0 * (1.0 - float(k) / steps)))
	for k in range(0 if inner > 0.0005 else 1, steps + 1):
		out.append(inner + r * tan(PI / 4.0 * float(k) / steps))
	return out


## One triangle, wound clockwise as seen from outside (Godot's front face).
static func _tri(st: SurfaceTool, pts: Array[Vector3], nrm: Array[Vector3], a: int, b: int, c: int) -> void:
	var n := nrm[a] + nrm[b] + nrm[c]
	if (pts[b] - pts[a]).cross(pts[c] - pts[a]).dot(n) > 0.0:
		var t := b
		b = c
		c = t
	for k: int in [a, b, c]:
		st.set_normal(nrm[k])
		st.set_uv(Vector2(pts[k].x + pts[k].z, pts[k].y))
		st.add_vertex(pts[k])


static func add_rbox(parent: Node, size: Vector3, pos: Vector3, m: Material, radius := 0.03, layer := 0, rot := Vector3.ZERO) -> Node3D:
	var shape: BoxShape3D = null
	if layer != 0:
		shape = BoxShape3D.new()
		shape.size = size
	return _place(parent, rbox_mesh(size, radius), shape, pos, m, layer, rot)


static func capsule_mesh(radius: float, height: float, sides := 12) -> CapsuleMesh:
	var key := "cap|%.4f|%.4f|%d" % [radius, height, sides]
	if not _meshes.has(key):
		var cm := CapsuleMesh.new()
		cm.radius = radius
		cm.height = maxf(height, radius * 2.0)
		cm.radial_segments = sides
		cm.rings = 4
		_meshes[key] = cm
	return _meshes[key]


## Thin tubes along polylines (wires, rails), all in one mesh.
static func tube_mesh(paths: Array, radius: float, sides := 5) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for path: PackedVector3Array in paths:
		for k in path.size() - 1:
			var a := path[k]
			var b := path[k + 1]
			var d := (b - a).normalized()
			var up := Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT
			var x := d.cross(up).normalized()
			var y := d.cross(x)
			for s in sides:
				var a0 := TAU * s / sides
				var a1 := TAU * (s + 1) / sides
				var n0 := x * cos(a0) + y * sin(a0)
				var n1 := x * cos(a1) + y * sin(a1)
				var pts: Array[Vector3] = [a + n0 * radius, b + n0 * radius, b + n1 * radius, a + n1 * radius]
				var nrm: Array[Vector3] = [n0, n0, n1, n1]
				_tri(st, pts, nrm, 0, 1, 2)
				_tri(st, pts, nrm, 0, 2, 3)
	return st.commit()


## A solid of revolution round +y: `profile` is (radius, y) points from one end to the other
## (start and finish on the axis for a closed shape). Vases, bottles, turned legs, knobs.
static func lathe_mesh(profile: PackedVector2Array, sides := 24) -> ArrayMesh:
	var key := "lathe|%s|%d" % [profile, sides]
	if _meshes.has(key):
		return _meshes[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Which way round the outline goes decides which side is "outside".
	var area := 0.0
	for k in profile.size() - 1:
		area += profile[k].x * profile[k + 1].y - profile[k + 1].x * profile[k].y
	var flip := 1.0 if area < 0.0 else -1.0
	# Segment normals, then smooth ones at each point unless the profile turns a sharp corner.
	var seg_n: Array[Vector2] = []
	for k in profile.size() - 1:
		var d := (profile[k + 1] - profile[k]).normalized()
		seg_n.append(Vector2(-d.y, d.x) * flip)
	for k in profile.size() - 1:
		var a := profile[k]
		var b := profile[k + 1]
		if a.distance_to(b) < 0.00001:
			continue
		var na := seg_n[k]
		var nb := seg_n[k]
		if k > 0 and seg_n[k - 1].dot(na) > 0.6:
			na = (seg_n[k - 1] + na).normalized()
		if k < seg_n.size() - 1 and seg_n[k + 1].dot(nb) > 0.6:
			nb = (seg_n[k + 1] + nb).normalized()
		for s in sides:
			var a0 := TAU * s / sides
			var a1 := TAU * (s + 1) / sides
			var c0 := Vector3(cos(a0), 0, sin(a0))
			var c1 := Vector3(cos(a1), 0, sin(a1))
			var pts: Array[Vector3] = [c0 * a.x + Vector3(0, a.y, 0), c0 * b.x + Vector3(0, b.y, 0),
				c1 * b.x + Vector3(0, b.y, 0), c1 * a.x + Vector3(0, a.y, 0)]
			var nrm: Array[Vector3] = [(c0 * na.x + Vector3(0, na.y, 0)).normalized(), (c0 * nb.x + Vector3(0, nb.y, 0)).normalized(),
				(c1 * nb.x + Vector3(0, nb.y, 0)).normalized(), (c1 * na.x + Vector3(0, na.y, 0)).normalized()]
			if a.x > 0.00001 or b.x > 0.00001:
				if b.x > 0.00001:
					_tri(st, pts, nrm, 0, 1, 2)
				if a.x > 0.00001:
					_tri(st, pts, nrm, 0, 2, 3)
	var mesh := st.commit()
	_meshes[key] = mesh
	return mesh


static func add_lathe(parent: Node, profile: PackedVector2Array, pos: Vector3, m: Material, sides := 24, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = lathe_mesh(profile, sides)
	mi.material_override = m
	mi.layers = vis_layers
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


## A flat plate (in the xy plane, `thick` deep in z) of cols x rows square cells, each with a
## round hole through it: the Connect Four grid. Centred on the origin.
static func holed_panel_mesh(cols: int, rows: int, cell: float, hole_r: float, thick: float, sides := 24) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := cell / 2.0
	for r in rows:
		for c in cols:
			var ctr := Vector2((c - (cols - 1) / 2.0) * cell, (r - (rows - 1) / 2.0) * cell)
			for s in sides:
				var a0 := TAU * s / sides
				var a1 := TAU * (s + 1) / sides
				var d0 := Vector2(cos(a0), sin(a0))
				var d1 := Vector2(cos(a1), sin(a1))
				var h0 := ctr + d0 * hole_r
				var h1 := ctr + d1 * hole_r
				var b0 := ctr + d0 * (half / maxf(absf(d0.x), absf(d0.y)))
				var b1 := ctr + d1 * (half / maxf(absf(d1.x), absf(d1.y)))
				for face: float in [1.0, -1.0]:
					var z := face * thick / 2.0
					var pts: Array[Vector3] = [Vector3(h0.x, h0.y, z), Vector3(b0.x, b0.y, z), Vector3(b1.x, b1.y, z), Vector3(h1.x, h1.y, z)]
					var n := Vector3(0, 0, face)
					var nrm: Array[Vector3] = [n, n, n, n]
					_tri(st, pts, nrm, 0, 1, 2)
					_tri(st, pts, nrm, 0, 2, 3)
				# The wall of the hole, facing its centre.
				var w: Array[Vector3] = [Vector3(h0.x, h0.y, thick / 2.0), Vector3(h0.x, h0.y, -thick / 2.0),
					Vector3(h1.x, h1.y, -thick / 2.0), Vector3(h1.x, h1.y, thick / 2.0)]
				var wn: Array[Vector3] = [Vector3(-d0.x, -d0.y, 0), Vector3(-d0.x, -d0.y, 0), Vector3(-d1.x, -d1.y, 0), Vector3(-d1.x, -d1.y, 0)]
				_tri(st, w, wn, 0, 1, 2)
				_tri(st, w, wn, 0, 2, 3)
	return st.commit()


## Points of a hanging wire between a and b, sagging `sag` metres in the middle.
static func catenary(a: Vector3, b: Vector3, sag: float, count: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in count + 1:
		var t := float(i) / count
		var p := a.lerp(b, t)
		p.y -= sag * 4.0 * t * (1.0 - t)
		out.append(p)
	return out


# ---------------------------------------------------------------- textures

static var _texs := {}


## A soft round blob, white in the middle fading to clear: glows, flames, smoke.
static func soft_texture() -> Texture2D:
	if _texs.has("soft"):
		return _texs["soft"]
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.35, Color(1, 1, 1, 0.55))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	_texs["soft"] = t
	return t


## Greyscale detail textures that tint a material's colour. Kinds: planks, tiles, pavers,
## grain, plaster, carpet, fabric, grass, bark.
static func tex(kind: String) -> Texture2D:
	if _texs.has(kind):
		return _texs[kind]
	var t: Texture2D
	match kind:
		"planks", "tiles", "pavers", "grain", "bricks":
			t = ImageTexture.create_from_image(_pattern(kind))
		_:
			var nt := NoiseTexture2D.new()
			var n := FastNoiseLite.new()
			n.seed = kind.hash() & 0xFFFF
			var lo := 0.78
			match kind:
				"plaster":
					n.frequency = 0.02
					lo = 0.9
				"carpet":
					n.frequency = 0.25
					lo = 0.8
				"fabric":
					n.frequency = 0.35
					lo = 0.85
				"grass":
					n.frequency = 0.05
					n.fractal_octaves = 4
					lo = 0.7
				"bark":
					n.frequency = 0.08
					n.fractal_octaves = 3
					lo = 0.55
			nt.noise = n
			nt.seamless = true
			nt.width = 128
			nt.height = 128
			var g := Gradient.new()
			g.set_color(0, Color(lo, lo, lo))
			g.set_color(1, Color(1, 1, 1))
			nt.color_ramp = g
			t = nt
	_texs[kind] = t
	return t


static func _pattern(kind: String) -> Image:
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var n := FastNoiseLite.new()
	n.seed = 11
	n.frequency = 0.05
	var rng := RandomNumberGenerator.new()
	rng.seed = kind.hash()
	match kind:
		"planks":   # 8 boards across, two lengths per row, staggered joints
			var tints := PackedFloat32Array()
			for i in 16:
				tints.append(rng.randf_range(0.78, 1.0))
			for y in size:
				var row := y / 32
				var shift := (row * 37) % 128
				for x in size:
					var col := ((x + shift) % size) / 128
					var v := tints[row * 2 + col] * (0.9 + 0.1 * n.get_noise_2d(x * 0.15, y * 3.0 + row * 50))
					if y % 32 < 1 or (x + shift) % 128 < 1:
						v *= 0.55
					img.set_pixel(x, y, Color(v, v, v))
		"grain":
			for y in size:
				for x in size:
					var v := 0.85 + 0.15 * n.get_noise_2d(x * 0.12, y * 2.5)
					img.set_pixel(x, y, Color(v, v, v))
		"tiles":   # 4 x 4 tiles with grout
			var tints := PackedFloat32Array()
			for i in 16:
				tints.append(rng.randf_range(0.93, 1.0))
			for y in size:
				for x in size:
					var v := tints[(y / 64) * 4 + x / 64] * (0.97 + 0.03 * n.get_noise_2d(x * 2.0, y * 2.0))
					if x % 64 < 2 or y % 64 < 2:
						v = 0.72
					img.set_pixel(x, y, Color(v, v, v))
		"bricks":   # 4 bricks across, 8 courses, alternate courses offset by half a brick
			var tints := PackedFloat32Array()
			for i in 40:
				tints.append(rng.randf_range(0.8, 1.0))
			for y in size:
				var row := y / 32
				var shift := 32 if row % 2 == 1 else 0
				for x in size:
					var col := ((x + shift) % size) / 64
					var v := tints[row * 5 + col] * (0.92 + 0.08 * n.get_noise_2d(x * 1.5, y * 1.5))
					if y % 32 < 3 or (x + shift) % 64 < 3:
						v = 0.72
					img.set_pixel(x, y, Color(v, v, v))
		"pavers":   # 3 x 3 stone slabs
			var tints := PackedFloat32Array()
			for i in 9:
				tints.append(rng.randf_range(0.82, 1.0))
			for y in size:
				for x in size:
					var cx := x * 3 / size
					var cy := y * 3 / size
					var v := tints[cy * 3 + cx] * (0.9 + 0.1 * n.get_noise_2d(x * 1.5, y * 1.5))
					if (x * 3) % size < 6 or (y * 3) % size < 6:
						v = 0.6
					img.set_pixel(x, y, Color(v, v, v))
	img.generate_mipmaps()
	return img


## A material whose colour is broken up by a detail texture, mapped by position so it tiles
## across any shape (`per_m` repeats per metre). Use world = false for things that move.
static func tmat(color: Color, kind: String, per_m := 1.0, rough := 0.85, metal := 0.0, world := true) -> StandardMaterial3D:
	var key := "t|%s|%s|%.3f|%.2f|%.2f|%s" % [color.to_html(), kind, per_m, rough, metal, world]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.albedo_texture = tex(kind)
	m.roughness = rough
	m.metallic = metal
	m.uv1_triplanar = true
	m.uv1_world_triplanar = world
	m.uv1_scale = Vector3.ONE * per_m
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_mats[key] = m
	return m


## Many copies of one mesh in a single draw call. colors (optional) tint each copy; the
## material must then use vertex colours (see mm_mat).
static func add_multimesh(parent: Node, mesh: Mesh, transforms: Array[Transform3D], m: Material, colors: Array = []) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not colors.is_empty()
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		if mm.use_colors:
			mm.set_instance_color(i, colors[i])
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = m
	mi.layers = vis_layers
	parent.add_child(mi)
	return mi


## A shaded material coloured per MultiMesh instance.
static func mm_mat(rough := 0.85, tex_kind := "", per_m := 1.0) -> StandardMaterial3D:
	var key := "mm|%.2f|%s|%.2f" % [rough, tex_kind, per_m]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = rough
	if tex_kind != "":
		m.albedo_texture = tex(tex_kind)
		m.uv1_triplanar = true
		m.uv1_scale = Vector3.ONE * per_m
	_mats[key] = m
	return m


## A soft additive halo (brightest facing you, fading at the edges): put it round a bulb to
## make it look like it's glowing. Works on spheres, including MultiMesh copies.
static func halo_mat(color: Color, strength := 0.8) -> ShaderMaterial:
	var key := "halo|%s|%.2f" % [color.to_html(), strength]
	if _mats.has(key):
		return _mats[key]
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode blend_add, unshaded, depth_draw_never, cull_back, shadows_disabled;
uniform vec4 glow : source_color = vec4(1.0, 0.7, 0.35, 1.0);
uniform float strength = 0.8;
void fragment() {
	float f = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	ALBEDO = glow.rgb;
	ALPHA = pow(f, 2.5) * strength;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("glow", color)
	m.set_shader_parameter("strength", strength)
	_mats[key] = m
	return m


## Merges the static meshes under `root` that share a material, visual layers and region into
## one mesh each, so hundreds of draw calls become a few dozen (the Quest is draw-call bound).
## Skips anything under a node in `skip`, transparent and shader materials, and multi-surface
## meshes. region_of(world position) -> String keeps areas apart, so culling still works and
## each mesh stays under the mobile renderer's 8-lights-per-object limit. Merged meshes made
## from nodes in `structure` (hidden in passthrough mode) are appended to it. Collision
## bodies are kept; only their meshes move. Returns how many meshes were merged away.
static func merge_static(root: Node3D, skip: Array, region_of: Callable, structure: Array = []) -> int:
	var skip_ids := {}
	for n: Node in skip:
		skip_ids[n.get_instance_id()] = true
	var struct_ids := {}
	for n: Node in structure:
		struct_ids[n.get_instance_id()] = true
	var groups := {}   # key -> [material, layers, is_structure, [MeshInstance3D...]]
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if skip_ids.has(n.get_instance_id()):
			continue
		for c in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null or mi.mesh.get_surface_count() != 1:
			continue
		var m := mi.material_override as StandardMaterial3D
		if m == null or m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or not m.uv1_world_triplanar and m.albedo_texture != null:
			continue
		var is_struct := struct_ids.has(mi.get_instance_id()) or struct_ids.has(mi.get_parent().get_instance_id())
		var region: String = region_of.call(mi.global_transform * mi.mesh.get_aabb().get_center())
		var key := "%d|%d|%s|%s" % [m.get_instance_id(), mi.layers, region, is_struct]
		if not groups.has(key):
			groups[key] = [m, mi.layers, is_struct, []]
		groups[key][3].append(mi)
	var merged := 0
	var to_root := root.global_transform.affine_inverse()
	for key: String in groups:
		var g: Array = groups[key]
		var list: Array = g[3]
		if list.size() < 2:
			continue
		var verts := PackedVector3Array()
		var norms := PackedVector3Array()
		var idx := PackedInt32Array()
		for mi: MeshInstance3D in list:
			var arr := mi.mesh.surface_get_arrays(0)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var t := to_root * mi.global_transform
			var nb := t.basis.inverse().transposed()
			var base := verts.size()
			for i in v.size():
				verts.append(t * v[i])
				norms.append((nb * nr[i]).normalized())
			var src_idx: Variant = arr[Mesh.ARRAY_INDEX]
			if src_idx is PackedInt32Array and (src_idx as PackedInt32Array).size() > 0:
				for i: int in src_idx:
					idx.append(base + i)
			else:
				for i in v.size():
					idx.append(base + i)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_INDEX] = idx
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var out := MeshInstance3D.new()
		out.mesh = am
		out.material_override = g[0]
		out.layers = g[1]
		root.add_child(out)
		if g[2]:
			structure.append(out)
		for mi: MeshInstance3D in list:
			mi.get_parent().remove_child(mi)
			mi.queue_free()
		merged += list.size() - 1
	return merged


## [x, y, z, qx, qy, qz, qw] for sending a transform (scale dropped), rounded to the millimetre.
static func pack_tf(t: Transform3D) -> Array:
	var q := t.basis.get_rotation_quaternion()
	return [snappedf(t.origin.x, 0.001), snappedf(t.origin.y, 0.001), snappedf(t.origin.z, 0.001),
		snappedf(q.x, 0.001), snappedf(q.y, 0.001), snappedf(q.z, 0.001), snappedf(q.w, 0.001)]


static func unpack_tf(a: Variant, fallback := Transform3D.IDENTITY) -> Transform3D:
	if not (a is Array) or a.size() < 7:
		return fallback
	var q := Quaternion(float(a[3]), float(a[4]), float(a[5]), float(a[6]))
	if q.length_squared() < 0.0001:
		q = Quaternion.IDENTITY
	return Transform3D(Basis(q.normalized()), Vector3(float(a[0]), float(a[1]), float(a[2])))


static func pack_v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]


static func unpack_v3(a: Variant) -> Vector3:
	if not (a is Array) or a.size() < 3:
		return Vector3.ZERO
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
