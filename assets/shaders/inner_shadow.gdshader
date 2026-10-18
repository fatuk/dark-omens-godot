shader_type canvas_item;

// Внутренняя тень по краям прямоугольника: картинка «утоплена» в рамку, края уходят
// в темноту. Кладётся ColorRect'ом ПОВЕРХ TextureRect (сам цвет ColorRect не важен —
// COLOR перезаписывается). Размеры — доли стороны; справа шире, чтобы арт мягко
// переходил в тёмную текстовую панель модалки Мифов.

uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.9);
uniform float size_left = 0.08;
uniform float size_right = 0.2;
uniform float size_top = 0.1;
uniform float size_bottom = 0.12;
uniform float curve = 1.8;  // >1 — тень плотнее у самого края и быстрее сходит на нет

void fragment() {
	float l = 1.0 - smoothstep(0.0, size_left, UV.x);
	float r = 1.0 - smoothstep(0.0, size_right, 1.0 - UV.x);
	float t = 1.0 - smoothstep(0.0, size_top, UV.y);
	float b = 1.0 - smoothstep(0.0, size_bottom, 1.0 - UV.y);
	float a = pow(max(max(l, r), max(t, b)), curve);
	COLOR = vec4(shadow_color.rgb, shadow_color.a * a);
}
