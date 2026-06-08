extends CanvasLayer
class_name HandCarousel

## Клик по НЕистощённой карте — запрос активации (item_index в player.items).
## Слушает WorldMap → GameState.activate_card; в пикере слушателя нет (просмотр).
signal card_played(item_index: int)

## «Закинули» жетон (currency) на проверку → зарядить валюту переброса; куб игрок
## выбирает тапом по кубу (как и обычный переброс).
signal token_played(currency: String)

## Веер карт руки сыщика (порт из HTML/CSS-макета).
## Открывается/закрывается по Tab. Карты задаются извне через set_cards()
## (в игре — реальное имущество игрока, см. WorldMap._refresh_hand; в пикере —
## имущество выбранного сыщика). Без set_cards — дефолтная демо-рука (_default_deck).
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
const MOD_EXHAUSTED := Color(0.45, 0.45, 0.5, 1.0)  # истощённая карта — приглушена

# Разыгрывание карты перетаскиванием «на кубы»: тащим карту из веера вверх и
# отпускаем над проверкой — если курсор выше этой доли высоты экрана, карта сыграна.
const DRAG_PLAY_Y_FRAC := 0.65

# Сдвиг меньше этого (px) считаем КЛИКОМ (а не перетаскиванием) — клик тоже разыгрывает.
const CLICK_DIST := 8.0

# Размер кликабельной стрелки переключения секций.
const ARROW_W := 80.0
const ARROW_H := 120.0

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
var _hint_text: String = ""  # пусто = подсказки нет (в игре скрыта; пикер задаёт через set_hint)
var _backdrop: ColorRect
var _hint: Label
var _els: Array[Control] = []
var _exhausted: Array = []  # параллельно _els: истощена ли карта (нельзя активировать)
var _active: int = -1
var _open: bool = false
var _mid: float = 0.0
var _tween: Tween
var _collapse_timer: Timer
var _scroll_sfx: AudioStream = null
var _scroll_tried: bool = false  # пытались ли уже загрузить звук перемотки
var _drag_idx: int = -1  # индекс перетаскиваемой карты (-1 — не тащим)
var _drag_grab: Vector2  # смещение «позиция карты − курсор» в момент захвата
var _drag_start: Vector2  # позиция курсора в момент нажатия (для распознавания клика)
var _playing: bool = false  # идёт анимация розыгрыша карты (пересборку откладываем)
var _sections: Array = []  # [{title, items}] — секции веера (имущество/жетоны/…)
var _section_idx: int = 0  # активная секция
var _arrow_l: Control  # ◄ переключение секции влево
var _arrow_r: Control  # ► переключение секции вправо
var _section_title: Label  # название активной секции (сверху по центру)


func _ready() -> void:
	# Поверх ВСЕХ игровых/диалоговых модалок (encounter 80 … outcome/dialog 90),
	# чтобы веер можно было открыть во время проверки и активировать карты. Ниже
	# системных слоёв: пауза/консоль (100), пост-эффект плёнки (200), курсор (1024).
	layer = 95
	add_to_group("hand_carousel")  # чтобы дебаг-панель (Ctrl+M) нашла инстанс
	_build_chrome()
	if _sections.is_empty():
		_sections = [{"title": "", "items": _default_deck()}]  # дефолтная фейк-рука
	_apply_section(false)
	visible = false
	get_viewport().size_changed.connect(_on_resize)


## Совместимость: одна безымянная секция (пикер просмотра имущества сыщика).
func set_cards(cards: Array) -> void:
	set_sections([{"title": "", "items": cards}] if not cards.is_empty() else [])


## Задать секции веера: [{title, items}]. Пустые секции отбирает вызывающий
## (WorldMap._refresh_hand). Активная секция клампится; заголовок/стрелки обновляются.
func set_sections(sections: Array) -> void:
	if _playing:
		return  # идёт анимация розыгрыша — пересборку откладываем (иначе карту-анимацию снесёт)
	_sections = sections
	_section_idx = clampi(_section_idx, 0, maxi(0, sections.size() - 1))
	if is_inside_tree():
		_apply_section(false)


