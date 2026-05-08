extends Node

## Игровое состояние Dark Omens — autoload-синглтон /root/GameState.
##
## Хост-клиент авторитетный: держит стейт, применяет действия, транслирует
## изменения через relay. Не-хост — зеркало: получает game_sync и заменяет
## локальный стейт. Для своих действий не-хост шлёт game_action хосту.
##
## Фазы раунда: action → encounter → mythos → action (next round).
## В Action-фазе игроки ходят по очереди (turn_order), у каждого 2 действия.
## Доступные действия: buy_ticket, take_concentration, rest, pass.
## Encounter — заглушка (каждый просто жмёт «Завершить»).
## Mythos — авто: omens_step += 1, doom += 1.

signal state_changed                        # любое изменение стейта
signal phase_changed(new_phase: String)     # переход фазы
signal mythos_resolved(omens_step: int, doom: int)  # для UI-уведомления

const ACTIONS_PER_ROUND := 2
const REST_HEAL_HP      := 1
const REST_HEAL_SANITY  := 1

# ── Глобальный стейт ──────────────────────────────────────────────────────────
var round_num:  int    = 0
var phase:      String = ""           # "action" | "encounter" | "mythos" | ""
var current_idx: int   = 0            # индекс в turn_order активного игрока
var turn_order: Array  = []           # [user_id, ...] — отсортирован, стабилен
var doom:       int    = 0
var omens_step: int    = 0
var active:     bool   = false        # игра запущена?

# ── По-игроку ────────────────────────────────────────────────────────────────
# pid (client_id) → {
#   user_id, name, investigator,
#   actions_left, encounter_done,
#   tickets, concentration, hp, sanity, hp_max, sanity_max
# }
var players: Dictionary = {}

var _nm: Node = null


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_nm = get_node("/root/NetworkManager")
	_nm.relay_received.connect(_on_relay_received)
	_nm.player_left.connect(_on_player_left)
	_nm.game_state_received.connect(_apply_snapshot)


# ── Helpers ──────────────────────────────────────────────────────────────────

func _is_host() -> bool:
	return is_instance_valid(_nm) and _nm.is_host()


func _broadcast_sync() -> void:
	# Только хост рассылает полное состояние
	if not _is_host():
		return
	_nm.relay_all({
		"action":      "game_sync",
		"round_num":   round_num,
		"phase":       phase,
		"current_idx": current_idx,
		"turn_order":  turn_order,
		"doom":        doom,
		"omens_step":  omens_step,
		"players":     players,
		"active":      active,
	})


func _emit_changed() -> void:
	state_changed.emit()


# ── Хост: запуск игры ────────────────────────────────────────────────────────

## Вызывается хостом после нажатия «Начать игру».
## players_init: [{ pid, user_id, name, investigator, hp_max, sanity_max }, ...]
func start_game(players_init: Array) -> void:
	if not _is_host():
		return

	players.clear()
	turn_order.clear()
	for p: Dictionary in players_init:
		var pid: String = p.get("pid", "")
		if pid.is_empty():
			continue
		players[pid] = {
			"user_id":        p.get("user_id", ""),
			"name":           p.get("name", "???"),
			"investigator":   p.get("investigator", ""),
			"actions_left":   ACTIONS_PER_ROUND,
			"encounter_done": false,
			"tickets":        0,
			"concentration":  0,
			"hp":             p.get("hp_max", 5),
			"sanity":         p.get("sanity_max", 5),
			"hp_max":         p.get("hp_max", 5),
			"sanity_max":     p.get("sanity_max", 5),
		}
		turn_order.append(pid)
	turn_order.sort()

	round_num   = 1
	phase       = "action"
	current_idx = 0
	doom        = 0
	omens_step  = 0
	active      = true

	GameConsole.log("[Game] Игра начата · игроков: %d · ход: %s" % [
		turn_order.size(), _name_of(_current_pid())
	])
	_broadcast_sync()
	_emit_changed()
	phase_changed.emit(phase)


