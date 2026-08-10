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

## Клик по орбу раунда — для открытия сайдбара текущей Мистерии.
signal round_clicked

## Клик по компасу знамений — «перечитать последний миф».
signal mythos_review_requested

## Кнопка «Запасы» — окно колод и сбросов.
signal supply_requested


func _ready() -> void:
	_info.mouse_filter = Control.MOUSE_FILTER_STOP
	_info.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_info.gui_input.connect(_on_info_gui_input)
	_omens.clicked.connect(func() -> void: mythos_review_requested.emit())
	_build_supply_btn()


# Кнопка «Запасы» в правом углу панели — строим кодом, чтобы не трогать раскладку
# сцены (позиции остальных элементов там выверены по арту фона).
func _build_supply_btn() -> void:
	var btn := UIStyle.button("SUPPLY_BTN")
	btn.name = "SupplyBtn"
	btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	btn.offset_left = -190.0
	btn.offset_right = -24.0
	btn.offset_top = 18.0
	btn.offset_bottom = 54.0
	btn.pressed.connect(func() -> void: supply_requested.emit())
	($Root as Control).add_child(btn)


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
