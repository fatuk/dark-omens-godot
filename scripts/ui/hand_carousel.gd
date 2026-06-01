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

# Размер карты в пропорциях рамки asset-card (аспект ≈0.632, см. GameCard.ASPECT).
const CARD_W: float = 186.0
const CARD_H: float = 294.0

# Тестовый арт для ВСЕХ карт руки (пока нет уникальных артов карт). Кладётся в
# арт-слот рамки GameCard; перекрывает глиф-заглушку.
const _TEST_ART: Texture2D = preload("res://assets/asset-card/18 Derringer.png")

# Тюнинг ПОЛОЖЕНИЯ карт и АНИМАЦИИ — правится вживую в дебаг-панели (Ctrl+M,
# секция «ВЕЕР КАРТ»). static var, а не const: панель меняет значения без ссылки
# на конкретный инстанс, а инстанс читает их при перекладке (см. relayout).
# Дефолты подобраны вживую в дебаг-панели (Ctrl+M, «ВЕЕР КАРТ») — абсолютные px,
# без множителя S.
static var SPREAD: float = 5.0  # градусов поворота между соседями
static var GAP_X: float = 87.0  # горизонтальный шаг (< ширины → нахлёст)
static var ARC: float = 2.3  # глубина дуги (края ниже центра)
static var LIFT: float = 9.0  # подъём активной карты
static var HSCALE: float = 1.56  # увеличение активной карты
static var PUSH: float = 73.0  # расступание соседей
static var PIVOT_Y_FRAC: float = 1.10  # центр поворота: доля высоты (ниже карты)
static var HAND_BELOW: float = -60.0  # насколько якорь веера ниже края экрана (минус = выше)
static var ANIM: float = 0.28  # длительность перекладки

# Звук перемотки: один файл нарезается на N равных кусков, при каждом шаге играет
# случайный (+ случайный питч). Тюнится в дебаг-панели. Файл подхватится, как
# только появится по пути SCROLL_SFX_PATH (пока его нет — перемотка просто молчит).
static var SCROLL_VARIATIONS: int = 5  # на сколько вариаций нарезан файл
static var SCROLL_PITCH: float = 0.06  # случайный сдвиг высоты ±

const SCROLL_SFX_PATH := "res://assets/audio/sfx/card-carousel-move.wav"

# Явные сегменты вариаций [start_sec, end_sec] — перемотка играет случайный из
# них. Посчитаны из самого файла (анализ амплитуды: 7 флипов, границы в тишине).
# Пусто → равная нарезка на SCROLL_VARIATIONS кусков.
static var SCROLL_SEGMENTS: Array = [
	[0.00, 0.14],
	[0.31, 0.50],
	[0.65, 0.86],
	[1.02, 1.24],
	[1.34, 1.58],
	[1.70, 1.91],
	[2.07, 2.22],
]

# Карта рисуется компонентом GameCard (рамка asset-card + зоны контента).
const MOD_ACTIVE := Color(1.12, 1.12, 1.12, 1.0)
const MOD_IDLE := Color(0.92, 0.92, 0.92, 1.0)
const MOD_HIDDEN := Color(0.92, 0.92, 0.92, 0.0)

# Фейковая рука (10 карт из прототипа).
const CARDS: Array[Dictionary] = [
	{
		"cost": 0,
		"title": "Мистраль",
		"glyph": "🌀",
		"art": "1f8f7a",
		"desc": "Повышает характеристики следующей карты «Брони»."
	},
	{
		"cost": 3,
		"title": "Виток смерти",
		"glyph": "🗡",
		"art": "7a1f6f",
		"desc": "Наносит 728 урона переднему ряду. Крит. удар."
	},
	{
		"cost": 2,
		"title": "Топор",
		"glyph": "🪓",
		"art": "5a6b1f",
		"desc": "Наносит 336 урона с шансом отталкивания."
	},
	{
		"cost": 0,
		"title": "Криотин",
		"glyph": "🧊",
		"art": "1f5a8f",
		"desc": "Понизьте стоимость следующей карты на 1."
	},
	{
		"cost": 3,
		"title": "Молот зари",
		"glyph": "🔨",
		"art": "8f6a1f",
		"desc": "Наносит урон и оглушает переднего врага."
	},
	{
		"cost": 2,
		"title": "Тёмный шквал",
		"glyph": "🌑",
		"art": "3a1f8f",
		"desc": "Наносит несколько ударов по случайным целям."
	},
	{
		"cost": 5,
		"title": "Пентаграмма",
		"glyph": "🔮",
		"art": "5a1f6f",
		"desc": "Призывает демона на 3 хода. Жертва: 5 HP."
	},
	{
		"cost": 1,
		"title": "Пугна",
		"glyph": "🏹",
		"art": "1f6f5a",
		"desc": "Стирание 6 ряда. Обратный отсчёт."
	},
	{
		"cost": 2,
		"title": "Воробей",
		"glyph": "🦅",
		"art": "6f5a1f",
		"desc": "Сила: на 20% больше урона по Бродяге."
	},
	{
		"cost": 3,
		"title": "Фиера Туфелло",
		"glyph": "⚔",
		"art": "8f1f2f",
		"desc": "Наносит 700 урона. Игнорирует броню."
	},
]

