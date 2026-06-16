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
}
const _SKILL_KEYS := {
	"lore": "SKILL_LORE",
	"influence": "SKILL_INFLUENCE",
	"observation": "SKILL_OBSERVATION",
	"strength": "SKILL_STRENGTH",
	"will": "SKILL_WILL",
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
	if node.has("test"):
		return "%s: %s" % [_t("ENCOUNTER_CHECK"), _skill_name(String(node.get("test", "will")))]
	# Лист-Action.
	var verb: String = String(node.get("do", ""))
	if verb.is_empty():
		return ""
	var def: Dictionary = verb_def(verb)
	var key: String = String(def.get("describeKey", ""))
	var s: String = _t(key) if not key.is_empty() else verb
	if key.is_empty() or s == key:  # нет записи в translations → деградация к verb'у
		s = verb
	else:
		for p_v: Variant in def.get("params", []) as Array:
			var p: Dictionary = p_v
			var pname: String = String(p.get("name", ""))
			if ("{" + pname + "}") in s:
				s = s.replace("{" + pname + "}", _render_param(p, node))
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


# Значение параметра как текст: condition → локализованное имя, skill → имя навыка,
# прочее — как есть (число/строка).
static func _render_param(p: Dictionary, node: Dictionary) -> String:
	var pname: String = String(p.get("name", ""))
	var ptype: Dictionary = p.get("type", {})
	var val: Variant = node.get(pname, p.get("default", ""))
	if String(ptype.get("t", "")) == "ref":
		match String(ptype.get("of", "")):
			"condition":
				return _t(Conditions.name_key(String(val)))
			"skill":
				return _skill_name(String(val))
	return str(val)


static func _skill_name(s: String) -> String:
	return _t(_SKILL_KEYS.get(s, s))


# tr() недоступен из static; TranslationServer.translate — статический эквивалент.
static func _t(key: String) -> String:
	return String(TranslationServer.translate(key))
