class_name OfflineContent
extends RefCounted

## Офлайн-источник контента: запечённые по Древним корпуса встреч и библии
## кампаний (их печёт bake-offline-content через relay-API):
##   res://data/offline/demo/<id>/  — Древние демо-сценариев, идут в сборки;
##   res://data/offline/dev/<id>/   — локальные тесты других Древних (не в гите,
##                                    вырезаны из экспорта).
## В папке — encounters.json (карты этого Древнего + общие) и campaigns.json
## (библии язык × число игроков). Повторяет серверную выборку (relay encounters.ts →
## buildCorpusCards) и отдаёт формы ответов ContentApi — игра не отличает офлайн.

const ROOT := "res://data/offline"
const TIERS := ["demo", "dev"]  # порядок = порядок в списке Древних

# Грузится один раз (lazy). Тесты подменяют через set_ancient, не трогая файлы.
static var _ancients: Dictionary = {}  # id → {tier, corpus: Array, campaigns: {lang: {"N": библия}}}
static var _order: Array = []  # id Древних: демо первыми
static var _by_campaign_id: Dictionary = {}  # bible.id → id Древнего
static var _special_tags: Dictionary = {}  # id Древнего → {тег особой встречи: true}
static var _loaded: bool = false
static var rng: RandomNumberGenerator = RandomNumberGenerator.new()

# ── Загрузка ──────────────────────────────────────────────────────────────────


## Есть ли хоть один запечённый Древний.
static func available() -> bool:
	_ensure_loaded()
	return not _ancients.is_empty()


## Тесты: подложить Древнего без файлов. campaigns — {lang: {"N": библия}}.
static func set_ancient(
	id: String, corpus: Array, campaigns: Dictionary, tier: String = "demo"
) -> void:
	_loaded = true
	_ancients[id] = {"tier": tier, "corpus": corpus, "campaigns": campaigns}
	if not _order.has(id):
		_order.append(id)
	_index(id)


static func reset() -> void:
	_ancients = {}
	_order = []
	_by_campaign_id = {}
	_special_tags = {}
	_loaded = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	for tier: String in TIERS:
		var dir: String = "%s/%s" % [ROOT, tier]
		if not DirAccess.dir_exists_absolute(dir):
			continue
		var ids: Array = Array(DirAccess.get_directories_at(dir))
		ids.sort()
		for id_v: Variant in ids:
			var id: String = String(id_v)
			if _ancients.has(id):
				continue  # демо важнее dev-копии того же Древнего
			var enc_path: String = "%s/%s/encounters.json" % [dir, id]
			var camp_path: String = "%s/%s/campaigns.json" % [dir, id]
			if not FileAccess.file_exists(enc_path) or not FileAccess.file_exists(camp_path):
				continue
			var camps: Dictionary = DataLoader.load_dict(camp_path).get("campaigns", {})
			set_ancient(id, DataLoader.load_array(enc_path), camps, tier)


# Индексы Древнего: id библий → Древний; теги особых встреч (afterDefeat.encounterTag
# его Тайн) — такие карты выдаются только назначением по тегу.
static func _index(id: String) -> void:
	var tags: Dictionary = {}
	var by_lang: Dictionary = _ancients[id]["campaigns"]
	for lang: String in by_lang.keys():
		var by_n: Dictionary = by_lang[lang]
		for n: String in by_n.keys():
			var bible: Dictionary = by_n[n]
			_by_campaign_id[String(bible.get("id", ""))] = id
			var mysteries: Array = bible.get("mysteries", [])
			for i: int in range(mysteries.size()):
				var after: Dictionary = (mysteries[i] as Dictionary).get("afterDefeat", {})
				var tag: String = String(after.get("encounterTag", ""))
				if not tag.is_empty():
					tags[tag] = true
	_special_tags[id] = tags


## id Древнего по id или имени на любом языке ("" — не запечён). Диалог создания
## комнаты шлёт имя (как и серверу — там его узнаёт findAncient).
static func resolve_ancient(id_or_name: String) -> String:
	_ensure_loaded()
	if _ancients.has(id_or_name):
		return id_or_name
	var want: String = id_or_name.strip_edges().to_lower()
	if want.is_empty():
		return ""
	for id: String in _order:
		var by_lang: Dictionary = _ancients[id]["campaigns"]
		for lang: String in by_lang.keys():
			var by_n: Dictionary = by_lang[lang]
			for n: String in by_n.keys():
				var ao: Dictionary = (by_n[n] as Dictionary).get("ancientOne", {})
				if String(ao.get("name", "")).to_lower() == want:
					return id
	return ""


# ── Кампании ──────────────────────────────────────────────────────────────────


