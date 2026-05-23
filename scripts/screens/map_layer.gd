extends Node2D
class_name MapLayer

## Отрисовывает локации и связи карты мира.
## Маркеры и подписи сохраняют постоянный экранный размер при любом зуме.

# ── Константы карты ───────────────────────────────────────────────────────────

const TILE_W: int = 4098
const TILE_H: int = 4000

## Смещение всех маркеров и связей в мировых пикселях.
@export var offset: Vector2 = Vector2(-120.0, 10.0)

# ── Цвета связей ──────────────────────────────────────────────────────────────

const COLOR_SHIP:      Color = Color(0.275, 0.510, 0.706, 0.90)  # #4682B4
const COLOR_TRAIN:     Color = Color(0.627, 0.322, 0.176, 0.90)  # #A0522D
const COLOR_UNCHARTED: Color = Color(1.000, 0.843, 0.000, 0.90)  # #FFD700

# ── Параметры отрисовки ───────────────────────────────────────────────────────

const LINE_W:         float = 1.8
const GC_STEPS:       int   = 48
## Экранный размер маркера локации (в пикселях). Лерпится по zoom:
## на дальнем зуме маркер компактный (_FAR), на близком — крупный (_NEAR,
## исторические 100/50, которыми пользовались до уменьшения общего масштаба).
const MARKER_SCREEN_FAR:   float = 67.0
const MARKER_SCREEN_NEAR:  float = 100.0
## Отступ от центра маркера до верха подписи. Лерпится синхронно с маркером,
## чтобы подпись не отрывалась/не наезжала при изменении масштаба.
const LABEL_SCREEN_Y_FAR:  float = 33.0
const LABEL_SCREEN_Y_NEAR: float = 50.0
const LABEL_FONT:     int   = 14    # шрифт в экранных пикселях
## Фото-карточка сыщика (avatar-pin): целевая экранная высота, подъём над
## локацией (низ карточки у точки локации), горизонтальный разнос при веере.
## Высота лерпится по зуму (как маркер): на дальнем зуме ≈1.5× меньше, на
## ближнем — полный размер. Подъём/разнос масштабируются тем же фактором,
## чтобы основание карточки оставалось привязанным к точке локации.
const INVESTIGATOR_CARD_H_NEAR: float = 150.0
const INVESTIGATOR_CARD_H_FAR:  float = 100.0   # ≈1.5× меньше на дальнем зуме
const INVESTIGATOR_OFFSET_Y:    float = -112.0   # подъём над жетоном локации
const INVESTIGATOR_FAN_X:       float = 55.0

## Открытые врата: два слоя (outer/inner) на маркере локации. Оба вращаются,
## inner ощутимо быстрее. Размер обоих ≈ MARKER_SCREEN (заполняют кружок).
const GATE_OUTER_TEX: Dictionary = {
	"red":   preload("res://assets/gates/gate-red-outer.png"),
	"green": preload("res://assets/gates/gate-green-outer.png"),
	"blue":  preload("res://assets/gates/gate-blue-outer.png"),
}
const GATE_INNER_TEX: Dictionary = {
	"red":   preload("res://assets/gates/gate-red-inner.png"),
	"green": preload("res://assets/gates/gate-green-inner.png"),
	"blue":  preload("res://assets/gates/gate-blue-inner.png"),
}
## Скорости вращения (рад/сек), оба по часовой — как в web-прототипе:
## outer — полный оборот за 15с, inner — за 8с.
const GATE_OUTER_SPEED: float = TAU / 15.0   # ≈0.419
const GATE_INNER_SPEED: float = TAU / 8.0    # ≈0.785
## Множитель размера врат относительно маркера локации — врата немного крупнее,
## чтобы полностью перекрывать кружок.
const GATE_SIZE_MULT: float = 1.1

