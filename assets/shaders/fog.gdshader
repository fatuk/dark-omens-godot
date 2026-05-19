shader_type canvas_item;

// Процедурный туман для титульного экрана — многослойный дрейф.
//
// Три слоя доменно-искажённого fbm-шума на разных масштабах, скоростях и
// направлениях. Слои накапливаются «спереди назад»: перекрытия дают плотные
// клубы, разрывы остаются чистыми. Создаёт ощущение глубины и медленного
// движения тумана. Рисуется поверх фона, под логотипом и кнопками.

// Цвет тумана — холодный блёклый, под лавкрафтовский фон.
uniform vec4  fog_color : source_color = vec4(0.58, 0.63, 0.61, 1.0);
// Скорость дрейфа клубов.
uniform float speed     : hint_range(0.0, 0.15) = 0.03;
// Базовый масштаб шума: больше — мельче клубы.
uniform float scale     : hint_range(0.5, 6.0) = 1.9;
// Общая непрозрачность тумана.
uniform float density   : hint_range(0.0, 2.0) = 1.1;
// Сила «наземного» градиента: 1 — гуще снизу, 0 — равномерно.
uniform float ground    : hint_range(0.0, 1.0) = 0.65;
// Клочковатость: выше — резче клубы и чище разрывы между ними.
uniform float wispiness : hint_range(0.0, 1.0) = 0.45;

// Хеш без синуса (по мотивам Dave Hoskins) — стабилен на GL Compatibility.
vec2 hash2(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy) * 2.0 - 1.0;
}

// Градиентный шум (Перлин-стайл), примерно в диапазоне [-1, 1].
float gnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(dot(hash2(i + vec2(0.0, 0.0)), f - vec2(0.0, 0.0)),
				   dot(hash2(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0)), u.x),
			   mix(dot(hash2(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0)),
				   dot(hash2(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0)), u.x), u.y);
}

// Фрактальный шум — 4 октавы.
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * gnoise(p);
		p = p * 2.03 + vec2(19.3, 7.7);
		a *= 0.5;
	}
	return v;
}

// Один слой тумана: доменно-искажённый fbm, плотность в [0, 1].
float fog_layer(vec2 uv, float lscale, vec2 drift, vec2 seed) {
	vec2 p = uv * lscale + seed + drift;
	vec2 warp = vec2(fbm(p + vec2(1.7, 9.2)), fbm(p + vec2(8.3, 2.8)));
	return fbm(p + 2.8 * warp) * 0.5 + 0.5;
}

void fragment() {
	// Коррекция соотношения сторон — клубы не растянуты по ширине.
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 uv = UV;
	uv.x *= res.x / res.y;

	float t = TIME * speed;

	// Три слоя: крупный медленный, средний, мелкие быстрые клочья —
	// разные масштабы и направления дрейфа дают глубину и параллакс.
	float n0 = fog_layer(uv, scale * 0.55, vec2( t * 0.8,  t * 0.12), vec2(11.0,  4.0));
	float n1 = fog_layer(uv, scale * 1.05, vec2(-t * 1.2,  t * 0.30), vec2(53.0, 19.0));
	float n2 = fog_layer(uv, scale * 1.85, vec2( t * 1.8, -t * 0.45), vec2(97.0, 61.0));

	// Клочковатость: нижний порог smoothstep управляет чистотой разрывов.
	float lo = 0.40 + wispiness * 0.25;
	float a0 = smoothstep(lo, 0.95, n0);
	float a1 = smoothstep(lo, 0.95, n1);
	float a2 = smoothstep(lo, 0.95, n2);

	// Накопление слоёв: перекрытия — гуще, разрывы — прозрачные.
	float acc = a0;
	acc += (1.0 - acc) * a1;
	acc += (1.0 - acc) * a2;

	// Наземный градиент: плотнее снизу, прозрачнее к верху — логотип чистый.
	float vert = mix(1.0, smoothstep(-0.1, 0.9, UV.y), ground);

	float alpha = clamp(acc * density, 0.0, 1.0) * vert;
	COLOR = vec4(fog_color.rgb, alpha * fog_color.a);
}
