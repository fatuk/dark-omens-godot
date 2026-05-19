extends CanvasLayer

## HUD-панель основной игровой информации.
## Тонкий API — наружу выставлены простые сеттеры.

@onready var _phase:  Label   = %PhaseLabel
@onready var _player: Label   = %PlayerLabel
@onready var _doom:   Control = %DoomTrack
@onready var _omens:  Control = %OmensDial
@onready var _info:   Control = %InfoOrb

## Клик по орбу раунда — для открытия сайдбара текущей Мистерии.
signal round_clicked


func _ready() -> void:
	_info.mouse_filter = Control.MOUSE_FILTER_STOP
	_info.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_info.gui_input.connect(_on_info_gui_input)


func _on_info_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			round_clicked.emit()


func set_phase(text: String) -> void:
	_phase.text = text


func set_player(text: String) -> void:
	_player.text = text


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
