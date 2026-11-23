extends Node3D
## A wood fire: crossed logs that char and glow, a bed of coals, flickering particle flames (a
## hot yellow core inside orange tongues), rising embers, a little smoke, a warm light on
## everything around, a glow on the ground and a crackle you hear up close.
##
## It's interactive:
## - Put your hand in it: sparks fly off your hand and the controller buzzes with the heat.
## - Throw a log on (props.gd): stoke() makes it roar for a while, then it settles back.
## - Hold things in it (marshmallows, props.gd): heat_at() says how hot a spot is.
## Fires are in the "heat" group so props can find them.

const Kit := preload("res://kit.gd")

const LOG_SHADER := """
shader_type spatial;
uniform vec4 bark : source_color = vec4(0.24, 0.15, 0.09, 1.0);
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float heat = 1.0;
uniform float coal = 0.0;
varying vec3 lpos;
void vertex() { lpos = VERTEX; }
void fragment() {
	vec2 uv = vec2(lpos.x + lpos.z, lpos.y) * 4.0;
	float n = texture(noise_tex, uv).r;
	float cracks = texture(noise_tex, uv * 2.3 + vec2(TIME * 0.02, -TIME * 0.035)).r;
	float charred = mix(smoothstep(0.25, 0.85, n), 1.0, coal);
	ALBEDO = mix(bark.rgb, vec3(0.025, 0.02, 0.02), 0.45 + 0.55 * charred);
	ROUGHNESS = 0.95;
	float pulse = 0.65 + 0.35 * sin(TIME * (2.0 + n * 3.0) + n * 30.0);
	float glow = smoothstep(mix(0.62, 0.42, coal), 0.92, cracks) * pulse;
	EMISSION = mix(vec3(1.0, 0.28, 0.03), vec3(1.0, 0.55, 0.12), glow) * glow * (2.5 + 2.0 * coal) * heat;
}
"""

var size := 1.0
var light_energy := 1.6
var smoke := true
## 1 normally; more while stoked.
var intensity := 1.0

var _boost := 0.0
var _flames: GPUParticles3D
var _core: GPUParticles3D
var _embers: GPUParticles3D
var _burst: GPUParticles3D
var _smoke: GPUParticles3D
var _flame_pm: ParticleProcessMaterial
var _light: OmniLight3D
var _glow_mat: StandardMaterial3D
var _log_mats: Array[ShaderMaterial] = []
var _audio: AudioStreamPlayer3D
var _noise := FastNoiseLite.new()
var _t := 0.0
var _hand_tick := 0.0

static var _flame_tex: Texture2D
static var _crackle: AudioStreamWAV
static var _log_noise: NoiseTexture2D


func _init(fire_size := 1.0, energy := 1.6, with_smoke := true) -> void:
	size = fire_size
	light_energy = energy
	smoke = with_smoke


