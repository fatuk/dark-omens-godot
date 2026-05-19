class_name Conditions

## Реестр состояний из data/conditions.json — аналог Investigators.
## Корень файла — объект {conditions, reckoningOutcomes}, поэтому грузим
## через FileAccess + JSON напрямую (DataLoader.load_array — для файлов-массивов).
##
##   Conditions.name_key("diseased")  → "COND_DISEASED_NAME" (ключ перевода)
##   # при присвоении в Label.text Godot сам вызовет tr()

const DATA_PATH := "res://data/conditions.json"

static var _by_id: Dictionary = {}


## Ключ перевода имени состояния по его id (либо сам id, если не найдено).
static func name_key(id: String) -> String:
	if id.is_empty():
		return id
	_ensure_loaded()
	var c: Dictionary = _by_id.get(id, {})
	return String(c.get("name", id))


# ── Внутренние ────────────────────────────────────────────────────────────────

static func _ensure_loaded() -> void:
	if not _by_id.is_empty():
		return
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)
	if file == null:
		push_warning("Conditions: не открыть %s" % DATA_PATH)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return
	var conds: Array = (parsed as Dictionary).get("conditions", [])
	for i in range(conds.size()):
		var c: Dictionary = conds[i]
		var cid: String = String(c.get("id", ""))
		if not cid.is_empty():
			_by_id[cid] = c
