class_name SpellFlow
extends RefCounted

## Подсистема заклинаний (хост-only). Двусторонняя карта: каст (тест Lore) → фронт
## onPass (если pass) → flip к СЛУЧАЙНОЙ рубашке → резолв её tiers по ЧИСЛУ УСПЕХОВ
## → discard (если рубашка эмитит discardCard) либо назад на фронт (заклинание
## многоразовое, остаётся в руке). Рубашка тянется ЗАНОВО при каждом касте — каждый
## каст свежий сюрприз (нарочно, чтобы провоцировать кастовать чаще).
## Сам бросок каста делает cast-flow (CheckFlow); сюда приходит результат
## (successes, dice). Стейт карт — в player.items {id, kind:"spell"}.
##
## flow.backs[item_index] — форс рубашки (детерминизм/тесты/replay). Доступ к
## стейту — через _gs: _gs.players, _gs._is_host(), _gs._name_of(),
## _gs._apply_board_effect(). Создаётся в GameState (поле _spell).

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


## Хост: разрешить каст заклинания item_index по результату теста (successes/dice).
## passed = successes ≥ 1 → фронт.onPass. Затем СЛУЧАЙНАЯ рубашка (каждый каст —
## свежая) → её tiers по числу успехов → discardCard в эффектах → карта сброшена.
## flow.backs[i] форсит конкретную рубашку (детерминизм/тесты). true — каст состоялся.
func resolve_cast(
	pid: String, item_index: int, successes: int, dice: Array, flow: Dictionary = {}
) -> bool:
	if not _gs._is_host() or not _gs.players.has(pid):
		return false
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	if item_index < 0 or item_index >= items.size():
		return false
	var sid: String = _spell_id(items[item_index])
	var spell: Dictionary = SpellCatalog.by_id(sid)
	if spell.is_empty():
		return false

	var ctx: Dictionary = {"successes": successes, "dice": dice}
	var consumed: bool = false
	# Фронт: эффект при успехе теста.
	if successes >= 1:
		var front: Dictionary = spell.get("front", {})
		consumed = _apply_effects(pid, front.get("onPass", []), ctx) or consumed
	# Рубашка СЛУЧАЙНА при КАЖДОМ касте (наугад из набора оборотов заклинания) —
	# это нарочно: каждый каст — свежий сюрприз, что провоцирует кастовать чаще.
	# Хост-авторитетно: бросок здесь, в клиентов уезжает уже результат (как кубики).
	# flow.backs[i] — форс конкретной рубашки (детерминизм/тесты), как flow.rolls
	# для кубиков.
	var forced: String = String((flow.get("backs", {}) as Dictionary).get(str(item_index), ""))
	var back: Dictionary = SpellCatalog.random_back(spell, forced)
	consumed = _apply_effects(pid, [{"resultTiers": back.get("tiers", [])}], ctx) or consumed
	GameConsole.log(
		(
			"[Заклинание] %s · «%s» (рубашка %s, успехов %d)"
			% [_gs._name_of(pid), sid, String(back.get("id", "")), successes]
		)
	)
	if consumed:
		items.remove_at(item_index)
		p["items"] = items
		GameConsole.log("[Заклинание] «%s» сброшено" % sid)
	return true


## Хост: каст Ritual-заклинания как действие. Валидирует (ritual + trigger:action +
## владение), бросает тест Lore±modifier через единый CheckFlow, разрешает каст
## (resolve_cast). true — каст выполнен (действие тратит зовущая сторона).
func cast_ritual(pid: String, item_index: int, flow: Dictionary = {}) -> bool:
	if not _gs._is_host() or not _gs.players.has(pid):
		return false
	var items: Array = (_gs.players[pid] as Dictionary).get("items", [])
	if item_index < 0 or item_index >= items.size():
		return false
	var spell: Dictionary = SpellCatalog.by_id(_spell_id(items[item_index]))
	if spell.is_empty():
		return false
	var front: Dictionary = spell.get("front", {})
	if String(spell.get("subtype", "")) != "ritual" or String(front.get("trigger", "")) != "action":
		return false
	_gs._check.start(
		"spell", pid, String(front.get("test", "lore")), int(front.get("modifier", 0)), "castSpell"
	)
	_gs._check.roll(pid)
	var c: Dictionary = _gs.active_check
	var dice: Array = c.get("dice", c.get("base", []))
	resolve_cast(pid, item_index, int(c.get("successes", 0)), dice, flow)
	_gs._check.clear()
	return true


## Хост: каст Incantation. В отличие от Ritual — НЕ действие, а контекстный
## триггер; для combatEncounter кастуется только при активной боевой проверке.
## Тест Lore транзиентный (бой держит active_check, поэтому бросаем здесь);
## flow.cast={successes,dice} переопределяет бросок (тесты/replay). true — каст.
func cast_incantation(pid: String, item_index: int, flow: Dictionary = {}) -> bool:
	if not _gs._is_host() or not _gs.players.has(pid):
		return false
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	if item_index < 0 or item_index >= items.size():
		return false
	var spell: Dictionary = SpellCatalog.by_id(_spell_id(items[item_index]))
	if spell.is_empty() or String(spell.get("subtype", "")) != "incantation":
		return false
	var front: Dictionary = spell.get("front", {})
	if String(front.get("trigger", "")) == "combatEncounter":
		if String((_gs.active_check as Dictionary).get("context", "")) != "combatEncounter":
			return false  # вне боя не кастуется

	var r: Dictionary = _lore_roll(p, int(front.get("modifier", 0)), flow)
	resolve_cast(pid, item_index, int(r["successes"]), r["dice"], flow)
	return true


