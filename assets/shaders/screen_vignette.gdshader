// Виньетка под рунами Рока: затемнение (или подкраска) к краям экрана.
// Отдельный проход от рун: те рисуются аддитивно и затемнять не умеют.
shader_type canvas_item;

uniform vec4 vig_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float vig_strength : hint_range(0.0, 1.0) = 0.0;  // непрозрачность у края
uniform float vig_start : hint_range(0.0, 1.0) = 0.35;  // где начинается затемнение
uniform float vig_softness : hint_range(0.01, 1.0) = 0.55;  // ширина растушёвки

void fragment() {
	// Круглая виньетка независимо от соотношения сторон: считаем в UV с поправкой.
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 d = (SCREEN_UV - 0.5) * vec2(res.x / res.y, 1.0);
	float r = length(d) / 0.5;  // 0 в центре, ~1 у короткой стороны
	float edge = smoothstep(vig_start, vig_start + vig_softness, r);
	COLOR = vec4(vig_color.rgb, edge * vig_strength * vig_color.a);
}