## Сущности на локации (улики/монстры/слухи) — жетоны-иконки. В покое сложены
## стопкой ПОД маркером (позади него, с небольшим сдвигом вниз, наслоены со
## сдвигом), при наведении на локацию анимированно выезжают вправо в ряд.
const ENTITY_TEX: Dictionary = {
	"clue":    preload("res://assets/map/clue-icon.png"),
	"monster": preload("res://assets/map/monster-icon.png"),
	"rumor":   preload("res://assets/map/rumor-icon.png"),
}
# NB: параметры раскладки сущностей — var (не const), чтобы подбирать их
# вживую через MCP без пересборки. Имена в UPPER_CASE сохранены ради ссылок
# в _process/set_entities.
## Размер иконки = размер маркера локации (как в макете).
var ENTITY_SIZE_FRAC: float = 1.0
## Стопка у локации: вертикальный сдвиг точки стопки (0 — на одной горизонтали
## с медальоном), стартовый сдвиг колоды вправо (чтобы первый жетон idx0 чуть
## выступал из-за медальона, а не прятался под ним) и сдвиг наслоения вправо
## (экранные px). Жетоны рисуются позади медальона (z=1 < 2) — выглядывают вправо.
var ENTITY_STACK_Y:  float = 0.0
var ENTITY_STACK_X0: float = 20.0
var ENTITY_STACK_DX: float = 18.0
## Выезд в ряд по наведению: шаг между иконками + сдвиг начала ряда вправо.
## ROW_X0 ≈ размер маркера, чтобы первый жетон (idx0) выходил из-за медальона,
## а не прятался под ним.
var ENTITY_ROW_GAP:  float = 42.0
var ENTITY_ROW_X0:   float = 40.0
## Радиус наведения (доля маркера) и скорость сглаживания выезда.
var ENTITY_HOVER_RADIUS_FRAC: float = 0.75
var ENTITY_HOVER_LERP:        float = 12.0

# ── Зависимости ───────────────────────────────────────────────────────────────

## Задаётся из world_map.gd после add_child.
var camera: Camera2D = null

## Диапазон зума камеры — точки лерпа MARKER_SCREEN_FAR/_NEAR. Дефолты
## совпадают с ZOOM_MIN/ZOOM_MAX в world_map.gd; world_map переустанавливает
## их явно после add_child, чтобы единый источник правды остался там.
var zoom_min: float = 0.5
var zoom_max: float = 1.2

# ── Данные ────────────────────────────────────────────────────────────────────

var _locs:             Dictionary = {}
var _edges:            Array      = []
var _markers:          Array      = []   # [{sprite, label, indicator, pos, loc_name}]
var _textures:         Dictionary = {}
var _selected_name:    String     = ""

# Маркеры сыщиков — поверх маркеров локаций.
var _inv_markers:   Array     = []    # [{sprite, base, screen_off, base_scale}]
var _inv_signature: String    = ""    # для пропуска лишних перестроений
var _token_tex:     Texture2D = null  # запасной жетон (нет файла портрета)

# Открытые врата: по 3 пары (outer+inner) на каждые врата для wrap-копий.
# Накопленные углы общие на все спрайты — wrap-копии крутятся синхронно.
var _gate_markers:     Array  = []    # [{outer, inner, outer_h, inner_h}]
var _gate_signature:   String = ""    # ключ для пропуска лишних перестроений
var _gate_outer_angle: float  = 0.0
var _gate_inner_angle: float  = 0.0

# Сущности на локациях — иконки стопкой над маркером (выезжают в ряд по hover).
var _entity_markers:   Array     = []    # [{sprite, base, idx, tex_h, loc_id, hover}]
var _entity_signature: String    = ""
# Какие локации сейчас под курсором (для SFX по фронту наведения/ухода).
var _entity_hover_state: Dictionary = {}  # {loc_id: true}


# ── Загрузка ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_textures = {
		"city":       load("res://assets/city.png"),
		"sea":        load("res://assets/sea.png"),
		"wilderness": load("res://assets/wilderness.png"),
	}


func load_from_file(path: String) -> void:
	for child in get_children():
		child.queue_free()
	_markers.clear()
	_inv_markers.clear()
	_inv_signature = ""
	_gate_markers.clear()
	_gate_signature = ""
	_entity_markers.clear()
	_entity_signature = ""
	_entity_hover_state.clear()
	_locs.clear()

	var data: Array = DataLoader.load_array(path)
	if data.is_empty():
		push_error("MapLayer: пустые данные локаций (%s)" % path)
		return

	for i: int in range(data.size()):
		var loc: Dictionary = data[i]
		# id — стабильный slug ("arkham", "1"), не показывается пользователю.
		# name — translation key с игровым именем (LOC_*_NAME), Godot переводит.
		var loc_id: String = String(loc.get("id", ""))
		if loc_id.is_empty():
			continue
		var coords: Array = loc.get("coordinates", [])
		if coords.size() < 2:
			continue
		var lat: float = float(coords[0])
		var lon: float = float(coords[1])
		_locs[loc_id] = {
			"pos":               _geo_to_pixel(lat, lon),
			"lat":               lat,
			"lon":               lon,
			"type":              loc.get("type", "city"),
			"connections":       loc.get("connections", []),
			"name":              String(loc.get("name", loc_id)),  # translation key
			"realWorldLocation": loc.get("realWorldLocation", ""),
			"description":       loc.get("description", ""),
		}

	_build_edges()
	_spawn_markers()
	queue_redraw()


