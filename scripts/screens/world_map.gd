extends Node2D

# ── Константы ─────────────────────────────────────────────────────────────────

const TILE_W:    int   = 4098
const TILE_H:    int   = 4000
const ZOOM_MIN:  float = 0.5
const ZOOM_MAX:  float = 1.2
const ZOOM_STEP: float = 0.15
const ZOOM_SPEED: float = 12.0  # скорость интерполяции (выше = быстрее)

# ── Состояние перетаскивания ──────────────────────────────────────────────────

## Меньше этого числа экранных пикселей считаем за клик, не за драг.
const CLICK_THRESHOLD: float = 6.0

var _dragging:      bool    = false
var _drag_origin:   Vector2 = Vector2.ZERO
var _cam_origin:    Vector2 = Vector2.ZERO
var _drag_distance: float   = 0.0

# ── Инерция (как в Google Maps) ──────────────────────────────────────────────

## Экспоненциальное затухание скорости. Выше = быстрее тормозит.
const INERTIA_FRICTION:  float = 2.5
## Ниже этой скорости (world units/сек) — обнуляем инерцию.
const INERTIA_MIN_SPEED: float = 6.0
## Окно для расчёта flick-скорости. Берём delta между самым старым сэмплом
## в окне и последним — даже если в самом конце мышь замедлилась, флик-моментум
## сохраняется. То же делают touch UI на iOS/Android.
const FLICK_WINDOW_MS:   int   = 100

var _inertia_velocity: Vector2 = Vector2.ZERO   # world units/сек
# Кольцевые сэмплы (t_ms, screen_pos) последних мотион-эвентов в окне FLICK_WINDOW_MS.
var _drag_samples: Array = []

# ── Плавный зум ───────────────────────────────────────────────────────────────

var _zoom_target: float = 0.5

# ── Ноды ──────────────────────────────────────────────────────────────────────

@onready var _camera:     Camera2D    = $Camera2D
@onready var _game_panel: CanvasLayer = $GamePanel
@onready var _sidebar:    CanvasLayer = $LocationSidebar

var _map_layer: MapLayer


func _ready() -> void:
	_camera.position = Vector2(TILE_W / 2.0, TILE_H / 2.0)
	_zoom_target = _camera.zoom.x
	_map_layer = MapLayer.new()
	add_child(_map_layer)
	_map_layer.camera = _camera
	_map_layer.load_from_file("res://data/locations.json")

	# Привязка GamePanel к глобальному GameState
	GameState.state_changed.connect(_refresh_game_panel)
	_refresh_game_panel()

	# Сайдбар закрылся — снимаем подсветку с карты
	_sidebar.closed.connect(func() -> void: _map_layer.set_selected(""))
	# Клик по соседу в списке — открываем его как если бы кликнули по карте
	_sidebar.neighbor_selected.connect(_on_neighbor_selected)


# Обновляем верхний HUD по текущему стейту игры.
func _refresh_game_panel() -> void:
	_game_panel.set_phase(_phase_label_for(GameState.phase))
	_game_panel.set_player(_current_player_name())
	_game_panel.set_doom(GameState.doom)
	_game_panel.set_omens_step(float(GameState.omens_step))
	_game_panel.set_info(_to_roman(GameState.round_num))


func _phase_label_for(p: String) -> String:
	match p:
		"action":    return "Действия"
		"encounter": return "Встречи"
		"mythos":    return "Мифы"
	return ""


func _current_player_name() -> String:
	# Активный игрок есть в action и encounter фазах (обе последовательные)
	if GameState.phase != "action" and GameState.phase != "encounter":
		return ""
	if GameState.turn_order.is_empty():
		return ""
	var pid: String = GameState.turn_order[GameState.current_idx]
	if not GameState.players.has(pid):
		return ""
	# Показываем имя сыщика (не username игрока)
	return GameState.players[pid].get("investigator", "???")


