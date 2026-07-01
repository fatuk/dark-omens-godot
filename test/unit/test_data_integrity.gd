extends GutTest

## Целостность боевых JSON (ссылочная): состояния, verb'ы, связи локаций и стартовые
## наборы сыщиков должны сходиться между файлами. Гоняется на реальных data/*.json —
## ловит рассинхрон данных и интерпретатора (битые gainCondition, verb'ы вне манифеста,
## односторонние связи, несуществующие стартовые предметы) ещё до запуска игры.

var _cond_ids: Dictionary = {}  # id состояния → true
var _verbs: Dictionary = {}  # verb из манифеста → true
var _asset_ids: Dictionary = {}
var _spell_ids: Dictionary = {}
var _loc_ids: Dictionary = {}


func before_all() -> void:
	for c_v: Variant in DataLoader.load_dict("res://data/conditions.json").get("conditions", []):
		_cond_ids[String((c_v as Dictionary).get("id", ""))] = true
	for v_k: Variant in DataLoader.load_dict("res://data/effect-manifest.json").get("verbs", {}):
		_verbs[String(v_k)] = true
	for a_v: Variant in DataLoader.load_array("res://data/assets.json"):
		_asset_ids[String((a_v as Dictionary).get("id", ""))] = true
	for s_v: Variant in DataLoader.load_array("res://data/spells.json"):
		_spell_ids[String((s_v as Dictionary).get("id", ""))] = true
	for l_v: Variant in DataLoader.load_array("res://data/locations.json"):
		_loc_ids[String((l_v as Dictionary).get("id", ""))] = true


# Рекурсивно собирает из произвольного узла DSL: все verb'ы (лист-`do`:String) и
# ссылки состояний (condition у gain/loseCondition). Структуру знать не нужно —
# обходим все вложенные словари/массивы (effect/tiers/backs/whileHeld/triggered/…).
func _scan(node: Variant, verbs: Array, cond_refs: Array) -> void:
	if node is Dictionary:
		var d: Dictionary = node
		var do_v: Variant = d.get("do", null)
		if do_v is String and not (do_v as String).is_empty():
			verbs.append(do_v)
			if (
				(do_v == "gainCondition" or do_v == "loseCondition")
				and d.get("condition") is String
			):
				cond_refs.append(String(d["condition"]))
		for k: Variant in d:
			_scan(d[k], verbs, cond_refs)
	elif node is Array:
		for e: Variant in node:
			_scan(e, verbs, cond_refs)


func _scan_all() -> Dictionary:
	var verbs: Array = []
	var refs: Array = []
	_scan(DataLoader.load_array("res://data/spells.json"), verbs, refs)
	_scan(DataLoader.load_array("res://data/monsters.json"), verbs, refs)
	_scan(DataLoader.load_array("res://data/investigators.json"), verbs, refs)
	_scan(DataLoader.load_dict("res://data/conditions.json").get("conditions", []), verbs, refs)
	return {"verbs": verbs, "refs": refs}


func test_all_do_verbs_in_manifest() -> void:
	var unknown: Array = []
	for v_v: Variant in _scan_all()["verbs"]:
		var v: String = String(v_v)
		if not _verbs.has(v) and not unknown.has(v):
			unknown.append(v)
	assert_eq(unknown, [], "verb'ы в данных, которых нет в effect-manifest.json: %s" % str(unknown))


func test_all_condition_refs_exist() -> void:
	var missing: Array = []
	for c_v: Variant in _scan_all()["refs"]:
		var c: String = String(c_v)
		if not _cond_ids.has(c) and not missing.has(c):
			missing.append(c)
	assert_eq(
		missing, [], "gainCondition/loseCondition на несуществующее состояние: %s" % str(missing)
	)


func test_location_connections_symmetric() -> void:
	var locs: Array = DataLoader.load_array("res://data/locations.json")
	var by: Dictionary = {}
	for l_v: Variant in locs:
		by[String((l_v as Dictionary).get("id", ""))] = l_v
	var bad: Array = []
	for l_v: Variant in locs:
		var a: String = String((l_v as Dictionary).get("id", ""))
		for c_v: Variant in (l_v as Dictionary).get("connections", []):
			var b: String = String((c_v as Dictionary).get("to", ""))
			var t: String = String((c_v as Dictionary).get("type", ""))
			var rev_ok: bool = false
			for rc_v: Variant in (by.get(b, {}) as Dictionary).get("connections", []):
				if (
					String((rc_v as Dictionary).get("to", "")) == a
					and String((rc_v as Dictionary).get("type", "")) == t
				):
					rev_ok = true
					break
			if not rev_ok:
				bad.append("%s -%s-> %s" % [a, t, b])
	assert_eq(bad, [], "несимметричные (по типу) связи локаций: %s" % str(bad))


func test_investigator_starting_refs_resolve() -> void:
	var bad: Array = []
	for inv_v: Variant in DataLoader.load_array("res://data/investigators.json"):
		var inv: Dictionary = inv_v
		var iid: String = String(inv.get("id", inv.get("name", "?")))
		var loc: String = String(inv.get("startingLocation", ""))
		if not loc.is_empty() and not _loc_ids.has(loc):
			bad.append("%s: локация %s" % [iid, loc])
		for it_v: Variant in inv.get("startingItems", []):
			var item_id: String = ""
			if it_v is String:
				item_id = String(it_v)
			elif it_v is Dictionary:
				item_id = String(
					(it_v as Dictionary).get("id", (it_v as Dictionary).get("asset", ""))
				)
			if (
				not item_id.is_empty()
				and not _asset_ids.has(item_id)
				and not _spell_ids.has(item_id)
			):
				bad.append("%s: предмет %s" % [iid, item_id])
	assert_eq(bad, [], "нерезолвящиеся стартовые наборы сыщиков: %s" % str(bad))