# ── Обновление масштаба каждый кадр ──────────────────────────────────────────

## t∈[0,1]: 0 на дальнем зуме (zoom_min), 1 на близком (zoom_max). Используется
## для лерпа размеров маркера и зависимых от него UI-элементов.
func _zoom_t() -> float:
	if not is_instance_valid(camera):
		return 0.0
	var z: float = camera.zoom.x
	return clampf((z - zoom_min) / maxf(zoom_max - zoom_min, 0.0001), 0.0, 1.0)


## Текущий экранный размер маркера локации с учётом зума.
func _marker_screen_size() -> float:
	return lerpf(MARKER_SCREEN_FAR, MARKER_SCREEN_NEAR, _zoom_t())


func _process(delta: float) -> void:
	if not is_instance_valid(camera):
		return
	var z: float   = camera.zoom.x
	var inv: float = 1.0 / z
	var t: float   = _zoom_t()
	var marker_screen: float = lerpf(MARKER_SCREEN_FAR,  MARKER_SCREEN_NEAR,  t)
	var label_y:       float = lerpf(LABEL_SCREEN_Y_FAR, LABEL_SCREEN_Y_NEAR, t)
	# Множитель «насколько крупнее маркер сейчас по сравнению с FAR»:
	# 1.0 на дальнем зуме, ≈1.49 на близком. Им же масштабируется индикатор
	# подсветки (RING/GLOW в SelectionIndicator заданы под FAR-размер).
	var marker_factor: float = marker_screen / MARKER_SCREEN_FAR

	# Мировой размер = желаемый экранный размер / зум
	var sp_scale:  Vector2 = Vector2.ONE * (marker_screen / 150.0) * inv
	var ind_scale: Vector2 = Vector2.ONE * inv * marker_factor

	for i: int in range(_markers.size()):
		var m: Dictionary       = _markers[i]
		var sp: Sprite2D        = m.sprite    as Sprite2D
		var lb: Label           = m.label     as Label
		var ind: Node2D         = m.indicator as Node2D

		if is_instance_valid(sp):
			sp.scale = sp_scale

		if is_instance_valid(ind) and ind.visible:
			ind.scale = ind_scale

		if is_instance_valid(lb) and lb.size.x > 0.0:
			lb.scale    = Vector2.ONE * inv
			lb.position = m.pos + Vector2(
				-lb.size.x * inv * 0.5,   # горизонтальное центрирование
				label_y * inv             # отступ ниже маркера (лерп по zoom)
			)

	# Фото-карточки сыщиков — высота лерпится по зуму (FAR/NEAR). Подъём над
	# локацией масштабируется тем же фактором, чтобы основание карточки
	# оставалось привязанным к точке локации при любом зуме.
	var inv_factor: float = lerpf(INVESTIGATOR_CARD_H_FAR, INVESTIGATOR_CARD_H_NEAR, t) / INVESTIGATOR_CARD_H_NEAR
	for i: int in range(_inv_markers.size()):
		var im: Dictionary = _inv_markers[i]
		var isp: Node2D    = im.sprite as Node2D
		if not is_instance_valid(isp):
			continue
		var ibase: Vector2 = im.base
		var ioff:  Vector2 = im.screen_off
		var iscale: float  = im.base_scale
		isp.scale    = Vector2.ONE * iscale * inv * inv_factor
		isp.position = ibase + ioff * inv * inv_factor

	# Открытые врата — заполняют кружок маркера, оба слоя вращаются.
	# Накопленные углы общие для всех wrap-копий — они крутятся синхронно.
	if not _gate_markers.is_empty():
		_gate_outer_angle += GATE_OUTER_SPEED * delta
		_gate_inner_angle += GATE_INNER_SPEED * delta
		var gate_screen: float = marker_screen * GATE_SIZE_MULT
		for i: int in range(_gate_markers.size()):
			var g: Dictionary = _gate_markers[i]
			var outer: Sprite2D = g.outer as Sprite2D
			var inner: Sprite2D = g.inner as Sprite2D
			if is_instance_valid(outer):
				outer.scale    = Vector2.ONE * (gate_screen / float(g.outer_h)) * inv
				outer.rotation = _gate_outer_angle
			if is_instance_valid(inner):
				inner.scale    = Vector2.ONE * (gate_screen / float(g.inner_h)) * inv
				inner.rotation = _gate_inner_angle

	# Сущности — стопкой над маркером; при наведении на локацию иконки
	# анимированно выезжают вправо в ряд. hover per-marker по близости курсора
	# к центру локации (своя tile-копия активируется отдельно).
	if not _entity_markers.is_empty():
		var ent_size: float = marker_screen * ENTITY_SIZE_FRAC
		var mouse_w:  Vector2 = get_global_mouse_position()
		var hover_r:  float = marker_screen * ENTITY_HOVER_RADIUS_FRAC * inv * 0.5
		var lerp_t:   float = clampf(ENTITY_HOVER_LERP * delta, 0.0, 1.0)
		var now_hovered: Dictionary = {}   # {loc_id: true} в этом кадре
		for i: int in range(_entity_markers.size()):
			var e: Dictionary = _entity_markers[i]
			var esp: Sprite2D = e.sprite as Sprite2D
			if not is_instance_valid(esp):
				continue
			var hovered: bool = mouse_w.distance_to(e.base) <= hover_r
			if hovered:
				now_hovered[String(e.loc_id)] = true
			e.hover = lerpf(float(e.hover), 1.0 if hovered else 0.0, lerp_t)
			var idx: int = int(e.idx)
			# Отступы раскладки масштабируются marker_factor — так разнос колоды
			# и дистанция выезда растут вместе с размером иконок при зуме (иначе
			# на близком зуме крупные иконки наезжали бы друг на друга).
			var stack_x: float = (float(idx) * ENTITY_STACK_DX + ENTITY_STACK_X0) * marker_factor
			var row_x:   float = (float(idx) * ENTITY_ROW_GAP + ENTITY_ROW_X0) * marker_factor
			var off_x:   float = lerpf(stack_x, row_x, float(e.hover))
			esp.position = e.base + Vector2(off_x, ENTITY_STACK_Y * marker_factor) * inv
			esp.scale    = Vector2.ONE * (ent_size / float(e.tex_h)) * inv

		# SFX по фронту: курсор зашёл на локацию с жетонами → hover, ушёл → blur.
		# Сравниваем с состоянием прошлого кадра (по loc_id, без дублей на tile-копии).
		for lid_v: Variant in now_hovered:
			if not _entity_hover_state.has(lid_v):
				SfxManager.play(SfxManager.SFX_MAP_ITEM_HOVER)
		for lid_v: Variant in _entity_hover_state:
			if not now_hovered.has(lid_v):
				SfxManager.play(SfxManager.SFX_MAP_ITEM_BLUR)
		_entity_hover_state = now_hovered


