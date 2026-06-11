class_name Conditions

## Реестр состояний из data/conditions.json — аналог Investigators.
## Корень файла — объект {conditions, reckoningOutcomes}, поэтому грузим
## через FileAccess + JSON напрямую (DataLoader.load_array — для файлов-массивов).
##
##   Conditions.name_key("diseased")  → "COND_DISEASED_NAME" (ключ перевода)
##   # при присвоении в Label.text Godot сам вызовет tr()

const DATA_PATH := "res://data/conditions.json"

static var _by_id: Dictionary = {}
static var _outcomes_by_kind: Dictionary = {}  # kind → Array[reckoningOutcome]
static var _outcome_by_id: Dictionary = {}


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


## Исходы расплаты (reckoningOutcomes) данного вида ([] если нет).
static func outcomes_of_kind(kind: String) -> Array:
	_ensure_loaded()
	return _outcomes_by_kind.get(kind, [])


## Определение исхода расплаты по id ({} если нет).
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
		if not cid.is_empty():
			_by_id[cid] = c
	var outs: Array = (parsed as Dictionary).get("reckoningOutcomes", [])
	for j in range(outs.size()):
		var o: Dictionary = outs[j]
		var oid: String = String(o.get("id", ""))
		if oid.is_empty():
			continue
		_outcome_by_id[oid] = o
		var okind: String = String(o.get("kind", ""))
		var lst: Array = _outcomes_by_kind.get(okind, [])
		lst.append(o)
		_outcomes_by_kind[okind] = lst