var tab_enabled: bool = true  # Tab открывает/закрывает (рука в игре); в пикере — false
var _deck: Array = []  # payload'ы карт (GameCard.set_card); пусто → дефолтная фейк-рука
var _hint_text: String = "Tab — закрыть   ·   ← →  /  колесо — выбор   ·   ЛКМ — сыграть"
var _backdrop: ColorRect
var _hint: Label
var _els: Array[Control] = []
var _active: int = -1
var _open: bool = false
var _mid: float = 0.0
var _tween: Tween
var _collapse_timer: Timer
var _scroll_sfx: AudioStream = null
var _scroll_tried: bool = false  # пытались ли уже загрузить звук перемотки


func _ready() -> void:
	layer = 70  # над картой/панелями, под финальной outcome-модалкой (90)
	add_to_group("hand_carousel")  # чтобы дебаг-панель (Ctrl+M) нашла инстанс
	_build_chrome()
	if _deck.is_empty():
		_deck = _default_deck()  # дефолтная фейк-рука (если set_cards не звали)
	_rebuild_cards()
	visible = false
	get_viewport().size_changed.connect(_on_resize)


## Задать произвольный набор карт (payload'ы GameCard.set_card) — для переиспользования
## веера вне игры (напр. просмотр имущества сыщика в пикере).
func set_cards(cards: Array) -> void:
	_deck = cards.duplicate()
	if is_inside_tree():
		_rebuild_cards()


## Текст подсказки внизу (в пикере «сыграть» неуместно — задаём своё).
func set_hint(text: String) -> void:
	_hint_text = text
	if is_instance_valid(_hint):
		_hint.text = text


# Дефолтная фейк-рука из CARDS (тестовый арт на всех картах).
func _default_deck() -> Array:
	var out: Array = []
	for i in range(CARDS.size()):
		var d: Dictionary = CARDS[i]
		out.append(
			{
				"cost": d["cost"],
				"title": d["title"],
				"desc": d["desc"],
				"art": _TEST_ART,
				"glyph": d["glyph"]
			}
		)
	return out


# ── Сборка ─────────────────────────────────────────────────────────────────────


func _build_chrome() -> void:
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP  # глушим клики по фону + закрытие
	_backdrop.z_index = -1
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)

	_hint = Label.new()
	_hint.name = "Hint"
	_hint.text = _hint_text
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.add_theme_color_override("font_color", UIColors.MUTED)
	_hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_hint.offset_top = 26.0
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)

	_collapse_timer = Timer.new()
	_collapse_timer.name = "CollapseTimer"
	_collapse_timer.one_shot = true
	_collapse_timer.wait_time = 0.06  # дебаунс: переход между нахлёстом не схлопывает веер
	_collapse_timer.timeout.connect(_on_collapse_timeout)
	add_child(_collapse_timer)


# Пересобрать карты из _deck (после set_cards). Хром (фон/подсказка) не трогаем.
func _rebuild_cards() -> void:
	for c in _els:
		c.queue_free()
	_els.clear()
	_mid = float(maxi(1, _deck.size()) - 1) / 2.0
	for i in range(_deck.size()):
		var card: Control = _build_card(_deck[i], i)
		add_child(card)
		_els.append(card)
	_active = -1