# ── Маркеры ───────────────────────────────────────────────────────────────────

func _spawn_markers() -> void:
	for loc_name: String in _locs:
		var loc: Dictionary = _locs[loc_name]
		var tex: Texture2D  = _textures.get(loc.type, _textures["city"]) as Texture2D

		for dx: int in [-TILE_W, 0, TILE_W]:
			var world_pos: Vector2 = loc.pos + Vector2(dx, 0)
			# tile_idx: -1 = слева, 0 = центр, 1 = справа (wraparound копии).
			var tile_idx: int = sign(dx)

			var sprite := Sprite2D.new()
			sprite.name     = "Marker_%s_%d" % [loc_name, tile_idx]
			sprite.texture  = tex
			sprite.position = world_pos
			sprite.z_index  = 2   # медальон локации — над колодой сущностей (z=1)
			add_child(sprite)

			var lbl := Label.new()
			lbl.name = "Label_%s_%d" % [loc_name, tile_idx]
			# loc.name — translation key с коротким игровым именем (LOC_*_NAME).
			# Godot вызывает tr() при рендере и сам обновит текст при смене локали.
			# Fallback на id (loc_name) — на случай отсутствия ключа в JSON.
			lbl.text = String(loc.get("name", loc_name))
			lbl.add_theme_font_size_override("font_size", LABEL_FONT)
			lbl.add_theme_color_override("font_color", Color.WHITE)
			var bg := StyleBoxFlat.new()
			bg.bg_color = Color(0.05, 0.05, 0.08, 0.82)
			bg.set_corner_radius_all(6)
			bg.set_content_margin_all(4)
			bg.content_margin_left  = 10.0
			bg.content_margin_right = 10.0
			lbl.add_theme_stylebox_override("normal", bg)
			lbl.z_index = 2   # подпись читаема поверх колоды сущностей
			add_child(lbl)

			var indicator := SelectionIndicator.new()
			indicator.name     = "Indicator_%s_%d" % [loc_name, tile_idx]
			indicator.position = world_pos
			indicator.visible  = false
			indicator.z_index  = 2   # вровень с медальоном
			add_child(indicator)

			_markers.append({
				"sprite":    sprite,
				"label":     lbl,
				"indicator": indicator,
				"pos":       world_pos,
				"loc_name":  loc_name,
			})


