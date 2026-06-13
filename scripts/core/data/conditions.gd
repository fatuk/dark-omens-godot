class_name Conditions

## Реестр состояний из data/conditions.json — аналог Investigators.
## Корень файла — объект {conditions}; грузим через FileAccess + JSON напрямую.
## Обороты-исходы лежат ИНЛАЙН в каждом состоянии (condition.backs, как рубашки
## заклинаний); outcome_def агрегирует их по id для UI/форс-выбора.
##
##   Conditions.name_key("diseased")  → "COND_DISEASED_NAME" (ключ перевода)
##   # при присвоении в Label.text Godot сам вызовет tr()

const DATA_PATH := "res://data/conditions.json"

static var _by_id: Dictionary = {}
static var _outcome_by_id: Dictionary = {}  # агрегат backs всех состояний (id → оборот)


## Ключ перевода имени состояния по его id (либо сам id, если не найдено).
static func name_key(id: String) -> String:
	if id.is_empty():
		return id
	_ensure_loaded()
	var c: Dictionary = _by_id.get(id, {})
	return String(c.get("name", id))


## Полное определение состояния по id ({} если нет).
static func get_def(id: String) -> Dictionary:
	_ensure_loaded()
	return _by_id.get(id, {})


## Вид состояния (injury/madness/…) по id.
static func kind_of(id: String) -> String:
	return String(get_def(id).get("kind", ""))


## Определение оборота-исхода по id (агрегат backs всех состояний; {} если нет).
static func outcome_def(id: String) -> Dictionary:
	_ensure_loaded()
	return _outcome_by_id.get(id, {})


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
		if cid.is_empty():
			continue
		_by_id[cid] = c
		# Обороты — инлайн в состоянии (c.backs); агрегируем по id для outcome_def
		# (панель/форс-выбор). Дубль id между состояниями безвреден (defs равны).
		for b_v: Variant in c.get("backs", []):
			var bid: String = String((b_v as Dictionary).get("id", ""))
			if not bid.is_empty():
				_outcome_by_id[bid] = b_v
