// Виньетка под рунами Рока: затемнение (или подкраска) к краям экрана.
// Отдельный проход от рун: те рисуются аддитивно и затемнять не умеют.
shader_type canvas_item;

uniform vec4 vig_color : source_color = vec4(0.01, 0.03, 0.0, 1.0);
uniform float vig_strength : hint_range(0.0, 1.0) = 0.0;  // ведёт трек Рока (0 в начале партии)
uniform float vig_start : hint_range(0.0, 1.0) = 0.45;  // где начинается затемнение
uniform float vig_softness : hint_range(0.01, 1.0) = 0.85;  // ширина растушёвки
// Пульсация: для виньетки Рока выключена (глубина 0), для виньетки на грани
// смерти включается — «дыхание» тревожит сильнее ровной заливки.
uniform float vig_pulse_speed : hint_range(0.0, 6.0) = 0.0;
uniform float vig_pulse_depth : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	// Круглая виньетка независимо от соотношения сторон: считаем в UV с поправкой.
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 d = (SCREEN_UV - 0.5) * vec2(res.x / res.y, 1.0);
	float r = length(d) / 0.5;  // 0 в центре, ~1 у короткой стороны
	float edge = smoothstep(vig_start, vig_start + vig_softness, r);
	float pulse = 1.0 - vig_pulse_depth * (0.5 + 0.5 * sin(TIME * vig_pulse_speed));
	COLOR = vec4(vig_color.rgb, edge * vig_strength * pulse * vig_color.a);
}
