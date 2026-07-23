class_name RelayRouter
extends RefCounted

## Роутер host-авторитетных relay-действий (вынесено из game_state.gd — тот упирался в
## лимит строк). Каждый _act_* — тонкий адаптер (data) → host-логика соответствующего
## модуля; тела перенесены дословно. Диспетчер остаётся в GameState._on_relay_received:
## он зовёт build_registry()[action].call(data) под гардом _is_host().
##
## Флоу держим типизированно (без warnings). Методы самого GameState (реколнинг-слот,
## late_join, dismiss, broadcast) — через _gs.call(): они приватные, класснейма у
## GameState нет. Транзиентные широковещалки (sync/chat/feed) — НЕ здесь (рендер у всех).

var _gs: Node
var _phase: PhaseController
var _encounter: EncounterFlow
var _spell: SpellFlow
var _check: CheckFlow
var _mythos: MythosFlow


func setup(
	gs: Node,
	phase: PhaseController,
	encounter: EncounterFlow,
	spell: SpellFlow,
	check: CheckFlow,
	mythos: MythosFlow
) -> void:
	_gs = gs
	_phase = phase
	_encounter = encounter
	_spell = spell
	_check = check
	_mythos = mythos


## Карта {relay-действие: адаптер}. GameState хранит её в _relay_actions и выводит из
## ключей _pid_owned (все, кроме безадресных RESOLVE_MYTHOS/SET_READY).
func build_registry() -> Dictionary:
	return {
		RelayActions.ACTION: _act_action,
		RelayActions.FINISH_ENCOUNTER: _act_finish_encounter,
		RelayActions.RESOLVE_ENCOUNTER: _act_resolve_encounter,
		RelayActions.REROLL_ENCOUNTER: _act_reroll_encounter,
		RelayActions.CHOOSE_ENCOUNTER: _act_choose_encounter,
		RelayActions.ADVANCE_STAGE: _act_advance_stage,
		RelayActions.CHOOSE_EFFECT: _act_choose_effect,
		RelayActions.ACTIVATE_CARD: _act_activate_card,
		RelayActions.CAST_INCANTATION: _act_cast_incantation,
		RelayActions.CAST_GLAMOUR: _act_cast_glamour,
		RelayActions.SPELL_CAST_ROLL: _act_spell_cast_roll,
		RelayActions.SPELL_CAST_REROLL: _act_spell_cast_reroll,
		RelayActions.SPELL_CAST_APPLY: _act_spell_cast_apply,
		RelayActions.CHECK_ROLL: _act_check_roll,
		RelayActions.CHECK_REROLL: _act_check_reroll,
		RelayActions.ADD_DIE: _act_add_die,
		RelayActions.RESOLVE_PENDING_CHECK: _act_resolve_pending_check,
		RelayActions.RECKONING_ROLL: _act_reckoning_roll,
		RelayActions.RECKONING_REROLL: _act_reckoning_reroll,
		RelayActions.RECKONING_REROLL_ALL: _act_reckoning_reroll_all,
		RelayActions.RECKONING_ADD_DIE: _act_reckoning_add_die,
		RelayActions.RECKONING_APPLY: _act_reckoning_apply,
		RelayActions.CAST_TRIGGER_SPELLS: _act_cast_trigger_spells,
		RelayActions.DISMISS_CAST_RESULT: _act_dismiss_cast_result,
		RelayActions.DISMISS_RECKONING: _act_dismiss_reckoning,
		RelayActions.SHOP_GRANT: _act_shop_grant,
		RelayActions.SHOP_CLOSE: _act_shop_close,
		RelayActions.SHOP_DEBT: _act_shop_debt,
		RelayActions.SHOP_SPEND_RESOURCE: _act_shop_spend_resource,
		RelayActions.SHOP_OPEN: _act_shop_open,
		RelayActions.SHOP_REROLL: _act_shop_reroll,
		RelayActions.REROLL_ALL: _act_reroll_all,
		RelayActions.RESOLVE_MYTHOS: _act_resolve_mythos,
		RelayActions.MYTHOS_DECIDE: _act_mythos_decide,
		RelayActions.SET_READY: _act_late_join,
	}


# ── Адаптеры ──────────────────────────────────────────────────────────────────


func _act_action(d: Dictionary) -> void:
	_phase.host_apply_action(
		String(d.get("pid", "")), String(d.get("type", "")), d.get("payload", {})
	)


func _act_finish_encounter(d: Dictionary) -> void:
	_phase.host_apply_finish_encounter(String(d.get("pid", "")))


func _act_resolve_encounter(d: Dictionary) -> void:
	_encounter.host_apply_resolve(String(d.get("pid", "")))


func _act_reroll_encounter(d: Dictionary) -> void:
	_encounter.host_apply_reroll(
		String(d.get("pid", "")), int(d.get("die", -1)), String(d.get("currency", ""))
	)


func _act_choose_encounter(d: Dictionary) -> void:
	_encounter.host_apply_choose(String(d.get("pid", "")), String(d.get("kind", "")))


func _act_advance_stage(d: Dictionary) -> void:
	_encounter.host_apply_advance_stage(String(d.get("pid", "")))


