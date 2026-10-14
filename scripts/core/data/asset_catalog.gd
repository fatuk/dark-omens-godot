class_name AssetCatalog
extends RefCounted

## Статичный каталог имущества (data/assets.json). Зеркало MonsterCatalog.
## Поля записи: id, nameKey, set, cost, traits[], skill?, tags?, abilityKey, effect.
##
## ФАЙЛ ГЕНЕРИРУЕТСЯ ИЗ CMS (relay scripts/export-game-content.ts), править
## его руками бессмысленно — следующий экспорт затрёт. Источник правды —
## админка. См. data/README.md.

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


## Запись по id. Не нашлось среди активов — ищем среди АРТЕФАКТОВ.
##
## Это единственный шов между двумя каталогами, и он намеренно здесь. Владение
## артефактом ничем не отличается от владения активом: пассивы проверок, слот
## action, боевые скидки и веер карт обязаны видеть его так же. Всё это ходит
## через by_id — значит работает без правок. А колода и витрина ходят через
## all(), который остаётся ЧИСТО активным: иначе артефакты утекли бы в магазин
## и в случайную выдачу gainAsset.
static func by_id(id: String) -> Dictionary:
	if _by_id.is_empty():
		_load()
	if _by_id.has(id):
		return _by_id[id]
	return ArtifactCatalog.by_id(id)


## Программа Расплаты актива (effect.onReckoning) по id. [] — нет. Зовётся шагом
## Расплаты сыщика (ReckoningFlow) наряду с состояниями.
static func reckoning_of(id: String) -> Array:
	return (by_id(id).get("effect", {}) as Dictionary).get("onReckoning", [])


## Несколько ассетов для витрины магазина (пока — первые `count` из доступных сезонов).
## Позже заменится на «резерв» (выложенные лицом карты) из стейта.
static func shop_offer(count: int = 4) -> Array:
	var out: Array = []
	for a in all():
		if SeasonGate.room_allows(a, "assets"):
			out.append(a)
		if out.size() >= count:
			break
	return out


static func _load() -> void:
	_list = DataLoader.load_array(PATH)
	_by_id.clear()
	for a in _list:
		_by_id[String((a as Dictionary).get("id", ""))] = a


# ── Карты для GameCard / веера (id → payload) ─────────────────────────────────


## Payload карты ассета для GameCard.set_card (название/трейт/способность/стоимость).
## i18n-ключ имени карты инвентаря любого вида (актив / заклинание / артефакт);
## неизвестная — сам id. Для строк «получено: …» в исходах.
static func card_name_key(entry: Variant) -> String:
	var id: String = entry_id(entry)
	var a: Dictionary = by_id(id)
	if not a.is_empty():
		return String(a.get("nameKey", id))
	var s: Dictionary = SpellCatalog.by_id(id)
	if not s.is_empty():
		return String(s.get("name", id))
	var art: Dictionary = ArtifactCatalog.by_id(id)
	if not art.is_empty():
		return String(art.get("nameKey", id))
	return id


## id из ids, у которых есть трейт want (пустой трейт — все). Строго, без отката
## ко всему списку: «возьмите ПРЕДМЕТ с витрины» не должен предлагать союзника.
## Общая для интерпретатора (gainAsset from:"reserve") и подписи кнопки выбора.
static func with_trait(ids: Array, want: String) -> Array:
	var out: Array = []
	for id_v: Variant in ids:
		if want.is_empty() or (by_id(String(id_v)).get("traits", []) as Array).has(want):
			out.append(String(id_v))
	return out


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
	var path: String = "res://assets/cards/asset/%s.png" % id.capitalize()
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
		# Артефакт рисуется своей рубашкой (нет цены, подзаголовок «Артефакт»),
		# но живёт в том же веере: для игрока это такая же карта на руках.
		var p: Dictionary = (
			ArtifactCatalog.card_payload(a) if ArtifactCatalog.has(aid) else card_payload(a)
		)
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
	"substituteSkill",
]