# ── Рёбра ─────────────────────────────────────────────────────────────────────

func _build_edges() -> void:
	_edges.clear()
	var seen: Dictionary = {}
	for loc_name: String in _locs:
		var conns: Array = _locs[loc_name].connections
		for i: int in range(conns.size()):
			var conn: Dictionary = conns[i]
			var other: String = conn.get("to", "")
			var ctype: String = conn.get("type", "ship")
			if not _locs.has(other):
				continue
			var a: String = loc_name if loc_name < other else other
			var b: String = other    if loc_name < other else loc_name
			var key: String = a + "|" + b + "|" + ctype
			if seen.has(key):
				continue
			seen[key] = true
			_edges.append({
				"lat0":  _locs[loc_name].lat,
				"lon0":  _locs[loc_name].lon,
				"lat1":  _locs[other].lat,
				"lon1":  _locs[other].lon,
				"ctype": ctype,
			})


# ── Отрисовка дуг ─────────────────────────────────────────────────────────────

func _draw() -> void:
	for dx: int in [-TILE_W, 0, TILE_W]:
		draw_set_transform(Vector2(dx, 0))
		for i: int in range(_edges.size()):
			var e: Dictionary = _edges[i]
			_draw_great_circle(e.lat0, e.lon0, e.lat1, e.lon1, _conn_color(e.ctype))
	draw_set_transform(Vector2.ZERO)


func _draw_great_circle(lat0: float, lon0: float, lat1: float, lon1: float, color: Color) -> void:
	var v0: Vector3 = _ll_to_vec3(lat0, lon0)
	var v1: Vector3 = _ll_to_vec3(lat1, lon1)
	var dot: float  = clampf(v0.dot(v1), -1.0, 1.0)
	var theta: float = acos(dot)

	if theta < 0.0001:
		draw_line(_geo_to_pixel(lat0, lon0), _geo_to_pixel(lat1, lon1), color, LINE_W, true)
		return

	var sin_t: float = sin(theta)
	var all_pts: Array[Vector2] = []
	for i: int in range(GC_STEPS + 1):
		var t: float   = float(i) / float(GC_STEPS)
		var w0: float  = sin((1.0 - t) * theta) / sin_t
		var w1: float  = sin(t * theta) / sin_t
		var v: Vector3 = (v0 * w0 + v1 * w1).normalized()
		var lat: float = asin(clampf(v.z, -1.0, 1.0)) * 180.0 / PI
		var lon: float = atan2(v.y, v.x) * 180.0 / PI
		all_pts.append(_geo_to_pixel(lat, lon))

	# Разбиваем при пересечении антимеридиана
	var seg := PackedVector2Array()
	var half_w: float = float(TILE_W) * 0.5
	for i: int in range(all_pts.size()):
		if i > 0 and absf(all_pts[i].x - all_pts[i - 1].x) > half_w:
			if seg.size() >= 2:
				draw_polyline(seg, color, LINE_W, true)
			seg.clear()
		seg.append(all_pts[i])
	if seg.size() >= 2:
		draw_polyline(seg, color, LINE_W, true)


# ── Вспомогательные ───────────────────────────────────────────────────────────

