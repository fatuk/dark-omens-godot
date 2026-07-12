class_name GalleryModal
extends CanvasLayer

## Полноэкранная «галерея» локации: слои-ассеты (assets/gallery) как в 2D-игре с
## параллаксом. Виртуальная камера (focus + zoom) наезжает к картине по клику на неё
## и к стенду с описанием — по клику на стенд; повторный клик / клик мимо — общий план.
##
## Параллакс: ближние слои (пол/стенд) масштабируются/сдвигаются сильнее дальних
## (стена) — эффект «шага вглубь» без реального 3D. Открывается open(data) поверх
## карты; закрывается Esc / крестиком / кликом мимо.

signal closed

# Дизайн-канва (совпадает с gallery-bg.png / floor.png). Слои позиционируются в ней.
const CANVAS: Vector2 = Vector2(3344.0, 1826.0)
const GALLERY_DIR: String = "res://assets/gallery/"
const LOCATION_ART_DIR: String = "res://assets/location-sidebar/"

# Окно картины: арт слегка ЗАХОДИТ под кромку рамы (у frame.png мягкий feather-край),
# чтобы не оставалось зазора/просвета стены. Габарит больше прозрачной дыры на ~30px.
const PAINTING_OFF: Vector2 = Vector2(1124.0, 328.0)
const PAINTING_SIZE: Vector2 = Vector2(1099.0, 727.0)
const PAINTING_DEPTH: float = 0.28  # как у рамы — двигаются в связке
# Лампа-подсветка над картиной (lamp.png 533×107): рисуется поверх картины/рамы,
# но параллаксит как СТЕНА (глубина 0.0) — настенный светильник, часть зала.
const LAMP_OFF: Vector2 = Vector2(1407.0, 122.0)
# При наезде лампа поднимается на LAMP_RISE×(zoom−1) экранных px — чтобы не наползать
# на крест рамы, который на глубине 0.28 уходит вверх сильнее лампы.
const LAMP_RISE: float = 90.0
# При наезде лампа дополнительно чуть увеличивается (масштаб вокруг центра).
const LAMP_GROW: float = 0.18
# Крепление лампы (lamp-mount.png 64×38): на глубине рамы (0.28), на кресте. При
# наезде тоже поднимается (MOUNT_RISE) — чуть меньше, чем нужно, чтобы почти зайти
# за лампу (мелкий остаточный зазор, крепление уходит под лампу).
const MOUNT_OFF: Vector2 = Vector2(1641.0, 178.0)
const MOUNT_RISE: float = 30.0

# Стенд с описанием и область парчмента под текст (в канве).
# Стенд опущен так, чтобы низ доходил до низа канвы (= низ экрана при cover-фите).
const PLATE_OFF: Vector2 = Vector2(537.0, 1175.0)
const PLATE_SIZE: Vector2 = Vector2(2270.0, 691.0)
const PLATE_DEPTH: float = 0.85
# При наезде на стенд фокусируемся ВЫШЕ центра текста на столько px канвы — тогда
# сам стенд оказывается ниже на экране (точка фокуса уходит в центр экрана).
const PLATE_FOCUS_UP: float = 110.0
# Читаемая область парчмента — трапеция (перспектива наклонённого стенда) в канве.
# Верх уже/дальше, низ шире/ближе → текст ложится на поверхность с keystone-искажением.
# Углы/шрифт/поля вынесены в тюнинг (Ctrl+M → «ГАЛЕРЕЯ · ТЕКСТ»); значения запекаются.
static var TEXT_QUAD_TL: Vector2 = Vector2(1080.0, 1215.0)
static var TEXT_QUAD_TR: Vector2 = Vector2(2220.0, 1210.0)
static var TEXT_QUAD_BR: Vector2 = Vector2(2280.0, 1685.0)
static var TEXT_QUAD_BL: Vector2 = Vector2(1005.0, 1675.0)
static var TEXT_FONT_SIZE: float = 46.0  # базовый (макс) размер шрифта описания
static var TEXT_MARGIN: Vector2 = Vector2(70.0, 40.0)  # поля текста внутри SubViewport
const TEXT_FONT_MIN: int = 22  # ниже не ужимаем (длинный текст авто-подгоняется)
const TEXT_VP_SIZE: Vector2i = Vector2i(1200, 760)  # плоский холст текста (до варпа на трапецию)

