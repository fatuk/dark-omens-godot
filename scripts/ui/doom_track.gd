extends Control

## Дискретный прогресс-бар «следа Рока».
## Показывает max_doom ячеек, заполнено `filled` штук слева.
##
## BG (фон) и Fill (зелёная заливка) — два TextureRect. Заливка использует
## шейдер с fill_pct + fade_width: правый край плавно фейдится до прозрачного,
## так что вместо «тейла-набалдашника» получается мягкое затухание прогресса.
## Дивайдеры между ячейками рисуются программно, max_doom настраивается под Древнего.

const TWEEN_TIME:    float = 0.3
const DIVIDER_WIDTH: float = 2.0
# Цвет из React-прототипа: #2b941161 (тёмно-зелёный с alpha ~0.38).
const DIVIDER_COLOR: Color = Color(0.169, 0.580, 0.067, 0.380)

@export var max_doom: int = 12:
	set(v):
		max_doom = maxi(1, v)
		filled   = clampi(filled, 0, max_doom)
		_rebuild_dividers()
		_apply_pct(_pct_for(filled))

@export_range(0, 99) var filled: int = 0:
	set(v):
		filled = clampi(v, 0, max_doom)
		_animate_to(_pct_for(filled))

@onready var _bg:       TextureRect = $Bg
@onready var _fill:     TextureRect = %Fill
@onready var _dividers: Control     = %Dividers

var _displayed_pct: float = 0.0
var _tween:         Tween = null


func _ready() -> void:
	resized.connect(_on_resized)
	_rebuild_dividers()
	_update_mask_size()
	_displayed_pct = _pct_for(filled)
	_apply_pct(_displayed_pct)


func _on_resized() -> void:
	_update_mask_size()
	_apply_pct(_displayed_pct)


func _update_mask_size() -> void:
	for rect: TextureRect in [_bg, _fill]:
		var mat: ShaderMaterial = rect.material as ShaderMaterial
		if mat:
			mat.set_shader_parameter("rect_size", size)


func _pct_for(value: int) -> float:
	return float(value) / float(maxi(1, max_doom))


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
	var mat: ShaderMaterial = _fill.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("fill_pct", pct)


# ── Дивайдеры между ячейками ──────────────────────────────────────────────────

func _rebuild_dividers() -> void:
	if not is_node_ready():
		return
	for child in _dividers.get_children():
		child.queue_free()
	# (max_doom - 1) вертикальных линий: между ячейками
	for i in range(1, max_doom):
		var line := ColorRect.new()
		line.name  = "D%d" % i
		line.color = DIVIDER_COLOR
		var x_frac: float = float(i) / float(max_doom)
		line.anchor_left   = x_frac
		line.anchor_right  = x_frac
		line.anchor_top    = 0.0
		line.anchor_bottom = 1.0
		line.offset_left   = -DIVIDER_WIDTH * 0.5
		line.offset_right  =  DIVIDER_WIDTH * 0.5
		line.mouse_filter  = Control.MOUSE_FILTER_IGNORE
		_dividers.add_child(line)
