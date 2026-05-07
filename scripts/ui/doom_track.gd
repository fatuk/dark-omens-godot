extends Control

## Дискретный прогресс-бар «следа Рока».
## Показывает SEGMENTS ячеек, заполнено `filled` штук слева.
## Tail (наконечник) сидит на границе заполненной/пустой части.
## Изменение filled плавно анимируется (~300 мс).

const SEGMENTS:    int   = 12
const TAIL_HALF_W: float = 11.0   # tail 22 px wide, half для центрирования
const TWEEN_TIME:  float = 0.3

@export_range(0, 12) var filled: int = 0:
	set(v):
		filled = clampi(v, 0, SEGMENTS)
		_animate_to(float(filled) / float(SEGMENTS))

@onready var _progress: TextureProgressBar = %Progress
@onready var _tail:     TextureRect        = %Tail

var _displayed_pct: float = 0.0
var _tween: Tween = null


func _ready() -> void:
	resized.connect(_on_resized)
	_displayed_pct = float(filled) / float(SEGMENTS)
	_apply_pct(_displayed_pct)


func _on_resized() -> void:
	# При ресайзе только перерисовываем по уже сохранённому проценту,
	# без новой анимации.
	_apply_pct(_displayed_pct)


func _animate_to(target_pct: float) -> void:
	if not is_node_ready():
		return
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_apply_pct, _displayed_pct, target_pct, TWEEN_TIME)


func _apply_pct(pct: float) -> void:
	_displayed_pct = pct
	if not is_node_ready():
		return
	_progress.value = pct * _progress.max_value
	var x: float = pct * size.x
	_tail.offset_left  = x - TAIL_HALF_W
	_tail.offset_right = x + TAIL_HALF_W