# Перспективно-корректный сэмпл текстуры текста: UV делим на вес q (в COLOR.r),
# интерполированный аффинно — даёт keystone (верх ужат сильнее низа).
const _PERSPECTIVE_SHADER: String = """
shader_type canvas_item;
render_mode blend_mix;
uniform sampler2D tex : filter_linear;
void fragment() {
	float q = COLOR.r;
	vec2 uv = UV / q;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		COLOR = vec4(0.0);
	} else {
		COLOR = texture(tex, uv);
	}
}
"""
# Табличка названия (title-frame.png) — отдельная рамка-нейнпатч, тянется под длину.
const NAME_FONT_SIZE: int = 46
const NAME_FONT_MIN: int = 26  # если даже на макс. ширине не влезает — ужимаем шрифт
const TITLE_CENTER: Vector2 = Vector2(1673.5, 1090.0)  # центр таблички в канве
const TITLE_HEIGHT: float = 150.0
const TITLE_MIN_W: float = 470.0  # ширина под короткие названия (≈натуральная)
const TITLE_MAX_W: float = 1180.0  # дальше не растягиваем — ужимаем шрифт
const TITLE_PAD: float = 120.0  # отступ текста от края рамки (под орнамент углов)
# Поля нейнпатча (несжимаемые орнаментные углы title-frame.png 478×186).
const TITLE_PATCH: Rect2 = Rect2(100.0, 55.0, 100.0, 55.0)  # left, top, right, bottom

# Параллакс/камера.
const ZOOM_IDLE: float = 1.0
const ZOOM_FOCUS: float = 1.7  # наезд к картине/стенду
const FAR_STR: float = 0.3  # насколько зумится дальний слой (0 — стоит на месте)
const NEAR_STR: float = 1.15  # насколько зумится ближний слой (> дальнего → параллакс)
const CAM_LERP: float = 7.0  # скорость доводки камеры к цели
# Базовый масштаб канвы (cover-фит); 1.0 — края (потолок/пол) видны как есть.
const OVERSCAN: float = 1.0

var _root: Control = null
var _layers: Array = []  # [{node, off, size, depth}]
var _painting: TextureRect = null
var _lamp: TextureRect = null  # лампа — доп. подъём при наезде (см. _apply_layout)
var _mount: TextureRect = null  # крепление лампы — свой подъём при наезде
var _plate_text: Label = null  # живёт внутри _text_vp (рендерится в текстуру)
var _text_vp: SubViewport = null  # плоский рендер описания
var _text_mesh: MeshInstance2D = null  # варп текста на трапецию парчмента
var _name_lbl: Label = null
var _title_ctrl: Control = null  # табличка названия (рамка+текст), тянется под длину
var _title_np: NinePatchRect = null
var _title_layer: Dictionary = {}  # запись слоя таблички (обновляем off/размер в _set_title)

var _focus: Vector2 = CANVAS * 0.5
var _zoom: float = ZOOM_IDLE
var _focus_target: Vector2 = CANVAS * 0.5
var _zoom_target: float = ZOOM_IDLE
var _focused: String = ""  # "", "painting" или "plate" — на что наведён клик-зум

# Интро: галерея открывается наезженной на картину (совпадает с концом летящей
# картинки сайдбара) и отъезжает к общему плану. Пока идёт — ховер отключён.
var _intro: bool = false
var _intro_start_zoom: float = 1.0
var _intro_start_focus: Vector2 = CANVAS * 0.5

# Закрытие — обратное интро: камера наезжает обратно на картину и гаснет.
var _closing: bool = false
var _close_start_zoom: float = 1.0
var _close_start_focus: Vector2 = CANVAS * 0.5

var _prev_msaa: int = Viewport.MSAA_DISABLED  # вернём MSAA вьюпорта при закрытии


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("gallery_modal")  # тюнинг текста стенда дёргает группу
	_build()
	set_process(true)


