extends CanvasLayer
class_name HandCarousel

## Веер карт руки сыщика (прототип, порт из HTML/CSS-макета).
## Открывается/закрывается по Tab на карте. Пока с ФЕЙКОВЫМИ картами.
##
## Навигация: ← / → или колесо мыши — листать; наведение мышью — выбрать;
## клик ЛКМ — «вспышка»; Esc или Tab — закрыть.
##
## Геометрия веера портирована из прототипа (spread/gap/arc/lift/hscale/push).
## Активная карта поднимается, увеличивается, соседи расступаются. Анимация —
## один параллельный Tween на перекладку (как CSS-transition .28s).
##
## NB: 3D-наклон активной карты за курсором (rotateX/rotateY из макета) здесь
## опущен — для 2D-Control в Godot нужен шейдер/SubViewport. Ядро веера — есть.

# Масштаб геометрии макета под 1080p (макет рисовался под мелкий вьюпорт).
const S: float = 1.5

const CARD_W: float = 132.0 * S
const CARD_H: float = 196.0 * S
const PAD:    float = 5.0 * S      # золотая рамка вокруг inner

# Тюнинг ПОЛОЖЕНИЯ карт и АНИМАЦИИ — правится вживую в дебаг-панели (Ctrl+M,
# секция «ВЕЕР КАРТ»). static var, а не const: панель меняет значения без ссылки
# на конкретный инстанс, а инстанс читает их при перекладке (см. relayout).
static var SPREAD: float = 5.0          # градусов поворота между соседями
static var GAP_X:  float = 64.0 * S     # горизонтальный шаг (< ширины → нахлёст)
static var ARC:    float = 4.2 * S      # глубина дуги (края ниже центра)
static var LIFT:   float = 78.0 * S     # подъём активной карты
static var HSCALE: float = 1.42         # увеличение активной карты
static var PUSH:   float = 46.0 * S     # расступание соседей
static var PIVOT_Y_FRAC: float = 1.3    # центр поворота: доля высоты (ниже карты)
static var HAND_BELOW: float = 26.0 * S # насколько якорь веера ниже края экрана
static var ANIM:   float = 0.28         # длительность перекладки

# Палитра из прототипа.
const C_GOLD       := Color("c9a24e")
const C_GOLD_EDGE  := Color("5c4317")
const C_GOLD_RING  := Color("e8c66b")
const C_FRAME      := Color("5e0f12")
const C_FRAME_DARK := Color("4a0c10")
const C_PLATE      := Color("b9c0e6")
const C_BLUE       := Color("2f6fd0")
const C_TITLE_BG   := Color("561012")
const C_TITLE_TXT  := Color("ffe9a8")
const C_DESC_TXT   := Color("27224a")
const C_ART_EDGE   := Color("0b0712")

const MOD_ACTIVE   := Color(1.12, 1.12, 1.12, 1.0)
const MOD_IDLE     := Color(0.92, 0.92, 0.92, 1.0)
const MOD_HIDDEN   := Color(0.92, 0.92, 0.92, 0.0)

# Фейковая рука (10 карт из прототипа).
const CARDS: Array[Dictionary] = [
	{ "cost": 0, "title": "Мистраль",      "glyph": "🌀", "art": "1f8f7a", "desc": "Повышает характеристики следующей карты «Брони»." },
	{ "cost": 3, "title": "Виток смерти",  "glyph": "🗡", "art": "7a1f6f", "desc": "Наносит 728 урона переднему ряду. Крит. удар." },
	{ "cost": 2, "title": "Топор",         "glyph": "🪓", "art": "5a6b1f", "desc": "Наносит 336 урона с шансом отталкивания." },
	{ "cost": 0, "title": "Криотин",       "glyph": "🧊", "art": "1f5a8f", "desc": "Понизьте стоимость следующей карты на 1." },
	{ "cost": 3, "title": "Молот зари",    "glyph": "🔨", "art": "8f6a1f", "desc": "Наносит урон и оглушает переднего врага." },
	{ "cost": 2, "title": "Тёмный шквал",  "glyph": "🌑", "art": "3a1f8f", "desc": "Наносит несколько ударов по случайным целям." },
	{ "cost": 5, "title": "Пентаграмма",   "glyph": "🔮", "art": "5a1f6f", "desc": "Призывает демона на 3 хода. Жертва: 5 HP." },
	{ "cost": 1, "title": "Пугна",         "glyph": "🏹", "art": "1f6f5a", "desc": "Стирание 6 ряда. Обратный отсчёт." },
	{ "cost": 2, "title": "Воробей",       "glyph": "🦅", "art": "6f5a1f", "desc": "Сила: на 20% больше урона по Бродяге." },
	{ "cost": 3, "title": "Фиера Туфелло", "glyph": "⚔", "art": "8f1f2f", "desc": "Наносит 700 урона. Игнорирует броню." },
]

