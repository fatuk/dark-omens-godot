class_name LocationSidebar
extends CanvasLayer

## Боковая панель справа с инфой о выбранной локации (орнаментальная рамка).
## Открывается show_location(data), закрывается close_panel() / крестиком.
##
## Раскладка: рамка-арт (sidebar-bg.png) → орнаментальный заголовок с шевронами →
## окно-картинка локации (assets/location-sidebar/<id>.png) → действия
## (Переместиться / Обмен, плюс контекстные Магазин / Билеты) → список
## объектов на локации (монстры/улики/слухи).
##
## Сигналы:
##   closed          — пользователь закрыл крестиком (карта снимет подсветку)
##   shop_requested  — клик «Магазин» (открыть модалку магазина)
##   trade_requested — клик «Обмен» (открыть модалку обмена)

signal closed
signal shop_requested
signal trade_requested
signal gallery_requested(loc_data: Dictionary)  # клик по картинке локации

const ANIM_TIME: float = 0.22  # длительность выезда (открытие)
const ANIM_TIME_CLOSE: float = 0.1  # закрытие чуть медленнее открытия
# Открытие/закрытие — один slide-файл, различаем высотой: открытие ярче/выше,
# закрытие ниже (нисходящее). Небольшой джиттер — чтобы повторы не были одинаковы.
const SLIDE_PITCH_OPEN: float = 1.08
const SLIDE_PITCH_CLOSE: float = 0.82
const SLIDE_PITCH_JITTER: float = 0.03
# Аспект рамки-ассета (sidebar-bg.png 1638×4506). Панель вписываем в высоту экрана
# по этому аспекту → рамка целиком видна, без искажений, углы/бордюр пропорциональны.
const FRAME_ASPECT: float = 1638.0 / 4506.0
# Панель шире базовой вписанной по высоте на этот коэффициент (больше места под текст).
const WIDTH_FACTOR: float = 1.25
# Заголовок локации: базовый размер шрифта и минимум при авто-подгонке под ширину
# (длинные названия ужимаем, чтобы влезали между шевронами — см. _fit_title).
const TITLE_SIZE: int = 33
const TITLE_SIZE_MIN: int = 15
# Небольшой отступ панели от краёв экрана (сверху/снизу/справа) — доля высоты экрана.
const EDGE_GAP_FACTOR: float = 0.005

# Тень под панелью (мягкий drop-shadow за рамкой). Параметры вынесены в тюнинг
# (Ctrl+M → «САЙДБАР · ТЕНЬ»); найденные значения запекаются сюда.
static var SHADOW_ALPHA: float = 0.26  # плотность (альфа) тени
static var SHADOW_SIZE: float = 48.0  # размытие/растекание тени, px
static var SHADOW_GROW: float = 10.0  # расширение силуэта тени за габарит панели, px
static var SHADOW_OFFSET_X: float = 1.0  # сдвиг тени по X (влево — от края экрана)
static var SHADOW_OFFSET_Y: float = 8.0  # сдвиг тени по Y (вниз)
# Ширина панели считается от высоты панели (см. _relayout); дефолт — фолбэк.
var _panel_width: float = 392.0 * WIDTH_FACTOR
# Текущий отступ от краёв в пикселях (считается в _relayout).
var _edge_gap: float = 0.0

# Картинка локации: по конвенции имени файла assets/location-sidebar/<id>.png
# (id как есть — «Arkham» → Arkham.png, «1» → 1.png). Нет файла → пустое окно.
const LOCATION_ART_DIR: String = "res://assets/location-sidebar/"
# Орнаментальная рамка окна-картинки (прозрачный центр — рисуем поверх картинки).
const _IMAGE_FRAME := preload("res://assets/location-sidebar/image-frame.png")

# Цвета типов дорог — для кнопок покупки билетов (соответствуют MapLayer.COLOR_*).
const CONN_COLORS: Dictionary = {
	"ship": Color(0.275, 0.510, 0.706),
	"train": Color(0.627, 0.322, 0.176),
}

@onready var _panel: Control = %Panel
@onready var _margin: MarginContainer = %Margin
@onready var _vbox: VBoxContainer = %VBox

var _shadow: Panel = null  # мягкая тень за рамкой (строится в _build_ui)

var _is_open: bool = false
var _tween: Tween = null
var _loc_id: String = ""  # id показанной сейчас локации (для GameState.travel)
var _data: Dictionary = {}  # полная карточка показанной локации (для галереи)
var _pending_data: Dictionary = {}  # инфа локации, ждущая показа после «спрятать»

# Узлы контента (строятся программно в _ready).
var _title_lbl: Label = null
var _caption: Label = null
var _close_btn: Button = null
var _image_hover: Panel = null  # рамка-подсветка картинки по наведению
var _image_box: Control = null
var _image: TextureRect = null
var _travel_btn: Button = null
var _trade_btn: Button = null
var _shop_btn: Button = null
var _buy_train_btn: Button = null
var _buy_ship_btn: Button = null
var _items_list: VBoxContainer = null