func _act_choose_effect(d: Dictionary) -> void:
	_phase.host_apply_effect_choice(String(d.get("pid", "")), int(d.get("index", -1)))


func _act_activate_card(d: Dictionary) -> void:
	var pid: String = String(d.get("pid", ""))
	var idx: int = int(d.get("index", -1))
	if not _encounter.try_combat_trigger(pid, idx):
		_check.activate(pid, idx)  # единая активная проверка (встреча/магазин/бой)


func _act_cast_incantation(d: Dictionary) -> void:
	if _spell.begin_incantation(String(d.get("pid", "")), int(d.get("index", -1))):
		_gs.call("_broadcast_and_emit")


func _act_cast_glamour(d: Dictionary) -> void:
	if _spell.begin_glamour(String(d.get("pid", "")), int(d.get("index", -1))):
		_gs.call("_broadcast_and_emit")


func _act_spell_cast_roll(d: Dictionary) -> void:
	_spell.roll_cast(String(d.get("pid", "")))


func _act_spell_cast_reroll(d: Dictionary) -> void:
	_check.reroll(String(d.get("pid", "")), int(d.get("die", -1)), String(d.get("currency", "")))


func _act_spell_cast_apply(d: Dictionary) -> void:
	if _spell.apply_cast(String(d.get("pid", ""))):
		_gs.call("_broadcast_and_emit")


func _act_check_roll(d: Dictionary) -> void:
	_check.roll(String(d.get("pid", "")))


func _act_check_reroll(d: Dictionary) -> void:
	_check.reroll(String(d.get("pid", "")), int(d.get("die", -1)), String(d.get("currency", "")))


func _act_add_die(d: Dictionary) -> void:
	_check.add_die(String(d.get("pid", "")), int(d.get("die", -1)))


func _act_resolve_pending_check(d: Dictionary) -> void:
	if bool(_gs.call("_resolve_pending_check_host", String(d.get("pid", "")))):
		_gs.call("_broadcast_and_emit")


func _act_reckoning_roll(d: Dictionary) -> void:
	var rp: String = String(d.get("pid", ""))
	_check.roll(rp, _slot(rp))


func _act_reckoning_add_die(d: Dictionary) -> void:
	var rp: String = String(d.get("pid", ""))
	_check.add_die(rp, int(d.get("die", -1)), _slot(rp))


func _act_reckoning_reroll(d: Dictionary) -> void:
	var rp: String = String(d.get("pid", ""))
	_check.reroll(rp, int(d.get("die", -1)), String(d.get("currency", "")), _slot(rp))


func _act_reckoning_reroll_all(d: Dictionary) -> void:
	var rp: String = String(d.get("pid", ""))
	_check.reroll_all(rp, _slot(rp))


func _act_reckoning_apply(d: Dictionary) -> void:
	if bool(_gs.call("_reckoning_apply_host", String(d.get("pid", "")))):
		_gs.call("_broadcast_and_emit")


func _act_cast_trigger_spells(d: Dictionary) -> void:
	_phase.host_apply_cast_trigger_spells(String(d.get("pid", "")), d.get("spells", []))


func _act_dismiss_cast_result(d: Dictionary) -> void:
	_gs.call("_host_dismiss_cast_result", String(d.get("pid", "")))


func _act_dismiss_reckoning(d: Dictionary) -> void:
	_gs.call("_host_dismiss_reckoning", String(d.get("pid", "")))


func _act_shop_grant(d: Dictionary) -> void:
	_phase.host_apply_shop_grant(String(d.get("pid", "")), d.get("assets", []))


func _act_shop_close(d: Dictionary) -> void:
	_phase.host_apply_shop_close(String(d.get("pid", "")))


func _act_shop_debt(d: Dictionary) -> void:
	_phase.host_apply_shop_debt(String(d.get("pid", "")))


func _act_shop_spend_resource(d: Dictionary) -> void:
	_phase.host_apply_shop_spend_resource(String(d.get("pid", "")))


func _act_shop_open(d: Dictionary) -> void:
	_check.start("shop", String(d.get("pid", "")), "influence", 0, "acquireAssets")
	_gs.call("_broadcast_and_emit")


func _act_shop_reroll(d: Dictionary) -> void:
	_check.reroll(String(d.get("pid", "")), int(d.get("die", -1)), String(d.get("currency", "")))


func _act_reroll_all(d: Dictionary) -> void:
	_check.reroll_all(String(d.get("pid", "")))


func _act_resolve_mythos(d: Dictionary) -> void:
	_mythos.mark_read(String(d.get("pid", "")))


func _act_mythos_decide(d: Dictionary) -> void:
	_phase.host_apply_mythos_decision(String(d.get("pid", "")), int(d.get("index", -1)))


func _act_late_join(d: Dictionary) -> void:
	# Поздний игрок выбрал сыщика в лобби уже идущей партии — подключаем участником.
	if bool(_gs.get("active")):
		_gs.call("_handle_late_join", d)


# Слот проверки Расплаты игрока (players[pid].reckoning_check) — из GameState.
func _slot(pid: String) -> Dictionary:
	return _gs.call("_reckoning_slot", pid)