# ── Public ────────────────────────────────────────────────────────────────────


## data — та же карточка локации, что и в сайдбаре (id/name/description — ключи).
func open(data: Dictionary) -> void:
	var loc_id: String = String(data.get("id", ""))
	_painting.texture = _location_art(loc_id)
	_plate_text.text = String(data.get("description", ""))
	_fit_description_font()  # длинное описание ужимаем, чтобы влезло на парчмент
	_set_title(String(data.get("name", "")))  # табличка названия тянется под длину

	# Старт — наезд на картину (её экранный размер ≈ конец летящей картинки), фокус
	# на её центре. Дальше камера отъезжает к общему плану → плавное перетекание.
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_intro_start_zoom = _intro_zoom(vp)
	_intro_start_focus = PAINTING_OFF + PAINTING_SIZE * 0.5
	_zoom = _intro_start_zoom
	_focus = _intro_start_focus
	_zoom_target = ZOOM_IDLE  # после интро _process продолжит с общего плана
	_focus_target = CANVAS * 0.5
	_intro = true
	_apply_layout()
	visible = true
	# MSAA 2D на время галереи — сглаживает края текст-меша и геометрии при зуме.
	_prev_msaa = get_viewport().msaa_2d
	get_viewport().msaa_2d = Viewport.MSAA_4X

	# Галерея открывается уже ПОСЛЕ того, как картинка вылетела и растворилась
	# (стык на картине): проявляемся с наезда на картину и отъезжаем к общему плану.
	_root.modulate.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_root, "modulate:a", 1.0, 0.3)
	tw.tween_method(_intro_progress, 0.0, 1.0, 0.75).set_trans(Tween.TRANS_CUBIC).set_ease(
		Tween.EASE_OUT
	)
	tw.chain().tween_callback(func() -> void: _intro = false)


# Зум, при котором картина на экране ≈ размер конца летящей картинки (vp.x*0.55).
func _intro_zoom(vp: Vector2) -> float:
	var base: float = _base_scale(vp)
	var want: float = (vp.x * 0.55) / maxf(1.0, PAINTING_SIZE.x * base)  # нужный zoomfac
	var k: float = lerpf(FAR_STR, NEAR_STR, PAINTING_DEPTH)
	return 1.0 + (want - 1.0) / k


# Прогресс интро 0..1: интерполируем зум/фокус от наезда к общему плану.
func _intro_progress(t: float) -> void:
	_zoom = lerpf(_intro_start_zoom, ZOOM_IDLE, t)
	_focus = _intro_start_focus.lerp(CANVAS * 0.5, t)
	_apply_layout()


