extends Node2D

# ── Константы ─────────────────────────────────────────────────────────────────

const TILE_W:    int   = 4098
const TILE_H:    int   = 4000
const ZOOM_MIN:  float = 0.5
const ZOOM_MAX:  float = 1.2
const ZOOM_STEP: float = 0.15
const ZOOM_SPEED: float = 12.0  # скорость интерполяции (выше = быстрее)

# ── Состояние перетаскивания ──────────────────────────────────────────────────

var _dragging:    bool    = false
var _drag_origin: Vector2 = Vector2.ZERO
var _cam_origin:  Vector2 = Vector2.ZERO

# ── Плавный зум ───────────────────────────────────────────────────────────────

var _zoom_target: float = 0.5

# ── Ноды ──────────────────────────────────────────────────────────────────────

@onready var _camera: Camera2D = $Camera2D


func _ready() -> void:
	_camera.position = Vector2(TILE_W / 2.0, TILE_H / 2.0)
	_zoom_target = _camera.zoom.x


func _process(delta: float) -> void:
	# Плавная интерполяция зума
	var current: float = _camera.zoom.x
	if not is_equal_approx(current, _zoom_target):
		var new_zoom: float = lerpf(current, _zoom_target, ZOOM_SPEED * delta)
		_camera.zoom = Vector2.ONE * new_zoom
		_apply_bounds()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE:
				if mb.pressed:
					_dragging = true
					_drag_origin = mb.position
					_cam_origin  = _camera.position
				else:
					_dragging = false
			MOUSE_BUTTON_WHEEL_UP:
				_zoom_target = clamp(_zoom_target + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_target = clamp(_zoom_target - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)

	elif event is InputEventMouseMotion and _dragging:
		var delta: Vector2 = (event as InputEventMouseMotion).position - _drag_origin
		_camera.position = _cam_origin - delta / _camera.zoom
		_apply_bounds()


# ── Зум ───────────────────────────────────────────────────────────────────────

# Устарело — оставлено для совместимости, используй _zoom_target напрямую
func _set_zoom(value: float) -> void:
	_zoom_target = clamp(value, ZOOM_MIN, ZOOM_MAX)


# ── Границы и горизонтальная бесконечность ────────────────────────────────────

func _apply_bounds() -> void:
	# Горизонтальный wrap: камера всегда остаётся в [0, TILE_W)
	# Три тайла рядом делают переход незаметным
	_camera.position.x = fmod(_camera.position.x, float(TILE_W))
	if _camera.position.x < 0.0:
		_camera.position.x += TILE_W

	# Вертикальный clamp: не выходим за верх/низ карты
	var vp_half_h: float = get_viewport().get_visible_rect().size.y * 0.5 / _camera.zoom.y
	_camera.position.y = clamp(_camera.position.y, vp_half_h, TILE_H - vp_half_h)