func _ll_to_vec3(lat: float, lon: float) -> Vector3:
	var lat_r: float = lat * PI / 180.0
	var lon_r: float = lon * PI / 180.0
	return Vector3(cos(lat_r) * cos(lon_r), cos(lat_r) * sin(lon_r), sin(lat_r))


func _geo_to_pixel(lat: float, lon: float) -> Vector2:
	var x: float     = (lon + 180.0) / 360.0 * float(TILE_W)
	var lat_r: float = lat * PI / 180.0
	var y_m: float   = log(tan(PI / 4.0 + lat_r / 2.0))
	var y: float     = (PI - y_m) / (2.0 * PI) * float(TILE_H)
	return Vector2(x, y) + offset


func _conn_color(ctype: String) -> Color:
	match ctype:
		"ship":      return COLOR_SHIP
		"train":     return COLOR_TRAIN
		"uncharted": return COLOR_UNCHARTED
	return COLOR_SHIP


# ── Пик и подсветка ───────────────────────────────────────────────────────────

## Возвращает имя локации под мировой позицией world_pos, либо "" если промах.
## Радиус пика берётся равным экранному размеру маркера (с учётом текущего зума).
func try_pick(world_pos: Vector2) -> String:
	if not is_instance_valid(camera):
		return ""
	var inv_z: float = 1.0 / camera.zoom.x
	var pick_r: float = _marker_screen_size() * 0.5 * inv_z
	var best: float = INF
	var best_name: String = ""
	for i: int in range(_markers.size()):
		var m: Dictionary = _markers[i]
		var d: float = m.pos.distance_to(world_pos)
		if d < pick_r and d < best:
			best = d
			best_name = m.loc_name
	return best_name


## Возвращает данные локации в формате для LocationSidebar.show_location().
## id — стабильный slug для travel-операций, name — translation key для отображения.
## В connections для каждого соседа добавляется его name (translation key) — иначе
## сайдбар знает только id и показывает "1"/"Arkham" вместо переводимых имён.
func get_location(loc_id: String) -> Dictionary:
	if not _locs.has(loc_id):
		return {}
	var loc: Dictionary = _locs[loc_id]
	var raw_conns: Array = loc.get("connections", [])
	var conns: Array = []
	for i: int in range(raw_conns.size()):
		var c: Dictionary = raw_conns[i]
		var to_id: String = String(c.get("to", ""))
		var to_name: String = to_id
		if _locs.has(to_id):
			to_name = String(_locs[to_id].get("name", to_id))
		conns.append({
			"to":   to_id,
			"name": to_name,                       # translation key
			"type": String(c.get("type", "ship")),
		})
	return {
		"id":                loc_id,
		"name":              String(loc.get("name", loc_id)),
		"type":              loc.get("type", "city"),
		"realWorldLocation": loc.get("realWorldLocation", ""),
		"description":       loc.get("description", ""),
		"connections":       conns,
	}


## Текущее имя выделенной локации (или "" если ничего не выделено).
func get_selected_name() -> String:
	return _selected_name


## Подсвечивает все 3 копии маркера с этим именем (или снимает подсветку, если "").
func set_selected(loc_name: String) -> void:
	if loc_name == _selected_name:
		return
	_selected_name = loc_name
	var inv: float = 1.0 / camera.zoom.x if is_instance_valid(camera) else 1.0
	# Тот же marker_factor, что в _process — индикатор сразу под текущий зум,
	# чтобы между set_selected и первым _process не дрогнул размер.
	var marker_factor: float = _marker_screen_size() / MARKER_SCREEN_FAR
	for i: int in range(_markers.size()):
		var m: Dictionary = _markers[i]
		var ind: Node2D = m.indicator as Node2D
		if not is_instance_valid(ind):
			continue
		var on: bool = (m.loc_name == loc_name)
		ind.visible = on
		if on:
			ind.scale = Vector2.ONE * inv * marker_factor  # сразу нужный размер до первого _process


# ── Маркеры сыщиков ───────────────────────────────────────────────────────────