func _ready() -> void:
	add_to_group("heat")
	_noise.frequency = 2.0
	_build_logs()
	# Colours go above 1 (HDR) so the additive flames read as bright even against a sunset.
	_flames = _emitter(64, 0.85, flame_texture(), true, Vector2(0.3, 0.56) * size)
	_flame_pm = _flames.process_material
	_set_flame_process(_flame_pm, 0.2 * size, Vector2(0.25, 0.55) * size, 1.6 * size)
	_flame_pm.color_ramp = _ramp([[0.0, Color(1.6, 1.3, 0.7, 0)], [0.1, Color(1.9, 1.2, 0.5, 0.9)],
		[0.35, Color(1.8, 0.72, 0.16, 0.8)], [0.7, Color(1.3, 0.3, 0.05, 0.45)], [1.0, Color(0.5, 0.06, 0, 0)]])
	_core = _emitter(20, 0.5, flame_texture(), true, Vector2(0.21, 0.34) * size)
	var core_pm: ParticleProcessMaterial = _core.process_material
	_set_flame_process(core_pm, 0.11 * size, Vector2(0.15, 0.3) * size, 1.0 * size)
	core_pm.color_ramp = _ramp([[0.0, Color(2.0, 1.9, 1.4, 0)], [0.15, Color(2.0, 1.75, 1.0, 0.95)],
		[0.6, Color(1.8, 1.1, 0.4, 0.65)], [1.0, Color(1.5, 0.5, 0.1, 0)]])
	_embers = _emitter(16, 2.4, Kit.soft_texture(), true, Vector2(0.016, 0.016) * maxf(size, 0.7))
	_set_spark_process(_embers.process_material, 0.2 * size, 30.0, Vector2(0.5, 1.3) * size)
	_burst = _emitter(30, 1.4, Kit.soft_texture(), true, Vector2(0.014, 0.014))
	_set_spark_process(_burst.process_material, 0.06, 60.0, Vector2(1.0, 2.6))
	_burst.one_shot = true
	_burst.explosiveness = 0.85
	_burst.emitting = false
	_burst.top_level = true
	if smoke:
		_smoke = _emitter(9, 3.8, Kit.soft_texture(), false, Vector2(0.45, 0.45) * size)
		var spm: ParticleProcessMaterial = _smoke.process_material
		spm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		spm.emission_sphere_radius = 0.12 * size
		spm.direction = Vector3.UP
		spm.spread = 12.0
		spm.initial_velocity_min = 0.25 * size
		spm.initial_velocity_max = 0.45 * size
		spm.gravity = Vector3(0.05, 0.12, 0.02)
		spm.damping_min = 0.05
		spm.damping_max = 0.15
		spm.angle_min = -180.0
		spm.angle_max = 180.0
		spm.angular_velocity_min = -25.0
		spm.angular_velocity_max = 25.0
		spm.scale_curve = _curve([[0.0, 0.35], [1.0, 1.0]])
		spm.color_ramp = _ramp([[0.0, Color(0.2, 0.18, 0.17, 0)], [0.2, Color(0.22, 0.2, 0.19, 0.16)],
			[1.0, Color(0.35, 0.34, 0.33, 0)]])
		_smoke.position.y = 0.55 * size
	# Warm light (it flickers), and a glow on the ground round the fire.
	_light = Kit.omni(self, Vector3(0, 0.45 * size, 0), Color(1.0, 0.58, 0.28), light_energy, 7.5 * size)
	var glow := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1.1, 1.1) * size
	glow.mesh = q
	_glow_mat = StandardMaterial3D.new()
	_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glow_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_glow_mat.albedo_texture = Kit.soft_texture()
	_glow_mat.albedo_color = Color(1.0, 0.45, 0.12, 0.35)
	glow.material_override = _glow_mat
	glow.rotation.x = -PI / 2
	glow.position.y = 0.012
	glow.layers = Kit.VIS_ALL
	add_child(glow)
	# Crackle.
	_audio = AudioStreamPlayer3D.new()
	_audio.stream = crackle_stream()
	_audio.unit_size = 2.2
	_audio.max_distance = 18.0
	_audio.volume_db = -5.0
	_audio.position.y = 0.3 * size
	add_child(_audio)
	_audio.play(randf() * 2.0)


func _build_logs() -> void:
	var s := size
	# Coal bed.
	var coals := MeshInstance3D.new()
	coals.mesh = Kit.sphere_mesh(0.3 * s, 16)
	coals.scale = Vector3(1.0, 0.18, 1.0)
	coals.position.y = 0.01 * s
	coals.material_override = _log_mat(1.0)
	coals.layers = Kit.VIS_ALL
	add_child(coals)
	# Four logs leaning in, teepee style, plus two lying across.
	for i in 4:
		var a := TAU * i / 4.0 + 0.4
		var log_node := MeshInstance3D.new()
		log_node.mesh = Kit.cylinder_mesh(0.045 * s, 0.5 * s, 0.035 * s, 10)
		log_node.material_override = _log_mat(0.0)
		log_node.position = Vector3(cos(a) * 0.14 * s, 0.17 * s, sin(a) * 0.14 * s)
		# Lean the top toward the middle.
		log_node.rotation = Vector3(0, -a, 0)
		log_node.rotate_object_local(Vector3(0, 0, 1), 0.55)
		log_node.layers = Kit.VIS_ALL
		add_child(log_node)
	for i in 2:
		var log_node := MeshInstance3D.new()
		log_node.mesh = Kit.cylinder_mesh(0.055 * s, 0.62 * s, 0.05 * s, 10)
		log_node.material_override = _log_mat(0.3)
		log_node.position = Vector3(0, 0.05 * s, (i - 0.5) * 0.12 * s)
		log_node.rotation = Vector3(0, 0.5 if i == 0 else -0.6, PI / 2)
		log_node.layers = Kit.VIS_ALL
		add_child(log_node)


func _log_mat(coal: float) -> ShaderMaterial:
	if _log_noise == null:
		_log_noise = NoiseTexture2D.new()
		var n := FastNoiseLite.new()
		n.frequency = 0.03
		n.fractal_octaves = 3
		_log_noise.noise = n
		_log_noise.seamless = true
		_log_noise.width = 128
		_log_noise.height = 128
	var sh := Shader.new()
	sh.code = LOG_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("noise_tex", _log_noise)
	m.set_shader_parameter("coal", coal)
	_log_mats.append(m)
	return m


