extends CanvasLayer

## HUD-панель основной игровой информации.
## Тонкий API — наружу выставлены простые сеттеры.
##
## Геймпад: пока зажат левый курок (GameInput.PEEK_OMEN — он же подсматривает знамение),
## фокус на панели: крестовина между компасом (Миф), медальоном (Запасы) и орбом
## раунда (Тайна), ✕/A открывает; отпустил курок (или ○/B) — обратно на карту. Пока
## активна, панель — зона фокуса PadFocus (is_open()). Зеркально R2 у панели действий.

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
const _PAD_FOCUS_TINT := Color(1.35, 1.28, 1.08)  # элемент панели в фокусе с геймпада

var _pad_targets: Array = []  # [Control] — компас, медальон, орб (слева направо)
var _pad_active: bool = false
var _pad_trigger: bool = false  # курок был зажат в прошлом кадре


func _ready() -> void:
	_info.mouse_filter = Control.MOUSE_FILTER_STOP
	_info.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_info.gui_input.connect(_on_info_gui_input)
	_omens.clicked.connect(func() -> void: mythos_review_requested.emit())
	_build_supply_hotspot()
	add_to_group(PadFocus.ZONE)
	_add_pad_target(_omens, func() -> void: mythos_review_requested.emit())
	_add_pad_target(
		$Root/SupplyHotspot as Control, func() -> void: supply_requested.emit(), "Hover"
	)
	_add_pad_target(_info, func() -> void: round_clicked.emit())
	# Иконка курка (L2/LT) у левого края панели — только при игре с геймпада.
	var glyph := InputGlyph.make(GameInput.PEEK_OMEN, 30.0, false)
	glyph.position = Vector2(-112.0, 40.0)
	($Root as Control).add_child(glyph)


# ── Геймпад ──────────────────────────────────────────────────────────────────


## Зона фокуса PadFocus открыта, пока панель активна с геймпада.
func is_open() -> bool:
	return _pad_active


# Элемент панели, доступный с геймпада: фокус только пока панель активна; в фокусе —
# подсветка (glow_name — свой оверлей подсветки, иначе модуляция), ✕/A — open.
func _add_pad_target(ctrl: Control, open: Callable, glow_name: String = "") -> void:
	ctrl.focus_mode = Control.FOCUS_NONE
	var glow: Control = ctrl.get_node_or_null(glow_name) if glow_name else null
	ctrl.focus_entered.connect(
		func() -> void:
			if glow != null:
				_fade(glow, 1.0)
			else:
				ctrl.modulate = _PAD_FOCUS_TINT
	)
	ctrl.focus_exited.connect(
		func() -> void:
			if glow != null:
				_fade(glow, 0.0)
			else:
				ctrl.modulate = Color.WHITE
	)
	ctrl.gui_input.connect(
		func(event: InputEvent) -> void:
			if _pad_active and event.is_action_pressed(&"ui_accept"):
				ctrl.accept_event()
				_pad_exit()
				open.call()
	)
	_pad_targets.append(ctrl)


# Курок — ось: реагируем на смену состояния. Зажал — на панель; отпустил — назад.
func _process(_dt: float) -> void:
	var held: bool = Input.is_action_pressed(GameInput.PEEK_OMEN)
	if held == _pad_trigger:
		return
	_pad_trigger = held
	if not held:
		if _pad_active:
			_pad_exit()
	elif InputDevice.using_pad() and not UIStyle.any_modal_open():
		_pad_enter()


func _input(event: InputEvent) -> void:
	if _pad_active and event is InputEventJoypadButton and event.is_action_pressed(GameInput.BACK):
		_pad_exit()
		get_viewport().set_input_as_handled()


func _pad_enter() -> void:
	for c: Control in _pad_targets:
		c.focus_mode = Control.FOCUS_ALL
	_pad_active = true
	(_pad_targets[0] as Control).grab_focus()


func _pad_exit() -> void:
	_pad_active = false
	for c: Control in _pad_targets:
		if c.has_focus():
			c.release_focus()
		c.focus_mode = Control.FOCUS_NONE


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