func _process(delta: float) -> void:
	# Инерция панорамирования
	if _inertia_velocity.length_squared() > 0.0:
		_camera.position += _inertia_velocity * delta
		_apply_bounds()
		# Экспоненциальное затухание (frame-rate independent)
		_inertia_velocity *= exp(-INERTIA_FRICTION * delta)
		if _inertia_velocity.length() < INERTIA_MIN_SPEED:
			_inertia_velocity = Vector2.ZERO

	# Плавная интерполяция зума
	var current: float = _camera.zoom.x
	if not is_equal_approx(current, _zoom_target):
		var new_zoom: float = lerpf(current, _zoom_target, ZOOM_SPEED * delta)
		_camera.zoom = Vector2.ONE * new_zoom
		_apply_bounds()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_start_drag(mb.position)
				else:
					_dragging = false
					if _drag_distance < CLICK_THRESHOLD:
						_handle_click(mb.position)
					else:
						_release_with_inertia()
			MOUSE_BUTTON_MIDDLE:
				if mb.pressed:
					_start_drag(mb.position)
				else:
					_dragging = false
					_release_with_inertia()
			MOUSE_BUTTON_WHEEL_UP:
				_zoom_target = clamp(_zoom_target + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_target = clamp(_zoom_target - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)

	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		var delta: Vector2 = motion.position - _drag_origin
		_drag_distance = maxf(_drag_distance, delta.length())
		_camera.position = _cam_origin - delta / _camera.zoom
		_apply_bounds()
		_push_sample(motion.position)


# ── Драг + инерция ───────────────────────────────────────────────────────────

func _start_drag(pos: Vector2) -> void:
	_dragging         = true
	_drag_origin      = pos
	_cam_origin       = _camera.position
	_drag_distance    = 0.0
	_inertia_velocity = Vector2.ZERO   # отменяем текущий «полёт»
	_drag_samples.clear()
	_push_sample(pos)


func _push_sample(pos: Vector2) -> void:
	var now: int = Time.get_ticks_msec()
	_drag_samples.append({"t": now, "p": pos})
	# Хвост: оставляем сэмплы в пределах окна FLICK_WINDOW_MS от текущего push'а.
	while _drag_samples.size() > 1 and now - int(_drag_samples[0].t) > FLICK_WINDOW_MS:
		_drag_samples.pop_front()


func _release_with_inertia() -> void:
	var now: int = Time.get_ticks_msec()
	# Доп. трим уже от ТЕКУЩЕГО момента: если после последнего motion прошла пауза,
	# все «старые» сэмплы (из активной фазы) выкидываются — юзер замер и решил
	# отпустить, инерции быть не должно.
	while _drag_samples.size() > 0 and now - int(_drag_samples[0].t) > FLICK_WINDOW_MS:
		_drag_samples.pop_front()

	if _drag_samples.size() < 2:
		_drag_samples.clear()
		return

	var first: Dictionary = _drag_samples[0]
	var last:  Dictionary = _drag_samples[-1]
	# dt считаем от первого сэмпла до МОМЕНТА RELEASE (now), а не до last.t.
	# Так короткая пауза между последним движением и отпусканием увеличивает
	# знаменатель → скорость падает пропорционально длине паузы.
	var dt: float = float(now - int(first.t)) / 1000.0
	if dt < 0.005:
		_drag_samples.clear()
		return
	var screen_v: Vector2 = (Vector2(last.p) - Vector2(first.p)) / dt
	# Камера движется в обратную сторону от мыши, в world-координатах.
	_inertia_velocity = -screen_v / _camera.zoom.x
	_drag_samples.clear()


# ── Клик по локации ──────────────────────────────────────────────────────────

func _handle_click(screen_pos: Vector2) -> void:
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var world_pos: Vector2 = _camera.position + (screen_pos - vp_size * 0.5) / _camera.zoom
	var loc_name: String = _map_layer.try_pick(world_pos)
	if loc_name.is_empty():
		return
	var data: Dictionary = _map_layer.get_location(loc_name)
	if data.is_empty():
		return
	_sidebar.show_location(data)
	_map_layer.set_selected(loc_name)


func _on_neighbor_selected(loc_name: String) -> void:
	var data: Dictionary = _map_layer.get_location(loc_name)
	if data.is_empty():
		return
	_sidebar.show_location(data)
	_map_layer.set_selected(loc_name)


# ── Утилиты ───────────────────────────────────────────────────────────────────

## Целое 1..3999 → римские цифры. Для номера раунда хватит с большим запасом.
func _to_roman(n: int) -> String:
	if n <= 0:
		return "0"
	const VALS := [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
	const SYMS := ["M",  "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
	var result := ""
	var v: int = n
	for i in VALS.size():
		while v >= VALS[i]:
			result += SYMS[i]
			v -= VALS[i]
	return result


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