## Аналог POST /campaign/assemble: библия Древнего под язык и число игроков.
## Нет точного размера партии — ближайший запечённый снизу (иначе сверху). Без
## Древнего — первый запечённый (демо).
static func assemble(req: Dictionary) -> Dictionary:
	_ensure_loaded()
	var asked: String = String(req.get("ancientOne", ""))
	var ancient: String = resolve_ancient(asked)
	if ancient.is_empty():
		if not asked.strip_edges().is_empty() or _order.is_empty():
			return _err("Офлайн-библии для Древнего «%s» нет — запеките его" % asked)
		ancient = String(_order[0])
	var by_lang: Dictionary = _ancients[ancient]["campaigns"]
	var lang: String = _lang_code(String(req.get("language", "")))
	if not by_lang.has(lang):
		if by_lang.is_empty():
			return _err("Офлайн-библии для Древнего «%s» нет" % ancient)
		lang = String(by_lang.keys()[0])
	var by_n: Dictionary = by_lang[lang]
	var want: int = maxi(1, int(req.get("playerCount", 1)))
	var best: String = _nearest_count(by_n.keys(), want)
	if best.is_empty():
		return _err("Офлайн-библии для Древнего «%s» нет" % ancient)
	var bible: Dictionary = (by_n[best] as Dictionary).duplicate(true)
	return {"ok": true, "error": "", "campaign": bible}


## Аналог GET /campaign/:id — библия по id (нужна хосту для восстановления колоды).
static func get_campaign(id: String) -> Dictionary:
	_ensure_loaded()
	if not _by_campaign_id.has(id):
		return _err("Кампания %s не запечена" % id.substr(0, 8))
	var ancient: String = _by_campaign_id[id]
	var by_lang: Dictionary = _ancients[ancient]["campaigns"]
	for lang: String in by_lang.keys():
		var by_n: Dictionary = by_lang[lang]
		for n: String in by_n.keys():
			if String((by_n[n] as Dictionary).get("id", "")) == id:
				return {
					"ok": true, "error": "", "campaign": (by_n[n] as Dictionary).duplicate(true)
				}
	return _err("Кампания %s не запечена" % id.substr(0, 8))


## Аналог GET /ancients: запечённые Древние (демо первыми) с именем на языке.
static func ancients(locale: String) -> Array:
	_ensure_loaded()
	var lang: String = "en" if locale.begins_with("en") else "ru"
	var out: Array = []
	for ancient: String in _order:
		var by_lang: Dictionary = _ancients[ancient]["campaigns"]
		var name: String = ancient
		if not by_lang.is_empty():
			var use: String = lang if by_lang.has(lang) else String(by_lang.keys()[0])
			var by_n: Dictionary = by_lang[use]
			if not by_n.is_empty():
				var ao: Dictionary = (by_n[by_n.keys()[0]] as Dictionary).get("ancientOne", {})
				name = String(ao.get("name", ancient))
		out.append({"id": ancient, "name": name})
	return out


# ── Встречи ───────────────────────────────────────────────────────────────────