# Улика на локации — строка «иконка + имя улики».
const _CLUE_ICON: Texture2D = preload("res://assets/map/clue-icon.png")
# Сыщики на локации: круглый портрет в кольце (как аватар в панели сыщика), уменьшенный.
const _INV_RING: Texture2D = preload("res://assets/investigator-panel/avatar-round-frame.png")
const _INV_D := 72.0  # диаметр портрета сыщика в списке
static var _circle_shader: Shader = null  # общая круглая маска (InvestigatorPanel)
const _CLUE_ICON_PX := 36.0

# Превью монстров локации — квадратные портреты (как карта в модалке боя).
# Ряд заполняется по ширине целиком: колонок столько, сколько влезает портретов не
# меньше _MON_TILE, и сторона растягивается, чтобы ряд лёг от края до края.
const _MON_TILE := 112.0  # МИНИМАЛЬНАЯ сторона портрета
const _MON_GAP := 8  # зазор между портретами
const _MON_PAD := 6.0  # инсет чисел от края (при _MON_TILE; растёт со стороной)
const _MON_FS := 28  # кегль чисел ужаса/урона (при _MON_TILE; растёт со стороной)


func _ready() -> void:
	add_to_group("location_sidebar")  # тюнинг тени дёргает группу (call_group)
	_build_ui()
	GameState.state_changed.connect(_refresh_actions)
	GameState.state_changed.connect(_refresh_items)
	get_viewport().size_changed.connect(_relayout)
	_relayout()


# Ширина панели = высота экрана × аспект рамки (рамка вписана в высоту без искажений).
# Отступы контента — доли размера (рамка не искажена → доли корректны). Рамка-
# TextureRect сама заполняет панель (аспект панели = аспект рамки → без растяжения).
func _relayout() -> void:
	if not is_instance_valid(_panel):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_edge_gap = vp.y * EDGE_GAP_FACTOR
	# Панель отступает от верха/низа на _edge_gap → высота меньше; ширину рамки
	# считаем от высоты ПАНЕЛИ, чтобы рамка осталась без искажений.
	var panel_h: float = vp.y - 2.0 * _edge_gap
	_panel_width = panel_h * FRAME_ASPECT * WIDTH_FACTOR
	_panel.offset_top = _edge_gap
	_panel.offset_bottom = -_edge_gap
	var margin_h: int = int(_panel_width * 0.085)
	if is_instance_valid(_margin):
		_margin.add_theme_constant_override("margin_left", margin_h)
		_margin.add_theme_constant_override("margin_right", margin_h)
		_margin.add_theme_constant_override("margin_top", int(panel_h * 0.025))
		_margin.add_theme_constant_override("margin_bottom", int(panel_h * 0.035))
	if is_instance_valid(_image_box):
		# Окно-картинка держит пропорцию 3:2 (высота = ширина контента × 2/3).
		var content_w: float = _panel_width - 2.0 * float(margin_h)
		_image_box.custom_minimum_size = Vector2(0, content_w * 2.0 / 3.0)
	apply_shadow()
	_fit_title()
	_apply_offsets(not _is_open)


# ── Сборка UI ─────────────────────────────────────────────────────────────────


func _build_ui() -> void:
	_build_shadow()
	_build_header()
	_build_caption()
	_build_image_box()
	_build_actions()
	_build_content()


# Мягкая тень за рамкой (Panel со StyleBoxFlat-тенью, позади Frame).
func _build_shadow() -> void:
	_shadow = Panel.new()
	_shadow.name = "Shadow"
	_shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_shadow)
	_panel.move_child(_shadow, 0)  # за рамку (первым ребёнком панели)


## Пересобирает StyleBox тени из статик-параметров (тюнинг дёргает по группе).
## Тень — сплошной тёмный скруглённый прямоугольник (заливка есть в середине,
## а не только по контуру), позади рамки. Сдвиг/расширение задаём ректом самого
## узла, чтобы заливка ехала целиком; shadow_size даёт лишь мягкое размытие краёв.
func apply_shadow() -> void:
	if not is_instance_valid(_shadow):
		return
	_shadow.offset_left = SHADOW_OFFSET_X - SHADOW_GROW
	_shadow.offset_top = SHADOW_OFFSET_Y - SHADOW_GROW
	_shadow.offset_right = SHADOW_OFFSET_X + SHADOW_GROW
	_shadow.offset_bottom = SHADOW_OFFSET_Y + SHADOW_GROW
	var col := Color(0.0, 0.0, 0.0, SHADOW_ALPHA)
	var sb := StyleBoxFlat.new()
	sb.draw_center = true  # заливка силуэта (не полый контур!)
	sb.bg_color = col
	sb.shadow_color = col
	sb.shadow_size = int(round(SHADOW_SIZE))
	sb.set_corner_radius_all(int(round(_panel_width * 0.06)))
	_shadow.add_theme_stylebox_override("panel", sb)


