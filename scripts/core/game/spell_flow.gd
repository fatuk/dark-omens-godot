class_name SpellFlow
extends RefCounted

## Подсистема заклинаний (хост-only). Двусторонняя карта: каст (тест Lore) → фронт
## onPass (если pass) → flip к СЛУЧАЙНОЙ рубашке → резолв её tiers по ЧИСЛУ УСПЕХОВ
## → discard (если рубашка эмитит discardCard) либо назад на фронт (заклинание
## многоразовое, остаётся в руке). Сам бросок каста делает cast-flow (CheckFlow);
## сюда приходит результат (successes, dice). Стейт карт — в player.items.
##
## flow.backs[item_index] — форс рубашки (детерминизм/тесты/replay). Доступ к
## стейту — через _gs: _gs.players, _gs._is_host(), _gs._name_of(),
## _gs._apply_board_effect(). Создаётся в GameState (поле _spell).

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


## Хост: разрешить каст заклинания item_index по результату теста (successes/dice).
## passed = successes ≥ 1 → фронт.onPass. Затем случайная рубашка → её tiers по
## числу успехов → discardCard в эффектах → карта сброшена. true — каст состоялся.
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
	# Рубашка: случайная (или форс через flow.backs[item_index]); резолв по тиру.
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


## Хост: выдать заклинание сыщику (board-verb gainSpell). spell_id пустой →
## случайное из каталога. Кладёт карту {id, kind:"spell"} в инвентарь.
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
