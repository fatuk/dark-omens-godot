extends Node

## Единое хранилище и persist пользовательских настроек.
## Владеет: relay URL, разрешением, fullscreen, громкостями (через
## Music/SfxManager).
##
## НЕ владеет: post_fx (см. PostFx — он сам грузит/сохраняет),
## locale (см. I18n — тот же паттерн). Каждый модуль пишет свой ключ
## в один и тот же user://settings.cfg.
##
## Порядок autoload'ов важен: SettingsStore должен идти РАНЬШЕ MusicManager
## и SfxManager, чтобы они в своих _ready() успели прочитать его поля.

signal relay_url_changed(new_url: String)

const SETTINGS_FILE := "user://settings.cfg"
const DEFAULT_URL   := "ws://127.0.0.1:3030"

const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280,  720),
	Vector2i(1366,  768),
	Vector2i(1600,  900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]

# ── Состояние ─────────────────────────────────────────────────────────────────
var relay_url:      String = DEFAULT_URL
var resolution_idx: int    = 3        # 1920×1080 по умолчанию
var fullscreen:     bool   = false
var music_volume:   float  = 1.0      # 0..1, читается Music/SfxManager на _ready
var sfx_volume:     float  = 1.0


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Чтобы настройки можно было менять из меню паузы (где tree.paused = true).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load()
	apply_display()


# ── Public API ────────────────────────────────────────────────────────────────

## Применяет текущее display-состояние к окну. Вызывать после изменения
## resolution_idx / fullscreen.
@warning_ignore("integer_division")
func apply_display() -> void:
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(RESOLUTIONS[resolution_idx])
		DisplayServer.window_set_position(
			DisplayServer.screen_get_position() +
			(DisplayServer.screen_get_size() - RESOLUTIONS[resolution_idx]) / 2
		)


## Меняет URL и эмитит сигнал — main_menu слушает, чтобы переподключиться.
func set_relay_url(url: String) -> void:
	var clean := url.strip_edges()
	if clean.is_empty():
		clean = DEFAULT_URL
	if clean == relay_url:
		return
	relay_url = clean
	relay_url_changed.emit(relay_url)


## Сохраняет ВСЕ owned-настройки в один cfg-файл. Громкости берёт из
## Music/SfxManager (они единственный источник правды для текущего значения).
func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_FILE)   # ок если файла нет
	cfg.set_value("relay", "url", relay_url)
	cfg.set_value("display", "fullscreen", fullscreen)
	var r: Vector2i = RESOLUTIONS[resolution_idx]
	cfg.set_value("display", "resolution", "%dx%d" % [r.x, r.y])
	cfg.set_value("audio", "music", MusicManager.volume)
	cfg.set_value("audio", "sfx",   SfxManager.volume)
	music_volume = MusicManager.volume
	sfx_volume   = SfxManager.volume
	cfg.save(SETTINGS_FILE)


# ── Internal ──────────────────────────────────────────────────────────────────

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) != OK:
		return
	relay_url = cfg.get_value("relay", "url", DEFAULT_URL)
	# Миграция: localhost резолвится в IPv6 ::1, а Docker Desktop на Windows
	# не пробрасывает IPv6 — соединение виснет. Переписываем на IPv4.
	if "://localhost:" in relay_url:
		relay_url = relay_url.replace("://localhost:", "://127.0.0.1:")
	fullscreen = cfg.get_value("display", "fullscreen", false)
	var res_str: String = cfg.get_value("display", "resolution", "1920x1080")
	for i in range(RESOLUTIONS.size()):
		var r: Vector2i = RESOLUTIONS[i]
		if "%dx%d" % [r.x, r.y] == res_str:
			resolution_idx = i
			break
	music_volume = float(cfg.get_value("audio", "music", 1.0))
	sfx_volume   = float(cfg.get_value("audio", "sfx",   1.0))
