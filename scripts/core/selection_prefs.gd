class_name SelectionPrefs
extends RefCounted

## Persist последнего выбранного сыщика в user://dark_omens_prefs.cfg.
## Используется picker'ом для автовыбора при повторном входе в лобби.

const _PATH    := "user://dark_omens_prefs.cfg"
const _SECTION := "investigator"
const _KEY     := "last_investigator"


static func save(inv_name: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_PATH)
	cfg.set_value(_SECTION, _KEY, inv_name)
	cfg.save(_PATH)


static func load_last() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(_PATH) != OK:
		return ""
	return cfg.get_value(_SECTION, _KEY, "")
