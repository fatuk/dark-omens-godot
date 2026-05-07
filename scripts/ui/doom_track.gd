extends Control

## Дискретный прогресс-бар «следа Рока».
## Показывает SEGMENTS ячеек, заполнено `filled` штук слева.
## Tail (наконечник) сидит на границе заполненной/пустой части.

const SEGMENTS:    int   = 12
const TAIL_HALF_W: float = 11.0   # tail 22 px wide, half для центрирования

@export_range(0, 12) var filled: int = 0:
	set(v):
		filled = clampi(v, 0, SEGMENTS)
		_apply()

@onready var _progress: TextureProgressBar = %Progress
@onready var _tail:     TextureRect        = %Tail


func _ready() -> void:
	resized.connect(_apply)
	_apply()


func _apply() -> void:
	if not is_node_ready():
		return
	var pct: float = float(filled) / float(SEGMENTS)
	_progress.value = pct * _progress.max_value
	# Tail двигаем по горизонтали — сидит на правом крае активной полосы.
	# Anchor у него left=0/right=0, позиция через offset_left/right.
	var x: float = pct * size.x
	_tail.offset_left  = x - TAIL_HALF_W
	_tail.offset_right = x + TAIL_HALF_W
