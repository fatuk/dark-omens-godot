class_name EffectManifest
extends RefCounted

## Описатель эффектов Effect-DSL по verb-манифесту (data/effect-manifest.json,
## генерится из relay scripts/bake-verb-manifest.ts → src/api/verb-manifest.ts).
## Единый источник человекочитаемой метки узла — заменяет дублирующиеся _describe_one
## в модалках Мифов и встреч. ПОВЕДЕНИЕ интерпретатора здесь НЕ живёт, только текст.
## Статический ленивый каталог (как SpellCatalog).

const PATH := "res://data/effect-manifest.json"

static var _verbs: Dictionary = {}

# Цель эффекта → ключ перевода (суффикс «· сосед справа» и т.п.).
const _TARGET_KEYS := {
	"rightNeighbor": "MYTHOS_TGT_RIGHT",
	"leftNeighbor": "MYTHOS_TGT_LEFT",
	"lead": "MYTHOS_TGT_LEAD",
	"each": "MYTHOS_TGT_EACH",
	"eachOnCity": "MYTHOS_TGT_EACH_CITY",
	"eachOnWilderness": "MYTHOS_TGT_EACH_WILD",
	"eachOnSea": "MYTHOS_TGT_EACH_SEA",
}
const _SKILL_KEYS := {
	"lore": "SKILL_LORE",
	"influence": "SKILL_INFLUENCE",
	"observation": "SKILL_OBSERVATION",
	"strength": "SKILL_STRENGTH",
	"will": "SKILL_WILL",
	# improveSkill/impairSkill без конкретного навыка: «на выбор», «все», не указан.
	"choice": "SKILL_OF_CHOICE",
	"all": "SKILL_EVERY",
	"": "SKILL_SOME",
}


static func _ensure() -> void:
	if not _verbs.is_empty():
		return
	var m: Dictionary = DataLoader.load_dict(PATH)
	_verbs = m.get("verbs", {})


## Дескриптор verb'а ({} если нет).
static func verb_def(verb: String) -> Dictionary:
	_ensure()
	return _verbs.get(verb, {})


## Метки эффектов через запятую («» для пустого списка).
static func describe_list(arr: Variant) -> String:
	if not (arr is Array):
		return ""
	return _join(arr, ", ")


## Человекочитаемая метка одного узла Effect-DSL (лист или комбинатор).
## Художественный node.text перекрывает всё (метка ветки / verb «text»).
static func describe(node: Dictionary) -> String:
	var artistic: String = String(node.get("text", "")).strip_edges()
	if not artistic.is_empty():
		return artistic
	if node.has("choice"):
		return _join(node.get("choice", []), " / ")
	if node.has("group"):
		return _join(node.get("group", []), ", ")
	if node.has("forEach"):  # do — под-программа (Array), а не verb: «у каждого: …»
		return (
			"%s: %s"
			% [
				describe_target(String(node.get("forEach", "each"))),
				_join(node.get("do", []), ", ")
			]
		)
	if node.has("test"):
		return "%s: %s" % [_t("ENCOUNTER_CHECK"), _skill_name(String(node.get("test", "will")))]
	if node.has("dieRoll"):  # перечисляем эффекты всех граней
		var faces := PackedStringArray()
		for r_v: Variant in node.get("dieRoll", []) as Array:
			if r_v is Dictionary:
				faces.append(_join((r_v as Dictionary).get("then", []), ", "))
		return " / ".join(faces)
	# Лист-Action. do у структурных узлов уже отсеян выше; на всякий — гард.
	var do_val: Variant = node.get("do", "")
	if not (do_val is String) or (do_val as String).is_empty():
		return ""
	var verb: String = do_val
	var s: String = _gain_asset_text(node) if verb == "gainAsset" else _verb_text(verb, node)
	var tgt: String = String(node.get("target", ""))
	if not tgt.is_empty() and tgt != "self":
		s += " · %s" % describe_target(tgt)
	return s