# Орнаментальный заголовок (шеврон · имя · шеврон) + крестик поверх правого угла.
func _build_header() -> void:
	var header := Control.new()
	header.name = "Header"
	header.custom_minimum_size = Vector2(0, 40)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_child(header)

	var title_row := UIStyle.ornate_title("", TITLE_SIZE, UIColors.ACCENT)
	title_row.name = "TitleRow"
	title_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(title_row)
	_title_lbl = title_row.get_node("Title")

	# Крестик закрытия — стандартный модальный, в правом верхнем углу панели. Смещения
	# меньше, чем у UIStyle.modal_header: панель прижата к верху экрана, и крестик
	# «за рамкой» уезжал бы за край окна.
	_close_btn = Button.new()
	_close_btn.name = "CloseBtn"
	UIStyle.style_modal_close_button(_close_btn)
	_close_btn.anchor_left = 1.0
	_close_btn.anchor_right = 1.0
	_close_btn.offset_left = -2.0
	_close_btn.offset_top = -30.0
	_close_btn.offset_right = 46.0
	_close_btn.offset_bottom = 18.0
	_close_btn.pressed.connect(_on_close_pressed)
	header.add_child(_close_btn)


# Ужимает шрифт заголовка так, чтобы название влезало между шевронами по ширине
# панели (длинные вроде «К северо-востоку от Гавайев» иначе вылезали за рамку).
func _fit_title() -> void:
	if not is_instance_valid(_title_lbl):
		return
	var text: String = tr(_title_lbl.text)  # меряем переведённую строку, не ключ
	if text.is_empty():
		return
	var reserved: float = 0.0  # ширина шевронов + разделители в орнаментном заголовке
	var row := _title_lbl.get_parent() as HBoxContainer
	if row != null:
		for c: Node in row.get_children():
			if c is TextureRect:
				reserved += (c as TextureRect).custom_minimum_size.x
		reserved += (
			float(row.get_theme_constant("separation")) * float(maxi(0, row.get_child_count() - 1))
		)
	var avail: float = _panel_width - 2.0 * (_panel_width * 0.085) - reserved
	var font: Font = _title_lbl.get_theme_font("font")
	var size: int = TITLE_SIZE
	if font != null and avail > 0.0:
		var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, TITLE_SIZE).x
		if w > avail:
			size = clampi(int(floor(TITLE_SIZE * avail / w)), TITLE_SIZE_MIN, TITLE_SIZE)
	_title_lbl.add_theme_font_size_override("font_size", size)


# Подпись под заголовком: тип · реальный прообраз (мелко, приглушённо).
func _build_caption() -> void:
	_caption = Label.new()
	_caption.name = "Caption"
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART  # длинный прообраз — в 2 строки
	_caption.add_theme_font_size_override("font_size", 18)
	_caption.add_theme_color_override("font_color", UIColors.MUTED)
	_vbox.add_child(_caption)


# Окно-картинка локации: тёмная подложка + картинка (cover) + орнаментальная рамка
# поверх (image-frame.png, прозрачный центр). Пусто, если файла нет — заглушка.
func _build_image_box() -> void:
	var box := Control.new()
	box.name = "ImageBox"
	box.custom_minimum_size = Vector2(0, 200)  # высота уточняется в _relayout (3:2)
	_image_box = box

	var bg := ColorRect.new()
	bg.name = "Bg"
	bg.color = Color(0.06, 0.06, 0.05, 0.85)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(bg)

	_image = TextureRect.new()
	_image.name = "Image"
	_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_image.clip_contents = true
	# Клик по картинке → открыть галерею локации (только если есть арт).
	_image.mouse_filter = Control.MOUSE_FILTER_STOP
	_image.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_image.gui_input.connect(_on_image_input)
	box.add_child(_image)

	# Рамка окна (image-frame.png, прозрачный центр) заполняет бокс целиком —
	# TextureRect растягивает всю рамку под размер окна (бордюр тонкий, пропорц.).
	var frame := TextureRect.new()
	frame.name = "Frame"
	frame.texture = _IMAGE_FRAME
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_SCALE
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(frame)

	# Подсветка-рамка по наведению — знак, что картинка кликабельна (галерея).
	# Поверх орнаментной рамки, гаснет уходом курсора; без арта не зажигается.
	_image_hover = Panel.new()
	_image_hover.name = "HoverFrame"
	_image_hover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_image_hover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hsb := StyleBoxFlat.new()
	hsb.draw_center = false
	hsb.border_color = UIColors.ACCENT
	hsb.set_border_width_all(2)
	_image_hover.add_theme_stylebox_override("panel", hsb)
	_image_hover.modulate.a = 0.0
	box.add_child(_image_hover)
	_image.mouse_entered.connect(func() -> void: _fade_image_hover(_image.texture != null))
	_image.mouse_exited.connect(func() -> void: _fade_image_hover(false))

	_vbox.add_child(box)