# Применить активную секцию: _deck = её items, пересборка карт, заголовок/стрелки,
# и (при открытом вевере) разложить. slide_dir != 0 → новый веер ВЛЕТАЕТ со стороны
# нажатой стрелки (+1 справа, −1 слева): карты стартуют за краем экрана и едут внутрь.
func _apply_section(animate: bool, slide_dir: int = 0) -> void:
	_deck = (_sections[_section_idx]["items"] as Array) if not _sections.is_empty() else []
	_rebuild_cards()
	_update_section_chrome()
	if not _open:
		return
	if slide_dir != 0:
		var off := Vector2(get_viewport().get_visible_rect().size.x * float(signi(slide_dir)), 0.0)
		for i in range(_els.size()):
			var b: Dictionary = _base_transform(i)
			_els[i].position = (b["pos"] as Vector2) + off  # старт за краем экрана
			_els[i].rotation = float(b["rot"])
			_els[i].scale = Vector2(b["scl"], b["scl"])
			_els[i].modulate = MOD_IDLE
		_layout(true)  # тянем к базовым позициям → слайд внутрь
	else:
		_layout(animate)


## Текст подсказки (пикер задаёт свою). Пусто → подсказка скрыта.
func set_hint(text: String) -> void:
	_hint_text = text
	if is_instance_valid(_hint):
		_hint.text = text
		_hint.visible = not text.is_empty()


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
	# Без затемнения: веер открывается ПОВЕРХ проверки, фон видно. Backdrop прозрачен
	# и служит лишь невидимым перехватчиком клика «мимо карт» → закрыть веер.
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.0)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP  # клик мимо карт — закрытие
	_backdrop.z_index = -1
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)

	_hint = Label.new()
	_hint.name = "Hint"
	_hint.text = _hint_text
	_hint.visible = not _hint_text.is_empty()  # в игре пусто → скрыта; пикер задаёт через set_hint
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.add_theme_color_override("font_color", UIColors.MUTED)
	_hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_hint.offset_top = 26.0
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)

	# Заголовок активной секции — ПОД колодой по центру (позиция в _position_chrome).
	_section_title = Label.new()
	_section_title.name = "SectionTitle"
	_section_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_section_title.add_theme_font_size_override("font_size", 28)
	_section_title.add_theme_color_override("font_color", UIColors.ACCENT)
	_section_title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_section_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_section_title)

	# Стрелки переключения секций ◄ ► по бокам (видны только при >1 секции).
	_arrow_l = _make_arrow("◄", -1)
	_arrow_r = _make_arrow("►", 1)
	add_child(_arrow_l)
	add_child(_arrow_r)

	_collapse_timer = Timer.new()
	_collapse_timer.name = "CollapseTimer"
	_collapse_timer.one_shot = true
	_collapse_timer.wait_time = 0.06  # дебаунс: переход между нахлёстом не схлопывает веер
	_collapse_timer.timeout.connect(_on_collapse_timeout)
	add_child(_collapse_timer)


# Кликабельная стрелка переключения секции (dir = -1 влево / +1 вправо).
func _make_arrow(glyph: String, dir: int) -> Control:
	var a := Label.new()
	a.name = "Arrow%d" % dir
	a.text = glyph
	a.add_theme_font_size_override("font_size", 52)
	a.add_theme_color_override("font_color", UIColors.ACCENT)
	a.size = Vector2(ARROW_W, ARROW_H)
	a.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	a.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	a.mouse_filter = Control.MOUSE_FILTER_STOP
	a.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	a.z_index = 3000  # поверх карт; позиция — сбоку от веера (_position_arrows)
	a.gui_input.connect(func(ev: InputEvent) -> void: _on_arrow_input(ev, dir))
	return a