## Размещает маркеры сыщиков на карте. list: [{pid, investigator, location}].
## Перестраивает, только если состав/локации изменились (сигнатура).
func set_investigators(list: Array) -> void:
	var sig: String = ""
	for i: int in range(list.size()):
		var e: Dictionary = list[i]
		sig += "%s@%s;" % [String(e.get("pid", "")), String(e.get("location", ""))]
	if sig == _inv_signature:
		return
	_inv_signature = sig

	for i: int in range(_inv_markers.size()):
		var old_e: Dictionary = _inv_markers[i]
		var old_sp: Node2D = old_e.sprite as Node2D
		if is_instance_valid(old_sp):
			old_sp.queue_free()
	_inv_markers.clear()

	# Сколько сыщиков в каждой локации — чтобы разнести их маркеры.
	var per_loc: Dictionary = {}
	for i: int in range(list.size()):
		var ln: String = String(list[i].get("location", ""))
		per_loc[ln] = int(per_loc.get(ln, 0)) + 1

	var inv0: float = (1.0 / camera.zoom.x) if is_instance_valid(camera) else 2.0
	var placed: Dictionary = {}

	for i: int in range(list.size()):
		var entry: Dictionary = list[i]
		var loc_name: String = String(entry.get("location", ""))
		if not _locs.has(loc_name):
			continue
		var total: int = int(per_loc.get(loc_name, 1))
		var k: int = int(placed.get(loc_name, 0))
		placed[loc_name] = k + 1
		var fan_x: float = (float(k) - float(total - 1) * 0.5) * INVESTIGATOR_FAN_X
		var screen_off := Vector2(fan_x, INVESTIGATOR_OFFSET_Y)

		var tex: Texture2D = _investigator_texture(String(entry.get("investigator", "")))
		# base_scale переводит нативную высоту ассета (avatar-pin @2×) в полную
		# экранную высоту (NEAR); фактор зума домножается per-frame в _process.
		var base_scale: float = INVESTIGATOR_CARD_H_NEAR / InvestigatorPin.card_height()
		var loc_pos: Vector2 = _locs[loc_name].pos

		for dx: int in [-TILE_W, 0, TILE_W]:
			var base: Vector2 = loc_pos + Vector2(dx, 0)
			var pin := InvestigatorPin.new()
			pin.name    = "Inv_%s_%d" % [String(entry.get("pid", "")), sign(dx)]
			pin.z_index = 4   # пины сыщиков — поверх медальона/врат
			pin.scale    = Vector2.ONE * base_scale * inv0
			pin.position = base + screen_off * inv0
			add_child(pin)
			pin.setup(tex)
			_inv_markers.append({
				"sprite":     pin,
				"base":       base,
				"screen_off": screen_off,
				"base_scale": base_scale,
			})


## Текстура маркера: портрет сыщика, либо общий жетон-кружок, если файла нет.
func _investigator_texture(inv_name: String) -> Texture2D:
	var path: String = "res://assets/investigators/%s.png" % inv_name
	if not inv_name.is_empty() and ResourceLoader.exists(path):
		return load(path) as Texture2D
	if _token_tex == null:
		_token_tex = _make_token_texture()
	return _token_tex


## Запасной жетон — залитый кружок (для сыщиков без файла портрета).
func _make_token_texture() -> Texture2D:
	var s: int = 96
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := Vector2(s, s) * 0.5
	var r: float = float(s) * 0.5 - 3.0
	for y: int in range(s):
		for x: int in range(s):
			if Vector2(x, y).distance_to(c) <= r:
				img.set_pixel(x, y, UIColors.ACCENT)
	return ImageTexture.create_from_image(img)


# ── Открытые врата ────────────────────────────────────────────────────────────

