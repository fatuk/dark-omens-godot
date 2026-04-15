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
## Желаемый экранный размер маркера в пикселях (не зависит от зума).
const MARKER_SCREEN:  float = 100.0
## Расстояние от центра маркера до верха подписи в экранных пикселях.
const LABEL_SCREEN_Y: float = 36.0
const LABEL_FONT:     int   = 13    # шрифт в экранных пикселях

# ── Зависимости ───────────────────────────────────────────────────────────────

## Задаётся из world_map.gd после add_child.
var camera: Camera2D = null

# ── Данные ────────────────────────────────────────────────────────────────────

var _locs:     Dictionary = {}
var _edges:    Array      = []
var _markers:  Array      = []   # [{sprite, label, pos}]
var _textures: Dictionary = {}


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

	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("MapLayer: не удалось прочитать %s" % path)
		return
	var data: Variant = JSON.parse_string(text)
	if not data is Array:
		push_error("MapLayer: JSON должен быть массивом в %s" % path)
		return

	for i: int in range((data as Array).size()):
		var loc: Dictionary = (data as Array)[i]
		var loc_name: String = loc.get("name", "")
		if loc_name.is_empty():
			continue
		var coords: Array = loc.get("coordinates", [])
		if coords.size() < 2:
			continue
		var lat: float = float(coords[0])
		var lon: float = float(coords[1])
		_locs[loc_name] = {
			"pos":         _geo_to_pixel(lat, lon),
			"lat":         lat,
			"lon":         lon,
			"type":        loc.get("type", "city"),
			"connections": loc.get("connections", []),
		}

	_build_edges()
	_spawn_markers()
	queue_redraw()


# ── Обновление масштаба каждый кадр ──────────────────────────────────────────

func _process(_delta: float) -> void:
	if not is_instance_valid(camera):
		return
	var z: float   = camera.zoom.x
	var inv: float = 1.0 / z

	# Мировой размер = желаемый экранный размер / зум
	var sp_scale: Vector2 = Vector2.ONE * (MARKER_SCREEN / 150.0) * inv

	for i: int in range(_markers.size()):
		var m: Dictionary = _markers[i]
		var sp: Sprite2D  = m.sprite as Sprite2D
		var lb: Label     = m.label  as Label

		if is_instance_valid(sp):
			sp.scale = sp_scale

		if is_instance_valid(lb) and lb.size.x > 0.0:
			lb.scale    = Vector2.ONE * inv
			lb.position = m.pos + Vector2(
				-lb.size.x * inv * 0.5,   # горизонтальное центрирование
				LABEL_SCREEN_Y * inv       # отступ ниже маркера
			)


# ── Маркеры ───────────────────────────────────────────────────────────────────

func _spawn_markers() -> void:
	for loc_name: String in _locs:
		var loc: Dictionary = _locs[loc_name]
		var tex: Texture2D  = _textures.get(loc.type, _textures["city"]) as Texture2D

		var sprite := Sprite2D.new()
		sprite.texture  = tex
		sprite.position = loc.pos
		add_child(sprite)

		var lbl := Label.new()
		lbl.text = loc_name
		lbl.add_theme_font_size_override("font_size", LABEL_FONT)
		lbl.add_theme_color_override("font_color", Color.WHITE)
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0.05, 0.05, 0.08, 0.82)
		bg.set_corner_radius_all(6)
		bg.set_content_margin_all(4)
		bg.content_margin_left  = 10.0
		bg.content_margin_right = 10.0
		lbl.add_theme_stylebox_override("normal", bg)
		add_child(lbl)

		_markers.append({"sprite": sprite, "label": lbl, "pos": loc.pos})


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
	for i: int in range(_edges.size()):
		var e: Dictionary = _edges[i]
		_draw_great_circle(e.lat0, e.lon0, e.lat1, e.lon1, _conn_color(e.ctype))


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
