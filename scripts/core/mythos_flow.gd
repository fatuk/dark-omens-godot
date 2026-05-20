class_name MythosFlow
extends RefCounted

## Фаза Мифов: вытяжка карты из колоды, отображение модалки всем игрокам,
## применение onDraw-эффектов по подтверждению, переход к новому раунду.
## Колода (_deck/_index) — host-only, не синкается; восстанавливается по
## campaign.id из снапшота через ContentApi (см. restore_deck).
##
## Owner — GameState (autoload). MythosFlow читает/пишет публичные поля
## GameState напрямую (current_mythos/players/doom/omens_step/phase…),
## зовёт _gs._broadcast_sync() и _gs._emit_changed() для рассылки и сигналов
## стейта, _gs._phase.start_new_round() — для перехода фазы. Это сознательная
## близкая связь: модуль владеет своими данными (deck/index), но не своим
## жизненным циклом.

const _EffectRunner = preload("res://scripts/core/effect_runner.gd")

# Колода и позиция — host-only. Колода восстанавливается по campaign.id из
# снапшота при реджойне хоста (см. restore_deck), индекс синкается через
# game_sync (см. GameState._broadcast_sync / _apply_snapshot).
var deck:  Array = []
var index: int   = 0

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


# ── Фаза ─────────────────────────────────────────────────────────────────────

## Вход в фазу Мифов из turn-flow (PhaseController.advance_encounter_turn /
## .enter_encounter).
## Хост сразу вытягивает карту и рассылает sync; не-хост дождётся синка с
## готовой current_mythos и покажет модалку.
func enter_phase() -> void:
	_gs.phase = "mythos"
	_gs.current_encounter = {}
	GameConsole.log("[Game] Фаза Мифов")
	_gs.phase_changed.emit(_gs.phase)
	if _gs._is_host():
		_draw_card()
		_gs._broadcast_sync()
	_gs._emit_changed()


## Любой игрок подтверждает «Дальше» в модалке мифа. Не-хост релеит хосту,
## хост применяет эффекты и стартует новый раунд.
func resolve() -> void:
	if _gs._is_host():
		_apply_resolve()
	else:
		_gs._nm.relay_all({ "action": "game_resolve_mythos" })


# ── Host-only: вытяжка ───────────────────────────────────────────────────────

# Хост: вытянуть следующую карту из deck в current_mythos.
func _draw_card() -> void:
	if deck.is_empty() or index >= deck.size():
		# Колода кончилась — карта-заглушка, чтобы цикл не вставал.
		_gs.current_mythos = {
			"name":       "Эхо Древних",
			"flavorText": "Колода Мифов исчерпана.",
			"text":       "Ничего нового не происходит — миф крутится по последнему витку.",
			"onDraw":     [],
		}
		GameConsole.warn("[Mythos] Колода исчерпана — карта-заглушка")
		return
	_gs.current_mythos = deck[index]
	index += 1
	GameConsole.log("[Mythos] вытянута карта: %s" % String(_gs.current_mythos.get("name", "?")))


# Хост: применить onDraw активной карты и стартовать новый раунд.
func _apply_resolve() -> void:
	if _gs.phase != "mythos" or _gs.current_mythos.is_empty():
		return
	var card: Dictionary = _gs.current_mythos
	_apply_effects(card.get("onDraw", []))
	GameConsole.log("[Mythos] %s — разрешена" % String(card.get("name", "?")))
	_gs.current_mythos = {}
	_gs.mythos_resolved.emit(_gs.omens_step, _gs.doom)
	_gs._phase.start_new_round()
	_gs._broadcast_sync()
	_gs._emit_changed()


# Эффекты карты Мифов. Узлы с target (например target=each) — к каждому
# подключённому игроку; без target — один раз на «доску» (advanceDoom,
# advanceOmen, openGate и т.п.). board-эффекты из per-player узла игнорим,
# чтобы не задвоить.
func _apply_effects(effects: Array) -> void:
	for i in range(effects.size()):
		var eff: Dictionary = effects[i]
		if eff.has("target"):
			for uid: String in _gs.players:
				if not bool(_gs.players[uid].get("connected", true)):
					continue
				var res: Dictionary = _EffectRunner.run([eff], _gs.players[uid])
				for log_msg in res.get("logs", []):
					GameConsole.log("[Mythos→%s] %s" % [_gs._name_of(uid), String(log_msg)])
		else:
			var dummy: Dictionary = {}
			var res: Dictionary = _EffectRunner.run([eff], dummy)
			for node in res.get("board", []):
				_gs._apply_board_effect(node)
			for log_msg in res.get("logs", []):
				GameConsole.log("[Mythos] %s" % String(log_msg))


# ── Реджойн ──────────────────────────────────────────────────────────────────

## Хост: восстановить deck после реджойна. Полная библия живёт в relay-API
## (таблица `campaigns`), тянем её по campaign.id из снапшота. Индекс уже
## подтянулся из снапшота — здесь восстанавливаем только саму колоду.
func restore_deck(campaign_id: String) -> void:
	var api: Node = _gs.get_node_or_null("/root/ContentApi")
	if api == null:
		GameConsole.warn("[Mythos] ContentApi недоступен — колоду не восстановить")
		return
	GameConsole.log("[Mythos] Восстановление колоды кампании %s..." % campaign_id.substr(0, 8))
	@warning_ignore("unsafe_method_access")
	var res: Dictionary = await api.get_campaign(campaign_id)
	if not bool(res.get("ok", false)):
		GameConsole.warn("[Mythos] Не удалось получить кампанию: %s" % String(res.get("error", "")))
		return
	var full: Dictionary = res.get("campaign", {})
	deck = full.get("mythosDeck", [])
	GameConsole.log("[Mythos] Колода восстановлена: %d карт (позиция %d)" % [deck.size(), index])