# ── Хост: обработка действия (своего или чужого через game_action) ──────────

## Применить действие. Если ты НЕ хост, отправит запрос хосту через relay.
func perform_action(action_type: String) -> void:
	var my_pid: String = _nm.my_id
	if _is_host():
		_apply_action_as_host(my_pid, action_type)
	else:
		_nm.relay_all({"action": "game_action", "type": action_type, "pid": my_pid})


func _apply_action_as_host(pid: String, action_type: String) -> bool:
	if phase != "action":
		GameConsole.warn("[Game] Действие вне фазы action отклонено")
		return false
	if turn_order[current_idx] != pid:
		GameConsole.warn("[Game] %s ходит вне очереди" % _name_of(pid))
		return false
	if not players.has(pid):
		return false

	var p: Dictionary = players[pid]
	if int(p.get("actions_left", 0)) <= 0:
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
		"pass":
			p["actions_left"] = 0
		_:
			GameConsole.warn("[Game] Неизвестное действие: %s" % action_type)
			return false

	GameConsole.log("[Game] %s · %s · осталось действий: %d" % [
		_name_of(pid), action_type, int(p["actions_left"])
	])
	if int(p["actions_left"]) == 0:
		_advance_turn()

	_broadcast_sync()
	_emit_changed()
	return true


func _advance_turn() -> void:
	current_idx += 1
	if current_idx >= turn_order.size():
		_enter_encounter()


func _enter_encounter() -> void:
	phase       = "encounter"
	current_idx = 0   # первый игрок начинает встречу, остальные ждут своей очереди
	for pid: String in players:
		players[pid]["encounter_done"] = false
	GameConsole.log("[Game] Фаза: встречи · ход: %s" % _name_of(_current_pid()))
	phase_changed.emit(phase)


# ── Encounter ────────────────────────────────────────────────────────────────

func finish_encounter() -> void:
	var my_pid: String = _nm.my_id
	if _is_host():
		_apply_finish_encounter(my_pid)
	else:
		_nm.relay_all({"action": "game_finish_encounter", "pid": my_pid})


func _apply_finish_encounter(pid: String) -> bool:
	if phase != "encounter":
		return false
	if not players.has(pid):
		return false
	if players[pid].get("encounter_done", false):
		return false
	# Встречи проходят по очереди — только активный игрок может завершить.
	if turn_order.is_empty() or turn_order[current_idx] != pid:
		GameConsole.warn("[Game] %s завершает встречу не в свой ход" % _name_of(pid))
		return false

	players[pid]["encounter_done"] = true
	GameConsole.log("[Game] %s завершил встречу" % _name_of(pid))

	# Передаём ход на встречу следующему игроку
	current_idx += 1
	if current_idx >= turn_order.size():
		_run_mythos()
	else:
		GameConsole.log("[Game] Встреча: ход → %s" % _name_of(_current_pid()))

	_broadcast_sync()
	_emit_changed()
	return true


# ── Mythos ───────────────────────────────────────────────────────────────────

func _run_mythos() -> void:
	phase       = "mythos"
	omens_step += 1
	doom       += 1
	GameConsole.log("[Game] Фаза Мифов · омен сдвинулся (%d) · doom +1 (%d)" % [omens_step, doom])
	phase_changed.emit(phase)
	mythos_resolved.emit(omens_step, doom)
	# Сразу новый раунд (Mythos для MVP — это просто шаг счётчиков)
	_start_new_round()


func _start_new_round() -> void:
	round_num  += 1
	phase       = "action"
	current_idx = 0
	for pid: String in players:
		players[pid]["actions_left"]   = ACTIONS_PER_ROUND
		players[pid]["encounter_done"] = false
	GameConsole.log("[Game] Раунд %d · ход: %s" % [round_num, _name_of(_current_pid())])
	phase_changed.emit(phase)


