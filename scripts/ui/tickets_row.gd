class_name TicketsRow
extends HBoxContainer

## Ряд билетов «брошенной стопкой»: поездные + морские, с нахлёстом, лёгким
## наклоном вразнобой и мягкой тенью под каждым. Переиспользуется в InfoBar
## (лобби/пикер) и ActionPanel (карта).
##
## API:
##   set_counts(train, ship) — перестроить ряд под N поездных + M морских билетов
##   ticket_height()         — высота билета (px) для резерва места под ряд

# Билеты @2× — выводим с _SCALE. PNG чуть разного размера (train 161×146,
# ocean 152×143) — нормализуем по ВЫСОТЕ.
const _TRAIN_TEX: Texture2D = preload("res://assets/train-ticket.png")
const _OCEAN_TEX: Texture2D = preload("res://assets/ocean-ticket.png")

const _SCALE: float = 0.34  # высота билета = текстура.h * _SCALE
const _TILT_DEG: float = 7.0  # наклон второго+ билетов («брошенная стопка»)
const _OVERLAP: int = -20  # нахлёст билетов (отрицательный separation)
const _SHADOW_OFFSET := Vector2(-6.0, 6.0)  # сдвиг тени влево-вниз
const _SHADOW_ALPHA: float = 0.55
const _SHADOW_BLUR: float = 6.0  # радиус размытия тени (в TEXTURE_PIXEL_SIZE)

# Тень билета: 5×5 box-blur alpha-маски текстуры → мягкий чёрный силуэт.
const _SHADOW_SHADER := """
shader_type canvas_item;
uniform float blur : hint_range(0.0, 32.0) = 6.0;
uniform float shadow_alpha : hint_range(0.0, 1.0) = 0.55;
void fragment() {
	vec2 stp = TEXTURE_PIXEL_SIZE * blur;
	float a = 0.0;
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			a += texture(TEXTURE, UV + vec2(float(x), float(y)) * stp).a;
		}
	}
	COLOR = vec4(0.0, 0.0, 0.0, (a / 25.0) * shadow_alpha);
}
"""

var _shadow_mat: ShaderMaterial


func _init() -> void:
	name = "TicketsRow"
	add_theme_constant_override("separation", _OVERLAP)
	alignment = BoxContainer.ALIGNMENT_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_shadow_mat = _make_shadow_material()


## Высота билета (для custom_minimum_size.y ряда-контейнера). Статик — чтобы
## зарезервировать место под ряд без создания инстанса.
static func ticket_height_px() -> float:
	return _TRAIN_TEX.get_size().y * _SCALE


## Перестроить ряд: train_n поездных + ship_n морских билетов.
func set_counts(train_n: int, ship_n: int) -> void:
	for c in get_children():
		c.queue_free()
	var h: float = ticket_height_px()
	var idx: int = 0
	for i in range(maxi(0, train_n)):
		add_child(_make_ticket(_TRAIN_TEX, "TrainTicket%d" % i, h, _tilt(idx)))
		idx += 1
	for i in range(maxi(0, ship_n)):
		add_child(_make_ticket(_OCEAN_TEX, "OceanTicket%d" % i, h, _tilt(idx)))
		idx += 1


# Наклон для эффекта брошенной стопки: первый билет ровно, дальше — вразнобой.
func _tilt(idx: int) -> float:
	if idx == 0:
		return 0.0
	return _TILT_DEG * (1.0 if idx % 2 == 1 else -1.0)


func _make_ticket(tex: Texture2D, node_name: String, height_px: float, tilt_deg: float) -> Control:
	var tex_size: Vector2 = tex.get_size()
	var ticket_size := Vector2(height_px * tex_size.x / tex_size.y, height_px)

	# holder — прямой ребёнок HBox. Контейнер сбрасывает rotation своих детей
	# (fit_child_in_rect), поэтому наклоняем вложенный Tilt, а не holder.
	var holder := Control.new()
	holder.name = node_name
	holder.custom_minimum_size = ticket_size
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var tilt := Control.new()
	tilt.name = "Tilt"
	tilt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tilt.pivot_offset = ticket_size * 0.5
	tilt.rotation_degrees = tilt_deg
	tilt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(tilt)

	# Тень — силуэт-копия билета (blur-шейдер), сдвинута влево-вниз, ПОД билетом.
	var shadow := TextureRect.new()
	shadow.name = "Shadow"
	shadow.texture = tex
	shadow.material = _shadow_mat
	shadow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shadow.stretch_mode = TextureRect.STRETCH_SCALE
	shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shadow.offset_left = _SHADOW_OFFSET.x
	shadow.offset_right = _SHADOW_OFFSET.x
	shadow.offset_top = _SHADOW_OFFSET.y
	shadow.offset_bottom = _SHADOW_OFFSET.y
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tilt.add_child(shadow)

	var ticket := TextureRect.new()
	ticket.name = "Ticket"
	ticket.texture = tex
	ticket.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ticket.stretch_mode = TextureRect.STRETCH_SCALE
	ticket.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ticket.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tilt.add_child(ticket)
	return holder


func _make_shadow_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = _SHADOW_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("blur", _SHADOW_BLUR)
	mat.set_shader_parameter("shadow_alpha", _SHADOW_ALPHA)
	return mat
