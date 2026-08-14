// Мягкая тень под спрайтом: размывает АЛЬФУ исходной текстуры и красит её в чёрный.
// Вешается на спрайт-двойник позади оригинала (show_behind_parent), поэтому форма
// тени всегда повторяет форму медальона — хоть круг, хоть что угодно.
//
// Двойник растягивается чуть шире оригинала (SHADOW_GROW в map_layer): размытие
// уходит за край текстуры, а спрайт рисуется только в своих границах — без запаса
// тень обрезало бы ровно по кромке.
shader_type canvas_item;

uniform float radius : hint_range(0.0, 16.0) = 4.0;  // размытие в текселях текстуры
uniform float darkness : hint_range(0.0, 1.0) = 0.55;  // непрозрачность тени

// Прозрачность узла тянем через varying: в vertex COLOR — это ещё чистый modulate
// (в fragment он уже перемножен с текстурой). Нужно, чтобы гаснущий медальон
// уводил за собой и тень, а не оставлял её висеть.
varying vec4 v_modulate;

void vertex() {
	v_modulate = COLOR;
}

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE * radius;
	// 3×3 отсчёта с весами Гаусса (1 2 1 / 2 4 2 / 1 2 1) — кромке медальона хватает.
	float a = texture(TEXTURE, UV).a * 4.0;
	a += texture(TEXTURE, UV + vec2(px.x, 0.0)).a * 2.0;
	a += texture(TEXTURE, UV - vec2(px.x, 0.0)).a * 2.0;
	a += texture(TEXTURE, UV + vec2(0.0, px.y)).a * 2.0;
	a += texture(TEXTURE, UV - vec2(0.0, px.y)).a * 2.0;
	a += texture(TEXTURE, UV + px).a;
	a += texture(TEXTURE, UV - px).a;
	a += texture(TEXTURE, UV + vec2(px.x, -px.y)).a;
	a += texture(TEXTURE, UV + vec2(-px.x, px.y)).a;
	COLOR = vec4(0.0, 0.0, 0.0, (a / 16.0) * darkness * v_modulate.a);
}
