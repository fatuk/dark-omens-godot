// Мягкая тень под спрайтом: размывает АЛЬФУ исходной текстуры и красит её в чёрный.
// Вешается на спрайт-двойник позади оригинала (show_behind_parent), поэтому форма
// тени всегда повторяет форму медальона — хоть круг, хоть что угодно.
//
// Медальоны нарисованы В УПОР к краям текстуры (круг вписан в квадрат и касается
// его сторон), поэтому размытию некуда расти: без запаса тень обрезало плоско по
// кромке спрайта. Двойник растягиваем на inset, а содержимое тем же множителем
// ужимаем внутрь кадра — получается прозрачная рамка, в которой живёт размытие,
// при неизменном размере самого медальона.
shader_type canvas_item;

uniform float radius : hint_range(0.0, 16.0) = 4.0;  // размытие в текселях текстуры
uniform float darkness : hint_range(0.0, 1.0) = 0.55;  // непрозрачность тени
uniform float inset : hint_range(1.0, 2.0) = 1.13;  // ставит map_layer: grow / spread

// Прозрачность узла тянем через varying: в vertex COLOR — это ещё чистый modulate
// (в fragment он уже перемножен с текстурой). Нужно, чтобы гаснущий медальон
// уводил за собой и тень, а не оставлял её висеть.
varying vec4 v_modulate;

void vertex() {
	v_modulate = COLOR;
}

// Альфа текстуры с ЯВНЫМ нулём за её пределами. Без этого края тянулись бы
// клампом, а край у медальона непрозрачный — рамку залило бы силуэтом.
//
// Сэмплер передаём параметром: встроенный TEXTURE виден только в fragment()/vertex(),
// внутри своих функций его нет. Без ветвления и через textureLod: выборка с неявным
// LOD внутри условия запрещена, а нулевой уровень заодно гарантирует, что мипмапы
// спрайта не подменят кромку более мелким уровнем.
float alpha_at(sampler2D tex, vec2 uv) {
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	return textureLod(tex, clamp(uv, vec2(0.0), vec2(1.0)), 0.0).a * inside;
}

void fragment() {
	vec2 uv = (UV - 0.5) * inset + 0.5;  // содержимое ужимаем внутрь рамки
	vec2 px = TEXTURE_PIXEL_SIZE * radius;
	// 3×3 отсчёта с весами Гаусса (1 2 1 / 2 4 2 / 1 2 1) — кромке медальона хватает.
	float a = alpha_at(TEXTURE, uv) * 4.0;
	a += alpha_at(TEXTURE, uv + vec2(px.x, 0.0)) * 2.0;
	a += alpha_at(TEXTURE, uv - vec2(px.x, 0.0)) * 2.0;
	a += alpha_at(TEXTURE, uv + vec2(0.0, px.y)) * 2.0;
	a += alpha_at(TEXTURE, uv - vec2(0.0, px.y)) * 2.0;
	a += alpha_at(TEXTURE, uv + px);
	a += alpha_at(TEXTURE, uv - px);
	a += alpha_at(TEXTURE, uv + vec2(px.x, -px.y));
	a += alpha_at(TEXTURE, uv + vec2(-px.x, px.y));
	COLOR = vec4(0.0, 0.0, 0.0, (a / 16.0) * darkness * v_modulate.a);
}
