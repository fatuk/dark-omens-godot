extends CanvasLayer

## Постобработка экрана: лёгкая сепия + виньетка + зерно («старая плёнка»).
## Autoload-синглтон /root/PostFx.
##
## Хранит флаг включения в settings.cfg ([display] post_fx_enabled).
## Меню настроек (pause_menu / main_menu) читают и пишут через
## set_enabled() / is_enabled().

const SETTINGS_FILE := "user://settings.cfg"
const SECTION       := "display"
const KEY           := "post_fx_enabled"

var _enabled: bool = true


func _ready() -> void:
	_load_setting()
	visible = _enabled


func is_enabled() -> bool:
	return _enabled


func set_enabled(on: bool) -> void:
	_enabled = on
	visible  = on
	_save_setting()


# ── Persist ───────────────────────────────────────────────────────────────────

func _load_setting() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) != OK:
		return
	_enabled = cfg.get_value(SECTION, KEY, true)


func _save_setting() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_FILE)   # ок если файла нет
	cfg.set_value(SECTION, KEY, _enabled)
	cfg.save(SETTINGS_FILE)
