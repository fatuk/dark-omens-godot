class_name SelectionPrefs
extends RefCounted

## Persist последнего выбранного сыщика в user://dark_omens_prefs.cfg.
## Используется picker'ом для автовыбора при повторном входе в лобби.

const _SECTION := "investigator"
const _KEY     := "last_investigator"


## Путь prefs с учётом профиля запуска (см. Profile).
static func _path() -> String:
	return Profile.path("dark_omens_prefs.cfg")


static func save(inv_name: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_path())
	cfg.set_value(_SECTION, _KEY, inv_name)
	cfg.save(_path())


static func load_last() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(_path()) != OK:
		return ""
	return cfg.get_value(_SECTION, _KEY, "")