# Стрелки — ВПРИТЫК к бокам веера (а не к краям экрана), по его вертикали; заголовок
# секции — ПОД нижним краем колоды по центру.
func _position_chrome() -> void:
	if not is_instance_valid(_arrow_l) or not is_instance_valid(_arrow_r):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var cx: float = vp.x * 0.5
	var half: float = _mid * GAP_X + CARD_W * 0.6 + 40.0  # полуширина веера + отступ
	var cy: float = _p0().y + CARD_H * 0.5  # вертикальный центр веера
	_arrow_l.position = Vector2(cx - half - ARROW_W, cy - ARROW_H * 0.5)
	_arrow_r.position = Vector2(cx + half, cy - ARROW_H * 0.5)
	# Подпись секции — под колодой (нижний край карт + отступ).
	if is_instance_valid(_section_title):
		var ty: float = _p0().y + CARD_H + 6.0
		_section_title.offset_top = ty
		_section_title.offset_bottom = ty + 40.0


func _on_arrow_input(ev: InputEvent, dir: int) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		_switch_section(dir)


# Переключить активную секцию (по кругу среди непустых). Стрелки/клавиши ← →.
func _switch_section(d: int) -> void:
	var n: int = _sections.size()
	if n <= 1:
		return
	_section_idx = (_section_idx + d + n) % n
	_active = -1
	_apply_section(true, d)  # d>0 — влетает справа, d<0 — слева
	_play_scroll()


# Обновить заголовок секции и видимость стрелок (стрелки — только при >1 секции).
func _update_section_chrome() -> void:
	var has: bool = not _sections.is_empty()
	if is_instance_valid(_section_title):
		_section_title.text = String(_sections[_section_idx].get("title", "")) if has else ""
	var multi: bool = _sections.size() > 1
	if is_instance_valid(_arrow_l):
		_arrow_l.visible = multi
	if is_instance_valid(_arrow_r):
		_arrow_r.visible = multi


# Пересобрать карты из _deck (после set_cards). Хром (фон/подсказка) не трогаем.
func _rebuild_cards() -> void:
	for c in _els:
		c.queue_free()
	_els.clear()
	_exhausted.clear()
	_mid = float(maxi(1, _deck.size()) - 1) / 2.0
	for i in range(_deck.size()):
		var card: Control = _build_card(_deck[i], i)
		add_child(card)
		_els.append(card)
		_exhausted.append(bool((_deck[i] as Dictionary).get("exhausted", false)))
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
	card.gui_input.connect(_on_card_gui_input.bind(idx))
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
	if _els.is_empty():
		return  # пустая рука — нечего раскладывать (иначе твин без твинеров)
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
		if _active != i and i < _exhausted.size() and bool(_exhausted[i]):
			mod = MOD_EXHAUSTED  # истощённая карта приглушена (нельзя активировать)
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
	_position_chrome()  # стрелки сбоку от веера + подпись секции под колодой


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
	if n == 0:
		return  # пустая рука — листать нечего (и защита от % 0)
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
	if _open or _els.is_empty():
		return  # пустую руку не открываем
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


## Открыт ли веер (для гарда зума карты при открытом вевере).
func is_open() -> bool:
	return _open


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
	# Перетаскивание карты: ведём за курсором; отпускание — сыграть (над кубами) / вернуть.
	# Прочий ввод (колесо/клавиши) во время перетаскивания игнорируем.
	if _drag_idx >= 0:
		if event is InputEventMouseMotion:
			_drag_to(get_viewport().get_mouse_position())
			get_viewport().set_input_as_handled()
		elif (
			event is InputEventMouseButton
			and not event.pressed
			and event.button_index == MOUSE_BUTTON_LEFT
		):
			_end_drag()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT:
				_switch_section(-1)  # ← → листают СЕКЦИИ (карты — колесом/наведением)
				get_viewport().set_input_as_handled()
			KEY_RIGHT:
				_switch_section(1)
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
	if not _open or _drag_idx >= 0:
		return  # во время перетаскивания наведение не переключает активную карту
	_collapse_timer.stop()
	if _active != idx:  # звук только при смене активной карты (не на дрожании курсора)
		set_active(idx)
		_play_scroll()


func _on_card_exit() -> void:
	if not _open or _drag_idx >= 0:
		return
	_collapse_timer.start()  # схлопнуть, если в течение дебаунса не наведём другую


