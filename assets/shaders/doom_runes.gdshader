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

uniform float amount : hint_range(0.0, 1.0) = 0.0;  // ведёт трек Рока (0 в начале партии)
uniform float grid : hint_range(2.0, 24.0) = 16.0;  // ячеек по короткой стороне
uniform float glyph_scale : hint_range(0.1, 2.0) = 0.84;  // базовый размер знака
uniform float size_jitter : hint_range(0.0, 1.0) = 0.45;  // разброс размера, ±доля
uniform float pos_jitter : hint_range(0.0, 1.0) = 0.35;  // сдвиг внутри ячейки
uniform float intensity : hint_range(0.0, 3.0) = 1.05;  // яркость свечения
uniform float reveal_spread : hint_range(0.01, 1.0) = 0.73;  // разброс проявления
uniform float pulse_speed : hint_range(0.0, 4.0) = 2.15;  // скорость «дыхания»
uniform float pulse_depth : hint_range(0.0, 1.0) = 0.61;  // глубина «дыхания»
uniform float drift : hint_range(0.0, 0.5) = 0.20;  // блуждание КАЖДОЙ руны (в долях ячейки)
uniform float edge_bias : hint_range(0.0, 2.0) = 1.05;  // к краям руны ярче
uniform vec4 tint : source_color = vec4(0.64, 0.85, 0.55, 1.0);

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

	vec2 cell = floor(uv * grid);
	vec2 local = fract(uv * grid) - 0.5;

	vec3 h = hash3(cell);
	// Второй хеш той же ячейки — на разброс размера и сдвига: без него знаки стоят
	// ровно по сетке и читаются как таблица, а не как проступающее письмо.
	vec3 j = hash3(cell + vec2(17.3, 41.7));
	local += (j.yz - 0.5) * pos_jitter;
	// Дрейф ХАОТИЧНЫЙ: у каждой руны своя частота и фаза по обеим осям, поэтому
	// знаки блуждают независимо. Раньше сдвигалась вся сетка целиком — это читалось
	// как ползущая таблица, а не как шевелящееся письмо.
	local += drift * vec2(
		sin(TIME * (0.17 + j.x * 0.5) + h.z * 6.2831),
		cos(TIME * (0.13 + j.y * 0.5) + h.x * 6.2831)
	);
	float gscale = max(glyph_scale * (1.0 + (j.x - 0.5) * 2.0 * size_jitter), 0.001);
	// Порог проявления свой у каждой ячейки — руны всплывают вразнобой.
	float reveal = smoothstep(h.x, h.x + reveal_spread, amount);

	// Координата внутри выбранного глифа атласа. За пределами знака — пусто.
	vec2 g = local / gscale + 0.5;
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
		float vig = mix(1.0, length(SCREEN_UV - 0.5) * 2.0, clamp(edge_bias, 0.0, 1.0));
		vig *= max(edge_bias, 1.0);

		float a = glyph * reveal * pulse * intensity * vig;
		COLOR = vec4(tint.rgb * a, a * tint.a);
	}
}