# Ряд действий: Переместиться | Обмен, плюс контекстные Магазин и Билеты (стопкой).
func _build_actions() -> void:
	var row := HBoxContainer.new()
	row.name = "Actions"
	row.add_theme_constant_override("separation", 8)
	_vbox.add_child(row)

	_travel_btn = UIStyle.button("SIDEBAR_TRAVEL")
	_travel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_travel_btn.visible = false
	_travel_btn.pressed.connect(_on_travel_pressed)
	row.add_child(_travel_btn)

	_trade_btn = UIStyle.button("SIDEBAR_TRADE")
	_trade_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trade_btn.visible = false
	_trade_btn.pressed.connect(func() -> void: trade_requested.emit())
	row.add_child(_trade_btn)

	# Ряд «Магазин | Закрыть»: магазин контекстный (скрыт вне города), кнопка
	# закрытия — всегда. Когда магазина нет, Закрыть занимает весь ряд.
	var shop_row := HBoxContainer.new()
	shop_row.name = "ShopRow"
	shop_row.add_theme_constant_override("separation", 8)
	_vbox.add_child(shop_row)

	_shop_btn = UIStyle.button("SIDEBAR_BTN_SHOP", UIColors.ACCENT)
	_shop_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shop_btn.visible = false
	_shop_btn.pressed.connect(
		func() -> void:
			shop_requested.emit()
			close_panel()  # магазин занимает весь экран — панель под ним не нужна
	)
	shop_row.add_child(_shop_btn)

	_buy_train_btn = _make_buy_ticket_btn("SIDEBAR_BTN_TICKET_TRAIN", "train")
	_buy_ship_btn = _make_buy_ticket_btn("SIDEBAR_BTN_TICKET_SHIP", "ship")
	_vbox.add_child(_buy_train_btn)
	_vbox.add_child(_buy_ship_btn)


func _make_buy_ticket_btn(label_key: String, ticket_type: String) -> Button:
	var btn := UIStyle.button(label_key, CONN_COLORS[ticket_type])
	btn.name = "BuyTicket_" + ticket_type
	btn.visible = false
	btn.pressed.connect(
		func() -> void:
			GameState.perform_action(GameActions.BUY_TICKET, {"type": ticket_type})
			close_panel()  # как и перемещение: сыграли действие — уходим с карты
	)
	return btn


# Описание + список объектов на локации в прокручиваемой области (тянется вниз).
func _build_content() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_vbox.add_child(scroll)

	var content := VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	_items_list = VBoxContainer.new()
	_items_list.name = "ItemsList"
	_items_list.add_theme_constant_override("separation", 6)
	content.add_child(_items_list)


# ── Public ────────────────────────────────────────────────────────────────────


func show_location(data: Dictionary) -> void:
	var new_id: String = String(data.get("id", ""))
	# Выбрали другую локацию при открытой панели — сначала прячем, потом
	# открываем заново с новой инфой (плавная пересборка вместо подмены на месте).
	if _is_open and not _loc_id.is_empty() and new_id != _loc_id:
		_pending_data = data
		_transition_to_new()
		return
	_apply_location(data)
	if not _is_open:
		_is_open = true
		_animate(false)


# Заполняет контент панели данными локации (name/realWorldLocation/description/
# type — translation-ключи, Label переводит при рендере).
func _apply_location(data: Dictionary) -> void:
	_data = data
	_loc_id = String(data.get("id", ""))
	_title_lbl.text = String(data.get("name", ""))
	_fit_title()  # длинное название ужимаем под ширину панели
	_caption.text = _caption_text(data)
	_image.texture = _location_art(_loc_id)
	_populate_items(_loc_id)
	_refresh_actions()


# Прячет панель, по завершении — подставляет _pending_data и открывает снова.
func _transition_to_new() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	# Звук закрытия здесь НЕ играем — это не закрытие, а смена локации. Прозвучит
	# только звук открытия, когда панель выедет обратно с новой инфой.
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.tween_property(_panel, "offset_left", 0.0, ANIM_TIME_CLOSE)
	_tween.tween_property(_panel, "offset_right", _panel_width, ANIM_TIME_CLOSE)
	_tween.finished.connect(_on_transition_hidden, CONNECT_ONE_SHOT)


func _on_transition_hidden() -> void:
	if _pending_data.is_empty():
		return
	_apply_location(_pending_data)
	_pending_data = {}
	_animate(false)  # открыть заново с новой инфой


func close_panel() -> void:
	if not _is_open:
		return
	_is_open = false
	_loc_id = ""
	_animate(true)
	closed.emit()


func is_open() -> bool:
	return _is_open


# ── Картинка локации ──────────────────────────────────────────────────────────


# Арт локации по конвенции имени файла: assets/locations/<id>.png (как арт ассетов
# по id). Нет файла → null (окно-заглушка).
func _location_art(loc_id: String) -> Texture2D:
	if loc_id.is_empty():
		return null
	var path: String = "%s%s.png" % [LOCATION_ART_DIR, loc_id]
	return load(path) if ResourceLoader.exists(path) else null