# ── Уход игрока ──────────────────────────────────────────────────────────────

# Игрок покинул комнату (закрыл клиент, вышел кнопкой, kicked).
# Только хост (после возможного промоута) чистит стейт и рассылает sync.
# Иначе оставшиеся игроки видят «сейчас ходит несуществующий игрок».
func _on_player_left(player_id: String, _new_host_id: String) -> void:
	if not active:
		return
	if not _is_host():
		return
	if not players.has(player_id):
		return

	var name_left: String = _name_of(player_id)
	players.erase(player_id)

	var idx: int = turn_order.find(player_id)
	if idx >= 0:
		turn_order.remove_at(idx)
		if turn_order.is_empty():
			active = false
			GameConsole.warn("[Game] Все игроки покинули игру")
		elif phase == "action":
			# Action: ход у turn_order[current_idx]. Сжимаем индекс если нужно.
			if idx < current_idx:
				current_idx -= 1
			elif idx == current_idx and current_idx >= turn_order.size():
				# Активный игрок ушёл и был последним — переходим в encounter
				_enter_encounter()
		elif phase == "encounter":
			# Encounter: тоже последовательно. Если ушёл идущий — current_idx
			# теперь указывает на следующего (после remove_at). Если был
			# последним — Mythos.
			if idx < current_idx:
				current_idx -= 1
			if current_idx >= turn_order.size():
				_run_mythos()

	GameConsole.log("[Game] %s покинул игру (осталось: %d)" % [name_left, turn_order.size()])
	_broadcast_sync()
	_emit_changed()


# ── Применить снапшот (от хоста через relay ИЛИ от сервера через joined_room) ─

func _apply_snapshot(data: Dictionary) -> void:
	round_num   = int(data.get("round_num",   0))
	phase       = String(data.get("phase",    ""))
	current_idx = int(data.get("current_idx", 0))
	turn_order  = data.get("turn_order",  [])
	doom        = int(data.get("doom",        0))
	omens_step  = int(data.get("omens_step",  0))
	players     = data.get("players",     {})
	active      = bool(data.get("active",     false))
	_emit_changed()
	phase_changed.emit(phase)


# ── Не-хост: приём от relay ──────────────────────────────────────────────────

func _on_relay_received(_from_id: String, data: Dictionary) -> void:
	match data.get("action", ""):
		"game_sync":
			# Хост прислал полный стейт — применяем тем же путём, что снапшот
			# с сервера (joined_room.game_state).
			_apply_snapshot(data)

		"game_action":
			# Не-хост попросил выполнить действие — хост валидирует и применяет
			if _is_host():
				var pid: String = data.get("pid", "")
				var t: String   = data.get("type", "")
				_apply_action_as_host(pid, t)

		"game_finish_encounter":
			if _is_host():
				_apply_finish_encounter(data.get("pid", ""))


# ── Сервисное ────────────────────────────────────────────────────────────────

func _current_pid() -> String:
	if turn_order.is_empty():
		return ""
	return turn_order[current_idx]


func _name_of(pid: String) -> String:
	if players.has(pid):
		return players[pid].get("name", pid)
	return pid


## Узнать, мой ли ход сейчас (только для phase=action).
func is_my_turn() -> bool:
	return active and phase == "action" and _current_pid() == _nm.my_id


## Узнать, моя ли очередь на встречу (только для phase=encounter).
## Встречи проходят последовательно по turn_order.
func is_my_encounter_turn() -> bool:
	return active and phase == "encounter" \
		and _current_pid() == _nm.my_id \
		and not have_finished_encounter()


## Узнать, я ли уже завершил встречу (только для phase=encounter).
func have_finished_encounter() -> bool:
	if not players.has(_nm.my_id):
		return false
	return bool(players[_nm.my_id].get("encounter_done", false))


## Получить мои собственные данные (или пустой словарь, если не в игре).
func my_player() -> Dictionary:
	return players.get(_nm.my_id, {})
