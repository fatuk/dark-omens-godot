class_name PhaseController
extends RefCounted

## Цикл фаз и обработка действий хостом. Хост-only.
##
## Содержит правила перехода фаз (action → encounter → mythos → action),
## валидацию и применение действий игрока (buy_ticket/take_concentration/
## rest/travel/pass), пропуск отключённых игроков, старт нового раунда.
## Триггерит подмодули: _encounter.begin_turn/generate и _mythos.enter_phase
## в нужные моменты цикла.
##
## GameState владеет полями (round_num, phase, current_idx, turn_order,
## players, …) — модуль пишет в них напрямую и зовёт _gs._broadcast_sync()/
## _gs._emit_changed() / _gs.phase_changed.emit().

const REST_HEAL_HP:     int = 1
const REST_HEAL_SANITY: int = 1

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


# ── Действия игрока ──────────────────────────────────────────────────────────

## Хост: валидирует и применяет действие игрока. Возвращает true при успехе.
## Зовётся из GameState.perform_action (для своего действия) и из relay-router
## на game_action (для чужого).
func host_apply_action(pid: String, action_type: String, payload: Dictionary = {}) -> bool:
	if _gs.phase != "action":
		GameConsole.warn("[Game] Действие вне фазы action отклонено")
		return false
	if _gs._current_pid() != pid:
		GameConsole.warn("[Game] %s ходит вне очереди" % _gs._name_of(pid))
		return false
	if not _gs.players.has(pid):
		return false

	var p: Dictionary = _gs.players[pid]
	if int(p.get("actions_left", 0)) <= 0:
		return false

	# Одно и то же действие нельзя повторять в раунде (pass не в счёт).
	var used: Array = p.get("actions_used", [])
	if action_type != "pass" and used.has(action_type):
		GameConsole.warn("[Game] %s — «%s» уже использовано в этом раунде" % [
			_gs._name_of(pid), action_type
		])
		return false

	match action_type:
		"buy_ticket":
			p["tickets"]      = int(p.get("tickets", 0)) + 1
			p["actions_left"] = int(p["actions_left"]) - 1
		"take_concentration":
			p["concentration"] = int(p.get("concentration", 0)) + 1
			p["actions_left"]  = int(p["actions_left"]) - 1
		"rest":
			p["hp"]     = mini(int(p["hp_max"]),     int(p["hp"])     + REST_HEAL_HP)
			p["sanity"] = mini(int(p["sanity_max"]), int(p["sanity"]) + REST_HEAL_SANITY)
			p["actions_left"] = int(p["actions_left"]) - 1
		"travel":
			var dest: String = String(payload.get("to", ""))
			if not can_travel(pid, dest):
				GameConsole.warn("[Game] %s — недопустимое перемещение" % _gs._name_of(pid))
				return false
			p["location"]     = dest
			p["actions_left"] = int(p["actions_left"]) - 1
		"pass":
			p["actions_left"] = 0
		_:
			GameConsole.warn("[Game] Неизвестное действие: %s" % action_type)
			return false

	if action_type != "pass":
		used.append(action_type)
		p["actions_used"] = used

	GameConsole.log("[Game] %s · %s · осталось действий: %d" % [
		_gs._name_of(pid), action_type, int(p["actions_left"])
	])
	if int(p["actions_left"]) == 0:
		advance_action_turn()

	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


## Хост: игрок завершил встречу — отметить и передать ход дальше.
## Возвращает true при успехе. Зовётся из GameState.finish_encounter и из
## relay-router на game_finish_encounter.
func host_apply_finish_encounter(pid: String) -> bool:
	if _gs.phase != "encounter":
		return false
	if not _gs.players.has(pid):
		return false
	if _gs.players[pid].get("encounter_done", false):
		return false
	# Встречи проходят по очереди — только активный игрок может завершить.
	if _gs._current_pid() != pid:
		GameConsole.warn("[Game] %s завершает встречу не в свой ход" % _gs._name_of(pid))
		return false

	_gs.players[pid]["encounter_done"] = true
	GameConsole.log("[Game] %s завершил встречу" % _gs._name_of(pid))

	advance_encounter_turn()

	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# ── Поток фаз ────────────────────────────────────────────────────────────────

