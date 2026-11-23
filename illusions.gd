extends RefCounted
## Optical-illusion artworks, drawn by one shader (`kind` picks the illusion). Being procedural
## they stay razor sharp up close, and a few animate. INFO holds each one's title and the
## line on its brass plaque.

const INFO := [
	["Rotating Snakes", "Nothing here moves. Look around the picture, not at it."],                   # 0
	["The Café Wall", "Every grey line is perfectly straight and parallel."],                          # 1
	["Scintillating Grid", "Count the black dots. There aren't any."],                                 # 2
	["Fraser's Spiral", "There is no spiral: these are separate circles. Trace one."],               # 3
	["Ebbinghaus Circles", "The two orange circles are exactly the same size."],                       # 4
	["Kanizsa's Triangle", "Nobody drew the bright white triangle."],                                  # 5
	["Ouchi Disc", "Move your head slowly: the centre floats on its own layer."],                     # 6
	["Pinna's Rings", "Lean in and back out: the rings turn."],                                        # 7
	["The Lilac Chaser", "Stare at the cross for 20 seconds. Watch the gap."],                        # 8
	["Hering's Lines", "The red lines are dead straight."],                                            # 9
	["Zöllner's Lines", "The long lines are all parallel."],                                           # 10
	["One Grey", "The bar across the middle is a single shade of grey."],                            # 11
	["Troxler Fading", "Fix your eyes on the cross and keep still. The colours melt away."],         # 12
	["Rubin's Vase", "A vase, or two faces about to kiss?"],                                          # 13
	["The Hypnotic Spiral", "Stare at the red dot for 30 s, then look at your friend's face."],     # 14
	["Stepping Feet", "The two blocks move at exactly the same steady speed."],                       # 15
]