# Подпись под заголовком — реальное название точки на карте (realWorldLocation).
# Если его нет — показываем тип локации как фолбэк.
func _caption_text(data: Dictionary) -> String:
	var real: String = String(data.get("realWorldLocation", ""))
	if not real.is_empty():
		return tr(real)
	return tr(_type_label_for(String(data.get("type", "city"))))


# ── Действия (перемещение / обмен / магазин / билеты) ─────────────────────────


func _refresh_actions() -> void:
	if not is_instance_valid(_travel_btn):
		return
	# Тень (dead) не ходит/не торгует/не покупает — прячем ВСЕ действия локации
	# (сайдбар открыть можно как оракулу, но кнопки действий недоступны).
	if bool(GameState.my_player().get("dead", false)):
		_travel_btn.visible = false
		_trade_btn.visible = false
		_shop_btn.visible = false
		_buy_train_btn.visible = false
		_buy_ship_btn.visible = false
		return
	var travel_cost: Dictionary = {} if _loc_id.is_empty() else GameState.travel_cost_to(_loc_id)
	_travel_btn.visible = not travel_cost.is_empty()
	# Метка кнопки несёт стоимость в билетах: базовый хоп — просто «Переместиться»,
	# доп. хопы — «Переместиться (ж/д ×N, корабль ×M)».
	if _travel_btn.visible:
		var cs: String = _travel_cost_str(travel_cost)
		_travel_btn.text = tr("SIDEBAR_TRAVEL") if cs.is_empty() else tr("SIDEBAR_TRAVEL_COST") % cs
	_trade_btn.visible = _can_trade()
	_shop_btn.visible = GameState.can_shop(_loc_id)
	# Монстр в городе → магазин закрыт: кнопка видна, но заблокирована с подписью.
	var shop_closed: bool = GameState.has_monster_at(_loc_id)
	_shop_btn.disabled = shop_closed
	_shop_btn.text = "SIDEBAR_BTN_SHOP_CLOSED" if shop_closed else "SIDEBAR_BTN_SHOP"
	var can_ticket: bool = GameState.can_buy_ticket(_loc_id)
	var avail: Array = GameState.map.ticket_types(_loc_id)
	_buy_train_btn.visible = can_ticket and avail.has("train")
	_buy_ship_btn.visible = can_ticket and avail.has("ship")


func _on_travel_pressed() -> void:
	if _loc_id.is_empty():
		return
	GameState.perform_action(GameActions.TRAVEL, {"to": _loc_id})
	close_panel()  # не заслоняем карту, пока фишка летит к новой локации


# Стоимость плана в билетах → строка «ж/д ×N, корабль ×M» (только ненулевые).
# Пусто, если билеты не тратятся (базовый ход).
func _travel_cost_str(cost: Dictionary) -> String:
	var parts: PackedStringArray = []
	var t: int = int(cost.get("train", 0))
	var s: int = int(cost.get("ship", 0))
	if t > 0:
		parts.append(tr("TICKET_COST_TRAIN") % t)
	if s > 0:
		parts.append(tr("TICKET_COST_SHIP") % s)
	return ", ".join(parts)


# Можно ли обменяться здесь: мой ход, моя локация, есть действие, обмен ещё не делал
# в раунде и есть со-локационный подключённый напарник (иначе меняться не с кем).
func _can_trade() -> bool:
	if _loc_id.is_empty() or not GameState.is_my_turn():
		return false
	var me: Dictionary = GameState.my_player()
	# «Мозг ми-го»: обмен по связи — действие уже потрачено на карту, напарник далеко.
	if not String(me.get("trade_link", "")).is_empty():
		return GameState.trade_offer.is_empty() and String(me.get("location", "")) == _loc_id
	if int(me.get("actions_left", 0)) <= 0:
		return false
	if (me.get("actions_used", []) as Array).has(GameActions.TRADE):
		return false
	if not GameState.trade_offer.is_empty():
		return false  # предложение уже висит — ждём ответа
	if String(me.get("location", "")) != _loc_id:
		return false
	var my_id: String = String(me.get("user_id", ""))
	for pid_v: Variant in GameState.players:
		var pid: String = String(pid_v)
		var p: Dictionary = GameState.players[pid]
		if (
			pid != my_id
			and bool(p.get("connected", true))
			and not bool(p.get("dead", false))  # с Тенью не поменяешься
			and String(p.get("location", "")) == _loc_id
		):
			return true
	return false


# ── Объекты на локации (монстры/улики/слухи) ──────────────────────────────────


## При смене стейта (спаун монстров/улик) — перерисовать список, если открыт.
func _refresh_items() -> void:
	if _is_open and not _loc_id.is_empty():
		_populate_items(_loc_id)


