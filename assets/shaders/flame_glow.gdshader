shader_type canvas_item;
render_mode blend_add;

// Мягкое тёплое свечение «живого» пламени поверх нарисованного огонька в арте
// лавки (лампа слева, свеча справа). Additive-глоу мерцает и чуть пляшет —
// иллюзия движения огня без перерисовки фона. Рисуется под картами.

uniform vec4 glow_color : source_color = vec4(1.0, 0.66, 0.30, 1.0);
uniform float intensity : hint_range(0.0, 3.0) = 1.0;
uniform float flicker_speed : hint_range(0.0, 20.0) = 7.0;
uniform float sway : hint_range(0.0, 0.5) = 0.10;  // размах пляса огонька
uniform float stretch : hint_range(0.3, 1.0) = 0.62;  // <1 — вытянуть по вертикали
uniform float seed = 0.0;  // сдвиг фазы — чтобы огни мерцали не в такт

float hash(float n) {
	return fract(sin(n) * 43758.5453123);
}

// Сглаженный value-noise 1D.
float vnoise(float x) {
	float i = floor(x);
	float f = fract(x);
	float u = f * f * (3.0 - 2.0 * f);
	return mix(hash(i), hash(i + 1.0), u);
}

void fragment() {
	float t = TIME * flicker_speed + seed;
	// Пляс огонька: горизонтальный снос + лёгкий вертикальный.
	vec2 uv = UV - vec2(0.5);
	uv.x -= (vnoise(t * 0.9) - 0.5) * sway;
	uv.y -= (vnoise(t * 0.7 + 5.0) - 0.5) * sway * 0.5;
	uv.y *= stretch;  // вытянуть пламя вверх-вниз
	float d = length(uv) * 2.0;  // 0 в центре, 1 у края
	float glow = pow(clamp(1.0 - d, 0.0, 1.0), 2.4);
	// Мерцание яркости: сумма двух шумов на разных частотах.
	float fl = 0.68 + 0.22 * vnoise(t) + 0.14 * vnoise(t * 2.7 + 3.1);
	vec3 col = glow_color.rgb * glow * intensity * fl;
	COLOR = vec4(col, 1.0);  // blend_add: складывается с фоном, спад — в rgb
}
