shader_type canvas_item;
render_mode blend_add;

// Живой фон окна каста (лист spell-cast): поверх арта, под картой.
//  • пылинки — мелкие сиреневые искры медленно всплывают, покачиваются и мерцают;
//  • магический круг «дышит»: по внешнему кольцу бежит мягкий блик, полоса рун
//    между кольцами слабо пульсирует.
// Additive; края листа (рамка) гасятся.

uniform vec2 sheet_px = vec2(781.0, 940.0);  // размер листа, px
uniform vec2 ring_center = vec2(0.495, 0.345);  // центр круга (доли листа)
uniform float ring_radius_px = 213.0;  // внешнее кольцо
uniform float rune_radius_px = 196.0;  // полоса рун

uniform vec4 mote_color : source_color = vec4(0.82, 0.62, 1.0, 1.0);
uniform float mote_density : hint_range(0.0, 1.0) = 0.35;  // доля ячеек с пылинкой
uniform float mote_speed : hint_range(0.0, 2.0) = 0.35;
uniform float mote_brightness : hint_range(0.0, 3.0) = 0.9;
uniform float mote_size_px : hint_range(0.5, 8.0) = 2.6;

uniform vec4 ring_color : source_color = vec4(0.70, 0.45, 1.0, 1.0);
uniform float ring_brightness : hint_range(0.0, 3.0) = 0.8;
uniform float ring_speed : hint_range(0.0, 2.0) = 0.25;  // оборотов блика за 2π сек

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 hash2(vec2 p) {
	return vec2(hash(p), hash(p + vec2(17.3, 41.9)));
}

// Слой пылинок: сетка ячеек cell_px, в каждой — может быть одна искра.
float motes(vec2 px, float cell_px, float t, float seed) {
	vec2 p = px / cell_px;
	p.y += t;  // сетка ползёт вверх (y вниз в UV)
	vec2 id = floor(p);
	vec2 f = fract(p);
	vec2 h = hash2(id + seed);
	if (hash(id + seed + 7.7) > mote_density) {
		return 0.0;
	}
	vec2 c = 0.2 + 0.6 * h;
	c.x += 0.12 * sin(t * 2.0 + h.y * 6.283);  // покачивание
	float d = length((f - c) * cell_px);
	float dot_v = exp(-d * d / (mote_size_px * mote_size_px));
	float tw = 0.45 + 0.55 * sin(t * 6.0 + h.x * 6.283);  // мерцание
	return dot_v * tw * tw;
}

void fragment() {
	vec2 px = UV * sheet_px;
	float t = TIME;

	// Пылинки: два слоя разной крупности и скорости — глубина.
	float m = motes(px, 46.0, t * mote_speed, 0.0);
	m += 0.6 * motes(px, 31.0, t * mote_speed * 0.6, 13.0);
	vec3 col = mote_color.rgb * m * mote_brightness;

	// Круг: расстояние до центра в px.
	vec2 cp = px - ring_center * sheet_px;
	float r = length(cp);
	float ang = atan(cp.y, cp.x);
	// Блик по внешнему кольцу: тонкая полоса × пятно, бегущее по углу.
	float band = exp(-pow((r - ring_radius_px) / 3.0, 2.0));
	float sweep = pow(0.5 + 0.5 * cos(ang - t * ring_speed * 6.283), 10.0);
	float sweep2 = pow(0.5 + 0.5 * cos(ang + 3.1416 - t * ring_speed * 6.283), 10.0);
	// Полоса рун: широкая, слабая пульсация.
	float runes = exp(-pow((r - rune_radius_px) / 9.0, 2.0));
	float pulse = 0.5 + 0.5 * sin(t * 1.3);
	float ring = band * (sweep + sweep2) + runes * (0.08 + 0.12 * pulse);
	col += ring_color.rgb * ring * ring_brightness;

	// Рамка листа — без эффектов.
	vec2 e = min(UV, vec2(1.0) - UV);
	col *= smoothstep(0.03, 0.07, e.x) * smoothstep(0.03, 0.07, e.y);
	COLOR = vec4(col, 1.0);
}
