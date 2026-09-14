extends CanvasLayer

## HUD-панель основной игровой информации.
## Тонкий API — наружу выставлены простые сеттеры.

const _PHASE_RUNES: int = 4  # рун в кадре при смене фазы
const _PLAYER_RUNES: int = 5  # рун в кадре при смене имени игрока

@onready var _phase: Label = %PhaseLabel
@onready var _player: Label = %PlayerLabel
@onready var _doom: Control = %DoomTrack
@onready var _omens: OmensCounter = %OmensDial
@onready var _info: Control = %InfoOrb

# Последние значения — чтобы рунный скрэмбл шёл только на реальной смене (сеттеры
# зовутся на каждом _refresh_game_panel, а не только когда текст изменился).
var _phase_text: String = ""
var _player_text: String = ""
var _pulse_mine: bool = false  # имя пульсирует — ход мой
var _pulse_tw: Tween = null
var _pulse_base: Variant = null  # исходный цвет имени (Color), снимаем при первом пульсе
const _PULSE_PERIOD: float = 0.75
const _PULSE_COLOR := UIColors.READY  # зелёный в тон орбам панели; янтарь сливался с плашкой

## Клик по орбу раунда — для открытия сайдбара текущей Мистерии.
signal round_clicked

## Клик по компасу знамений — «перечитать последний миф».
signal mythos_review_requested

## Клик по медальону в центре панели — окно «Запасы» (колоды и сбросы).
signal supply_requested

# Медальон-компас нарисован в фоне панели (game-panel-bg.png). Прямоугольник — в
# координатах Root (790×110): арт нарисован в двойном размере, поэтому центр ядра
# из текстуры (768, 117) даёт здесь (384, 58). По низу не доходим до трека Рока,
# он лежит поверх той же полосы.
const _SUPPLY_HOTSPOT := Rect2(330.0, 6.0, 108.0, 86.0)
const _HOVER_ALPHA: float = 0.16  # подсветка медальона под курсором


func _ready() -> void:
	_info.mouse_filter = Control.MOUSE_FILTER_STOP
	_info.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_info.gui_input.connect(_on_info_gui_input)
	_omens.clicked.connect(func() -> void: mythos_review_requested.emit())
	_build_supply_hotspot()


# «Запасы» открываются кликом по медальону в фоне панели — отдельной кнопки нет.
# Кликабельную область строим кодом, чтобы не трогать раскладку сцены (позиции
# остальных элементов там выверены по арту).
func _build_supply_hotspot() -> void:
	var hot := Control.new()
	hot.name = "SupplyHotspot"
	hot.position = _SUPPLY_HOTSPOT.position
	hot.size = _SUPPLY_HOTSPOT.size
	hot.custom_minimum_size = _SUPPLY_HOTSPOT.size
	hot.mouse_filter = Control.MOUSE_FILTER_STOP
	hot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hot.tooltip_text = TranslationServer.translate("SUPPLY_BTN")

	# Медальон — часть фонового арта, подсвечивать нечего: кладём поверх мягкий
	# круг, он и служит откликом на наведение.
	var glow := Panel.new()
	glow.name = "Hover"
	glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.modulate.a = 0.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UIColors.ACCENT, _HOVER_ALPHA)
	sb.set_corner_radius_all(int(_SUPPLY_HOTSPOT.size.y * 0.5))
	glow.add_theme_stylebox_override("panel", sb)
	hot.add_child(glow)

	hot.mouse_entered.connect(func() -> void: _fade(glow, 1.0))
	hot.mouse_exited.connect(func() -> void: _fade(glow, 0.0))
	hot.gui_input.connect(
		func(event: InputEvent) -> void:
			if event is InputEventMouseButton:
				var mb := event as InputEventMouseButton
				if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
					supply_requested.emit()
	)
	($Root as Control).add_child(hot)


func _fade(node: Control, to: float) -> void:
	node.create_tween().tween_property(node, "modulate:a", to, 0.12)


func _on_info_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			round_clicked.emit()


func set_phase(text: String) -> void:
	if text == _phase_text:
		return
	_phase_text = text
	UIStyle.rune_scramble(_phase, text, _PHASE_RUNES)


func set_player(text: String) -> void:
	if text == _player_text:
		return
	_player_text = text
	UIStyle.rune_scramble(_player, text, _PLAYER_RUNES)


## Пульс имени, когда ходит САМ игрок (на его экране): чтобы «твой ход» бросалось
## в глаза и на панели, а не только баннером. Пульс цветом — базовый цвет ↔ зелёный
## (размер не трогаем, чтобы не дёргать раскладку панели). Остальным — статичное
## имя (кого ждут, им показывает ореол на карте).
func set_turn_mine(mine: bool) -> void:
	if mine == _pulse_mine:
		return
	_pulse_mine = mine
	if _pulse_tw != null and _pulse_tw.is_valid():
		_pulse_tw.kill()
	_pulse_tw = null
	if _pulse_base == null:
		_pulse_base = _player.get_theme_color("font_color")
	_player.add_theme_color_override("font_color", _pulse_base)
	if not mine:
		return
	_pulse_tw = _player.create_tween().set_loops()
	_pulse_tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_pulse_tw.tween_method(_set_name_color, _pulse_base as Color, _PULSE_COLOR, _PULSE_PERIOD)
	_pulse_tw.tween_method(_set_name_color, _PULSE_COLOR, _pulse_base as Color, _PULSE_PERIOD)


func _set_name_color(c: Color) -> void:
	_player.add_theme_color_override("font_color", c)


func set_doom(filled: int) -> void:
	_doom.filled = filled


## Максимальное значение Doom — зависит от Древнего. По умолчанию 12.
func set_max_doom(value: int) -> void:
	_doom.max_doom = value


## Поворот компасного диска слева (0..N, где каждая «ступень» — 45°).
## Анимируется плавно (~300 мс).
func set_omens_step(step: float) -> void:
	_omens.current_step = step


## Число справа в зелёном орбе (текущий раунд / счётчик).
func set_info(text: String) -> void:
	_info.label_text = text
