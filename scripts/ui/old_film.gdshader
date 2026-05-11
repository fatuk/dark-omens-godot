// Постобработка «старая плёнка»: лёгкая сепия.
// Применяется на CanvasLayer поверх всего через ColorRect на весь экран.
shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

uniform float sepia_amount : hint_range(0.0, 1.0) = 0.1;

void fragment() {
	vec3 color = texture(screen_texture, SCREEN_UV).rgb;

	// Sepia: классическая матрица «коричневых» весов.
	vec3 sepia = vec3(
		dot(color, vec3(0.393, 0.769, 0.189)),
		dot(color, vec3(0.349, 0.686, 0.168)),
		dot(color, vec3(0.272, 0.534, 0.131))
	);
	color = mix(color, sepia, sepia_amount);

	COLOR = vec4(color, 1.0);
}