## Список объектов локации: Сыщики → Монстры (со статами) → Улики → Слухи.
func _populate_items(loc_id: String) -> void:
	if not is_instance_valid(_items_list):
		return
	for child in _items_list.get_children():
		_items_list.remove_child(child)  # сразу из дерева: _add_section считает детей
		child.queue_free()

	var ents: Array = GameState.entities.get(loc_id, [])
	var mons: Array = GameState.monsters.get(loc_id, [])
	var clues: int = (ents as Array).count("clue")
	var rumors: int = (ents as Array).count("rumor")

	var invs: Array = _investigators_at(loc_id)

	var empty: bool = invs.is_empty() and mons.is_empty() and clues == 0 and rumors == 0
	_items_list.visible = not empty
	if empty:
		return

	# Каждая категория — под своим заголовком («СЫЩИКИ», «МОНСТРЫ», …), а не общим
	# «НА ЛОКАЦИИ».
	if not invs.is_empty():
		_add_section("SIDEBAR_CAT_INVESTIGATORS")
		for pid_v: Variant in invs:
			_items_list.add_child(_make_investigator_row(String(pid_v)))

	if not mons.is_empty():
		_add_section("SIDEBAR_CAT_MONSTERS")
		var grid := HFlowContainer.new()
		grid.name = "MonsterGrid"
		grid.add_theme_constant_override("h_separation", _MON_GAP)
		grid.add_theme_constant_override("v_separation", _MON_GAP)
		grid.resized.connect(_fit_monster_grid.bind(grid))
		_items_list.add_child(grid)
		for i: int in range(mons.size()):
			var inst_v: Variant = mons[i]  # {id, health} или легаси id-строка
			var mid: String = (
				String(inst_v.get("id", "")) if inst_v is Dictionary else String(inst_v)
			)
			var hp: int = (
				int((inst_v as Dictionary).get("health", -1)) if inst_v is Dictionary else -1
			)
			var m: Dictionary = GameState.monster_def(mid)
			if not m.is_empty():
				grid.add_child(_make_monster_tile(m, hp))
		_fit_monster_grid(grid)
	if clues > 0:
		# Улики — вертикальным списком: иконка улики + её имя (идентичность Древнего для
		# этой локации; не заведена — просто «Улика»).
		var clue_name: String = String(ClueCatalog.by_location(loc_id).get("title", ""))
		if clue_name.strip_edges().is_empty():
			clue_name = tr("TOKEN_CLUE")
		_add_section("SIDEBAR_CAT_CLUES")
		for i: int in range(clues):
			_items_list.add_child(_make_clue_row(clue_name, i))
	if rumors > 0:
		_add_section("SIDEBAR_CAT_RUMORS", rumors)  # своего списка у слухов нет — число


# Сыщики на клетке (id игроков в порядке хода). Тень (погибший) тоже стоит на поле —
# показываем её ч/б портретом.
func _investigators_at(loc_id: String) -> Array:
	var out: Array = []
	for pid_v: Variant in GameState.turn_order:
		var p: Dictionary = GameState.players.get(String(pid_v), {})
		if (
			String(p.get("location", "")) == loc_id
			and not String(p.get("investigator", "")).is_empty()
		):
			out.append(String(pid_v))
	return out


# Строка сыщика: круглый портрет в кольце, имя сыщика, ник игрока под ним.
func _make_investigator_row(pid: String) -> HBoxContainer:
	var p: Dictionary = GameState.players.get(pid, {})
	var inv: String = String(p.get("investigator", ""))
	var row := HBoxContainer.new()
	row.name = "Investigator_" + pid
	row.add_theme_constant_override("separation", 12)

	var holder := Control.new()
	holder.name = "Avatar"
	holder.custom_minimum_size = Vector2(_INV_D, _INV_D)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(holder)
	var portrait := TextureRect.new()
	portrait.name = "Portrait"
	var path: String = "res://assets/investigators/%s.png" % inv
	portrait.texture = load(path) as Texture2D if ResourceLoader.exists(path) else null
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _circle_shader == null:
		_circle_shader = Shader.new()
		_circle_shader.code = InvestigatorPanel._CIRCLE_MASK_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _circle_shader
	mat.set_shader_parameter("dead", 1.0 if bool(p.get("dead", false)) else 0.0)
	portrait.material = mat
	holder.add_child(portrait)
	var ring := TextureRect.new()
	ring.name = "Ring"
	ring.texture = _INV_RING
	ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ring.stretch_mode = TextureRect.STRETCH_SCALE
	ring.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(ring)

	var text := VBoxContainer.new()
	text.name = "Text"
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	var inv_lbl := Label.new()
	inv_lbl.name = "Investigator"
	inv_lbl.text = Investigators.display_name(inv)
	inv_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inv_lbl.add_theme_font_size_override("font_size", 19)
	inv_lbl.add_theme_color_override("font_color", UIColors.ACCENT)
	text.add_child(inv_lbl)
	var nick := Label.new()
	nick.name = "Player"
	nick.text = String(p.get("name", pid))
	nick.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED  # ник — не ключ перевода
	nick.add_theme_font_size_override("font_size", 15)
	nick.add_theme_color_override("font_color", UIColors.MUTED)
	text.add_child(nick)
	return row


