extends Control

## Компасный диск «омен» — слева на главной панели.
## Внутренний Circle вращается через rotation_degrees (показывая разные омены),
## но виден только через круглую маску в шейдере (привязана к canvas-центру
## контейнера, не вращается с диском).
##
## current_step — текущее состояние из игры. При наведении мышью диск
## плавно подкручивается на +0.3 шага, чтобы юзер мог «подсмотреть»
## следующий омен. Уход мыши — возвращает на current_step.

const STEP_DEG:        float = 45.0
const START_ANGLE_DEG: float = -82.0   # как в React-прототипе
const PEEK_AMOUNT:     float = 0.3
const TWEEN_TIME:      float = 0.3     # секунды
const MASK_RADIUS:     float = 46.0    # радиус видимого окошка в canvas-координатах

@export var current_step: float = 0.0:
	set(v):
		current_step = v
		_animate_to(current_step)

@onready var _circle: TextureRect = %Circle

var _tween: Tween = null
var _last_center: Vector2 = Vector2.INF


func _ready() -> void:
	mouse_entered.connect(_on_hover)
	mouse_exited.connect(_on_unhover)
	# Первый layout-pass для корректных global_position/size
	await get_tree().process_frame
	_update_mask_center()
	_circle.rotation_degrees = _angle_for(current_step)


func _process(_delta: float) -> void:
	# Если позиция компонента поменялась (resize окна и т.д.) — пересчитываем.
	_update_mask_center()


func _on_hover() -> void:
	_animate_to(current_step + PEEK_AMOUNT)


func _on_unhover() -> void:
	_animate_to(current_step)


func _animate_to(step_value: float) -> void:
	if not is_instance_valid(_circle):
		return
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_circle, "rotation_degrees", _angle_for(step_value), TWEEN_TIME)


func _angle_for(step_value: float) -> float:
	return START_ANGLE_DEG + step_value * STEP_DEG


func _update_mask_center() -> void:
	if not is_instance_valid(_circle):
		return
	var mat: ShaderMaterial = _circle.material as ShaderMaterial
	if mat == null:
		return
	var center: Vector2 = global_position + size * 0.5
	if center == _last_center:
		return
	_last_center = center
	mat.set_shader_parameter("mask_center", center)
	mat.set_shader_parameter("mask_radius", MASK_RADIUS)