var _backdrop: ColorRect
var _hint: Label
var _els: Array[Control] = []
var _active: int = -1
var _open: bool = false
var _mid: float = 0.0
var _tween: Tween
var _collapse_timer: Timer


func _ready() -> void:
	layer = 70   # над картой/панелями, под финальной outcome-модалкой (90)
	add_to_group("hand_carousel")   # чтобы дебаг-панель (Ctrl+M) нашла инстанс
	_mid = float(CARDS.size() - 1) / 2.0
	_build()
	visible = false
	get_viewport().size_changed.connect(_on_resize)


# ── Сборка ─────────────────────────────────────────────────────────────────────

func _build() -> void:
	_backdrop = ColorRect.new()
	_backdrop.name  = "Backdrop"
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP   # глушим клики по карте
	_backdrop.z_index = -1
	add_child(_backdrop)

	_hint = Label.new()
	_hint.name = "Hint"
	_hint.text = "Tab — закрыть   ·   ← →  /  колесо — выбор   ·   ЛКМ — сыграть"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.add_theme_color_override("font_color", UIColors.MUTED)
	_hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_hint.offset_top = 26.0
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)

	_collapse_timer = Timer.new()
	_collapse_timer.one_shot = true
	_collapse_timer.wait_time = 0.06   # дебаунс: переход между нахлёстом не схлопывает веер
	_collapse_timer.timeout.connect(func() -> void: if _open: set_active(-1))
	add_child(_collapse_timer)

	for i in range(CARDS.size()):
		var card: Control = _build_card(CARDS[i], i)
		add_child(card)
		_els.append(card)


