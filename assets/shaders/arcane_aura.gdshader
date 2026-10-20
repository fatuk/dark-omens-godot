shader_type canvas_item;
render_mode blend_add;

// Магическая аура за картой заклинания (окно каста): фиолетовые языки «лижут» края
// карты наружу и чуть тянутся вверх, закручиваясь (domain-warp FBM по TIME).
// Прямоугольник центрирован на карте; сама карта лежит сверху и закрывает середину.
// Additive: на тёмном арте даёт свечение, спад — в rgb.

uniform vec2 rect_px = vec2(600.0, 800.0);  // размер прямоугольника ауры, px
uniform vec2 card_half_px = vec2(160.0, 250.0);  // полуразмер карты, px
uniform float reach_px = 150.0;  // как далеко от края карты достают языки
uniform vec4 color_deep : source_color = vec4(0.38, 0.12, 0.62, 1.0);
uniform vec4 color_bright : source_color = vec4(0.86, 0.62, 1.0, 1.0);
uniform float intensity : hint_range(0.0, 3.0) = 1.0;
uniform float speed : hint_range(0.0, 3.0) = 0.55;
uniform float rise : hint_range(0.0, 1.0) = 0.35;  // тяга языков вверх

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
		u.y
	);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(1.7, 9.2);
		a *= 0.5;
	}
	return v;
}

// Расстояние до прямоугольника карты (0 на краю, >0 снаружи), px.
float sd_box(vec2 p, vec2 b) {
	vec2 d = abs(p) - b;
	return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * rect_px;  // px от центра карты, y вниз
	float d = sd_box(p, card_half_px) / reach_px;  // 0 — край карты, 1 — предел языков
	float t = TIME * speed;

	// Координаты «вдоль края» (угол) и «от края» (d): языки бегут наружу по d,
	// тянутся вверх (rise) и закручиваются варпом.
	float ang = atan(p.y, p.x);
	vec2 q = vec2(ang * 2.2, d * 2.4 - t + p.y / reach_px * rise);
	vec2 warp = vec2(fbm(q + vec2(0.0, t * 0.6)), fbm(q + vec2(5.2, 1.3 - t * 0.4)));
	float n = fbm(q * 1.6 + warp * 2.2);

	float tongues = smoothstep(0.42, 0.85, n);
	float fade = clamp(1.0 - d, 0.0, 1.0);
	fade *= fade;
	float halo = exp(-max(d, 0.0) * 4.0) * 0.35;  // мягкое сияние у самого края карты
	float a = (tongues * fade + halo) * step(0.0, d + 0.05);

	// Края прямоугольника — мягкий спад, чтобы не было видно границ.
	vec2 e = min(UV, vec2(1.0) - UV);
	a *= smoothstep(0.0, 0.12, e.x) * smoothstep(0.0, 0.12, e.y);

	vec3 col = mix(color_deep.rgb, color_bright.rgb, clamp(n * n * 1.4, 0.0, 1.0));
	COLOR = vec4(col * a * intensity, 1.0);
}