func close() -> void:
	if _closing:
		return
	_closing = true  # _process замирает — камерой рулит твин
	_close_start_zoom = _zoom
	_close_start_focus = _focus
	var tw := create_tween().set_parallel(true)
	tw.tween_method(_close_progress, 0.0, 1.0, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(
		Tween.EASE_IN
	)
	tw.tween_property(_root, "modulate:a", 0.0, 0.35)
	# Сигнал closed — ПОСЛЕ растворения (карта затем вернёт картинку в сайдбар),
	# затем удаляемся.
	tw.chain().tween_callback(_finish_close)


func _finish_close() -> void:
	closed.emit()
	queue_free()


func _exit_tree() -> void:
	# Возвращаем MSAA вьюпорта, каким он был до галереи (на случай любого закрытия).
	var vp := get_viewport()
	if vp != null:
		vp.msaa_2d = _prev_msaa as Viewport.MSAA


# Прогресс закрытия 0..1: наезд обратно на картину + затухание (обратное интро).
func _close_progress(t: float) -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_zoom = lerpf(_close_start_zoom, _intro_zoom(vp), t)
	_focus = _close_start_focus.lerp(PAINTING_OFF + PAINTING_SIZE * 0.5, t)
	_apply_layout()


# ── Сборка слоёв ──────────────────────────────────────────────────────────────


func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP  # ловим ввод, карта под нами не реагирует
	# Мипмапы: слои — крупные PNG, на общем плане рисуются уменьшенными; без мипмап
	# мелкая позолота «шумит»/алиасит при зуме. Дети наследуют фильтр от Root.
	_root.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_root.gui_input.connect(_on_root_input)  # клик по зонам → наезд/отъезд камеры
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

	_add_layer("Frame", "frame.png", Vector2(981, 190), 0.28)
	_mount = _add_layer("LampMount", "lamp-mount.png", MOUNT_OFF, 0.28)  # крепление на кресте
	# Лампа на стене (глубина 0.0), но при наезде поднимается (LAMP_RISE), чтобы не
	# наползать на крест рамы (та на глубине 0.28 и уходит вверх сильнее).
	_lamp = _add_layer("Lamp", "lamp.png", LAMP_OFF, 0.0)

	_build_title()  # табличка названия (нейнпатч + текст), под картиной

	_add_layer("Statue", "statue.png", Vector2(20, 75), 0.55)
	_add_layer("Plate", "plate.png", PLATE_OFF, PLATE_DEPTH)

	_build_text_plate()

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


# Описание рисуем плоско в SubViewport, затем варпим на трапецию парчмента
# перспективным мешем (текст ложится на наклонённую поверхность стенда).
func _build_text_plate() -> void:
	_text_vp = SubViewport.new()
	_text_vp.name = "TextViewport"
	_text_vp.size = TEXT_VP_SIZE
	_text_vp.transparent_bg = true
	_text_vp.disable_3d = true
	_text_vp.gui_disable_input = true
	_text_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_text_vp)  # рендерится офскрин (не как Control-слой)

	_plate_text = Label.new()
	_plate_text.name = "PlateText"
	_plate_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_plate_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_plate_text.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_plate_text.add_theme_font_size_override("font_size", int(TEXT_FONT_SIZE))
	_plate_text.add_theme_color_override("font_color", Color(0.16, 0.11, 0.06))
	_plate_text.position = TEXT_MARGIN
	_plate_text.size = Vector2(TEXT_VP_SIZE) - TEXT_MARGIN * 2.0
	_text_vp.add_child(_plate_text)

	_text_mesh = MeshInstance2D.new()
	_text_mesh.name = "PlateTextMesh"
	_text_mesh.mesh = _make_perspective_mesh()
	var sh := Shader.new()
	sh.code = _PERSPECTIVE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("tex", _text_vp.get_texture())
	_text_mesh.material = mat
	_root.add_child(_text_mesh)  # поверх слоя Plate (добавлен раньше)


# Меш-трапеция парчмента с перспективно-корректными UV (вес q в COLOR.r).
func _make_perspective_mesh() -> ArrayMesh:
	var qt: float = (TEXT_QUAD_TR.x - TEXT_QUAD_TL.x) / (TEXT_QUAD_BR.x - TEXT_QUAD_BL.x)
	var qb: float = 1.0
	var verts := PackedVector2Array([TEXT_QUAD_TL, TEXT_QUAD_TR, TEXT_QUAD_BR, TEXT_QUAD_BL])
	var uvs := PackedVector2Array(
		[Vector2(0, 0) * qt, Vector2(1, 0) * qt, Vector2(1, 1) * qb, Vector2(0, 1) * qb]
	)
	var cols := PackedColorArray(
		[Color(qt, qt, qt, 1), Color(qt, qt, qt, 1), Color(qb, qb, qb, 1), Color(qb, qb, qb, 1)]
	)
	var idx := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## Пересобирает текст-меш и лейбл из статик-параметров (тюнинг дёргает по группе).
func apply_text_tuning() -> void:
	if not is_instance_valid(_text_mesh) or not is_instance_valid(_plate_text):
		return
	_text_mesh.mesh = _make_perspective_mesh()
	_plate_text.position = TEXT_MARGIN
	_plate_text.size = Vector2(TEXT_VP_SIZE) - TEXT_MARGIN * 2.0
	_fit_description_font()  # шрифт — по вписыванию (учитывает новые поля)
	_apply_layout()


