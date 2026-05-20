extends Node2D

# ── Константы ─────────────────────────────────────────────────────────────────

# Размер тайла карты — единственный источник правды в MapLayer.TILE_W/TILE_H.
# Здесь дублировать не надо: world_map двигает камеру по тем же координатам,
# что MapLayer рисует маркеры.

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
@onready var _mystery:    CanvasLayer = $MysterySidebar

var _map_layer: MapLayer

# Интро-гейт: блокирующая модалка-цепочка (загрузка → Древний → первая
# Тайна → карта), строится в коде.
var _campaign_gate: CanvasLayer   = null
var _gate_vbox:     VBoxContainer = null
var _intro_step:    int           = 0   # 0=загрузка 1=Древний 2=Тайна 3=готово
var _gate_rendered: int           = -1  # последний отрисованный шаг


func _ready() -> void:
	# Игровая музыка — основной трек, общий для всех экранов, кроме выбора
	# сыщика (там picker сам ставит TRACK_NO_CHOICE). Придя из лобби, где
	# играл NO_CHOICE, MusicManager переключит трек обратно на основной.
	MusicManager.play(MusicManager.TRACK_ELDER_SIGN)

	# На карте мира декоративная рамка лишняя (карта — основная игровая сцена,
	# UI поверх неё в виде GamePanel/LocationSidebar). Возвращаем при выходе.
	ScreenFrame.set_enabled(false)
	_camera.position = Vector2(MapLayer.TILE_W / 2.0, MapLayer.TILE_H / 2.0)
	_zoom_target = _camera.zoom.x

	_map_layer = MapLayer.new()
	_map_layer.name = "MapLayer"
	add_child(_map_layer)
	_map_layer.camera = _camera
	_map_layer.load_from_file("res://data/locations.json")

	# Привязка GamePanel к глобальному GameState
	GameState.state_changed.connect(_refresh_game_panel)
	GameState.state_changed.connect(_refresh_investigators)
	GameState.state_changed.connect(_refresh_campaign_gate)
	_build_campaign_gate()
	_refresh_game_panel()
	_refresh_investigators()
	_refresh_campaign_gate()

	# Сайдбар закрылся — снимаем подсветку с карты
	_sidebar.closed.connect(func() -> void: _map_layer.set_selected(""))
	# Клик по соседу в списке — открываем его как если бы кликнули по карте
	_sidebar.neighbor_selected.connect(_on_neighbor_selected)
	# Клик по орбу раунда — открыть/закрыть сайдбар текущей Мистерии.
	_game_panel.round_clicked.connect(_on_round_clicked)
	# Смена языка не требует здесь обработки: данные локаций/сыщиков содержат
	# translation keys, лейблы Godot переводит автоматически при смене локали.


func _exit_tree() -> void:
	ScreenFrame.set_enabled(true)


# Обновляем верхний HUD по текущему стейту игры.
func _refresh_game_panel() -> void:
	_game_panel.set_phase(_phase_label_for(GameState.phase))
	_game_panel.set_player(_current_player_name())
	_game_panel.set_doom(GameState.doom)
	_game_panel.set_omens_step(float(GameState.omens_step))
	_game_panel.set_info(_to_roman(GameState.round_num))


## Обновляет маркеры сыщиков на карте по позициям из GameState.
func _refresh_investigators() -> void:
	if not is_instance_valid(_map_layer):
		return
	var list: Array = []
	for pid: String in GameState.players:
		var p: Dictionary = GameState.players[pid]
		list.append({
			"pid":          pid,
			"investigator": String(p.get("investigator", "")),
			"location":     String(p.get("location", "")),
		})
	_map_layer.set_investigators(list)


func _phase_label_for(p: String) -> String:
	match p:
		"action":    return "PHASE_ACTION"
		"encounter": return "PHASE_ENCOUNTER"
		"mythos":    return "PHASE_MYTHOS"
	return ""


func _current_player_name() -> String:
	if GameState.phase != "action" and GameState.phase != "encounter":
		return ""
	if GameState.turn_order.is_empty():
		return ""
	var pid: String = GameState.turn_order[GameState.current_idx]
	if not GameState.players.has(pid):
		return ""
	var inv_id: String = GameState.players[pid].get("investigator", "???")
	return Investigators.display_name(inv_id)


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


func _on_round_clicked() -> void:
	_mystery.toggle()