# Транзиентный тест Lore (для контекстных/exhaust-кастов, когда CheckFlow занят).
# flow.cast={successes,dice} переопределяет бросок (тесты/replay).
func _lore_roll(p: Dictionary, modifier: int, flow: Dictionary) -> Dictionary:
	var roll: Dictionary = flow.get("cast", {})
	if roll.has("successes"):
		return {"successes": int(roll["successes"]), "dice": roll.get("dice", [])}
	var inv: Dictionary = Investigators.get_data(String(p.get("investigator", "")))
	var lore: int = int((inv.get("skills", {}) as Dictionary).get("lore", 1))
	var mods: int = int((p.get("skill_mods", {}) as Dictionary).get("lore", 0))
	var dice: Array = Dice.roll(maxi(1, lore + mods + modifier))
	return {"successes": int(Dice.result(dice).get("successes", 0)), "dice": dice}


## Хост: каст glamour («⟳: Test Lore и flip»). Истощает карту (oncePerRound),
## бросает Lore (транзиентный; flow.cast переопределяет), разрешает каст. Пассив-
## аура glamour применяется отдельно — через CheckFlow.activate. true — каст.
func cast_glamour(pid: String, item_index: int, flow: Dictionary = {}) -> bool:
	if not _gs._is_host() or not _gs.players.has(pid):
		return false
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	if item_index < 0 or item_index >= items.size():
		return false
	var it: Dictionary = items[item_index] if items[item_index] is Dictionary else {}
	if bool(it.get("exhausted", false)):
		return false  # уже истощена в этом раунде
	var spell: Dictionary = SpellCatalog.by_id(_spell_id(it))
	if spell.is_empty() or String(spell.get("subtype", "")) != "glamour":
		return false
	var r: Dictionary = _lore_roll(
		p, int((spell.get("front", {}) as Dictionary).get("modifier", 0)), flow
	)
	it["exhausted"] = true  # ⟳ — oncePerRound
	resolve_cast(pid, item_index, int(r["successes"]), r["dice"], flow)
	return true


## Хост: сработавший spell-триггер по игровому событию (onRest/onTravel/…). Кастует
## ВСЕ заклинания сыщика с front.trigger == event (а не только первое — игрок может
## держать несколько, напр. три onRest-лечилки). Для каждого: тест Lore → фронт
## onPass к себе → рубашка. true — сработало хотя бы одно. Зовётся из игровых хуков
## (phase_controller.rest и т.п.). flow.cast/backs — детерминизм/тесты.
func fire_trigger(pid: String, event: String, flow: Dictionary = {}) -> bool:
	if not _gs._is_host() or not _gs.players.has(pid):
		return false
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	# Собираем индексы ВСЕХ совпавших заклинаний, потом кастуем.
	var matches: Array[int] = []
	for i in range(items.size()):
		var it: Variant = items[i]
		if not (it is Dictionary):
			continue
		var spell: Dictionary = SpellCatalog.by_id(_spell_id(it))
		if spell.is_empty():
			continue
		if String((spell.get("front", {}) as Dictionary).get("trigger", "")) == event:
			matches.append(i)
	if matches.is_empty():
		return false
	# Кастуем по УБЫВАНИЮ индекса: если рубашка сбросит карту (resolve_cast удалит
	# элемент), индексы НИЖЕ не сдвинутся — обработка остальных не поедет.
	matches.reverse()
	for idx: int in matches:
		var front: Dictionary = SpellCatalog.by_id(_spell_id(items[idx])).get("front", {})
		var r: Dictionary = _lore_roll(p, int(front.get("modifier", 0)), flow)
		resolve_cast(pid, idx, int(r["successes"]), r["dice"], flow)
	return true


## Хост: выдать заклинание сыщику (board-verb gainSpell). spell_id пустой →
## случайное из каталога. Кладёт карту {id, kind:"spell"} в инвентарь (рубашка не
## фиксируется — тянется заново при каждом касте).
func grant_spell(pid: String, spell_id: String = "") -> void:
	if not _gs._is_host() or not _gs.players.has(pid):
		return
	var sid: String = spell_id
	if sid.is_empty():
		var pool: Array = SpellCatalog.all()
		if pool.is_empty():
			return
		sid = String((pool[randi() % pool.size()] as Dictionary).get("id", ""))
	if sid.is_empty() or SpellCatalog.by_id(sid).is_empty():
		return
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	items.append({"id": sid, "kind": "spell"})
	p["items"] = items
	GameConsole.log("[Заклинание] %s получил «%s»" % [_gs._name_of(pid), sid])


# Прогон Effect-программы каста: мутирует игрока; discardCard → consumed (сброс
# карты); прочий board — обычным эффектом. Возвращает, был ли discardCard.
func _apply_effects(pid: String, program: Array, ctx: Dictionary) -> bool:
	var p: Dictionary = _gs.players[pid]
	var res: Dictionary = _EffectRunner.run(program, p, ctx)
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[Заклинание] %s · %s" % [_gs._name_of(pid), String(l_v)])
	var consumed: bool = false
	for node_v: Variant in res.get("board", []):
		if String((node_v as Dictionary).get("do", "")) == "discardCard":
			consumed = true
		else:
			_gs._apply_board_effect(node_v as Dictionary)
	return consumed


# id заклинания из элемента инвентаря ({id} | {id, kind} | строка).
func _spell_id(entry: Variant) -> String:
	if entry is Dictionary:
		return String((entry as Dictionary).get("id", ""))
	return String(entry)