# ---------------------------------------------------------------- particles

func _emitter(amount: int, lifetime: float, tex: Texture2D, additive: bool, quad: Vector2) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = maxi(int(amount * maxf(size, 0.5)), 4)
	p.lifetime = lifetime
	p.preprocess = lifetime
	p.randomness = 0.3
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-1.5, -0.5, -1.5) * maxf(size, 0.5), Vector3(3, 4, 3) * maxf(size, 0.5))
	p.process_material = ParticleProcessMaterial.new()
	var q := QuadMesh.new()
	q.size = quad
	p.draw_pass_1 = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = tex
	m.disable_receive_shadows = true
	q.material = m
	p.layers = Kit.VIS_ALL
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	return p


func _set_flame_process(pm: ParticleProcessMaterial, radius: float, speed: Vector2, lift: float) -> void:
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = radius
	pm.direction = Vector3.UP
	pm.spread = 10.0
	pm.initial_velocity_min = speed.x
	pm.initial_velocity_max = speed.y
	pm.gravity = Vector3(0, lift, 0)
	pm.damping_min = 0.4
	pm.damping_max = 0.9
	pm.angle_min = -12.0
	pm.angle_max = 12.0
	pm.scale_min = 0.7
	pm.scale_max = 1.15
	pm.scale_curve = _curve([[0.0, 0.45], [0.2, 1.0], [0.6, 0.75], [1.0, 0.12]])
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.8
	pm.turbulence_noise_scale = 2.2
	pm.turbulence_noise_speed = Vector3(0, 0.6, 0)
	pm.turbulence_influence_min = 0.03
	pm.turbulence_influence_max = 0.1


func _set_spark_process(pm: ParticleProcessMaterial, radius: float, spread: float, speed: Vector2) -> void:
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = radius
	pm.direction = Vector3.UP
	pm.spread = spread
	pm.initial_velocity_min = speed.x
	pm.initial_velocity_max = speed.y
	pm.gravity = Vector3(0, -0.6, 0)
	pm.damping_min = 0.2
	pm.damping_max = 0.6
	pm.scale_min = 0.6
	pm.scale_max = 1.4
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.5
	pm.turbulence_noise_scale = 1.5
	pm.turbulence_influence_min = 0.1
	pm.turbulence_influence_max = 0.3
	pm.color_ramp = _ramp([[0.0, Color(1, 0.9, 0.5, 1)], [0.5, Color(1, 0.5, 0.1, 1)], [1.0, Color(0.8, 0.15, 0.0, 0)]])


static func _ramp(points: Array) -> GradientTexture1D:
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for p: Array in points:
		offsets.append(p[0])
		colors.append(p[1])
	var g := Gradient.new()
	g.offsets = offsets
	g.colors = colors
	var t := GradientTexture1D.new()
	t.gradient = g
	t.use_hdr = true
	return t


static func _curve(points: Array) -> CurveTexture:
	var c := Curve.new()
	for p: Array in points:
		c.add_point(Vector2(p[0], p[1]))
	var t := CurveTexture.new()
	t.curve = c
	return t


## A teardrop flame shape, white (particle colours tint it): wide and bright low down,
## tapering to a soft point.
static func flame_texture() -> Texture2D:
	if _flame_tex:
		return _flame_tex
	var w := 64
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var v := float(y) / (h - 1)          # 0 top, 1 bottom
		var half := 0.46 * sin(PI * pow(v, 1.5))
		for x in w:
			var u := absf((x + 0.5) / w - 0.5)
			var a := 0.0
			if half > 0.001:
				a = pow(clampf(1.0 - u / half, 0.0, 1.0), 1.4) * (0.45 + 0.55 * v)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	img.generate_mipmaps()
	_flame_tex = ImageTexture.create_from_image(img)
	return _flame_tex


## A small flame for something that's caught fire (a marshmallow), as a child of `parent`.
static func small_flame(parent: Node3D, s := 0.25) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 16
	p.lifetime = 0.5
	p.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.1 * s
	pm.direction = Vector3.UP
	pm.spread = 10.0
	pm.initial_velocity_min = 0.2 * s
	pm.initial_velocity_max = 0.5 * s
	pm.gravity = Vector3(0, 2.0 * s, 0)
	pm.scale_curve = _curve([[0.0, 0.5], [0.25, 1.0], [1.0, 0.1]])
	pm.color_ramp = _ramp([[0.0, Color(1, 0.95, 0.7, 0)], [0.15, Color(1, 0.75, 0.3, 0.9)], [1.0, Color(0.8, 0.2, 0.0, 0)]])
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.24, 0.42) * s
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = flame_texture()
	q.material = m
	p.draw_pass_1 = q
	p.layers = Kit.VIS_ALL
	parent.add_child(p)
	return p


