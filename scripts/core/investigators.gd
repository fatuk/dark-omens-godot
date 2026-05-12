class_name Investigators

## Реестр данных сыщиков. Данные локалe-агностичны (все переводимые поля —
## ключи translations.csv), кэш заполняется один раз и не инвалидируется.
##
## Использование:
##   Investigators.display_name("Silas Marsh")  → "INV_SILAS_MARSH_NAME" (ключ)
##   # При присвоении в label.text Godot сам вызовет tr() и покажет «Сайлас Марш»
##   Investigators.get_data("Silas Marsh")     → весь словарь сыщика

const DATA_PATH := "res://data/investigators.json"

static var _by_name: Dictionary = {}


## Возвращает translation key для имени сыщика. Когда присваивается в
## Label.text, Godot автоматически переводит при рендере и обновляет при
## смене локали.
static func display_name(inv_name: String) -> String:
	if inv_name.is_empty():
		return inv_name
	_ensure_loaded()
	var inv: Dictionary = _by_name.get(inv_name, {})
	return inv.get("displayName", inv_name)


static func get_data(inv_name: String) -> Dictionary:
	_ensure_loaded()
	return _by_name.get(inv_name, {})


# ── Внутренние ────────────────────────────────────────────────────────────────

static func _ensure_loaded() -> void:
	if not _by_name.is_empty():
		return
	var arr: Array = DataLoader.load_array(DATA_PATH)
	for inv: Dictionary in arr:
		var key: String = inv.get("name", "")
		if not key.is_empty():
			_by_name[key] = inv
