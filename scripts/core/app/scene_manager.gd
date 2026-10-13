## Централизованный роутер сцен Dark Omens.
## Использование: SceneManager.go("world_map")
## Передача данных: SceneManager.go("world_map", {"room_id": "abc"})
##
## Загрузка сцен — ПОТОКОВАЯ (ResourceLoader.load_threaded_request): тяжёлый
## диск/импорт уходит с главного потока, поэтому курсор/ввод не «висят» на время
## загрузки (см. лобби с 3D-каруселью сыщиков). Лёгкий спиннер показывается, только
## если загрузка длится дольше нескольких кадров — быстрые переходы не мигают.
##
## Повторный go() НЕ блокируется: сцена в _ready может сразу перенаправить (лобби
## при rejoin прыгает на world_map). Новый вызов вытесняет предыдущую загрузку
## (поколение _gen), спиннер при этом ведётся непрерывно через «прыжок».
extends Node

# ── Реестр сцен ───────────────────────────────────────────────────────────────

const SCENES: Dictionary = {
	"home": "res://scenes/home.tscn",
	"login": "res://scenes/login.tscn",
	"main_menu": "res://scenes/main_menu.tscn",
	"lobby": "res://scenes/lobby.tscn",
	"world_map": "res://scenes/world_map.tscn",
}

## Сколько кадров ждём перед показом спиннера (быстрые переходы не мигают им).
const SPINNER_DELAY_FRAMES: int = 3
## Скорость вращения спиннера (рад/кадр).
const SPINNER_SPEED: float = 0.15

# ── Данные для передачи между сценами ─────────────────────────────────────────

## Словарь, который целевая сцена может прочитать в _ready().
var params: Dictionary = {}

# ── Состояние загрузки ────────────────────────────────────────────────────────

## Поколение загрузки: каждый go() инкрементит. Корутина бросает свою работу, если
## её поколение устарело (вытеснено более новым go()).
var _gen: int = 0
var _spinner: CanvasLayer = null
var _spinner_ring: TextureRect = null

# ── API ───────────────────────────────────────────────────────────────────────


## Переход на сцену по имени. data — необязательные параметры для целевой сцены.
func go(scene_name: String, data: Dictionary = {}) -> void:
	assert(SCENES.has(scene_name), "SceneManager: unknown scene '%s'" % scene_name)
	params = data
	# Демо-сборка: меню комнат и входа нет — выход из партии ведёт на главную, а сама
	# партия забывается (прогресс в демо не хранится).
	var target: String = Demo.redirect(scene_name)
	if target != scene_name:
		Demo.leave()
	var path: String = SCENES[target]
	var err: Error = ResourceLoader.load_threaded_request(path)
	if err != OK:
		# Не удалось запустить поток — фолбэк на синхронную загрузку (как было).
		get_tree().change_scene_to_file(path)
		return
	_gen += 1
	_load_and_swap(path, _gen)


# ── Потоковая загрузка ────────────────────────────────────────────────────────


# Корутина: поллит статус потоковой загрузки, по готовности меняет сцену. gen —
# поколение этого вызова; если оно устарело (пришёл новый go()) — тихо выходим.
func _load_and_swap(path: String, gen: int) -> void:
	var frames: int = 0
	while true:
		await get_tree().process_frame
		if gen != _gen:
			return  # вытеснены более новым go() — спиннер ведёт уже он
		var status: int = ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			break
		if (
			status == ResourceLoader.THREAD_LOAD_FAILED
			or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE
		):
			push_error("SceneManager: загрузка сцены провалилась — %s" % path)
			_hide_spinner()
			return
		frames += 1
		if frames >= SPINNER_DELAY_FRAMES:
			_show_spinner()
		_spin()

	var packed: PackedScene = ResourceLoader.load_threaded_get(path) as PackedScene
	if gen != _gen:
		return
	if packed == null:
		push_error("SceneManager: пустой PackedScene — %s" % path)
		_hide_spinner()
		return
	# Меняем сцену. НЕ блокируем повторный go(): новая сцена в _ready может сразу
	# перенаправить (лобби → world_map при rejoin) — тогда _gen вырастет, и ниже мы
	# НЕ прячем спиннер (его доведёт новый вызов).
	get_tree().change_scene_to_packed(packed)
	await get_tree().process_frame
	await get_tree().process_frame
	if gen == _gen:
		_hide_spinner()


# ── Спиннер ───────────────────────────────────────────────────────────────────


func _spin() -> void:
	if is_instance_valid(_spinner_ring) and _spinner.visible:
		_spinner_ring.rotation += SPINNER_SPEED


func _show_spinner() -> void:
	_ensure_spinner()
	_spinner.visible = true


func _hide_spinner() -> void:
	if is_instance_valid(_spinner):
		_spinner.visible = false


# Строит оверлей спиннера один раз (ленивая инициализация): затемнение + кольцо.
func _ensure_spinner() -> void:
	if is_instance_valid(_spinner):
		return
	_spinner = CanvasLayer.new()
	_spinner.name = "LoadingSpinner"
	_spinner.layer = 900  # выше игрового UI, ниже кастомного курсора (1024)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.02, 0.02, 0.05, 0.5)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP  # блокируем ввод во время загрузки
	_spinner.add_child(dim)

	var ring := TextureRect.new()
	ring.name = "Ring"
	ring.texture = _make_spinner_texture()
	ring.anchor_left = 0.5
	ring.anchor_top = 0.5
	ring.anchor_right = 0.5
	ring.anchor_bottom = 0.5
	ring.offset_left = -32.0
	ring.offset_top = -32.0
	ring.offset_right = 32.0
	ring.offset_bottom = 32.0
	ring.pivot_offset = Vector2(32.0, 32.0)  # вращение вокруг центра
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.add_child(ring)
	_spinner_ring = ring

	add_child(_spinner)
	_spinner.visible = false


# Текстура спиннера — «комета»: кольцо с альфой, спадающей по кругу. При вращении
# читается как крутящийся индикатор. Генерируется один раз.
func _make_spinner_texture() -> Texture2D:
	var s: int = 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var c := Vector2(s, s) * 0.5
	var r_out: float = float(s) * 0.5 - 2.0
	var r_in: float = r_out - 7.0
	var col := Color(0.85, 0.70, 0.35)  # тёплое золото под тему
	for y: int in range(s):
		for x: int in range(s):
			var p := Vector2(x, y) - c
			var d: float = p.length()
			if d >= r_in and d <= r_out:
				var ang: float = fposmod(atan2(p.y, p.x), TAU)
				img.set_pixel(x, y, Color(col.r, col.g, col.b, ang / TAU))
	return ImageTexture.create_from_image(img)
