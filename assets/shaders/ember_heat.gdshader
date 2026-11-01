shader_type canvas_item;
render_mode blend_mix;

// Искра костра с жарким маревом (экран «Итоги партии»): квад частицы преломляет то,
// что под ним (screen texture), — фон вокруг искры дрожит, как воздух над огнём;
// в центре — яркое ядро цвета частицы. Цвет и затухание приходят из color_ramp
// CPUParticles2D через вершинный COLOR (во fragment COLOR — уже texture × vertex,
// поэтому берём вершинный через varying). Текстура частицы задаёт только размер квада.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float strength : hint_range(0.0, 0.03) = 0.008;  // сила смещения, доля экрана
uniform float wobble_speed : hint_range(0.0, 20.0) = 7.0;  // частота дрожания марева
uniform float core_radius : hint_range(0.0, 0.5) = 0.16;  // радиус ядра, доля квада
uniform float core_gain : hint_range(0.0, 4.0) = 1.8;  // яркость ядра

varying vec4 v_color;

void vertex() {
	v_color = COLOR;
}

void fragment() {
	vec2 d = UV - 0.5;
	float r = length(d) * 2.0;  // 0 — центр, 1 — край квада
	float halo = 1.0 - smoothstep(0.35, 1.0, r);  // мягкий край марева
	float life = clamp(v_color.a, 0.0, 1.0);
	// Линза от центра + дрожь по времени: воздух «плывёт», а не просто увеличивает.
	vec2 dir = d / max(length(d), 1e-4);
	vec2 wobble = vec2(
		sin(TIME * wobble_speed + UV.y * 18.0),
		cos(TIME * wobble_speed * 0.8 + UV.x * 18.0)
	);
	vec2 offset = (dir * (1.0 - r) + wobble * 0.5) * strength * halo * life;
	vec3 under = textureLod(screen_tex, SCREEN_UV + offset, 0.0).rgb;
	float core = 1.0 - smoothstep(0.0, core_radius * 2.0, r);
	vec3 col = under + v_color.rgb * core * core_gain * life;  // ядро светится поверх марева
	COLOR = vec4(col, halo * step(0.001, life));
}