## Ноды-модификаторы проверки из слота action актива, подходящие по контексту
## (пусто/anyTest/совпадение). Их скармливают конвейеру Dice; cost/limit/optional
## остаются в нодах — их читает обработчик активации (GameState).
## Самостоятельное действие актива (тег "action" в карточке): action-узлы, которые
## НЕ являются модификаторами проверки. Их играют отдельным действием в фазе
## действий, а не тапом по активной проверке: ancient_tome (проверка Знания →
## улика), ritual_candles (gainSpell), dynamite (damageMonster), holy_water
## (gainCondition). Тег обязателен: reduceMonsterDamage/preventLoss у bandages и
## tear_gas — РЕАКТИВНЫЕ способности, играть их по своей воле нельзя.
static func standalone_action(a: Dictionary) -> Array:
	if not (a.get("tags", []) as Array).has("action"):
		return []
	var out: Array = []
	for n_v: Variant in (a.get("effect", {}) as Dictionary).get("action", []):
		if not (n_v is Dictionary):
			continue
		var n: Dictionary = n_v
		if _CHECK_MOD_VERBS.has(String(n.get("do", ""))):
			continue  # это мод проверки — он играется тапом на проверке
		out.append(n)
	return out


## Есть ли у актива самостоятельное действие (см. standalone_action).
static func has_standalone_action(a: Dictionary) -> bool:
	return not standalone_action(a).is_empty()


## Есть ли у актива мод под КОНКРЕТНУЮ проверку: по контексту, навыку шага и таймингу
## (усиление пула — только до броска, работа с результатом — только после). Зеркалит
## фильтр CheckFlow.activate, чтобы UI не предлагал розыгрыш туда, откуда вернут false.
static func fits_check(a: Dictionary, context: String, skill: String, rolled: bool) -> bool:
	var mods: Array = action_check_mods(a, context).duplicate()
	mods.append_array(passive_check_mods(a, context))
	for m_v: Variant in mods:
		if Dice.mod_skill_ok(m_v, skill) and Dice.mod_is_pre_roll(m_v) != rolled:
			return true
	return false


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


## Суммарный пассивный вычет урона/ужаса монстра по всем ПРИНАДЛЕЖАЩИМ активам
## (whileOwned do==verb: reduceMonsterDamage/reduceMonsterHorror). Применяется
## АВТОМАТИЧЕСКИ (не тапом) в боевом резолве. {amount: сумма amount, min: макс. пол}:
## эффективный урон монстра = max(min, base − amount), если amount > 0 (иначе не трогаем).
static func owned_combat_reduce(items: Array, verb: String) -> Dictionary:
	var amount: int = 0
	var floor_min: int = 0
	for it_v: Variant in items:
		var a: Dictionary = by_id(entry_id(it_v))
		if a.is_empty():
			continue
		for n_v: Variant in (a.get("effect", {}) as Dictionary).get("whileOwned", []):
			var n: Dictionary = n_v
			if String(n.get("do", "")) == verb:
				amount += int(n.get("amount", 0))
				floor_min = maxi(floor_min, int(n.get("min", 0)))
	return {"amount": amount, "min": floor_min}


## Применить вычет к базовому урону монстра: max(min, base − amount) при amount>0.
static func apply_combat_reduce(base: int, reduce: Dictionary) -> int:
	var amt: int = int(reduce.get("amount", 0))
	if amt <= 0:
		return base
	return maxi(int(reduce.get("min", 0)), base - amt)


