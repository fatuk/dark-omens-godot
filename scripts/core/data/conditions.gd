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

# Вид состояния → подпись (i18n), глиф-заглушка (арта у состояний нет) и цвет фона.
const KIND_KEY := {
	"deal": "COND_KIND_DEAL",
	"madness": "COND_KIND_MADNESS",
	"injury": "COND_KIND_INJURY",
	"illness": "COND_KIND_ILLNESS",
	"bane": "COND_KIND_BANE",
	"boon": "COND_KIND_BOON",
	"restriction": "COND_KIND_RESTRICTION",
	"exposure": "COND_KIND_EXPOSURE",
	"pursuit": "COND_KIND_PURSUIT",
}
const KIND_GLYPH := {
	"deal": "◆",
	"madness": "◈",
	"injury": "✚",
	"illness": "◐",
	"bane": "✖",
	"boon": "☼",
	"restriction": "■",
	"exposure": "❄",
	"pursuit": "➤",
}
const KIND_COLOR := {
	"deal": Color(0.42, 0.34, 0.12),
	"madness": Color(0.30, 0.16, 0.34),
	"injury": Color(0.40, 0.12, 0.12),
	"illness": Color(0.18, 0.32, 0.16),
	"bane": Color(0.34, 0.10, 0.14),
	"boon": Color(0.36, 0.32, 0.14),
	"restriction": Color(0.20, 0.20, 0.24),
	"exposure": Color(0.14, 0.28, 0.34),
	"pursuit": Color(0.36, 0.22, 0.10),
}


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


## Все id состояний (для автодополнения/списка в debug-консоли).
static func all_ids() -> Array:
	_ensure_loaded()
	return _by_id.keys()


## Вид состояния (injury/madness/…) по id.
static func kind_of(id: String) -> String:
	return String(get_def(id).get("kind", ""))


## Порог успеха проверок сыщика от held-состояний (whileHeld successThreshold):
## Cursed → 6 («только 6»), Blessed → 4 («4-6»). Перевёрнутые фронтом не действуют.
## Конфликт (Cursed+Blessed разом) → нейтральные Dice.SUCCESS_MIN. Единый источник
## для видимых (CheckFlow) и тихих (EffectRunner/SpellFlow) бросков.
static func success_threshold(conditions: Array, flipped: Dictionary) -> int:
	var vals: Array = []
	for i in range(conditions.size()):
		var cid: String = String(conditions[i])
		if flipped.has(cid):
			continue
		for n_v: Variant in get_def(cid).get("whileHeld", []):
			if String((n_v as Dictionary).get("do", "")) == "successThreshold":
				vals.append(int((n_v as Dictionary).get("value", Dice.SUCCESS_MIN)))
	if vals.is_empty():
		return Dice.SUCCESS_MIN
	var first: int = int(vals[0])
	for v_v: Variant in vals:
		if int(v_v) != first:
			return Dice.SUCCESS_MIN  # конфликт (напр. Cursed+Blessed) → нейтрально
	return first


## Определение оборота-исхода по id (агрегат backs всех состояний; {} если нет).
static func outcome_def(id: String) -> Dictionary:
	_ensure_loaded()
	return _outcome_by_id.get(id, {})


## Payload карты состояния для GameCard (веер состояний). Поля title/subtitle/desc —
## i18n-КЛЮЧИ (Label переведёт сам). Арта нет → glyph/art_color по виду. flipped_outcome_id
## != "" → desc = текст исхода (рубашка), иначе текст лица. has_action — есть ли локальное
## действие (Detained «сбежать» и т.п.). {} для неизвестного id.
static func card_payload(cid: String, flipped_outcome_id := "") -> Dictionary:
	var def: Dictionary = get_def(cid)
	if def.is_empty():
		return {}
	var kind: String = String(def.get("kind", ""))
	var desc: String = String(def.get("front", ""))
	if not flipped_outcome_id.is_empty():
		desc = String(outcome_def(flipped_outcome_id).get("text", desc))
	return {
		"kind": "condition",
		"condition_id": cid,
		"title": name_key(cid),
		"subtitle": String(KIND_KEY.get(kind, "")),
		"desc": desc,
		"glyph": String(KIND_GLYPH.get(kind, "◈")),
		"art_color": KIND_COLOR.get(kind, UIColors.ART_BG),
		"has_action": not (def.get("action", []) as Array).is_empty(),
	}


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
