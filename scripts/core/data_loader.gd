class_name DataLoader

## Тонкая обёртка над FileAccess + JSON для удобства.
## Локализация теперь зашита в самих данных (поля содержат translation keys,
## переводы в translations.csv) — DataLoader локалью не управляет.
##
## Использование:
##   var arr: Array = DataLoader.load_array("res://data/locations.json")
##   var dict: Dictionary = DataLoader.load_dict("res://data/some.json")


static func load_array(path: String) -> Array:
	var v: Variant = _parse(_read(path))
	if v is Array:
		return v
	return []


static func load_dict(path: String) -> Dictionary:
	var v: Variant = _parse(_read(path))
	if v is Dictionary:
		return v
	return {}


# ── Внутренние ────────────────────────────────────────────────────────────────

static func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		push_error("DataLoader: %s не найден" % path)
		return ""
	return FileAccess.get_file_as_string(path)


static func _parse(text: String) -> Variant:
	if text.is_empty():
		return null
	return JSON.parse_string(text)