## Аналог POST /encounters/draw. Тот же порядок отбора, что на реле:
## вид → оси (loc / location / world) → requires по флагам → pinned/общие →
## сброс (exclude) → карты этого Древнего, потом общие → заглушка на недостачу.
## Корпус — Древнего кампании (campaignId); без кампании — первого запечённого.
static func draw(req: Dictionary) -> Dictionary:
	_ensure_loaded()
	var ancient_id: String = _ancient_for(String(req.get("campaignId", "")))
	var corpus_owner: String = ancient_id
	if corpus_owner.is_empty() and not _order.is_empty():
		corpus_owner = String(_order[0])
	var corpus: Array = (_ancients.get(corpus_owner, {}) as Dictionary).get("corpus", [])
	var special: Dictionary = _special_tags.get(corpus_owner, {})
	if corpus.is_empty():
		return _err("Офлайн-корпус встреч пуст")
	var kind: String = String(req.get("kind", "general"))
	var real_loc: Dictionary = req.get("realLocation", {})
	var loc_type: String = String(real_loc.get("locationType", "city"))
	var loc_id: String = String(real_loc.get("id", ""))
	var lang: String = _lang_code(String(req.get("language", "")))
	var n: int = maxi(1, int(req.get("count", 1)))
	var world: String = String(req.get("otherWorld", "")) if kind == "gate" else ""
	var tag: String = String(req.get("tag", ""))
	var flags: Array = req.get("flags", [])
	var site_specific: bool = bool(req.get("siteSpecific", false))
	var exclude: Array = req.get("exclude", [])

	var base: Array = []
	for i: int in range(corpus.size()):
		var c: Dictionary = corpus[i]
		if String(c.get("kind", "")) != kind:
			continue
		var tags: Array = c.get("tags", [])
		if not _requires_ok(c, flags):
			continue
		if not tag.is_empty():
			if tags.has(tag):
				base.append(c)
			continue
		if _has_special_tag(tags, special):
			continue
		if not _axis_matches(tags, "loc", loc_type, true):
			continue
		if not _axis_matches(tags, "location", loc_id, not loc_id.is_empty()):
			continue
		# gate без явного мира — мир не фильтруем; не-gate world:-карту не берём.
		if kind == "gate" and world.is_empty():
			pass
		elif not _axis_matches(tags, "world", world, not world.is_empty()):
			continue
		base.append(c)

	var all: Array = base
	if tag.is_empty():
		var pinned: Array = []
		var unpinned: Array = []
		for i: int in range(base.size()):
			var c: Dictionary = base[i]
			if _tag_value(c.get("tags", []), "location").is_empty():
				unpinned.append(c)
			else:
				pinned.append(c)
		if kind == "general":
			all = pinned if site_specific else unpinned
		else:
			all = pinned if not pinned.is_empty() else unpinned

	# Сначала — кто подходит по Древнему (свои + общие), и только потом сброс: иначе
	# свежие карты чужих Древних держали бы пул «не пустым» вместо перетасовки.
	var eligible: Array = []
	for i: int in range(all.size()):
		var c: Dictionary = all[i]
		var a: String = _tag_value(c.get("tags", []), "ancient")
		if a.is_empty() or a == "any" or (not ancient_id.is_empty() and a == ancient_id):
			eligible.append(c)
	var fresh: Array = []
	for i: int in range(eligible.size()):
		var c: Dictionary = eligible[i]
		if not exclude.has(String(c.get("id", ""))):
			fresh.append(c)
	var pool: Array = fresh if not fresh.is_empty() else eligible

	var specific: Array = []
	var generic: Array = []
	for i: int in range(pool.size()):
		var c: Dictionary = pool[i]
		var a: String = _tag_value(c.get("tags", []), "ancient")
		if not ancient_id.is_empty() and a == ancient_id:
			specific.append(c)
		else:
			generic.append(c)

	var chosen: Array = _pick_n(specific, n)
	if chosen.size() < n:
		chosen.append_array(_pick_n(generic, n - chosen.size()))

	var out: Array = []
	for i: int in range(chosen.size()):
		out.append(_assemble_from_corpus(chosen[i], kind, loc_type, lang))
	while out.size() < n:
		out.append(_minimal_stub(kind, loc_type, world))
	return {"ok": true, "error": "", "encounters": out}


# ── Сборка карты (зеркало assembleCard / assembleFromCorpus на реле) ──────────


static func _assemble_from_corpus(
	card: Dictionary, kind: String, loc_type: String, lang: String
) -> Dictionary:
	var text: Dictionary = _pick_locale(card.get("i18n", {}), lang)
	var data: Dictionary = card.get("data", {})
	var src: Dictionary = text.duplicate()
	if kind == "gate":
		# Мир врат — ось карточки (тег world:<name>), i18n.otherWorld не смотрим.
		src["otherWorld"] = _tag_value(card.get("tags", []), "world")
	var out: Dictionary = _assemble_card(src, data, kind, loc_type, false)
	out["sourceId"] = String(card.get("id", ""))
	return out


static func _assemble_card(
	text: Dictionary, mech: Dictionary, kind: String, loc_type: String, mechanical: bool
) -> Dictionary:
	var id: String = _uuid()
	if (kind == "gate" or kind == "mystery") and mech.has("stage1"):
		var s1: Dictionary = text.get("stage1", {})
		var sb: Dictionary = text.get("successBranch", {})
		var fb: Dictionary = text.get("failureBranch", {})
		var g1: Dictionary = mech.get("stage1", {})
		var card: Dictionary = {
			"id": id,
			"type": "encounter",
			"kind": kind,
			"name": String(text.get("name", "")),
			"stage1":
			{
				"mainText": String(s1.get("mainText", "")),
				"successText": String(s1.get("successText", "")),
				"failureText": String(s1.get("failureText", "")),
				"test": g1.get("test", {}),
			},
			"branches":
			{
				"success": _branch(sb, mech.get("successBranch", {})),
				"failure": _branch(fb, mech.get("failureBranch", {})),
			},
			"mechanical": mechanical,
		}
		if kind == "gate":
			card["otherWorld"] = String(text.get("otherWorld", ""))
		else:
			card["locationType"] = loc_type
		return card
	return {
		"id": id,
		"type": "encounter",
		"kind": kind,
		"locationType": loc_type,
		"name": String(text.get("name", "")),
		"mainText": String(text.get("mainText", "")),
		"successText": String(text.get("successText", "")),
		"failureText": String(text.get("failureText", "")),
		"test": mech.get("test", {}),
		"onSuccess": mech.get("onSuccess", []),
		"onFailure": mech.get("onFailure", []),
		"mechanical": mechanical,
	}


