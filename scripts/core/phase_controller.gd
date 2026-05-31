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
		"acquire_assets":
			# Поход в магазин — уникальное действие (раз за раунд). Фиксируется уже
			# при БРОСКЕ кубов: тратит действие сразу, поэтому отмена покупки не
			# вернёт возможность снова пойти в магазин. Сами товары выдаются позже
			# (host_apply_shop_grant по кнопке «Купить»).
			if _gs.location_type(String(p.get("location", ""))) != "city":
				GameConsole.warn("[Магазин] %s не в городе" % _gs._name_of(pid))
				return false
			p["actions_left"] = int(p["actions_left"]) - 1
			p["shopping"]     = true   # не передаём ход, пока магазин открыт
			GameConsole.log("[Магазин] %s пошёл за покупками" % _gs._name_of(pid))
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
	# Пока игрок в магазине (модалка открыта) — ход не передаём, даже если это
	# было последнее действие. Передача произойдёт при закрытии (host_apply_shop_close).
	if int(p["actions_left"]) == 0 and not bool(p.get("shopping", false)):
		advance_action_turn()

	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


## Хост: выдать купленные ассеты. Действие уже потрачено при броске
## (acquire_assets в actions_used), поэтому очередь/лимит тут не проверяем — только
## что игрок реально начал поход в магазин в этом раунде и стоит в городе.
func host_apply_shop_grant(pid: String, assets: Array) -> bool:
	if not _gs.players.has(pid) or assets.is_empty():
		return false
	var p: Dictionary = _gs.players[pid]
	if not (p.get("actions_used", []) as Array).has("acquire_assets"):
		return false
	if _gs.location_type(String(p.get("location", ""))) != "city":
		return false
	var items: Array = p.get("items", [])
	for aid_v: Variant in assets:
		var aid: String = String(aid_v)
		if not AssetCatalog.by_id(aid).is_empty():
			items.append(aid)
	p["items"] = items
	_gs._refill_shop_reserve(assets)   # купленные → заменить новыми
	GameConsole.log("[Магазин] %s купил %d товар(ов)" % [_gs._name_of(pid), assets.size()])
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


## Хост: магазин закрыт. Снимаем флаг shopping и, если действий не осталось,
## только теперь передаём ход (отложенная передача после похода в магазин).
func host_apply_shop_close(pid: String) -> bool:
	if not _gs.players.has(pid):
		return false
	var p: Dictionary = _gs.players[pid]
	if not bool(p.get("shopping", false)):
		return false
	p["shopping"] = false
	if int(p.get("actions_left", 0)) == 0:
		advance_action_turn()
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


## Хост: игрок берёт долг — вешает состояние «debt». Двух одинаковых состояний
## иметь нельзя, поэтому повторный debt игнорируется. Долг — не отдельное действие
## (часть похода в магазин), но взять его может только активный игрок в городе.
func host_apply_shop_debt(pid: String) -> bool:
	if not _gs.players.has(pid):
		return false
	if _gs._current_pid() != pid:
		return false
	var p: Dictionary = _gs.players[pid]
	if _gs.location_type(String(p.get("location", ""))) != "city":
		return false
	var conds: Array = p.get("conditions", [])
	if conds.has("debt"):
		GameConsole.log("[Магазин] %s уже имеет «Долг»" % _gs._name_of(pid))
		return false
	conds.append("debt")
	p["conditions"] = conds
	GameConsole.log("[Магазин] %s взял Долг" % _gs._name_of(pid))
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


## Хост: списать 1 концентрацию за переброс куба в магазине. Сам переброс и
## пересчёт монет — на клиенте (бросок магазина клиентский), здесь авторитетно
## тратится только синкаемый фокус. Можно только активному игроку, который сейчас
## в магазине (shopping) и имеет концентрацию.
func host_apply_shop_reroll(pid: String) -> bool:
	if not _gs.players.has(pid):
		return false
	if _gs._current_pid() != pid:
		return false
	var p: Dictionary = _gs.players[pid]
	if not bool(p.get("shopping", false)):
		return false
	if int(p.get("concentration", 0)) <= 0:
		return false
	p["concentration"] = int(p["concentration"]) - 1
	GameConsole.log("[Магазин] %s · переброс за фокус (−1)" % _gs._name_of(pid))
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

	# Применяем итоговые эффекты встречи ЗДЕСЬ (не при броске) — чтобы между
	# броском и завершением был доступен переброс за концентрацию.
	_gs._encounter._commit_outcome(pid)

	# Бой может продолжиться (ещё монстры на клетке) или перейти к выбору не-боевой
	# встречи — тогда ход того же игрока НЕ завершаем.
	if _gs._encounter.continue_encounter_turn(pid):
		_gs._broadcast_sync()
		_gs._emit_changed()
		return true

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
