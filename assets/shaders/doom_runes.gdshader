// Руны Ктулху поверх экрана: чем выше `amount`, тем больше их проступает.
// Привязка к треку Рока — снаружи (пока крутится вручную в панели тюнинга).
//
// Глифы НЕ процедурные: слой печёт атлас из шрифта CTHUR (тот же, что в
// рунном «скрэмбле» смены значений) в SubViewport, шейдер его тайлит. Экран
// режется на ячейки, каждая по хешу берёт свой глиф атласа — знаки не повторяются
// соседями. Порог проявления у ячейки тоже свой, поэтому руны всплывают
// вразнобой, как проявляющаяся плёнка, а не разом.
shader_type canvas_item;
render_mode blend_add;

uniform sampler2D runes_tex : filter_linear_mipmap, repeat_disable;
uniform float atlas : hint_range(1.0, 8.0) = 4.0;  // глифов в ряду атласа

uniform float amount : hint_range(0.0, 1.0) = 0.0;  // сколько рун проступило
uniform float grid : hint_range(2.0, 24.0) = 7.0;  // ячеек по короткой стороне
uniform float glyph_scale : hint_range(0.1, 2.0) = 0.8;  // размер знака в ячейке
uniform float intensity : hint_range(0.0, 3.0) = 1.0;  // яркость свечения
uniform float reveal_spread : hint_range(0.01, 1.0) = 0.35;  // разброс проявления
uniform float pulse_speed : hint_range(0.0, 4.0) = 0.6;  // скорость «дыхания»
uniform float pulse_depth : hint_range(0.0, 1.0) = 0.35;  // глубина «дыхания»
uniform float drift : hint_range(0.0, 0.5) = 0.03;  // медленное блуждание сетки
uniform float vignette : hint_range(0.0, 2.0) = 0.9;  // к краям руны ярче
uniform vec4 tint : source_color = vec4(0.35, 0.85, 0.55, 1.0);

// Хеш ячейки → три независимых 0..1 (какой глиф, порог проявления, фаза пульса).
vec3 hash3(vec2 c) {
	vec3 p = fract(vec3(c.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yzz) * p.zyx);
}

void fragment() {
	// Квадратные ячейки при любом соотношении сторон: тянем по короткой стороне.
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	float aspect = res.x / res.y;
	vec2 uv = SCREEN_UV;
	uv.x *= aspect;

	// Очень медленный дрейф — сетка не «прибита» к пикселям экрана.
	uv += vec2(sin(TIME * 0.05), cos(TIME * 0.037)) * drift;

	vec2 cell = floor(uv * grid);
	vec2 local = fract(uv * grid) - 0.5;

	vec3 h = hash3(cell);
	// Порог проявления свой у каждой ячейки — руны всплывают вразнобой.
	float reveal = smoothstep(h.x, h.x + reveal_spread, amount);

	// Координата внутри выбранного глифа атласа. За пределами знака — пусто.
	vec2 g = local / max(glyph_scale, 0.001) + 0.5;
	if (reveal <= 0.001 || g.x < 0.0 || g.x > 1.0 || g.y < 0.0 || g.y > 1.0) {
		COLOR = vec4(0.0);
	} else {
		float n = max(atlas, 1.0);
		float idx = floor(h.y * n * n);
		vec2 acell = vec2(mod(idx, n), floor(idx / n));
		// Поджимаем края клетки атласа: иначе фильтрация тянет соседний глиф.
		vec2 auv = (acell + clamp(g, 0.004, 0.996)) / n;
		float glyph = texture(runes_tex, auv).a;

		// «Дыхание»: у каждой руны своя фаза.
		float ph = h.z * 6.2831;
		float pulse = 1.0 - pulse_depth * (0.5 + 0.5 * sin(TIME * pulse_speed + ph));

		// К краям экрана руны заметнее — центр остаётся читаемым.
		float vig = mix(1.0, length(SCREEN_UV - 0.5) * 2.0, clamp(vignette, 0.0, 1.0));
		vig *= max(vignette, 1.0);

		float a = glyph * reveal * pulse * intensity * vig;
		COLOR = vec4(tint.rgb * a, a * tint.a);
	}
}