# Авто-подгонка шрифта описания: от TEXT_FONT_SIZE вниз, пока перенесённый текст
# не влезет по высоте в область лейбла (текст разной длины → всегда помещается).
func _fit_description_font() -> void:
	if not is_instance_valid(_plate_text):
		return
	var text: String = tr(_plate_text.text)  # меряем переведённую строку, не ключ
	var font: Font = _plate_text.get_theme_font("font")
	var avail: Vector2 = _plate_text.size
	# Цель — с запасом снизу (перспектива поджимает нижние строки к краю парчмента).
	var target_h: float = avail.y * 0.86
	var size: int = int(TEXT_FONT_SIZE)
	if font != null and not text.is_empty() and avail.x > 0.0:
		while size > TEXT_FONT_MIN:
			var h: float = (
				font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, avail.x, size).y
			)
			if h <= target_h:
				break
			size -= 1
	_plate_text.add_theme_font_size_override("font_size", size)


# Табличка названия: нейнпатч-рамка (углы несжимаемы, серединка тянется) + текст.
# Ширина подгоняется под название в _set_title.
func _build_title() -> void:
	_title_ctrl = Control.new()
	_title_ctrl.name = "Title"
	_title_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_title_ctrl)

	_title_np = NinePatchRect.new()
	_title_np.name = "TitleFrame"
	_title_np.texture = load(GALLERY_DIR + "title-frame.png")
	_title_np.patch_margin_left = int(TITLE_PATCH.position.x)
	_title_np.patch_margin_top = int(TITLE_PATCH.position.y)
	_title_np.patch_margin_right = int(TITLE_PATCH.size.x)
	_title_np.patch_margin_bottom = int(TITLE_PATCH.size.y)
	_title_np.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_ctrl.add_child(_title_np)

	_name_lbl = Label.new()
	_name_lbl.name = "NameLabel"
	_name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_lbl.add_theme_color_override("font_color", Color(0.20, 0.15, 0.08))
	_name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_ctrl.add_child(_name_lbl)

	_title_layer = {"node": _title_ctrl, "off": Vector2.ZERO, "size": Vector2.ZERO, "depth": 0.28}
	_layers.append(_title_layer)


# Задаёт название и подгоняет ширину таблички под него; на макс. ширине — ужимает шрифт.
func _set_title(name: String) -> void:
	if not is_instance_valid(_name_lbl):
		return
	var disp: String = tr(name)
	var font: Font = _name_lbl.get_theme_font("font")
	var fs: int = NAME_FONT_SIZE
	if font != null:
		var inner_max: float = TITLE_MAX_W - 2.0 * TITLE_PAD
		while fs > NAME_FONT_MIN and font.get_string_size(disp, 0, -1, fs).x > inner_max:
			fs -= 1
	_name_lbl.add_theme_font_size_override("font_size", fs)
	_name_lbl.text = name
	var tw: float = font.get_string_size(disp, 0, -1, fs).x if font != null else 0.0
	var w: float = clampf(tw + 2.0 * TITLE_PAD, TITLE_MIN_W, TITLE_MAX_W)
	var sz := Vector2(w, TITLE_HEIGHT)
	_title_ctrl.size = sz
	_title_np.position = Vector2.ZERO
	_title_np.size = sz
	_name_lbl.position = Vector2.ZERO
	_name_lbl.size = sz
	_title_layer["off"] = TITLE_CENTER - sz * 0.5  # центрируем табличку в TITLE_CENTER
	_title_layer["size"] = sz


# Центр читаемой трапеции (для наводки камеры на стенд).
func _text_center() -> Vector2:
	return (TEXT_QUAD_TL + TEXT_QUAD_TR + TEXT_QUAD_BR + TEXT_QUAD_BL) * 0.25


func _add_layer(node_name: String, file: String, off: Vector2, depth: float) -> TextureRect:
	var tex: Texture2D = load(GALLERY_DIR + file)
	var rect := TextureRect.new()
	rect.name = node_name
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.size = tex.get_size()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(rect)
	_layers.append({"node": rect, "off": off, "size": tex.get_size(), "depth": depth})
	return rect


# ── Камера / параллакс ────────────────────────────────────────────────────────


