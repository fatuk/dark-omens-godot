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
const LABEL_SCREEN_Y: float = 50.0
const LABEL_FONT:     int   = 14    # шрифт в экранных пикселях
## Маркер сыщика: экранный размер, смещение над локацией, разнос соседей.
const INVESTIGATOR_SCREEN:   float = 72.0
const INVESTIGATOR_OFFSET_Y: float = -54.0
const INVESTIGATOR_FAN_X:    float = 42.0

# ── Зависимости ───────────────────────────────────────────────────────────────

## Задаётся из world_map.gd после add_child.
var camera: Camera2D = null

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
	_locs.clear()

	var data: Array = DataLoader.load_array(path)
	if data.is_empty():
		push_error("MapLayer: пустые данные локаций (%s)" % path)
		return

	for i: int in range(data.size()):
		var loc: Dictionary = data[i]
		var loc_name: String = loc.get("name", "")
		if loc_name.is_empty():
			continue
		var coords: Array = loc.get("coordinates", [])
		if coords.size() < 2:
			continue
		var lat: float = float(coords[0])
		var lon: float = float(coords[1])
		_locs[loc_name] = {
			"pos":               _geo_to_pixel(lat, lon),
			"lat":               lat,
			"lon":               lon,
			"type":              loc.get("type", "city"),
			"connections":       loc.get("connections", []),
			"realWorldLocation": loc.get("realWorldLocation", ""),
			"description":       loc.get("description", ""),
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
	var ui_scale: Vector2 = Vector2.ONE * inv

	for i: int in range(_markers.size()):
		var m: Dictionary       = _markers[i]
		var sp: Sprite2D        = m.sprite    as Sprite2D
		var lb: Label           = m.label     as Label
		var ind: Node2D         = m.indicator as Node2D

		if is_instance_valid(sp):
			sp.scale = sp_scale

		if is_instance_valid(ind) and ind.visible:
			ind.scale = ui_scale

		if is_instance_valid(lb) and lb.size.x > 0.0:
			lb.scale    = Vector2.ONE * inv
			lb.position = m.pos + Vector2(
				-lb.size.x * inv * 0.5,   # горизонтальное центрирование
				LABEL_SCREEN_Y * inv       # отступ ниже маркера
			)

	# Маркеры сыщиков — постоянный экранный размер, смещение над локацией.
	for i: int in range(_inv_markers.size()):
		var im: Dictionary = _inv_markers[i]
		var isp: Sprite2D  = im.sprite as Sprite2D
		if not is_instance_valid(isp):
			continue
		var ibase: Vector2 = im.base
		var ioff:  Vector2 = im.screen_off
		var iscale: float  = im.base_scale
		isp.scale    = Vector2.ONE * iscale * inv
		isp.position = ibase + ioff * inv


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
			add_child(sprite)

			var lbl := Label.new()
			lbl.name = "Label_%s_%d" % [loc_name, tile_idx]
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

			var indicator := SelectionIndicator.new()
			indicator.name     = "Indicator_%s_%d" % [loc_name, tile_idx]
			indicator.position = world_pos
			indicator.visible  = false
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
	var pick_r: float = MARKER_SCREEN * 0.5 * inv_z
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
func get_location(loc_name: String) -> Dictionary:
	if not _locs.has(loc_name):
		return {}
	var loc: Dictionary = _locs[loc_name]
	return {
		"name":              loc_name,
		"type":              loc.get("type", "city"),
		"realWorldLocation": loc.get("realWorldLocation", ""),
		"description":       loc.get("description", ""),
		"connections":       loc.get("connections", []),
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
	for i: int in range(_markers.size()):
		var m: Dictionary = _markers[i]
		var ind: Node2D = m.indicator as Node2D
		if not is_instance_valid(ind):
			continue
		var on: bool = (m.loc_name == loc_name)
		ind.visible = on
		if on:
			ind.scale = Vector2.ONE * inv  # сразу нужный размер до первого _process


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
		var old_sp: Sprite2D = old_e.sprite as Sprite2D
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
		var base_scale: float = INVESTIGATOR_SCREEN / maxf(1.0, float(tex.get_height()))
		var loc_pos: Vector2 = _locs[loc_name].pos

		for dx: int in [-TILE_W, 0, TILE_W]:
			var base: Vector2 = loc_pos + Vector2(dx, 0)
			var sprite := Sprite2D.new()
			sprite.name     = "Inv_%s_%d" % [String(entry.get("pid", "")), sign(dx)]
			sprite.texture  = tex
			sprite.z_index  = 1
			sprite.scale    = Vector2.ONE * base_scale * inv0
			sprite.position = base + screen_off * inv0
			add_child(sprite)
			_inv_markers.append({
				"sprite":     sprite,
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