## Размещает символы открытых врат на маркерах локаций. gates — словарь
## {loc_id: "red"|"green"|"blue"}. Перестраивает только при смене состава/цветов
## (сигнатура). Размеры и углы вращения применяются в _process per-frame.
func set_gates(gates: Dictionary) -> void:
	var keys: Array = gates.keys()
	keys.sort()   # стабильный порядок для сигнатуры
	var sig: String = ""
	for k in keys:
		sig += "%s=%s;" % [String(k), String(gates[k])]
	if sig == _gate_signature:
		return
	_gate_signature = sig

	for i: int in range(_gate_markers.size()):
		var old: Dictionary = _gate_markers[i]
		if is_instance_valid(old.outer): (old.outer as Sprite2D).queue_free()
		if is_instance_valid(old.inner): (old.inner as Sprite2D).queue_free()
	_gate_markers.clear()

	for loc_id_v: Variant in keys:
		var loc_id: String = String(loc_id_v)
		if not _locs.has(loc_id):
			continue
		var color: String = String(gates[loc_id])
		var outer_tex: Texture2D = GATE_OUTER_TEX.get(color, GATE_OUTER_TEX["red"]) as Texture2D
		var inner_tex: Texture2D = GATE_INNER_TEX.get(color, GATE_INNER_TEX["red"]) as Texture2D
		# Кэшируем height — _process пересчитывает scale каждый кадр.
		var outer_h: float = maxf(1.0, float(outer_tex.get_height()))
		var inner_h: float = maxf(1.0, float(inner_tex.get_height()))
		var loc_pos: Vector2 = _locs[loc_id].pos

		for dx: int in [-TILE_W, 0, TILE_W]:
			var world_pos: Vector2 = loc_pos + Vector2(dx, 0)
			# Врата (z=5) — поверх всего: медальона (2), колоды (1) и пинов
			# сыщиков (4). Оба слоя на одном z; inner добавлен позже —
			# рисуется поверх outer.
			var outer := Sprite2D.new()
			outer.name          = "GateOuter_%s_%d" % [loc_id, sign(dx)]
			outer.texture       = outer_tex
			outer.position      = world_pos
			outer.z_index       = 5
			# Mipmaps сглаживают край при downscale (дальний зум) и вращении —
			# MSAA 2D в gl_compatibility недоступен, mipmaps работают.
			outer.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			add_child(outer)

			var inner := Sprite2D.new()
			inner.name          = "GateInner_%s_%d" % [loc_id, sign(dx)]
			inner.texture       = inner_tex
			inner.position      = world_pos
			inner.z_index       = 5
			inner.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			add_child(inner)

			_gate_markers.append({
				"outer": outer, "inner": inner,
				"outer_h": outer_h, "inner_h": inner_h,
			})


# ── Сущности на локациях ──────────────────────────────────────────────────────

## Размещает иконки сущностей стопкой над маркерами. by_loc — {loc_id: [type,…]}
## где type ∈ {"clue","monster","rumor"}. Перестраивает только при смене состава
## (сигнатура). Позиции/выезд по hover/размер считаются в _process.
func set_entities(by_loc: Dictionary) -> void:
	var keys: Array = by_loc.keys()
	keys.sort()
	var sig: String = ""
	for k in keys:
		sig += "%s=%s;" % [String(k), str(by_loc[k])]
	if sig == _entity_signature:
		return
	_entity_signature = sig

	for i: int in range(_entity_markers.size()):
		var old: Dictionary = _entity_markers[i]
		if is_instance_valid(old.sprite):
			(old.sprite as Sprite2D).queue_free()
	_entity_markers.clear()

	for loc_id_v: Variant in keys:
		var loc_id: String = String(loc_id_v)
		if not _locs.has(loc_id):
			continue
		var types_v: Variant = by_loc[loc_id]
		if not (types_v is Array):
			continue   # старая модель {loc_id: count} — игнорируем
		var types: Array = types_v
		if types.is_empty():
			continue
		var loc_pos: Vector2 = _locs[loc_id].pos
		# Создаём в обратном порядке (последний idx первым), чтобы idx0 —
		# ближний к локации — добавлялся последним и рисовался ПОВЕРХ остальных
		# (все жетоны на z=1, порядок задаёт очередь в дереве). Остальные
		# выглядывают из-под него вправо.
		for idx: int in range(types.size() - 1, -1, -1):
			var type_name: String = String(types[idx])
			var tex: Texture2D = ENTITY_TEX.get(type_name, ENTITY_TEX["clue"]) as Texture2D
			var tex_h: float = maxf(1.0, float(tex.get_height()))
			for dx: int in [-TILE_W, 0, TILE_W]:
				var base: Vector2 = loc_pos + Vector2(dx, 0)
				var sprite := Sprite2D.new()
				sprite.name          = "Entity_%s_%d_%d" % [loc_id, idx, sign(dx)]
				sprite.texture       = tex
				sprite.position      = base
				# z=1: над фоном/дугами, но ПОД медальоном локации (z=2) —
				# колода выглядывает из-под него. z<0 ушло бы за фон карты.
				sprite.z_index       = 1
				sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
				add_child(sprite)
				_entity_markers.append({
					"sprite": sprite, "base": base, "idx": idx, "tex_h": tex_h,
					"loc_id": loc_id, "hover": 0.0,
				})