# ── Интро-гейт: загрузка → Древний → первая Тайна → карта ────────────────────

## Строит блокирующую модалку поверх всех слоёв. Контент шага наполняет
## _render_gate().
func _build_campaign_gate() -> void:
	var layer := CanvasLayer.new()
	layer.name    = "CampaignGate"
	layer.layer   = 90
	layer.visible = false
	add_child(layer)

	var backdrop := ColorRect.new()
	backdrop.name  = "Backdrop"
	backdrop.color = Color(0.03, 0.03, 0.07, 0.96)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(backdrop)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.add_child(center)

	var panel := UIStyle.panel(32)
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(620.0, 0.0)
	center.add_child(panel)

	_gate_vbox = VBoxContainer.new()
	_gate_vbox.name = "VBox"
	_gate_vbox.add_theme_constant_override("separation", 14)
	panel.add_child(_gate_vbox)

	_campaign_gate = layer


## Шаг 0 (загрузка) ведётся campaign_pending; дальше — кнопками интро.
func _refresh_campaign_gate() -> void:
	if not is_instance_valid(_campaign_gate):
		return
	if GameState.campaign_pending:
		_intro_step = 0
	elif _intro_step == 0:
		# кампания готова: показываем Древнего; нет кампании — сразу на карту
		_intro_step = 1 if not GameState.campaign.is_empty() else 3
	_campaign_gate.visible = _intro_step < 3
	if _campaign_gate.visible and _intro_step != _gate_rendered:
		_gate_rendered = _intro_step
		_render_gate()


## Наполняет панель гейта содержимым текущего шага.
func _render_gate() -> void:
	for child in _gate_vbox.get_children():
		child.queue_free()
	match _intro_step:
		0:
			_gate_title("CAMPAIGN_GATE_TITLE")
			_gate_body("CAMPAIGN_GATE_BODY")
		1:
			var ao: Dictionary = GameState.campaign.get("ancientOne", {})
			_gate_eyebrow("INTRO_ANCIENT_EYEBROW")
			_gate_title(String(ao.get("name", "")))
			var epithet: String = String(ao.get("epithet", ""))
			if not epithet.is_empty():
				_gate_subtitle(epithet)
			_gate_body(String(ao.get("description", "")))
			_gate_button("INTRO_NEXT", _on_gate_next)
		2:
			var m: Dictionary = GameState.current_mystery()
			_gate_eyebrow("INTRO_MYSTERY_EYEBROW")
			_gate_title(String(m.get("title", "")))
			var flavor: String = String(m.get("flavorText", ""))
			if not flavor.is_empty():
				_gate_body(flavor)
			_gate_body(String(m.get("text", "")))
			_gate_button("INTRO_START", _on_gate_start)


func _on_gate_next() -> void:
	_intro_step = 2
	_refresh_campaign_gate()


func _on_gate_start() -> void:
	_intro_step = 3
	_refresh_campaign_gate()


# ── Хелперы наполнения гейта ──────────────────────────────────────────────────

func _gate_eyebrow(text: String) -> void:
	var lbl := UIStyle.label(text, 12, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Eyebrow"
	_gate_vbox.add_child(lbl)


func _gate_title(text: String) -> void:
	var lbl := UIStyle.label(text, 26, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Title"
	_gate_vbox.add_child(lbl)


func _gate_subtitle(text: String) -> void:
	var lbl := UIStyle.label(text, 15, UIColors.WARNING, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Subtitle"
	_gate_vbox.add_child(lbl)


func _gate_body(text: String) -> void:
	var lbl := UIStyle.label(text, 15, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Body"
	lbl.custom_minimum_size = Vector2(540.0, 0.0)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_gate_vbox.add_child(lbl)


func _gate_button(text: String, handler: Callable) -> void:
	var btn := UIStyle.button(text)
	btn.name = "GateButton"
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.pressed.connect(handler)
	_gate_vbox.add_child(btn)


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
	_camera.position.x = fmod(_camera.position.x, float(MapLayer.TILE_W))
	if _camera.position.x < 0.0:
		_camera.position.x += MapLayer.TILE_W

	# Вертикальный clamp: не выходим за верх/низ карты
	var vp_half_h: float = get_viewport().get_visible_rect().size.y * 0.5 / _camera.zoom.y
	_camera.position.y = clamp(_camera.position.y, vp_half_h, MapLayer.TILE_H - vp_half_h)