func _build_card(data: Dictionary, idx: int) -> Control:
	var card := Panel.new()
	card.name = "Card%d" % idx
	card.custom_minimum_size = Vector2(CARD_W, CARD_H)
	card.size          = Vector2(CARD_W, CARD_H)
	card.pivot_offset  = Vector2(CARD_W * 0.5, CARD_H * PIVOT_Y_FRAC)
	card.mouse_filter  = Control.MOUSE_FILTER_STOP
	card.add_theme_stylebox_override("panel", _gold_sb())

	var inner := Panel.new()
	inner.name = "Inner"
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inner.offset_left = PAD; inner.offset_top = PAD
	inner.offset_right = -PAD; inner.offset_bottom = -PAD
	inner.clip_contents = true
	inner.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	inner.add_theme_stylebox_override("panel", _frame_sb())
	card.add_child(inner)

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var m: float = 4.0 * S
	vb.offset_left = m; vb.offset_top = m; vb.offset_right = -m; vb.offset_bottom = -m
	vb.add_theme_constant_override("separation", int(4 * S))
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(vb)

	var title := Label.new()
	title.name = "Title"
	title.text = String(data["title"])
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", C_TITLE_TXT)
	title.add_theme_stylebox_override("normal", _title_sb())
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.clip_text = true
	title.custom_minimum_size = Vector2(0, 24 * S)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title)

	var art := TextureRect.new()
	art.name = "Art"
	art.texture = _art_tex(String(data["art"]))
	art.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_SCALE
	art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glyph := Label.new()
	glyph.name = "Glyph"
	glyph.text = String(data["glyph"])
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	glyph.add_theme_font_size_override("font_size", int(46 * S))
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.add_child(glyph)
	vb.add_child(art)

	var desc := Label.new()
	desc.name = "Desc"
	desc.text = String(data["desc"])
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	desc.add_theme_font_size_override("font_size", 15)
	desc.add_theme_color_override("font_color", C_DESC_TXT)
	desc.add_theme_stylebox_override("normal", _plate_sb())
	desc.custom_minimum_size = Vector2(0, 46 * S)
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(desc)

	# Бейдж стоимости — поверх vbox, абсолютно в левом верхнем углу inner.
	var cost := Panel.new()
	cost.name = "Cost"
	cost.custom_minimum_size = Vector2(30 * S, 30 * S)
	cost.size     = Vector2(30 * S, 30 * S)
	cost.position = Vector2(5 * S, 5 * S)
	cost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cost.add_theme_stylebox_override("panel", _cost_sb())
	var costlbl := Label.new()
	costlbl.text = str(data["cost"])
	costlbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	costlbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	costlbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	costlbl.add_theme_font_size_override("font_size", 15)
	costlbl.add_theme_color_override("font_color", Color.WHITE)
	costlbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cost.add_child(costlbl)
	inner.add_child(cost)

	# Сигналы наведения/клика на саму карту.
	card.mouse_entered.connect(_on_card_enter.bind(idx))
	card.mouse_exited.connect(_on_card_exit)
	card.gui_input.connect(_on_card_gui_input.bind(card))
	return card


# ── StyleBox-фабрики ─────────────────────────────────────────────────────────

func _gold_sb() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = C_GOLD
	s.set_corner_radius_all(int(9 * S))
	s.set_border_width_all(1)
	s.border_color = C_GOLD_EDGE
	s.shadow_color  = Color(0.0, 0.0, 0.0, 0.55)
	s.shadow_size   = int(8 * S)
	s.shadow_offset = Vector2(0.0, 6.0 * S)
	return s


func _frame_sb() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = C_FRAME
	s.set_corner_radius_all(int(6 * S))
	s.set_border_width_all(1)
	s.border_color = C_FRAME_DARK
	return s


func _title_sb() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = C_TITLE_BG
	s.set_corner_radius_all(int(4 * S))
	s.set_border_width_all(1)
	s.border_color = C_GOLD_EDGE
	s.content_margin_left   = 34 * S   # текст начинается ПОСЛЕ бейджа стоимости
	s.content_margin_right  = 6 * S
	s.content_margin_top    = 3 * S
	s.content_margin_bottom = 3 * S
	return s


func _plate_sb() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = C_PLATE
	s.set_corner_radius_all(int(4 * S))
	s.set_border_width_all(1)
	s.border_color = C_GOLD_EDGE
	s.set_content_margin_all(5 * S)
	return s


func _cost_sb() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = C_BLUE
	s.set_corner_radius_all(int(15 * S))   # = половина диаметра → круг
	s.set_border_width_all(2)
	s.border_color = C_GOLD_RING
	return s


# Радиальный градиент арта (как radial-gradient в макете).
func _art_tex(hex: String) -> GradientTexture2D:
	var grad := Gradient.new()
	grad.set_color(0, Color(hex))
	grad.set_color(1, C_ART_EDGE)
	var tex := GradientTexture2D.new()
	tex.gradient  = grad
	tex.fill      = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.4, 0.3)   # «circle at 40% 30%»
	tex.fill_to   = Vector2(1.05, 1.15)
	tex.width  = int(CARD_W)
	tex.height = int(CARD_H)
	return tex


# ── Геометрия веера ─────────────────────────────────────────────────────────

# Натуральный левый-верх карты (общий для всех): низ-центр карты на якоре веера.
func _p0() -> Vector2:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var anchor := Vector2(vp.x * 0.5, vp.y + HAND_BELOW)
	return anchor - Vector2(CARD_W * 0.5, CARD_H)


