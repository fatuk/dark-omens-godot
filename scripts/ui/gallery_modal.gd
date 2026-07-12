class_name GalleryModal
extends CanvasLayer

## Полноэкранная «галерея» локации: слои-ассеты (assets/gallery) как в 2D-игре с
## параллаксом. Виртуальная камера (focus + zoom) наезжает к картине при наведении
## на неё и к стенду с описанием — при наведении на стенд; иначе общий план.
##
## Параллакс: ближние слои (пол/стенд) масштабируются/сдвигаются сильнее дальних
## (стена) — эффект «шага вглубь» без реального 3D. Открывается open(data) поверх
## карты; закрывается Esc / крестиком / кликом мимо.

signal closed

# Дизайн-канва (совпадает с gallery-bg.png / floor.png). Слои позиционируются в ней.
const CANVAS: Vector2 = Vector2(3344.0, 1826.0)
const GALLERY_DIR: String = "res://assets/gallery/"
const LOCATION_ART_DIR: String = "res://assets/location-sidebar/"

# Окно картины (прозрачная дыра в frame.png) — куда вписываем арт локации.
const PAINTING_OFF: Vector2 = Vector2(1154.0, 318.0)
const PAINTING_SIZE: Vector2 = Vector2(1039.0, 667.0)
const PAINTING_DEPTH: float = 0.28  # как у рамы — двигаются в связке

# Стенд с описанием и область парчмента под текст (в канве).
# Стенд опущен так, чтобы низ доходил до низа канвы (= низ экрана при cover-фите).
const PLATE_OFF: Vector2 = Vector2(537.0, 1135.0)
const PLATE_SIZE: Vector2 = Vector2(2270.0, 691.0)
const PLATE_DEPTH: float = 0.85
const PLATE_TEXT_RECT: Rect2 = Rect2(1047.0, 1275.0, 1250.0, 360.0)
# Картуш рамы (табличка снизу по центру) — куда пишем название локации.
const NAME_RECT: Rect2 = Rect2(1426.0, 979.0, 449.0, 121.0)

# Параллакс/камера.
const ZOOM_IDLE: float = 1.0
const ZOOM_FOCUS: float = 1.7  # наезд к картине/стенду
const FAR_STR: float = 0.3  # насколько зумится дальний слой (0 — стоит на месте)
const NEAR_STR: float = 1.15  # насколько зумится ближний слой (> дальнего → параллакс)
const CAM_LERP: float = 7.0  # скорость доводки камеры к цели

var _root: Control = null
var _layers: Array = []  # [{node, off, size, depth}]
var _painting: TextureRect = null
var _plate_text: Label = null
var _name_lbl: Label = null

var _focus: Vector2 = CANVAS * 0.5
var _zoom: float = ZOOM_IDLE
var _focus_target: Vector2 = CANVAS * 0.5
var _zoom_target: float = ZOOM_IDLE


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	set_process(true)


# ── Public ────────────────────────────────────────────────────────────────────


## data — та же карточка локации, что и в сайдбаре (id/name/description — ключи).
func open(data: Dictionary) -> void:
	var loc_id: String = String(data.get("id", ""))
	_painting.texture = _location_art(loc_id)
	_plate_text.text = String(data.get("description", ""))
	_name_lbl.text = String(data.get("name", ""))
	# Стартуем с общего плана и мгновенно раскладываем (без «прыжка» на первом кадре).
	_focus = CANVAS * 0.5
	_zoom = ZOOM_IDLE
	_focus_target = _focus
	_zoom_target = _zoom
	_apply_layout()
	visible = true
	# Проявление под летящей картинкой сайдбара — плавный переход, а не рывок.
	_root.modulate.a = 0.0
	create_tween().tween_property(_root, "modulate:a", 1.0, 0.35)


func close() -> void:
	closed.emit()
	queue_free()


# ── Сборка слоёв ──────────────────────────────────────────────────────────────


