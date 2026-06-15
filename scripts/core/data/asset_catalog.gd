class_name AssetCatalog
extends RefCounted

## Статичный каталог имущества (data/assets.json). Зеркало MonsterCatalog.
## Поля записи: id, nameKey, set, cost, traits[], skill?, tags?, abilityKey, effect.

const PATH := "res://data/assets.json"

# Трейт карты → ключ перевода подзаголовка (берём последний трейт записи).
const _TRAIT_KEY := {
	"weapon": "TRAIT_WEAPON",
	"magical": "TRAIT_MAGICAL",
	"relic": "TRAIT_RELIC",
	"tome": "TRAIT_TOME",
	"teamwork": "TRAIT_TEAMWORK",
	"item": "TRAIT_ITEM",
	"trinket": "TRAIT_TRINKET",
	"task": "TRAIT_TASK",
	"service": "TRAIT_SERVICE",
	"ally": "TRAIT_ALLY",
}

static var _list: Array = []
static var _by_id: Dictionary = {}


static func all() -> Array:
	if _list.is_empty():
		_load()
	return _list


static func by_id(id: String) -> Dictionary:
	if _by_id.is_empty():
		_load()
	return _by_id.get(id, {})


## Программа Расплаты актива (effect.onReckoning) по id. [] — нет. Зовётся шагом
## Расплаты сыщика (ReckoningFlow) наряду с состояниями.
static func reckoning_of(id: String) -> Array:
	return (by_id(id).get("effect", {}) as Dictionary).get("onReckoning", [])


## Несколько ассетов для витрины магазина (пока — первые `count` из набора core).
## Позже заменится на «резерв» (выложенные лицом карты) из стейта.
static func shop_offer(count: int = 4) -> Array:
	var core: Array = []
	for a in all():
		if String((a as Dictionary).get("set", "")) == "core":
			core.append(a)
		if core.size() >= count:
			break
	return core


static func _load() -> void:
	_list = DataLoader.load_array(PATH)
	_by_id.clear()
	for a in _list:
		_by_id[String((a as Dictionary).get("id", ""))] = a


# ── Карты для GameCard / веера (id → payload) ─────────────────────────────────


## Payload карты ассета для GameCard.set_card (название/трейт/способность/стоимость).
static func card_payload(a: Dictionary) -> Dictionary:
	var traits: Array = a.get("traits", [])
	var trait_id: String = String(traits[-1]) if not traits.is_empty() else "item"
	var payload: Dictionary = {
		"cost": int(a.get("cost", 0)),
		"title": a.get("nameKey", ""),
		"subtitle": _TRAIT_KEY.get(trait_id, trait_id.to_upper()),
		"desc": a.get("abilityKey", ""),
	}
	var art: Texture2D = card_art(String(a.get("id", "")))
	if art != null:
		payload["art"] = art
	return payload


## Арт ассета по конвенции имени файла: assets/asset-card/<Id Capitalized>.png
## (id "18_derringer" → "18 Derringer.png"). Нет файла → null (рамка без арта).
static func card_art(id: String) -> Texture2D:
	if id.is_empty():
		return null
	var path: String = "res://assets/asset-card/%s.png" % id.capitalize()
	return load(path) if ResourceLoader.exists(path) else null


## id ассета из элемента инвентаря: "id" | {"asset": id} | {"id": id}; иначе ""
## (токены вроде {"clue": N} — не карты).
static func entry_id(entry: Variant) -> String:
	if entry is String:
		return String(entry)
	if entry is Dictionary:
		var d: Dictionary = entry
		if d.has("asset"):
			return String(d["asset"])
		if d.has("id"):
			return String(d["id"])
	return ""


## Колода payload'ов карт по списку предметов игрока (пропускает не-ассеты и
## неизвестные id — напр. MVP-маркеры gainAsset). Переносит флаг exhausted из
## инстанса {id, exhausted} в payload — веер гасит истощённые карты.
static func deck_for_items(items: Array) -> Array:
	var out: Array = []
	for i in range(items.size()):
		var it: Variant = items[i]
		var aid: String = entry_id(it)
		if aid.is_empty():
			continue
		var a: Dictionary = by_id(aid)
		if a.is_empty():
			continue
		var p: Dictionary = card_payload(a)
		p["id"] = aid
		p["item_index"] = i  # индекс в player.items — для активации карты
		if it is Dictionary:
			p["exhausted"] = bool((it as Dictionary).get("exhausted", false))
		out.append(p)
	return out


# ── Активация (слот action → модификаторы текущей проверки, Фаза 5) ────────────

# Глаголы action, влияющие на бросок (идут в конвейер Dice). Прочие action
# (damageMonster, preventLoss, gainCondition…) — не модификаторы проверки.
const _CHECK_MOD_VERBS := [
	"rollAdditionalDice",
	"addToDie",
	"convertDie",
	"improveSkill",
	"impairSkill",
	"rerollDice",
	"rerollMatching",
	"enhanceReroll",
	"minDice",
]


## Ноды-модификаторы проверки из слота action актива, подходящие по контексту
## (пусто/anyTest/совпадение). Их скармливают конвейеру Dice; cost/limit/optional
## остаются в нодах — их читает обработчик активации (GameState).
static func action_check_mods(a: Dictionary, context: String) -> Array:
	var out: Array = []
	var action: Array = (a.get("effect", {}) as Dictionary).get("action", [])
	for n_v: Variant in action:
		if not (n_v is Dictionary):
			continue
		var n: Dictionary = n_v
		if not _CHECK_MOD_VERBS.has(String(n.get("do", ""))):
			continue
		if not _ctx_match(String(n.get("context", "")), context):
			continue
		out.append(n)
	return out


## Пассивные модификаторы проверки (АУРЫ): любой check-mod-глагол в whileOwned без
## cost/when, подходящий по контексту. Применяются АВТОМАТИЧЕСКИ — сидируются в
## active_mods при старте проверки (improveSkill «.38 Revolver» = +2 Силы; rerollDice
## «Lucky Ring» = бесплатный переброс). Навык фильтруется в конвейере (карта боя —
## только на «свой» шаг). Платные (axe: «переброс за 2 рассудка») и условные (when)
## пока не поддержаны.
static func passive_check_mods(a: Dictionary, context: String) -> Array:
	var out: Array = []
	for e_v: Variant in (a.get("effect", {}) as Dictionary).get("whileOwned", []):
		var e: Dictionary = e_v
		if not _CHECK_MOD_VERBS.has(String(e.get("do", ""))):
			continue
		if e.has("cost") or e.has("when"):
			continue
		if _ctx_match(String(e.get("context", "")), context):
			out.append(e)
	return out


## Активируемые сейчас ноды — только слот action (по контексту). Пассивы whileOwned
## применяются автоматически (passive_check_mods), не через активацию.
static func activatable_mods(a: Dictionary, context: String) -> Array:
	return action_check_mods(a, context)


## Есть ли у актива активируемая способность под текущую проверку (контекст).
static func is_check_activatable(a: Dictionary, context: String) -> bool:
	return not activatable_mods(a, context).is_empty()


# Совпадает ли контекст эффекта с контекстом текущей проверки: пусто = безусловно,
# anyTest = всегда, иначе должен совпасть.
static func _ctx_match(eff_ctx: String, cur_ctx: String) -> bool:
	return eff_ctx.is_empty() or eff_ctx == "anyTest" or eff_ctx == cur_ctx