## Передать ход в action-фазе. Если списком кончились — переход в encounter.
## Public — зовётся из _on_player_left когда отключился current.
func advance_action_turn() -> void:
	_gs.current_idx += 1
	if not skip_disconnected():
		enter_encounter()


## Войти в фазу encounter с первого подключённого игрока. Сбрасывает
## encounter_done у всех, запускает _encounter.generate. Если живых игроков
## не осталось — пропуск сразу в mythos.
func enter_encounter() -> void:
	_gs.phase       = "encounter"
	_gs.current_idx = 0   # первый игрок начинает встречу, остальные ждут своей очереди
	for pid: String in _gs.players:
		_gs.players[pid]["encounter_done"] = false
	# Все игроки отключены — фаза встреч пропускается.
	if not skip_disconnected():
		_gs._mythos.enter_phase()
		return
	GameConsole.log("[Game] Фаза: встречи · ход: %s" % _gs._name_of(_gs._current_pid()))
	_gs.phase_changed.emit(_gs.phase)
	_gs._encounter.begin_turn()


## Передать ход на встречу следующему подключённому игроку (или Mythos, если
## кончился список). Public — зовётся также из _on_player_left.
func advance_encounter_turn() -> void:
	_gs.current_idx += 1
	if not skip_disconnected():
		_gs._mythos.enter_phase()
	else:
		GameConsole.log("[Game] Встреча: ход → %s" % _gs._name_of(_gs._current_pid()))
		_gs._encounter.begin_turn()


## Стартует новый раунд (зовётся из MythosFlow после применения карты мифов):
## раунд++, фаза action, action-окно у всех восстановлено, встречи закрыты.
func start_new_round() -> void:
	_gs.round_num  += 1
	_gs.phase       = "action"
	_gs.current_idx = 0
	for pid: String in _gs.players:
		_gs.players[pid]["actions_left"]   = _gs.ACTIONS_PER_ROUND
		_gs.players[pid]["actions_used"]   = []
		_gs.players[pid]["encounter_done"] = false
	skip_disconnected()   # начинаем раунд с первого подключённого игрока
	GameConsole.log("[Game] Раунд %d · ход: %s" % [_gs.round_num, _gs._name_of(_gs._current_pid())])
	_gs.phase_changed.emit(_gs.phase)


## Прокрутить current_idx мимо отключённых игроков. true — остановились на
## подключённом игроке; false — досмотрели turn_order до конца (ходить некому).
func skip_disconnected() -> bool:
	while _gs.current_idx < _gs.turn_order.size():
		var pid: String = _gs.turn_order[_gs.current_idx]
		if _gs.players.has(pid) and bool(_gs.players[pid].get("connected", true)):
			return true
		_gs.current_idx += 1
	return false


# ── Travel ──────────────────────────────────────────────────────────────────

## Проверка связности: dest достижима из текущей локации игрока pid.
func can_travel(pid: String, dest: String) -> bool:
	if dest.is_empty() or not _gs.players.has(pid):
		return false
	var here: String = String(_gs.players[pid].get("location", ""))
	if dest == here:
		return false
	var conns: Array = _location_connections(here)
	for i in range(conns.size()):
		var c: Dictionary = conns[i]
		if String(c.get("to", "")) == dest:
			return true
	return false


# Список связей локации из locations.json. Матчим по id (стабильный slug),
# а не по name — name теперь translation key (LOC_*_NAME), не уникальный.
func _location_connections(loc_id: String) -> Array:
	var locations: Array = _gs._load_locations()
	for i in range(locations.size()):
		var loc: Dictionary = locations[i]
		if String(loc.get("id", "")) == loc_id:
			return loc.get("connections", [])
	return []