func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP  # ловим ввод, карта под нами не реагирует
	add_child(_root)

	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.02, 0.02, 0.03, 1.0)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(backdrop)

	# Порядок = z-порядок (дальше → раньше рисуется).
	# Пол — самым первым, ПОД стеной: низ стены (плинтус) перекрывает верх пола.
	_add_layer("Floor", "floor.png", Vector2(0, 1612), 0.7)
	_add_layer("GalleryBg", "gallery-bg.png", Vector2(0, 0), 0.0)

	# Картина локации — между стеной и рамой (рама с прозрачным центром поверх).
	_painting = TextureRect.new()
	_painting.name = "Painting"
	_painting.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_painting.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_painting.clip_contents = true
	_painting.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_painting.size = PAINTING_SIZE
	_root.add_child(_painting)
	_layers.append(
		{"node": _painting, "off": PAINTING_OFF, "size": PAINTING_SIZE, "depth": PAINTING_DEPTH}
	)

	_add_layer("Frame", "frame.png", Vector2(981, 150), 0.28)

	# Название локации — в картуше рамы (маленькая табличка снизу по центру рамы).
	_name_lbl = Label.new()
	_name_lbl.name = "NameLabel"
	_name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_lbl.add_theme_font_size_override("font_size", 46)
	_name_lbl.add_theme_color_override("font_color", Color(0.20, 0.15, 0.08))
	_name_lbl.size = NAME_RECT.size
	_name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_name_lbl)
	_layers.append(
		{"node": _name_lbl, "off": NAME_RECT.position, "size": NAME_RECT.size, "depth": 0.28}
	)

	_add_layer("Statue", "statue.png", Vector2(80, 75), 0.55)
	_add_layer("Plate", "plate.png", PLATE_OFF, PLATE_DEPTH)

	# Описание — на парчменте стенда (движется вместе со стендом, та же глубина).
	_plate_text = Label.new()
	_plate_text.name = "PlateText"
	_plate_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_plate_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_plate_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_plate_text.add_theme_font_size_override("font_size", 52)
	_plate_text.add_theme_color_override("font_color", Color(0.16, 0.11, 0.06))
	_plate_text.size = PLATE_TEXT_RECT.size
	_plate_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_plate_text)
	_layers.append(
		{
			"node": _plate_text,
			"off": PLATE_TEXT_RECT.position,
			"size": PLATE_TEXT_RECT.size,
			"depth": PLATE_DEPTH
		}
	)

	# Крестик закрытия — в экранных координатах (не слой, не параллаксит).
	var close_btn := Button.new()
	close_btn.name = "CloseBtn"
	close_btn.custom_minimum_size = Vector2(48, 48)
	UIStyle.style_modal_close_button(close_btn)
	close_btn.anchor_left = 1.0
	close_btn.anchor_right = 1.0
	close_btn.offset_left = -72.0
	close_btn.offset_top = 24.0
	close_btn.offset_right = -24.0
	close_btn.offset_bottom = 72.0
	close_btn.pressed.connect(close)
	_root.add_child(close_btn)


func _add_layer(node_name: String, file: String, off: Vector2, depth: float) -> void:
	var tex: Texture2D = load(GALLERY_DIR + file)
	var tr := TextureRect.new()
	tr.name = node_name
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.size = tex.get_size()
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(tr)
	_layers.append({"node": tr, "off": off, "size": tex.get_size(), "depth": depth})


# ── Камера / параллакс ────────────────────────────────────────────────────────


func _process(delta: float) -> void:
	if not visible:
		return
	_update_hover()
	var t: float = minf(1.0, CAM_LERP * delta)
	_zoom = lerpf(_zoom, _zoom_target, t)
	_focus = _focus.lerp(_focus_target, t)
	_apply_layout()


# Масштаб слоя = базовый cover-фит × зум с учётом глубины. Позиция такова, что
# точка focus в канве всегда оказывается в центре экрана (наезд «к точке»).
func _apply_layout() -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var base: float = maxf(vp.x / CANVAS.x, vp.y / CANVAS.y)  # cover
	var center: Vector2 = vp * 0.5
	for l_v: Variant in _layers:
		var l: Dictionary = l_v
		var s: float = base * (1.0 + (_zoom - 1.0) * lerpf(FAR_STR, NEAR_STR, float(l.depth)))
		var node: Control = l.node
		node.scale = Vector2(s, s)
		node.position = center + (Vector2(l.off) - _focus) * s


# Зона (картина / стенд) под курсором → цель камеры. Ничего — общий план.
func _update_hover() -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var base: float = maxf(vp.x / CANVAS.x, vp.y / CANVAS.y)
	var center: Vector2 = vp * 0.5
	var m: Vector2 = _root.get_global_mouse_position()
	if _zone_rect(PAINTING_OFF, PAINTING_SIZE, PAINTING_DEPTH, base, center).has_point(m):
		_focus_target = PAINTING_OFF + PAINTING_SIZE * 0.5
		_zoom_target = ZOOM_FOCUS
	elif _zone_rect(PLATE_OFF, PLATE_SIZE, PLATE_DEPTH, base, center).has_point(m):
		_focus_target = PLATE_TEXT_RECT.position + PLATE_TEXT_RECT.size * 0.5
		_zoom_target = ZOOM_FOCUS
	else:
		_focus_target = CANVAS * 0.5
		_zoom_target = ZOOM_IDLE


func _zone_rect(off: Vector2, size: Vector2, depth: float, base: float, center: Vector2) -> Rect2:
	var s: float = base * (1.0 + (_zoom - 1.0) * lerpf(FAR_STR, NEAR_STR, depth))
	return Rect2(center + (off - _focus) * s, size * s)


# ── Внутреннее ────────────────────────────────────────────────────────────────


func _location_art(loc_id: String) -> Texture2D:
	if loc_id.is_empty():
		return null
	var path: String = "%s%s.png" % [LOCATION_ART_DIR, loc_id]
	return load(path) if ResourceLoader.exists(path) else null


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