func _build_card(data: Dictionary, idx: int) -> Control:
	var card := GameCard.new()
	card.name = "Card%d" % idx
	card.custom_minimum_size = Vector2(CARD_W, CARD_H)
	card.size = Vector2(CARD_W, CARD_H)
	card.pivot_offset = Vector2(CARD_W * 0.5, CARD_H * PIVOT_Y_FRAC)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.set_card(data)  # payload готов у вызывающего (set_cards / _default_deck)

	# Сигналы наведения/клика на саму карту.
	card.mouse_entered.connect(_on_card_enter.bind(idx))
	card.mouse_exited.connect(_on_card_exit)
	card.gui_input.connect(_on_card_gui_input.bind(card))
	return card


# Клик по фону (не по карте) — закрыть веер.
func _on_backdrop_input(event: InputEvent) -> void:
	if (
		_open
		and event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_LEFT
	):
		close()


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
			"rot": 0.0,
			"scl": HSCALE,
			"z": 1000,
		}
	var x: float = off * GAP_X
	if _active != -1:
		x += (-PUSH if i < _active else PUSH)
	return {
		"pos": _p0() + Vector2(x, off * off * ARC),
		"rot": deg_to_rad(off * SPREAD),
		"scl": 1.0,
		"z": i,
	}


func _layout(animate: bool) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if animate:
		_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(
			Tween.EASE_OUT
		)
	for i in range(_els.size()):
		var card: Control = _els[i]
		var b: Dictionary = _base_transform(i)
		card.z_index = int(b["z"])
		var mod: Color = MOD_ACTIVE if _active == i else MOD_IDLE
		var scl := Vector2(b["scl"], b["scl"])
		if animate:
			_tween.tween_property(card, "position", b["pos"], ANIM)
			_tween.tween_property(card, "rotation", b["rot"], ANIM)
			_tween.tween_property(card, "scale", scl, ANIM)
			_tween.tween_property(card, "modulate", mod, ANIM)
		else:
			card.position = b["pos"]
			card.rotation = b["rot"]
			card.scale = scl
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
	_play_scroll()


# Звук перемотки: случайная вариация из одного файла (см. SfxManager.play_variation).
# Файл грузим лениво и только если он есть — пока его нет, перемотка молчит.
func _scroll_stream() -> AudioStream:
	if not _scroll_tried:
		_scroll_tried = true
		if ResourceLoader.exists(SCROLL_SFX_PATH):
			_scroll_sfx = load(SCROLL_SFX_PATH)
	return _scroll_sfx


func _play_scroll() -> void:
	var s: AudioStream = _scroll_stream()
	if s != null:
		SfxManager.play_variation(s, SCROLL_VARIATIONS, SCROLL_PITCH, SCROLL_SEGMENTS)


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
		card.scale = Vector2.ONE
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
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	for card in _els:
		_tween.tween_property(card, "position:y", card.position.y + 160.0, ANIM)
		_tween.tween_property(card, "modulate", MOD_HIDDEN, ANIM)
	_tween.chain().tween_callback(func() -> void: visible = false)


func toggle() -> void:
	if _open:
		close()
	else:
		open()


# ── Ввод ───────────────────────────────────────────────────────────────────


func _input(event: InputEvent) -> void:
	# Tab — открыть/закрыть (перехватываем до ui_focus_next). Только если включено
	# (рука в игре); в пикере веер открывают кликом по карте, Tab не трогаем.
	if (
		tab_enabled
		and event is InputEventKey
		and event.pressed
		and not event.echo
		and event.keycode == KEY_TAB
	):
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not _open:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT:
				_step(-1)
				get_viewport().set_input_as_handled()
			KEY_RIGHT:
				_step(1)
				get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				close()
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_step(1)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_step(-1)
			get_viewport().set_input_as_handled()


func _on_card_enter(idx: int) -> void:
	if not _open:
		return
	_collapse_timer.stop()
	if _active != idx:  # звук только при смене активной карты (не на дрожании курсора)
		set_active(idx)
		_play_scroll()


func _on_card_exit() -> void:
	if not _open:
		return
	_collapse_timer.start()  # схлопнуть, если в течение дебаунса не наведём другую


# Дебаунс схлопывания: курсор ушёл со всех карт — снять выделение.
func _on_collapse_timeout() -> void:
	if _open:
		set_active(-1)


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
