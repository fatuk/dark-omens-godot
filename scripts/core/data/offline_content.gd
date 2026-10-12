class_name OfflineContent
extends RefCounted

## Офлайн-источник контента: запечённый корпус встреч и готовые библии кампаний
## из `res://data/offline/` (их печёт `make offline-bake` через relay-API).
## Повторяет серверную выборку (relay `encounters.ts` → buildCorpusCards) и отдаёт
## те же формы ответов, что и ContentApi, — игра не отличает офлайн от сервера.
##
## Библии запечены на Древнего × язык × число игроков: сборка на сервере
## детерминирована, а случайность в ней (какие Мифы и Тайны попали в слоты)
## для офлайн-партии не важна.

const ENCOUNTERS_PATH := "res://data/offline/encounters.json"
const CAMPAIGNS_PATH := "res://data/offline/campaigns.json"

# Корпус и библии грузятся один раз (lazy). Тесты подменяют через set_corpus /
# set_campaigns, не трогая файлы.
static var _corpus: Array = []  # записи {id, kind, tags, data, i18n}
static var _campaigns: Dictionary = {}  # ancientId → lang → "N" → библия
static var _by_campaign_id: Dictionary = {}  # bible.id → {ancient, bible}
static var _special_tags: Dictionary = {}  # тег особой встречи → true
static var _loaded: bool = false
static var rng: RandomNumberGenerator = RandomNumberGenerator.new()

# ── Загрузка ──────────────────────────────────────────────────────────────────


## Есть ли запечённый контент (оба файла на месте).
static func available() -> bool:
	_ensure_loaded()
	return not _corpus.is_empty() and not _campaigns.is_empty()


static func set_corpus(records: Array) -> void:
	_corpus = records
	_loaded = true


static func set_campaigns(campaigns: Dictionary) -> void:
	_campaigns = campaigns
	_index_campaigns()
	_loaded = true


static func reset() -> void:
	_corpus = []
	_campaigns = {}
	_by_campaign_id = {}
	_loaded = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if FileAccess.file_exists(ENCOUNTERS_PATH):
		_corpus = DataLoader.load_array(ENCOUNTERS_PATH)
	if FileAccess.file_exists(CAMPAIGNS_PATH):
		_campaigns = DataLoader.load_dict(CAMPAIGNS_PATH).get("campaigns", {})
	_index_campaigns()


static func _index_campaigns() -> void:
	_by_campaign_id = {}
	_special_tags = {}
	for ancient: String in _campaigns.keys():
		var by_lang: Dictionary = _campaigns[ancient]
		for lang: String in by_lang.keys():
			var by_n: Dictionary = by_lang[lang]
			for n: String in by_n.keys():
				var bible: Dictionary = by_n[n]
				_by_campaign_id[String(bible.get("id", ""))] = {"ancient": ancient, "bible": bible}
				# Теги особых встреч (afterDefeat.encounterTag Тайн): такие карты выдаются
				# только назначением по тегу, в обычную выборку не попадают.
				var mysteries: Array = bible.get("mysteries", [])
				for i: int in range(mysteries.size()):
					var after: Dictionary = (mysteries[i] as Dictionary).get("afterDefeat", {})
					var tag: String = String(after.get("encounterTag", ""))
					if not tag.is_empty():
						_special_tags[tag] = true


# ── Кампании ──────────────────────────────────────────────────────────────────


## Аналог POST /campaign/assemble: библия Древнего под язык и число игроков.
## Нет точного размера партии — ближайший запечённый снизу (иначе сверху).
static func assemble(req: Dictionary) -> Dictionary:
	_ensure_loaded()
	var ancient: String = String(req.get("ancientOne", ""))
	if ancient.is_empty() or not _campaigns.has(ancient):
		if ancient.is_empty() and not _campaigns.is_empty():
			ancient = String(_campaigns.keys()[0])
		else:
			return _err("Офлайн-библии для Древнего «%s» нет" % ancient)
	var by_lang: Dictionary = _campaigns[ancient]
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
	var bible: Dictionary = (_by_campaign_id[id]["bible"] as Dictionary).duplicate(true)
	return {"ok": true, "error": "", "campaign": bible}


## Аналог GET /ancients: Древние, для которых есть библии, с именем на языке.
static func ancients(locale: String) -> Array:
	_ensure_loaded()
	var lang: String = "en" if locale.begins_with("en") else "ru"
	var out: Array = []
	for ancient: String in _campaigns.keys():
		var by_lang: Dictionary = _campaigns[ancient]
		var use: String = lang if by_lang.has(lang) else String(by_lang.keys()[0])
		var by_n: Dictionary = by_lang[use]
		var any: Dictionary = by_n[by_n.keys()[0]] if not by_n.is_empty() else {}
		var ao: Dictionary = any.get("ancientOne", {})
		out.append({"id": ancient, "name": String(ao.get("name", ancient))})
	return out


# ── Встречи ───────────────────────────────────────────────────────────────────


## Аналог POST /encounters/draw. Тот же порядок отбора, что на реле:
## вид → оси (loc / location / world) → requires по флагам → pinned/общие →
## сброс (exclude) → карты этого Древнего, потом общие → заглушка на недостачу.
static func draw(req: Dictionary) -> Dictionary:
	_ensure_loaded()
	if _corpus.is_empty():
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
	var ancient_id: String = _ancient_for(String(req.get("campaignId", "")))

	var base: Array = []
	for i: int in range(_corpus.size()):
		var c: Dictionary = _corpus[i]
		if String(c.get("kind", "")) != kind:
			continue
		var tags: Array = c.get("tags", [])
		if not _requires_ok(c, flags):
			continue
		if not tag.is_empty():
			if tags.has(tag):
				base.append(c)
			continue
		if _has_special_tag(tags):
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
	if campaign_id.is_empty() or not _by_campaign_id.has(campaign_id):
		return ""
	return String(_by_campaign_id[campaign_id]["ancient"])


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


static func _has_special_tag(tags: Array) -> bool:
	for i: int in range(tags.size()):
		if _special_tags.has(String(tags[i])):
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