static func _branch(txt: Dictionary, gm: Dictionary) -> Dictionary:
	return {
		"mainText": String(txt.get("mainText", "")),
		"successText": String(txt.get("successText", "")),
		"failureText": String(txt.get("failureText", "")),
		"test": gm.get("test", {}),
		"onSuccess": gm.get("onSuccess", []),
		"onFailure": gm.get("onFailure", []),
	}


# Минимальная механическая заглушка на пробел в корпусе (без флейвора).
static func _minimal_stub(kind: String, loc_type: String, world: String) -> Dictionary:
	var stub: Dictionary = {"name": ""}
	if kind == "gate":
		stub["otherWorld"] = world
	if kind == "gate" or kind == "mystery":
		var gate: Dictionary = {
			"stage1": {"test": {"skill": "lore", "modifier": 0}},
			"successBranch":
			{
				"test": {"skill": "observation", "modifier": 0},
				"onSuccess": [{"do": "gainClue", "count": 1}],
				"onFailure": [{"do": "loseHealth", "amount": 1}],
			},
			"failureBranch":
			{
				"test": {"skill": "will", "modifier": 0},
				"onSuccess": [],
				"onFailure": [{"do": "loseSanity", "amount": 1}],
			},
		}
		return _assemble_card(stub, gate, kind, loc_type, true)
	var flat: Dictionary = {
		"test": {"skill": "observation", "modifier": 0},
		"onSuccess": [{"do": "gainClue", "count": 1}],
		"onFailure": [{"do": "loseSanity", "amount": 1}],
	}
	return _assemble_card(stub, flat, kind, loc_type, true)


# ── Helpers ───────────────────────────────────────────────────────────────────


# Ключ запечённого размера партии: наибольший ≤ want, иначе наименьший из доступных.
static func _nearest_count(keys: Array, want: int) -> String:
	var below: String = ""
	var below_n: int = 0
	var above: String = ""
	var above_n: int = 0
	for i: int in range(keys.size()):
		var key: String = String(keys[i])
		var n: int = int(key)
		if n <= want and n > below_n:
			below = key
			below_n = n
		elif n > want and (above.is_empty() or n < above_n):
			above = key
			above_n = n
	return below if not below.is_empty() else above


static func _ancient_for(campaign_id: String) -> String:
	return String(_by_campaign_id.get(campaign_id, "")) if not campaign_id.is_empty() else ""


# requires: {hasSpell: true, …} — все ключи со значением true должны быть среди флагов.
static func _requires_ok(c: Dictionary, flags: Array) -> bool:
	var data: Dictionary = c.get("data", {})
	var req: Variant = data.get("requires", null)
	if not (req is Dictionary):
		return true
	for k: String in (req as Dictionary).keys():
		if bool((req as Dictionary)[k]) and not flags.has(k):
			return false
	return true


static func _has_special_tag(tags: Array, special: Dictionary) -> bool:
	for i: int in range(tags.size()):
		if special.has(String(tags[i])):
			return true
	return false


static func _tag_value(tags: Array, prefix: String) -> String:
	var p: String = prefix + ":"
	for i: int in range(tags.size()):
		var t: String = String(tags[i])
		if t.begins_with(p):
			return t.substr(p.length())
	return ""


# Ось подходит: у карты нет тега оси (вайлдкард) ИЛИ значение совпало.
# has_value=false — контекста нет: карта с требованием по оси не подходит.
static func _axis_matches(tags: Array, prefix: String, value: String, has_value: bool) -> bool:
	var v: String = _tag_value(tags, prefix)
	if v.is_empty():
		return true
	if not has_value:
		return false
	return v == value


static func _pick_n(arr: Array, n: int) -> Array:
	var bag: Array = arr.duplicate()
	var out: Array = []
	while out.size() < n and not bag.is_empty():
		out.append(bag.pop_at(rng.randi_range(0, bag.size() - 1)))
	return out


static func _pick_locale(i18n: Dictionary, lang: String) -> Dictionary:
	if i18n.has(lang):
		return i18n[lang]
	var other: String = "en" if lang == "ru" else "ru"
	return i18n.get(other, {})


static func _lang_code(language: String) -> String:
	var l: String = language.to_lower()
	if l.begins_with("rus") or l.contains("рус") or l == "ru":
		return "ru"
	return "en"


static func _uuid() -> String:
	return (
		"%08x-%04x-%04x-%08x"
		% [rng.randi(), rng.randi() & 0xFFFF, rng.randi() & 0xFFFF, rng.randi()]
	)


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}