## A looping crackle: a soft roar of filtered noise with random pops and snaps.
static func crackle_stream() -> AudioStreamWAV:
	if _crackle:
		return _crackle
	var rate := 22050
	var n := rate * 3
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var low := 0.0
	var pop_left := 0
	var pop_amp := 0.0
	var pop_len := 1
	for i in n:
		low += (rng.randf_range(-1.0, 1.0) - low) * 0.02
		var v := low * 0.35
		if pop_left <= 0 and rng.randf() < 14.0 / rate:
			pop_len = rng.randi_range(40, 400)
			pop_left = pop_len
			pop_amp = rng.randf_range(0.15, 0.7)
		if pop_left > 0:
			var k := float(pop_left) / pop_len
			v += rng.randf_range(-1.0, 1.0) * pop_amp * k * k
			pop_left -= 1
		# Fade the ends together so the loop doesn't click.
		var edge := minf(minf(float(i), float(n - i)) / 400.0, 1.0)
		data.encode_s16(i * 2, int(clampf(v * edge, -1.0, 1.0) * 26000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_end = n
	_crackle = w
	return w


# ---------------------------------------------------------------- heat and interaction

## How hot it is at a world point: 1 in the flames, falling to 0 a little way out.
func heat_at(p: Vector3) -> float:
	var local := p - global_position
	var flat := Vector2(local.x, local.z).length()
	var radial := 1.0 - flat / (0.38 * size)
	var up := local.y / (1.1 * size * (0.8 + 0.2 * intensity))
	if up < -0.1 or up > 1.0:
		return 0.0
	return clampf(radial * 1.5, 0.0, 1.0) * clampf(1.2 - up, 0.0, 1.0)


## Whether a point is in the fire bed (where a thrown log would land and burn).
func contains(p: Vector3) -> bool:
	var local := p - global_position
	return Vector2(local.x, local.z).length() < 0.6 * size and local.y > -0.2 and local.y < 0.8 * size


## A log thrown on (or a poke): the fire flares up for a while.
func stoke(power := 1.0) -> void:
	_boost = minf(_boost + 0.6 * power, 1.4)
	sparks_at(global_position + Vector3(0, 0.25 * size, 0))


func sparks_at(p: Vector3) -> void:
	_burst.global_position = p
	_burst.restart()


func _process(delta: float) -> void:
	_t += delta
	_boost = maxf(_boost - delta * 0.045, 0.0)
	intensity = 1.0 + _boost
	var flick := 0.85 + 0.15 * _noise.get_noise_1d(_t * 6.0) + 0.06 * _noise.get_noise_1d(_t * 23.0 + 50.0)
	_light.light_energy = light_energy * flick * (0.85 + 0.35 * intensity)
	_light.position = Vector3(_noise.get_noise_1d(_t * 3.0 + 9.0), 0.45 + 0.1 * _noise.get_noise_1d(_t * 4.0 + 20.0),
		_noise.get_noise_1d(_t * 3.0 + 30.0)) * Vector3(0.08, 1.0, 0.08) * size
	_glow_mat.albedo_color.a = 0.2 * flick * (0.8 + 0.3 * intensity)
	_flames.amount_ratio = clampf(0.65 * intensity, 0.0, 1.0)
	_flame_pm.scale_min = 0.6 + 0.2 * intensity
	_flame_pm.scale_max = 0.95 + 0.3 * intensity
	_embers.amount_ratio = clampf(0.5 * intensity, 0.0, 1.0)
	for m in _log_mats:
		m.set_shader_parameter("heat", 0.7 + 0.3 * intensity)
	_audio.volume_db = -6.0 + 4.0 * _boost
	# Hands in the fire: sparks and a buzz.
	_hand_tick -= delta
	if _hand_tick <= 0.0:
		_hand_tick = 0.12
		for h in get_tree().get_nodes_in_group("player_hands"):
			if not h.visible or h.get_world_3d() != get_world_3d():
				continue
			var hp: Vector3 = h.grab_point()
			var heat := heat_at(hp)
			if heat > 0.08:
				h.buzz(0.12 + 0.4 * heat, 0.08)
				if heat > 0.35 and not _burst.emitting:
					sparks_at(hp)
