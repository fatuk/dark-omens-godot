extends CanvasLayer

## HUD-панель основной игровой информации.
## Тонкий API — наружу выставлены простые сеттеры.

@onready var _phase:  Label   = %PhaseLabel
@onready var _player: Label   = %PlayerLabel
@onready var _doom:   Control = %DoomTrack
@onready var _omens:  Control = %OmensDial
@onready var _info:   Control = %InfoOrb


func set_phase(text: String) -> void:
	_phase.text = text


func set_player(text: String) -> void:
	_player.text = text


func set_doom(filled: int) -> void:
	_doom.filled = filled


## Поворот компасного диска слева (0..N, где каждая «ступень» — 45°).
## Анимируется плавно (~300 мс).
func set_omens_step(step: float) -> void:
	_omens.current_step = step


## Число справа в зелёном орбе (текущий раунд / счётчик).
func set_info(text: String) -> void:
	_info.label_text = text