## Метка цели (суффикс). Неизвестная — как есть.
static func describe_target(t: String) -> String:
	if _TARGET_KEYS.has(t):
		return _t(_TARGET_KEYS[t])
	return t


# ── Внутреннее ────────────────────────────────────────────────────────────────


static func _join(arr: Variant, sep: String) -> String:
	if not (arr is Array):
		return ""
	var parts := PackedStringArray()
	for i in range((arr as Array).size()):
		var e: Variant = (arr as Array)[i]
		if e is Dictionary:
			var s: String = describe(e)
			if not s.is_empty():
				parts.append(s)
	return sep.join(parts)


# Метка verb'а по describeKey манифеста с подстановкой {param}.
static func _verb_text(verb: String, node: Dictionary) -> String:
	var def: Dictionary = verb_def(verb)
	var key: String = String(def.get("describeKey", ""))
	var s: String = _t(key) if not key.is_empty() else verb
	if key.is_empty() or s == key:  # нет записи в translations → деградация к verb'у
		return verb
	for p_v: Variant in def.get("params", []) as Array:
		var p: Dictionary = p_v
		var pname: String = String(p.get("name", ""))
		if ("{" + pname + "}") in s:
			s = s.replace("{" + pname + "}", _render_param(p, node))
	return s


# gainAsset: ОТКУДА и КАКОЙ актив — «Выбрать с витрины: Предмет» против «Случайная
# карта из колоды: Предмет». Иначе две ветки выбора читались одинаково («получает
# актив»). Трейт — имя по TRAIT_*, без трейта — «Актив».
static func _gain_asset_text(node: Dictionary) -> String:
	var tr_key: String = String(node.get("trait", ""))
	var trait_name: String = (
		_t("ASSET_ANY") if tr_key.is_empty() else _t("TRAIT_" + tr_key.to_upper())
	)
	var key: String = (
		"VERB_GAIN_ASSET_RESERVE"
		if String(node.get("from", "")) == "reserve"
		else "VERB_GAIN_ASSET_DECK"
	)
	return _t(key).replace("{trait}", trait_name)


# Значение параметра как текст: condition → локализованное имя, skill → имя навыка,
# прочее — как есть (число/строка).
static func _render_param(p: Dictionary, node: Dictionary) -> String:
	var pname: String = String(p.get("name", ""))
	var ptype: Dictionary = p.get("type", {})
	var val: Variant = node.get(pname, p.get("default", ""))
	if String(ptype.get("t", "")) == "ref":
		match String(ptype.get("of", "")):
			"condition":
				if String(val).is_empty():
					return _condition_kind_text(node)
				return _t(Conditions.name_key(String(val)))
			"skill":
				return _skill_name(String(val))
	# Числа из JSON приходят float'ами (relay-карты) — целые рендерим без «.0».
	if val is float and val == floor(val):
		return str(int(val))
	return str(val)


# Состояние задано ВИДОМ, а не картой (gainCondition kind:"madness" — случайное
# безумие; loseCondition kind:[…] — любое из видов): имя вида, несколько — через «/»
# («Вы получаете состояние «Безумие»»). Конкретная карта выпадет только при применении.
# Ни карты, ни вида — «любое».
static func _condition_kind_text(node: Dictionary) -> String:
	var kinds: Variant = node.get("kind", "")
	var list: Array = kinds if kinds is Array else ([kinds] if not String(kinds).is_empty() else [])
	var names := PackedStringArray()
	for k_v: Variant in list:
		names.append(_t("COND_KIND_" + String(k_v).to_upper()))
	if names.is_empty():
		return _t("COND_ANY")
	return " / ".join(names)


static func _skill_name(s: String) -> String:
	return _t(_SKILL_KEYS.get(s, s))


# tr() недоступен из static; TranslationServer.translate — статический эквивалент.
static func _t(key: String) -> String:
	return String(TranslationServer.translate(key))