const SHADER := """
shader_type spatial;
render_mode cull_back;
uniform int kind = 0;
uniform float aspect = 1.4;

// 1 inside (d < 0), 0 outside, smoothed over a pixel.
float fill(float d, float px) { return 1.0 - smoothstep(-px, px, d); }

float gauss(float x, float m, float s) { return exp(-(x - m) * (x - m) / (2.0 * s * s)); }

float seg_d(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a, ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

float cross2(vec2 a, vec2 b) { return a.x * b.y - a.y * b.x; }

vec3 snakes(vec2 c, float px) {
	float s = 0.25;
	vec2 cell = floor(c / s);
	vec2 q = (fract(c / s) - 0.5) * s;
	float r = length(q);
	float dir = mod(cell.x + cell.y, 2.0) < 0.5 ? 1.0 : -1.0;
	vec3 col = vec3(0.12, 0.5, 0.22);
	float R = s * 0.46;
	if (r < R) {
		float rings = 4.0;
		float ring = floor(r / R * rings);
		float a = atan(q.y, q.x) * dir + ring * 0.3;
		float n = 6.0 + ring * 5.0;
		float k = mod(floor(a / TAU * n * 4.0), 4.0);
		col = k < 0.5 ? vec3(0.0) : (k < 1.5 ? vec3(0.12, 0.25, 0.9) : (k < 2.5 ? vec3(1.0) : vec3(1.0, 0.88, 0.08)));
		col = mix(col, vec3(0.05, 0.25, 0.1), fill(r - R * 0.12, px));
	}
	return col;
}

vec3 cafe(vec2 c, float px) {
	float h = 0.085;
	float row = floor(c.y / h);
	float m = mod(row, 4.0);
	float off = (m == 1.0 || m == 3.0) ? 0.25 : ((m == 2.0) ? 0.5 : 0.0);
	float x = c.x / h + off;
	vec3 col = mix(vec3(0.03), vec3(0.96), mod(floor(x), 2.0));
	float yy = fract(c.y / h);
	return mix(col, vec3(0.52), fill(min(yy, 1.0 - yy) * h - 0.0035, px));
}

vec3 scint(vec2 c, float px) {
	float s = 0.1;
	vec2 q = (fract(c / s + 0.5) - 0.5) * s;
	vec3 col = mix(vec3(0.0), vec3(0.42), fill(min(abs(q.x), abs(q.y)) - s * 0.075, px));
	return mix(col, vec3(1.0), fill(length(q) - s * 0.11, px));
}

vec3 fraser(vec2 c, float px) {
	float r = length(c);
	float a = atan(c.y, c.x);
	float lr = log(max(r, 0.001));
	float ch = mod(floor(a / TAU * 24.0 + lr * 7.0) + floor(a / TAU * 24.0 - lr * 7.0), 2.0);
	vec3 col = mix(vec3(0.12, 0.3, 0.72), vec3(0.4, 0.78, 0.3), ch);
	for (int i = 1; i <= 6; i++) {
		float R = 0.072 * float(i);
		float w = 0.01 + 0.0025 * float(i);
		if (abs(r - R) < w) {
			float t = (r - R) / w;
			float n = 10.0 + float(i) * 9.0;
			col = mix(vec3(0.02), vec3(0.98), mod(floor(a / TAU * n + t * 0.9), 2.0));
		}
	}
	return col;
}

vec3 ebbinghaus(vec2 c, float px) {
	vec3 col = vec3(0.96, 0.95, 0.92);
	vec3 grey = vec3(0.45, 0.5, 0.62);
	vec2 L = vec2(-0.32, 0.0);
	vec2 R = vec2(0.34, 0.0);
	for (int i = 0; i < 6; i++) {
		float a = TAU * float(i) / 6.0;
		col = mix(col, grey, fill(length(c - L - vec2(cos(a), sin(a)) * 0.22) - 0.095, px));
	}
	for (int i = 0; i < 8; i++) {
		float a = TAU * float(i) / 8.0;
		col = mix(col, grey, fill(length(c - R - vec2(cos(a), sin(a)) * 0.115) - 0.03, px));
	}
	col = mix(col, vec3(1.0, 0.5, 0.08), fill(length(c - L) - 0.07, px));
	return mix(col, vec3(1.0, 0.5, 0.08), fill(length(c - R) - 0.07, px));
}

vec3 kanizsa(vec2 c, float px) {
	vec3 col = vec3(0.97);
	float R = 0.3;
	vec2 v[3];
	vec2 w[3];
	for (int i = 0; i < 3; i++) {
		float a = PI / 2.0 + TAU * float(i) / 3.0;
		v[i] = vec2(cos(a), sin(a)) * R;
		w[i] = -v[i] * 0.85;
	}
	float dl = 1e9;
	for (int i = 0; i < 3; i++) {
		dl = min(dl, seg_d(c, w[i], w[(i + 1) % 3]));
	}
	col = mix(col, vec3(0.05), fill(dl - 0.007, px));
	// The illusory triangle hides the outline where it "covers" it.
	float s0 = cross2(v[1] - v[0], c - v[0]);
	float s1 = cross2(v[2] - v[1], c - v[1]);
	float s2 = cross2(v[0] - v[2], c - v[2]);
	if ((s0 > 0.0 && s1 > 0.0 && s2 > 0.0) || (s0 < 0.0 && s1 < 0.0 && s2 < 0.0)) {
		col = vec3(0.97);
	}
	for (int i = 0; i < 3; i++) {
		vec2 q = c - v[i];
		vec2 u = normalize(-v[i]);
		vec2 e1 = vec2(u.x * cos(PI / 6.0) - u.y * sin(PI / 6.0), u.x * sin(PI / 6.0) + u.y * cos(PI / 6.0));
		vec2 e2 = vec2(u.x * cos(-PI / 6.0) - u.y * sin(-PI / 6.0), u.x * sin(-PI / 6.0) + u.y * cos(-PI / 6.0));
		float d = max(length(q) - 0.1, min(cross2(e2, q), cross2(q, e1)));
		col = mix(col, vec3(0.05), fill(d, px));
	}
	return col;
}

vec3 ouchi(vec2 c, float px) {
	vec2 q = length(c) < 0.24 ? c.yx : c;
	vec2 g = floor(q / vec2(0.06, 0.016));
	return mix(vec3(0.02), vec3(0.98), mod(g.x + g.y, 2.0));
}

vec3 pinna(vec2 c, float px) {
	vec3 col = vec3(0.55);
	float a = atan(c.y, c.x);
	for (int k = 0; k < 3; k++) {
		float R = 0.13 + 0.11 * float(k);
		float n = 18.0 + 14.0 * float(k);
		float tilt = mod(float(k), 2.0) < 0.5 ? 0.55 : -0.55;
		float ai = (floor(a / TAU * n) + 0.5) * TAU / n;
		vec2 d = c - vec2(cos(ai), sin(ai)) * R;
		float th = ai + tilt;
		vec2 u = vec2(cos(th), sin(th));
		vec2 e = vec2(dot(d, u), dot(d, vec2(-u.y, u.x)));
		float s = 0.012;
		vec2 ae = abs(e);
		float m = max(ae.x, ae.y);
		if (m < s) {
			col = vec3(0.55);
			if (s - m < s * 0.4) {
				float sg = ae.x > ae.y ? sign(e.x) : sign(e.y);
				col = sg > 0.0 ? vec3(0.0) : vec3(1.0);
			}
		}
	}
	return col;
}

vec3 lilac(vec2 c, float px, float t) {
	vec3 col = vec3(0.72);
	float missing = mod(floor(t * 8.0), 12.0);
	for (int i = 0; i < 12; i++) {
		if (float(i) == missing) {
			continue;
		}
		float a = TAU * float(i) / 12.0;
		float d = length(c - vec2(cos(a), sin(a)) * 0.3);
		col = mix(col, vec3(0.88, 0.42, 0.88), exp(-d * d / (2.0 * 0.032 * 0.032)) * 0.9);
	}
	float cr = min(max(abs(c.x) - 0.025, abs(c.y) - 0.004), max(abs(c.y) - 0.025, abs(c.x) - 0.004));
	return mix(col, vec3(0.0), fill(cr, px));
}

vec3 hering(vec2 c, float px) {
	float r = length(c);
	float a = atan(c.y, c.x);
	float n = 44.0;
	float da = (fract(a / TAU * n + 0.5) - 0.5) * TAU / n;
	vec3 col = mix(vec3(0.97), vec3(0.05), fill(r * abs(sin(da)) - 0.0022, px));
	return mix(col, vec3(0.85, 0.05, 0.08), fill(abs(abs(c.x) - 0.18) - 0.006, px));
}

vec3 zollner(vec2 c, float px) {
	vec3 col = vec3(0.97);
	vec2 q = vec2(c.x + c.y, c.y - c.x) * 0.70710678;
	float sp = 0.13;
	float li = floor(q.y / sp + 0.5);
	col = mix(col, vec3(0.02), fill(abs(q.y - li * sp) - 0.005, px));
	float hs = 0.045;
	vec2 rel = q - vec2(floor(q.x / hs + 0.5) * hs, li * sp);
	vec2 dir = mod(li, 2.0) < 0.5 ? vec2(0.70710678, -0.70710678) : vec2(0.70710678, 0.70710678);
	float along = dot(rel, dir);
	float dh = max(abs(along) - 0.027, length(rel - along * dir) - 0.004);
	return mix(col, vec3(0.02), fill(dh, px));
}

vec3 contrast(vec2 c, float px) {
	vec3 col = vec3(pow(clamp(c.x / (aspect * 0.92) + 0.5, 0.0, 1.0), 1.0));
	float bar = max(abs(c.y) - 0.05, abs(c.x) - aspect * 0.42);
	return mix(col, vec3(0.5), fill(bar, px));
}

vec3 troxler(vec2 c, float px) {
	vec3 col = vec3(0.86);
	for (int i = 0; i < 8; i++) {
		float a = TAU * float(i) / 8.0 + 0.3;
		vec2 p = vec2(cos(a), sin(a)) * (0.22 + 0.08 * mod(float(i), 2.0));
		vec3 tint = 0.6 + 0.35 * cos(vec3(0.0, 2.1, 4.2) + float(i) * 0.8);
		float d = length(c - p);
		col = mix(col, tint, exp(-d * d / (2.0 * 0.07 * 0.07)) * 0.9);
	}
	float cr = min(max(abs(c.x) - 0.02, abs(c.y) - 0.003), max(abs(c.y) - 0.02, abs(c.x) - 0.003));
	return mix(col, vec3(0.0), fill(cr, px));
}

vec3 rubin(vec2 c, float px) {
	float y = c.y + 0.5;
	float h = 0.2 + 0.14 * smoothstep(0.16, 0.0, y) + 0.12 * smoothstep(0.66, 1.0, y)
		- 0.085 * gauss(y, 0.585, 0.035) - 0.032 * gauss(y, 0.47, 0.014) - 0.032 * gauss(y, 0.405, 0.014)
		+ 0.012 * gauss(y, 0.437, 0.008) - 0.06 * gauss(y, 0.31, 0.032) + 0.035 * gauss(y, 0.67, 0.03);
	return mix(vec3(0.06, 0.07, 0.16), vec3(0.97, 0.9, 0.72), fill(abs(c.x) - h, px));
}

vec3 spiral(vec2 c, float px, float t) {
	float r = length(c);
	if (r > 0.46) {
		return vec3(0.12);
	}
	float a = atan(c.y, c.x);
	float s = sin(3.0 * a - 38.0 * r + t * 3.5);
	vec3 col = mix(vec3(0.02), vec3(0.98), smoothstep(-0.25, 0.25, s));
	return mix(col, vec3(0.9, 0.05, 0.05), fill(r - 0.012, px));
}

vec3 feet(vec2 c, float px, float t) {
	vec3 col = vec3(step(0.5, fract(c.x / 0.04)));
	float x = mod(t * 0.1, aspect + 0.3) - aspect * 0.5 - 0.15;
	if (abs(c.y - 0.12) < 0.03 && abs(c.x - x) < 0.07) {
		col = vec3(1.0, 0.9, 0.1);
	}
	if (abs(c.y + 0.12) < 0.03 && abs(c.x - x) < 0.07) {
		col = vec3(0.04, 0.04, 0.4);
	}
	return col;
}

void fragment() {
	vec2 c = vec2((UV.x - 0.5) * aspect, 0.5 - UV.y);
	float px = max(length(fwidth(c)), 0.0003);
	float t = TIME;
	vec3 col;
	if (kind == 0) { col = snakes(c, px); }
	else if (kind == 1) { col = cafe(c, px); }
	else if (kind == 2) { col = scint(c, px); }
	else if (kind == 3) { col = fraser(c, px); }
	else if (kind == 4) { col = ebbinghaus(c, px); }
	else if (kind == 5) { col = kanizsa(c, px); }
	else if (kind == 6) { col = ouchi(c, px); }
	else if (kind == 7) { col = pinna(c, px); }
	else if (kind == 8) { col = lilac(c, px, t); }
	else if (kind == 9) { col = hering(c, px); }
	else if (kind == 10) { col = zollner(c, px); }
	else if (kind == 11) { col = contrast(c, px); }
	else if (kind == 12) { col = troxler(c, px); }
	else if (kind == 13) { col = rubin(c, px); }
	else if (kind == 14) { col = spiral(c, px, t); }
	else { col = feet(c, px, t); }
	ALBEDO = col * 0.8;
	EMISSION = col * 0.35;
	ROUGHNESS = 0.92;
}
"""

static var _shader: Shader


static func material(kind: int, aspect: float) -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("kind", kind)
	m.set_shader_parameter("aspect", aspect)
	return m