# Начать перетаскивание карты idx: поднять над веером, запомнить смещение от курсора.
func _begin_drag(idx: int) -> void:
	_drag_idx = idx
	_collapse_timer.stop()
	if _tween != null and _tween.is_valid():
		_tween.kill()
	var card: Control = _els[idx]
	card.z_index = 2000
	card.rotation = 0.0
	card.scale = Vector2(HSCALE, HSCALE)
	card.modulate = MOD_ACTIVE
	_drag_start = get_viewport().get_mouse_position()
	_drag_grab = card.position - _drag_start


# Вести перетаскиваемую карту за курсором (сохраняя точку захвата).
func _drag_to(mouse: Vector2) -> void:
	if _drag_idx >= 0 and _drag_idx < _els.size():
		_els[_drag_idx].position = mouse + _drag_grab


# Отпустить элемент. Жетон → на провальный куб под курсором (переброс валютой);
# карта → выше DRAG_PLAY_Y_FRAC высоты экрана (на проверку). Иначе — вернуть в веер.
func _end_drag() -> void:
	var idx: int = _drag_idx
	_drag_idx = -1
	if idx < 0 or idx >= _els.size():
		return
	var item: Dictionary = _deck[idx] if idx < _deck.size() else {}
	var pos: Vector2 = get_viewport().get_mouse_position()
	var vp: Vector2 = get_viewport().get_visible_rect().size
	# Вытащил элемент на проверку (выше порога) → разыграть и СПРЯТАТЬ веер. Карта
	# применяется; жетон «закидывается» (заряжает валюту переброса) — куб игрок
	# выберет тапом. Мимо проверки — элемент возвращается в веер.
	# Сначала emit (на хосте синхронно пересобирает веер), затем close — анимация
	# закрытия идёт по обновлённому раскладу.
	# Разыгрываем, если вытащили на проверку (выше порога) ЛИБО это клик (карта почти
	# не сдвинулась) — клик по карте тоже её разыгрывает.
	var on_check: bool = pos.y < vp.y * DRAG_PLAY_Y_FRAC
	var is_click: bool = pos.distance_to(_drag_start) < CLICK_DIST
	if (on_check or is_click) and not (idx < _exhausted.size() and bool(_exhausted[idx])):
		_play_and_close(idx, item)
		return
	_layout(true)  # бросил мимо — вернуть в веер


# Анимация розыгрыша: карта ОДНОВРЕМЕННО увеличивается и уходит в прозрачность, затем
# применяется и веер закрывается. На время анимации пересборка веера заблокирована
# (_playing), поэтому пересборка после emit сама уберёт выцветшую карту.
func _play_and_close(idx: int, item: Dictionary) -> void:
	if idx < 0 or idx >= _els.size():
		return
	_playing = true
	var card: Control = _els[idx]
	card.z_index = 2500  # поверх соседей
	var t := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(card, "scale", card.scale * 1.4, ANIM)
	t.tween_property(card, "modulate:a", 0.0, ANIM)
	t.set_parallel(false)
	t.tween_callback(
		func() -> void:
			_playing = false
			if String(item.get("kind", "asset")) == "token":
				token_played.emit(String(item.get("currency", "")))
			else:
				card_played.emit(int(item.get("item_index", -1)))
			close()
	)


# Дебаунс схлопывания: курсор ушёл со всех карт — снять выделение.
func _on_collapse_timeout() -> void:
	if _open:
		set_active(-1)


func _on_card_gui_input(event: InputEvent, idx: int) -> void:
	if not _open:
		return
	# ЛКМ по карте — НАЧАТЬ перетаскивание (играем не тапом, а вытаскиванием на кубы).
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if idx < 0 or idx >= _els.size():
			return
		if idx < _exhausted.size() and bool(_exhausted[idx]):
			return  # истощённую карту не разыгрываем
		_begin_drag(idx)
		get_viewport().set_input_as_handled()


func _on_resize() -> void:
	if _open:
		_layout(false)