func _make_clue_row(clue_name: String, index: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Clue%d" % index
	row.add_theme_constant_override("separation", 10)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = _CLUE_ICON
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(_CLUE_ICON_PX, _CLUE_ICON_PX)
	row.add_child(icon)
	var l := Label.new()
	l.name = "Name"
	l.text = clue_name
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 19)
	l.add_theme_color_override("font_color", UIColors.TEXT)
	row.add_child(l)
	return row


# Заголовок категории объектов локации («СЫЩИКИ», «МОНСТРЫ»…); count ≥ 0 — дописать
# число (у слухов нет своего списка). Не первая категория — отступ сверху.
func _add_section(key: String, count: int = -1) -> void:
	if _items_list.get_child_count() > 0:
		var gap := Control.new()
		gap.name = "SectionGap"
		gap.custom_minimum_size.y = 8.0
		_items_list.add_child(gap)
	var l := Label.new()
	l.name = "Section_" + key.trim_prefix("SIDEBAR_CAT_").to_lower()
	l.text = tr(key).to_upper() + (" · %d" % count if count >= 0 else "")
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", UIColors.MUTED)
	_items_list.add_child(l)


## Сторона портрета, при которой ряд шириной width заполняется целиком.
static func monster_tile_side(width: float) -> float:
	if width <= 0.0:
		return _MON_TILE
	var cols: int = maxi(1, int((width + _MON_GAP) / (_MON_TILE + _MON_GAP)))
	return floorf((width - _MON_GAP * (cols - 1)) / cols)


# Подогнать портреты под ширину ряда: сторона, кегль и инсет чисел — пропорционально.
func _fit_monster_grid(grid: HFlowContainer) -> void:
	var side: float = monster_tile_side(grid.size.x)
	var k: float = side / _MON_TILE
	for tile: Node in grid.get_children():
		(tile as Control).custom_minimum_size = Vector2(side, side)
		for num_name: String in ["Horror", "Damage"]:
			var l: Label = tile.get_node_or_null(num_name)
			if l == null:
				continue
			var right: bool = num_name == "Damage"
			l.add_theme_font_size_override("font_size", roundi(_MON_FS * k))
			l.offset_bottom = -_MON_PAD * k + 4
			if right:
				l.offset_right = -_MON_PAD * k
			else:
				l.offset_left = _MON_PAD * k


## Превью монстра — квадратный портрет, как карта в модалке боя: арт «под обрез»,
## ужас (синий) слева снизу, урон (красный) справа снизу. Полные статы (стойкость,
## проверки, сопротивление, способность) — во всплывающей подсказке.
func _make_monster_tile(m: Dictionary, cur_health: int = -1) -> Control:
	var tile := Control.new()
	tile.name = "Monster"
	tile.custom_minimum_size = Vector2(_MON_TILE, _MON_TILE)
	tile.clip_contents = true
	tile.mouse_filter = Control.MOUSE_FILTER_PASS  # подсказка; колесо — скроллу
	tile.tooltip_text = _monster_tooltip(m, cur_health)

	var bg := ColorRect.new()  # подложка: под артом с прозрачностью и вместо него
	bg.name = "ArtBg"
	bg.color = UIColors.ART_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(bg)
	var tex: Texture2D = MonsterCatalog.card_art(String(m.get("id", "")))
	if tex != null:
		var art := TextureRect.new()
		art.name = "Art"
		art.texture = tex
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.add_child(art)

	if m.has("horror"):
		var horror: int = int((m.get("horror", {}) as Dictionary).get("damage", 0))
		var combat: int = int((m.get("combat", {}) as Dictionary).get("damage", 0))
		tile.add_child(_tile_number("Horror", horror, UIColors.WILL, false))
		tile.add_child(_tile_number("Damage", combat, UIColors.STRENGTH, true))

	var frame := Panel.new()  # рамка поверх арта
	frame.name = "Frame"
	var sb := StyleBoxFlat.new()
	sb.draw_center = false
	sb.set_border_width_all(1)
	sb.border_color = UIColors.BORDER
	frame.add_theme_stylebox_override("panel", sb)
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(frame)
	return tile


# Крупное число в нижнем углу портрета (right — правый угол), с тенью, как в бою.
func _tile_number(node_name: String, value: int, color: Color, right: bool) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = str(value)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", _MON_FS)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color.BLACK)
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.set_anchors_and_offsets_preset(
		Control.PRESET_BOTTOM_RIGHT if right else Control.PRESET_BOTTOM_LEFT
	)
	l.grow_horizontal = Control.GROW_DIRECTION_BEGIN if right else Control.GROW_DIRECTION_END
	l.grow_vertical = Control.GROW_DIRECTION_BEGIN
	l.offset_bottom = -_MON_PAD + 4
	if right:
		l.offset_right = -_MON_PAD
	else:
		l.offset_left = _MON_PAD
	return l