func _base_transform(i: int) -> Dictionary:
	var off: float = float(i) - _mid
	if _active == i:
		return {
			"pos": _p0() + Vector2(off * GAP_X, -LIFT),
			"rot": 0.0, "scl": HSCALE, "z": 1000,
		}
	var x: float = off * GAP_X
	if _active != -1:
		x += (-PUSH if i < _active else PUSH)
	return {
		"pos": _p0() + Vector2(x, off * off * ARC),
		"rot": deg_to_rad(off * SPREAD), "scl": 1.0, "z": i,
	}


func _layout(animate: bool) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if animate:
		_tween = create_tween().set_parallel(true) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	for i in range(_els.size()):
		var card: Control = _els[i]
		var b: Dictionary = _base_transform(i)
		card.z_index = int(b["z"])
		var mod: Color = MOD_ACTIVE if _active == i else MOD_IDLE
		var scl := Vector2(b["scl"], b["scl"])
		if animate:
			_tween.tween_property(card, "position", b["pos"], ANIM)
			_tween.tween_property(card, "rotation", b["rot"], ANIM)
			_tween.tween_property(card, "scale",    scl,      ANIM)
			_tween.tween_property(card, "modulate", mod,      ANIM)
		else:
			card.position = b["pos"]
			card.rotation = b["rot"]
			card.scale    = scl
			card.modulate = mod


func set_active(i: int) -> void:
	_active = i
	_layout(true)


## Перечитать тюнинг-параметры (после правки в дебаг-панели): pivot зависит от
## PIVOT_Y_FRAC и задаётся на карту, поэтому переприменяем его, затем перекладка.
func relayout() -> void:
	for card in _els:
		card.pivot_offset = Vector2(CARD_W * 0.5, CARD_H * PIVOT_Y_FRAC)
	if _open:
		_layout(true)


func _step(d: int) -> void:
	var n: int = _els.size()
	if _active == -1:
		_active = int(round(_mid))
	_active = (_active + d + n) % n
	set_active(_active)


# ── Открытие / закрытие ─────────────────────────────────────────────────────

func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	_active = -1
	# Стартовое положение «снизу и прозрачно» — для въезда веера.
	for card in _els:
		card.position = _p0() + Vector2(0.0, 160.0)
		card.rotation = 0.0
		card.scale    = Vector2.ONE
		card.modulate = MOD_HIDDEN
	_layout(true)


func close() -> void:
	if not _open:
		return
	_open = false
	_active = -1
	_collapse_timer.stop()
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	for card in _els:
		_tween.tween_property(card, "position:y", card.position.y + 160.0, ANIM)
		_tween.tween_property(card, "modulate", MOD_HIDDEN, ANIM)
	_tween.chain().tween_callback(func() -> void: visible = false)


func toggle() -> void:
	if _open: close()
	else:     open()


# ── Ввод ───────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	# Tab — открыть/закрыть (перехватываем до ui_focus_next).
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not _open:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT:
				_step(-1); get_viewport().set_input_as_handled()
			KEY_RIGHT:
				_step(1);  get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				close(); get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_step(1);  get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_step(-1); get_viewport().set_input_as_handled()


func _on_card_enter(idx: int) -> void:
	if not _open:
		return
	_collapse_timer.stop()
	set_active(idx)


func _on_card_exit() -> void:
	if not _open:
		return
	_collapse_timer.start()   # схлопнуть, если в течение дебаунса не наведём другую


func _on_card_gui_input(event: InputEvent, card: Control) -> void:
	if not _open:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_flash(card)


func _flash(card: Control) -> void:
	var t := create_tween()
	t.tween_property(card, "modulate", Color(2.0, 1.7, 1.3, 1.0), 0.0)
	t.tween_property(card, "modulate", MOD_ACTIVE, ANIM).set_ease(Tween.EASE_OUT)


func _on_resize() -> void:
	if _open:
		_layout(false)