# Verb'ы, которые движок реально исполняет (для фильтра пула выдачи, is_supported).
# Пополняется по мере реализации механик — карта включается в игру САМА. См.
# docs/asset-effects-support (аудит) и check-pipeline.
const _SUPPORTED_VERBS := [
	# конвейер проверок
	"improveSkill",
	"impairSkill",
	"rollAdditionalDice",
	"addToDie",
	"convertDie",
	"rerollDice",
	"minDice",
	"substituteSkill",
	# эффекты на сыщика
	"gainClue",
	"loseClue",
	"spendClue",
	"gainCondition",
	"loseCondition",
	"gainAsset",
	"loseAsset",
	"gainSpell",
	"loseSpell",
	"gainArtifact",
	"gainImprovement",
	"loseImprovement",
	"loseAllPossessions",
	"gainFocus",
	"loseFocus",
	"healHealth",
	"healSanity",
	"loseHealth",
	"loseSanity",
	"becomeDelayed",
	"extraAction",
	"move",
	"addSuccesses",
	"text",
	"discardCard",
	# эффекты поля
	"openGate",
	"closeGate",
	"spawnMonster",
	"discardMonster",
	"damageMonster",
	"advanceDoom",
	"advanceOmen",
	"moveOmen",
	"retreatDoom",
	"placeClue",
	"placeRumor",
	"placeEldritchToken",
	"giveAsset",
	"giveClue",
	# боевая митигация / пассивы
	"reduceMonsterDamage",
	"reduceMonsterHorror",
	"protectResource",
	"immuneTo",
	"substituteResource",
	# боевой триггер (on:combatEncounter)
	"defeatMonster",
]

# События, по которым движок стреляет triggered активов: боевой — EncounterFlow,
# остальные — AssetActionFlow.fire_triggered из PhaseController/CheckFlow.
const SUPPORTED_EVENTS: Array = [
	"combatEncounter",
	"rest",
	"focus",
	"defeatMonster",
	"closeGate",
	"gainClueResearch",
	"researchResolved",
	"encounterResolved",
	"spendClue",
]


## Полностью ли поддержаны ВСЕ эффекты карты — для фильтра пула выдачи (магазин /
## случайный gainAsset). Слото-осознанно: triggered с событием вне SUPPORTED_EVENTS и
## onReckoning НЕ срабатывают → карта не поддержана; verb'ы в поддержанных слотах
## (whileOwned/action/onGain/triggered) должны быть в _SUPPORTED_VERBS.
## Самоподдерживающийся: реализуем verb или событие → карта включается САМА.
static func is_supported(a: Dictionary) -> bool:
	var eff: Dictionary = a.get("effect", {})
	if not (eff.get("onReckoning", []) as Array).is_empty():
		return false
	for t_v: Variant in eff.get("triggered", []):
		var t: Dictionary = t_v
		if not SUPPORTED_EVENTS.has(String(t.get("on", ""))):
			return false  # событие никто не вызывает
		if not _verbs_supported(t.get("do", [])):
			return false
	for slot: String in ["whileOwned", "action", "onGain"]:
		if not _verbs_supported(eff.get(slot, [])):
			return false
	return true


# Рекурсивно: все do-verb'ы узла из _SUPPORTED_VERBS.
static func _verbs_supported(node: Variant) -> bool:
	if node is Dictionary:
		var do_v: Variant = (node as Dictionary).get("do", null)
		if do_v is String and not _SUPPORTED_VERBS.has(do_v):
			return false
		for k: Variant in node:
			if not _verbs_supported((node as Dictionary)[k]):
				return false
	elif node is Array:
		for x: Variant in node:
			if not _verbs_supported(x):
				return false
	return true


## id всех ПОДДЕРЖАННЫХ активов (для пула выдачи — магазин/случайный gainAsset).
static func supported_ids() -> Array:
	var out: Array = []
	for a_v: Variant in all():
		var a: Dictionary = a_v
		if is_supported(a):
			out.append(String(a.get("id", "")))
	return out


## Активы, доступные СТОЛУ: поддержанные движком минус чужие сезоны.
##
## Отдельно от supported_ids() намеренно: там речь про то, что умеет движок, а
## тут — про то, что куплено. Колода и сброс обязаны считаться из ОДНОГО
## источника (сброс выводится как «всё минус колода/витрина/руки»), поэтому оба
## зовут именно эту функцию — иначе активы бы утекали.
static func available_ids() -> Array:
	var out: Array = []
	for a_v: Variant in all():
		var a: Dictionary = a_v
		if is_supported(a) and SeasonGate.room_allows(a, "assets"):
			out.append(String(a.get("id", "")))
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