# Подсказка портрета: имя, стойкость (тек./макс., если ранен), проверки, способность.
func _monster_tooltip(m: Dictionary, cur_health: int = -1) -> String:
	var lines: PackedStringArray = [tr(String(m.get("nameKey", "")))]
	if m.has("horror"):
		var tough: int = MonsterCatalog.toughness_for(m, maxi(1, GameState.players.size()))
		lines.append(
			(
				("%s: %d / %d" % [tr("SIDEBAR_TOUGHNESS"), cur_health, tough])
				if cur_health >= 0
				else ("%s: %d" % [tr("SIDEBAR_TOUGHNESS"), tough])
			)
		)
		lines.append(_stat_line("SIDEBAR_HORROR", m.get("horror", {})))
		lines.append(_stat_line("SIDEBAR_COMBAT", m.get("combat", {})))
		if m.has("resist"):
			lines.append("%s: %s" % [tr("SIDEBAR_RESIST"), _resist_text(m.get("resist"))])
	elif bool(m.get("useAncientOne", false)):
		lines.append(tr("SIDEBAR_USE_ANCIENT_ONE"))
	var ability: String = String((m.get("ability", {}) as Dictionary).get("textKey", ""))
	if not ability.is_empty():
		lines.append(tr(ability))
	return "\n".join(lines)


# Строка проверки: «Ужас: Воля −1 · урон 2».
func _stat_line(label_key: String, stat: Dictionary) -> String:
	var skill: String = String(stat.get("skill", "none"))
	var skill_tr: String = tr("SKILL_" + skill.to_upper())
	var mod: int = int(stat.get("modifier", 0))
	var mod_s: String = ("%+d" % mod) if mod != 0 else "0"
	return (
		"%s: %s %s · %s %d"
		% [tr(label_key), skill_tr, mod_s, tr("SIDEBAR_DAMAGE"), int(stat.get("damage", 0))]
	)


# Текст сопротивления монстра: «физическое»/«магическое» (resist — строка/массив).
func _resist_text(r: Variant) -> String:
	var types: Array = r if r is Array else [r]
	var parts: PackedStringArray = []
	for t: Variant in types:
		parts.append(tr("RESIST_PHYSICAL" if String(t) == "physical" else "RESIST_MAGICAL"))
	return ", ".join(parts)


# ── Внутренние ───────────────────────────────────────────────────────────────


func _on_close_pressed() -> void:
	close_panel()


# Клик по картинке локации → открыть галерею (только если для локации есть арт).
func _fade_image_hover(on: bool) -> void:
	_image_hover.create_tween().tween_property(_image_hover, "modulate:a", 1.0 if on else 0.0, 0.12)


func _on_image_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if _location_art(_loc_id) != null and not _data.is_empty():
				gallery_requested.emit(_data)  # галерея сама проявляется с масштабом


# Слайд-звук с разной высотой для открытия и закрытия (+лёгкий джиттер).
func _play_slide_sfx(closing: bool) -> void:
	var base: float = SLIDE_PITCH_CLOSE if closing else SLIDE_PITCH_OPEN
	var pitch: float = base + randf_range(-SLIDE_PITCH_JITTER, SLIDE_PITCH_JITTER)
	SfxManager.play(SfxManager.SFX_SIDEBAR_SLIDE, false, pitch)


func _animate(hide_panel: bool) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	# Звук слайда синхронен с tween'ом; закрытие ниже открытия по высоте.
	_play_slide_sfx(hide_panel)
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var off_left: float = 0.0 if hide_panel else -_panel_width - _edge_gap
	var off_right: float = _panel_width if hide_panel else -_edge_gap
	var dur: float = ANIM_TIME_CLOSE if hide_panel else ANIM_TIME
	_tween.tween_property(_panel, "offset_left", off_left, dur)
	_tween.tween_property(_panel, "offset_right", off_right, dur)
	if hide_panel:
		# Уехав за край, панель прячется совсем: её мягкая тень (SHADOW_SIZE +
		# SHADOW_GROW) иначе торчит из-за края экрана.
		_tween.chain().tween_callback(func() -> void: _panel.visible = _is_open)
	else:
		_panel.visible = true


func _apply_offsets(hide_panel: bool) -> void:
	_panel.visible = not hide_panel  # спрятанная — невидима (тень не торчит из-за края)
	if hide_panel:
		_panel.offset_left = 0.0
		_panel.offset_right = _panel_width
	else:
		_panel.offset_left = -_panel_width - _edge_gap
		_panel.offset_right = -_edge_gap


func _type_label_for(t: String) -> String:
	# Возвращаем translation key — Godot переводит автоматически.
	match t:
		"city":
			return "LOC_TYPE_CITY"
		"sea":
			return "LOC_TYPE_SEA"
		"wilderness":
			return "LOC_TYPE_WILDERNESS"
	return t.to_upper()