func _process(delta: float) -> void:
	if not visible or _intro or _closing:
		return  # во время интро/закрытия камерой рулит твин
	# Уже на месте — НЕ пересчитываем раскладку (иначе субпиксельный дребезг «качает»
	# ассеты, пока экспоненциальный lerp асимптотически ползёт к цели).
	if is_equal_approx(_zoom, _zoom_target) and _focus.is_equal_approx(_focus_target):
		return
	var t: float = minf(1.0, CAM_LERP * delta)
	_zoom = lerpf(_zoom, _zoom_target, t)
	_focus = _focus.lerp(_focus_target, t)
	# Близко к цели — защёлкиваем точно, чтобы движение завершилось, а не болталось.
	if absf(_zoom - _zoom_target) < 0.002 and _focus.distance_to(_focus_target) < 0.5:
		_zoom = _zoom_target
		_focus = _focus_target
	_apply_layout()


# Масштаб слоя = базовый cover-фит × зум с учётом глубины. Позиция такова, что
# точка focus в канве всегда оказывается в центре экрана (наезд «к точке»).
# Базовый масштаб канвы: cover-фит × OVERSCAN (крупнее экрана, края за кадром).
func _base_scale(vp: Vector2) -> float:
	return maxf(vp.x / CANVAS.x, vp.y / CANVAS.y) * OVERSCAN


func _apply_layout() -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var base: float = _base_scale(vp)
	var center: Vector2 = vp * 0.5
	for l_v: Variant in _layers:
		var l: Dictionary = l_v
		var s: float = base * (1.0 + (_zoom - 1.0) * lerpf(FAR_STR, NEAR_STR, float(l.depth)))
		var node: Control = l.node
		node.scale = Vector2(s, s)
		node.position = center + (Vector2(l.off) - _focus) * s
	# Лампа при наезде поднимается (чтобы не наползать на крест) и чуть растёт (вокруг
	# центра); крепление тоже поднимается — чтобы почти зайти за лампу.
	var zk: float = maxf(0.0, _zoom - 1.0)
	if is_instance_valid(_lamp):
		var s0: float = _lamp.scale.x
		var center_scr: Vector2 = _lamp.position + _lamp.size * 0.5 * s0
		var grown: float = s0 * (1.0 + LAMP_GROW * zk)
		_lamp.scale = Vector2(grown, grown)
		_lamp.position = center_scr - _lamp.size * 0.5 * grown
		_lamp.position.y -= LAMP_RISE * zk
	if is_instance_valid(_mount):
		_mount.position.y -= MOUNT_RISE * zk
	# Перспективный текст-меш (вершины в канве) — тот же аффинный сдвиг камеры,
	# что и у слоя стенда (PLATE_DEPTH); трапеция сохраняется, keystone — в UV.
	if is_instance_valid(_text_mesh):
		var st: float = base * (1.0 + (_zoom - 1.0) * lerpf(FAR_STR, NEAR_STR, PLATE_DEPTH))
		_text_mesh.scale = Vector2(st, st)
		_text_mesh.position = center - _focus * st


# Клик по зоне (картина / стенд) → наезд на неё; повторный клик по той же зоне
# или клик мимо — отъезд к общему плану.
func _on_root_input(event: InputEvent) -> void:
	if _intro or _closing:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not (mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var base: float = _base_scale(vp)
	var center: Vector2 = vp * 0.5
	var m: Vector2 = mb.position
	var hit: String = ""
	if _zone_rect(PAINTING_OFF, PAINTING_SIZE, PAINTING_DEPTH, base, center).has_point(m):
		hit = "painting"
	elif _zone_rect(PLATE_OFF, PLATE_SIZE, PLATE_DEPTH, base, center).has_point(m):
		hit = "plate"
	if hit.is_empty() or hit == _focused:
		_focused = ""
		_focus_target = CANVAS * 0.5
		_zoom_target = ZOOM_IDLE
	elif hit == "painting":
		_focused = hit
		_focus_target = PAINTING_OFF + PAINTING_SIZE * 0.5
		_zoom_target = ZOOM_FOCUS
	else:
		_focused = hit
		_focus_target = _text_center() - Vector2(0.0, PLATE_FOCUS_UP)  # стенд ниже на экране
		_zoom_target = ZOOM_FOCUS


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
