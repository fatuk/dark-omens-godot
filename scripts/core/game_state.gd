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

# Интерпретатор Effect-DSL — применяет onSuccess/onFailure встреч.
const EffectRunner = preload("res://scripts/core/effect_runner.gd")

# ── Глобальный стейт ──────────────────────────────────────────────────────────
var round_num:  int    = 0
var phase:      String = ""           # "action" | "encounter" | "mythos" | ""
var current_idx: int   = 0            # индекс в turn_order активного игрока
var turn_order: Array  = []           # [user_id, ...] — отсортирован, стабилен
var doom:       int    = 0
var omens_step: int    = 0
var active:     bool   = false        # игра запущена?

# Карта встречи активного игрока (фаза encounter). {} — ещё генерится либо
# встреч сейчас нет. Хост генерит через ContentApi и кладёт сюда, рассылает
# синком всем.
var current_encounter: Dictionary = {}

# Компактная сводка сгенерированной кампании: {id, doomClock, ancientOne,
# theme, mysteries}. {} — кампания ещё генерится либо не настроена. Полная
# библия хранится на сервере и тянется по id при генерации встреч.
var campaign: Dictionary = {}

# true, пока хост генерит сценарную библию — на это время игрок заблокирован
# модалкой и не допущен на карту.
var campaign_pending: bool = false

# ── По-игроку ────────────────────────────────────────────────────────────────
# Ключ — стабильный user_id аккаунта (для анонимов фолбэк на id соединения).
# Благодаря этому переподключившийся игрок находит свой слот, а не создаёт
# новый. user_id → {
#   user_id, name, investigator, location, connected,
#   actions_left, actions_used, encounter_done,
#   tickets, concentration, hp, sanity, hp_max, sanity_max,
#   clues, conditions, items, skill_mods
# }
var players: Dictionary = {}

var _nm: Node = null

# Кэш data/locations.json — для имени/типа локации в запросе встречи.
var _locations_cache: Array = []

# Эпоха генерации кампании: инкрементится на каждый новый цикл генерации и на
# reset_pregame. Защищает от записи устаревшего результата (см.
# _start_campaign_generation).
var _campaign_epoch: int = 0

# Зерно будущей кампании из модалки создания комнаты: имя Древнего ("" — на
# выбор модели) и размер партии (0 — не задан, фолбэк на состав лобби).
var _seed_ancient_one: String = ""
var _seed_player_count: int = 0


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_nm = get_node("/root/NetworkManager")
	_nm.relay_received.connect(_on_relay_received)
	_nm.player_left.connect(_on_player_left)
	_nm.player_connected.connect(_on_player_connected)
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
		"current_encounter": current_encounter,
		"campaign":    campaign,
		"campaign_pending": campaign_pending,
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
	current_encounter = {}
	# campaign / campaign_pending НЕ сбрасываем — библия могла быть прогрета
	# заранее в лобби (prewarm_campaign). Сброс прошлой игры — reset_pregame().
	for p: Dictionary in players_init:
		var pid: String = p.get("pid", "")
		if pid.is_empty():
			continue
		# Ключ слота — стабильный user_id; для анонима фолбэк на id соединения.
		var uid: String = String(p.get("user_id", ""))
		if uid.is_empty():
			uid = pid
		var start_loc: String = String(
			Investigators.get_data(String(p.get("investigator", ""))).get("startingLocation", "")
		)
		players[uid] = {
			"user_id":        uid,
			"name":           p.get("name", "???"),
			"investigator":   p.get("investigator", ""),
			"location":       start_loc,
			"connected":      true,
			"actions_left":   ACTIONS_PER_ROUND,
			"actions_used":   [],
			"encounter_done": false,
			"tickets":        0,
			"concentration":  0,
			"hp":             p.get("hp_max", 5),
			"sanity":         p.get("sanity_max", 5),
			"hp_max":         p.get("hp_max", 5),
			"sanity_max":     p.get("sanity_max", 5),
			"clues":          0,
			"conditions":     [],
			"items":          [],
			"skill_mods":     {},
		}
		turn_order.append(uid)
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
	# Библия: прогрета в лобби — используем готовую (или дождёмся текущей
	# генерации); не прогрета — запускаем генерацию сейчас (фолбэк).
	if campaign.is_empty() and not campaign_pending:
		_start_campaign_generation(turn_order.size(), "")
	_broadcast_sync()
	_emit_changed()
	phase_changed.emit(phase)


# ── Хост: обработка действия (своего или чужого через game_action) ──────────

## Применить действие. Если ты НЕ хост, отправит запрос хосту через relay.
func perform_action(action_type: String, payload: Dictionary = {}) -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_apply_action_as_host(my_pid, action_type, payload)
	else:
		_nm.relay_all({
			"action": "game_action", "type": action_type,
			"pid": my_pid, "payload": payload,
		})


func _apply_action_as_host(pid: String, action_type: String, payload: Dictionary = {}) -> bool:
	if phase != "action":
		GameConsole.warn("[Game] Действие вне фазы action отклонено")
		return false
	if _current_pid() != pid:
		GameConsole.warn("[Game] %s ходит вне очереди" % _name_of(pid))
		return false
	if not players.has(pid):
		return false

	var p: Dictionary = players[pid]
	if int(p.get("actions_left", 0)) <= 0:
		return false

	# Одно и то же действие нельзя повторять в раунде (pass не в счёт).
	var used: Array = p.get("actions_used", [])
	if action_type != "pass" and used.has(action_type):
		GameConsole.warn("[Game] %s — «%s» уже использовано в этом раунде" % [
			_name_of(pid), action_type
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
			if not _can_travel(pid, dest):
				GameConsole.warn("[Game] %s — недопустимое перемещение" % _name_of(pid))
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
		_name_of(pid), action_type, int(p["actions_left"])
	])
	if int(p["actions_left"]) == 0:
		_advance_turn()

	_broadcast_sync()
	_emit_changed()
	return true


func _advance_turn() -> void:
	current_idx += 1
	if not _skip_disconnected():
		_enter_encounter()


func _enter_encounter() -> void:
	phase       = "encounter"
	current_idx = 0   # первый игрок начинает встречу, остальные ждут своей очереди
	for pid: String in players:
		players[pid]["encounter_done"] = false
	# Все игроки отключены — фаза встреч пропускается.
	if not _skip_disconnected():
		_run_mythos()
		return
	GameConsole.log("[Game] Фаза: встречи · ход: %s" % _name_of(_current_pid()))
	phase_changed.emit(phase)
	_generate_encounter_for_current()


## Прокрутить current_idx мимо отключённых игроков. true — остановились на
## подключённом игроке; false — досмотрели turn_order до конца (ходить некому).
func _skip_disconnected() -> bool:
	while current_idx < turn_order.size():
		var pid: String = turn_order[current_idx]
		if players.has(pid) and bool(players[pid].get("connected", true)):
			return true
		current_idx += 1
	return false


## Передать ход на встречу следующему подключённому игроку (или Mythos).
func _advance_encounter_turn() -> void:
	current_idx += 1
	if not _skip_disconnected():
		_run_mythos()
	else:
		GameConsole.log("[Game] Встреча: ход → %s" % _name_of(_current_pid()))
		_generate_encounter_for_current()


# ── Encounter ────────────────────────────────────────────────────────────────

func finish_encounter() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_apply_finish_encounter(my_pid)
	else:
		_nm.relay_all({"action": "game_finish_encounter", "pid": my_pid})


## Активный игрок бросает проверку встречи. Хост катит и применяет эффекты.
func resolve_encounter() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_apply_resolve_encounter(my_pid)
	else:
		_nm.relay_all({"action": "game_resolve_encounter", "pid": my_pid})


# ── Действие «Перемещение» ────────────────────────────────────────────────────

## Переместиться в связанную локацию dest (расходует действие).
func travel(dest: String) -> void:
	perform_action("travel", { "to": dest })


## Может ли локальный игрок переместиться в dest прямо сейчас (для UI сайдбара).
func can_travel_to(dest: String) -> bool:
	if not is_my_turn():
		return false
	var me: Dictionary = my_player()
	if int(me.get("actions_left", 0)) <= 0:
		return false
	var used: Array = me.get("actions_used", [])
	if used.has("travel"):
		return false
	return _can_travel(_nm.my_user_id, dest)


## Проверка связности: dest достижима из текущей локации игрока pid.
func _can_travel(pid: String, dest: String) -> bool:
	if dest.is_empty() or not players.has(pid):
		return false
	var here: String = String(players[pid].get("location", ""))
	if dest == here:
		return false
	var conns: Array = _location_connections(here)
	for i in range(conns.size()):
		var c: Dictionary = conns[i]
		if String(c.get("to", "")) == dest:
			return true
	return false


## Список связей локации из locations.json.
func _location_connections(loc_name: String) -> Array:
	if _locations_cache.is_empty():
		_locations_cache = DataLoader.load_array("res://data/locations.json")
	for i in range(_locations_cache.size()):
		var loc: Dictionary = _locations_cache[i]
		if String(loc.get("name", "")) == loc_name:
			return loc.get("connections", [])
	return []


func _apply_finish_encounter(pid: String) -> bool:
	if phase != "encounter":
		return false
	if not players.has(pid):
		return false
	if players[pid].get("encounter_done", false):
		return false
	# Встречи проходят по очереди — только активный игрок может завершить.
	if _current_pid() != pid:
		GameConsole.warn("[Game] %s завершает встречу не в свой ход" % _name_of(pid))
		return false

	players[pid]["encounter_done"] = true
	GameConsole.log("[Game] %s завершил встречу" % _name_of(pid))

	_advance_encounter_turn()

	_broadcast_sync()
	_emit_changed()
	return true


# ── Mythos ───────────────────────────────────────────────────────────────────

func _run_mythos() -> void:
	phase             = "mythos"
	current_encounter = {}   # фаза встреч закончилась
	omens_step       += 1
	doom             += 1
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
		players[pid]["actions_used"]   = []
		players[pid]["encounter_done"] = false
	_skip_disconnected()   # начинаем раунд с первого подключённого игрока
	GameConsole.log("[Game] Раунд %d · ход: %s" % [round_num, _name_of(_current_pid())])
	phase_changed.emit(phase)


# ── Уход игрока ──────────────────────────────────────────────────────────────

# Игрок отключился (закрыл клиент, потерял связь, вышел кнопкой).
# Слот НЕ удаляется и НЕ выбывает из turn_order — игрок помечается
# отключённым и при повторном входе возвращается в тот же слот. Только хост
# двигает стейт и рассылает sync.
func _on_player_left(player_id: String, _new_host_id: String, user_id: String) -> void:
	if not active or not _is_host():
		return
	# Ключ слота — стабильный user_id; аноним → фолбэк на id соединения.
	var uid: String = user_id
	if uid.is_empty():
		uid = player_id
	if not players.has(uid):
		return

	players[uid]["connected"] = false
	GameConsole.log("[Game] %s отключился — слот сохранён до возвращения" % _name_of(uid))

	# Если отключился игрок, чей сейчас ход — пропускаем его, иначе партия
	# застрянет на «ходит несуществующий игрок».
	if _current_pid() == uid:
		if phase == "action":
			_advance_turn()
		elif phase == "encounter":
			_advance_encounter_turn()

	_broadcast_sync()
	_emit_changed()


# Игрок (пере)подключился к комнате. Хост возвращает прежнего участника в его
# слот, а нового игрока с уже выбранным сыщиком — подключает к идущей партии.
func _on_player_connected(pid: String, info: Dictionary) -> void:
	if not active or not _is_host():
		return
	var uid: String = String(info.get("user_id", ""))
	if uid.is_empty():
		uid = pid
	if players.has(uid):
		if not bool(players[uid].get("connected", true)):
			players[uid]["connected"] = true
			GameConsole.log("[Game] %s вернулся в игру" % _name_of(uid))
			_broadcast_sync()
			_emit_changed()
		return
	# Новый участник: сыщик уже выбран (relay восстановил из БД) — подключаем
	# сразу; иначе ждём set_ready после выбора в лобби (_handle_late_join).
	var inv: String = String(info.get("investigator", ""))
	if not inv.is_empty():
		_add_player_mid_game(uid, String(info.get("name", "???")), inv)


## Хост: подключить позднего игрока по его set_ready (выбор сыщика в лобби
## уже идущей партии). user_id и имя берём из живого списка NetworkManager.
func _handle_late_join(data: Dictionary) -> void:
	var conn_id: String = String(data.get("player_id", ""))
	var inv: String     = String(data.get("investigator", ""))
	if conn_id.is_empty() or inv.is_empty():
		return
	var uid: String   = conn_id
	var pname: String = conn_id
	var lobby: Dictionary = _nm.players
	if lobby.has(conn_id):
		var rec: Dictionary = lobby[conn_id]
		var u: String = String(rec.get("user_id", ""))
		if not u.is_empty():
			uid = u
		pname = String(rec.get("name", conn_id))
	if players.has(uid):
		return   # уже участник — обычный set_ready, не поздний вход
	_add_player_mid_game(uid, pname, inv)


## Хост: добавить нового игрока в идущую партию. Слот ставится в конец
## turn_order — поздний игрок получает ход в текущем же раунде после остальных.
func _add_player_mid_game(uid: String, pname: String, investigator: String) -> void:
	if uid.is_empty() or investigator.is_empty() or players.has(uid):
		return
	var inv: Dictionary = Investigators.get_data(investigator)
	var hp_max: int  = int(inv.get("health", 5))
	var san_max: int = int(inv.get("sanity", 5))
	players[uid] = {
		"user_id":        uid,
		"name":           pname,
		"investigator":   investigator,
		"location":       String(inv.get("startingLocation", "")),
		"connected":      true,
		"actions_left":   ACTIONS_PER_ROUND,
		"actions_used":   [],
		"encounter_done": false,
		"tickets":        0,
		"concentration":  0,
		"hp":             hp_max,
		"sanity":         san_max,
		"hp_max":         hp_max,
		"sanity_max":     san_max,
		"clues":          0,
		"conditions":     [],
		"items":          [],
		"skill_mods":     {},
	}
	turn_order.append(uid)
	GameConsole.log("[Game] %s присоединился к партии (игроков: %d)" % [
		pname, turn_order.size()
	])
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
	current_encounter = data.get("current_encounter", {})
	campaign    = data.get("campaign",    {})
	campaign_pending = bool(data.get("campaign_pending", false))
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
				_apply_action_as_host(pid, t, data.get("payload", {}))

		"game_finish_encounter":
			if _is_host():
				_apply_finish_encounter(data.get("pid", ""))

		"game_resolve_encounter":
			if _is_host():
				_apply_resolve_encounter(data.get("pid", ""))

		"set_ready":
			# Поздний игрок выбрал сыщика в лобби уже идущей партии —
			# хост подключает его полноценным участником.
			if _is_host() and active:
				_handle_late_join(data)


# ── Сервисное ────────────────────────────────────────────────────────────────

func _current_pid() -> String:
	if current_idx < 0 or current_idx >= turn_order.size():
		return ""
	return turn_order[current_idx]


func _name_of(pid: String) -> String:
	if players.has(pid):
		return players[pid].get("name", pid)
	return pid


## Узнать, мой ли ход сейчас (только для phase=action).
func is_my_turn() -> bool:
	return active and phase == "action" and _current_pid() == _nm.my_user_id


## Узнать, моя ли очередь на встречу (только для phase=encounter).
## Встречи проходят последовательно по turn_order.
func is_my_encounter_turn() -> bool:
	return active and phase == "encounter" \
		and _current_pid() == _nm.my_user_id \
		and not have_finished_encounter()


## Узнать, я ли уже завершил встречу (только для phase=encounter).
func have_finished_encounter() -> bool:
	if not players.has(_nm.my_user_id):
		return false
	return bool(players[_nm.my_user_id].get("encounter_done", false))


## Получить мои собственные данные (или пустой словарь, если не в игре).
func my_player() -> Dictionary:
	return players.get(_nm.my_user_id, {})


# ── Хост: генерация встречи через ContentApi ──────────────────────────────────

## Генерит карту встречи для игрока, чей сейчас ход на встречу, и рассылает её.
## Пока карта генерится, current_encounter пустой — клиенты показывают загрузку.
## Корутина: вызывается без await (fire-and-forget) из encounter-флоу.
func _generate_encounter_for_current() -> void:
	if not _is_host():
		return
	var pid: String = _current_pid()
	if pid.is_empty() or not players.has(pid):
		return

	current_encounter = {}            # состояние «загрузка»
	_broadcast_sync()
	_emit_changed()

	var api: Node = get_node_or_null("/root/ContentApi")
	if api == null:
		GameConsole.warn("[Game] ContentApi недоступен — ставим встречу-заглушку")
		current_encounter = _fallback_encounter()
		_broadcast_sync()
		_emit_changed()
		return

	var req: Dictionary = _build_encounter_request(players[pid])
	GameConsole.log("[Game] Генерация встречи для %s..." % _name_of(pid))
	@warning_ignore("unsafe_method_access")
	var res: Dictionary = await api.generate_encounter(req)

	# За время генерации (десятки секунд) ход/фаза могли смениться —
	# не перетираем чужую встречу.
	if phase != "encounter" or _current_pid() != pid:
		return

	var encs: Array = res.get("encounters", [])
	if bool(res.get("ok", false)) and not encs.is_empty():
		current_encounter = encs[0]
		GameConsole.log("[Game] Встреча готова: %s" % String(current_encounter.get("name", "")))
	else:
		current_encounter = _fallback_encounter()
		GameConsole.warn("[Game] Генерация встречи не удалась: %s" % String(res.get("error", "")))
	_broadcast_sync()
	_emit_changed()


## Собирает тело запроса /encounters/generate для игрока.
func _build_encounter_request(p: Dictionary) -> Dictionary:
	var inv_id: String  = String(p.get("investigator", ""))
	var inv: Dictionary = Investigators.get_data(inv_id)
	var inv_name: String   = tr(String(inv.get("displayName", inv_id)))
	var background: String = tr(String(inv.get("occupation", "")))
	if background.is_empty():
		background = tr("ENCOUNTER_DEFAULT_BG")
	# Трекинга позиции сыщика ещё нет — берём его стартовую локацию.
	var loc: Dictionary = _location_info(String(p.get("location", "Arkham")))
	var req: Dictionary = {
		"kind":         "general",
		"investigator": { "name": inv_name, "background": background },
		"realLocation": { "name": loc["name"], "locationType": loc["type"] },
		"conditions":   [],
		"count":        1,
		"language":     _relay_language(),
	}
	# Библия готова — встреча несёт контекст кампании (Древний, акт, doom).
	var cid: String = String(campaign.get("id", ""))
	if not cid.is_empty():
		req["campaignId"] = cid
		req["act"]        = _current_act()
		req["doom"]       = doom
	return req


## Реальное (локализованное) имя и тип локации по её id из locations.json.
func _location_info(loc_name: String) -> Dictionary:
	if _locations_cache.is_empty():
		_locations_cache = DataLoader.load_array("res://data/locations.json")
	for i in range(_locations_cache.size()):
		var loc: Dictionary = _locations_cache[i]
		if String(loc.get("name", "")) == loc_name:
			return {
				"name": tr(String(loc.get("realWorldLocation", loc_name))),
				"type": String(loc.get("type", "city")),
			}
	return { "name": loc_name, "type": "city" }


## Запасная карта на случай сбоя генерации — игра не должна вставать.
func _fallback_encounter() -> Dictionary:
	return {
		"id":          "fallback",
		"name":        "ENCOUNTER_FALLBACK_NAME",
		"mainText":    "ENCOUNTER_FALLBACK_MAIN",
		"test":        { "skill": "will", "modifier": 0 },
		"successText": "ENCOUNTER_FALLBACK_SUCCESS",
		"failureText": "ENCOUNTER_FALLBACK_FAILURE",
		"onSuccess":   [],
		"onFailure":   [],
	}


## Текущий язык игры названием для relay ("Russian" / "English").
func _relay_language() -> String:
	if I18n.get_locale() == "en":
		return "English"
	return "Russian"


# ── Хост: разрешение встречи (бросок + эффекты) ───────────────────────────────

## Хост катит проверку активного игрока, применяет onSuccess/onFailure,
## кладёт результат в current_encounter.resolution и рассылает синком.
func _apply_resolve_encounter(pid: String) -> bool:
	if phase != "encounter" or not players.has(pid):
		return false
	if _current_pid() != pid:
		return false
	if current_encounter.is_empty() or current_encounter.has("resolution"):
		return false   # карта ещё генерится либо уже разрешена

	var roll: Dictionary = _roll_encounter_check(pid)
	var branch: Array = current_encounter.get(
		"onSuccess" if roll["passed"] else "onFailure", []
	)
	_apply_encounter_effects(branch, pid)

	current_encounter["resolution"] = roll
	GameConsole.log("[Game] %s · встреча %s · успехов: %d" % [
		_name_of(pid),
		"пройдена" if roll["passed"] else "провалена",
		int(roll["successes"]),
	])
	_broadcast_sync()
	_emit_changed()
	return true


## Бросок основной проверки: пул d6 = навык сыщика + модификаторы навыка +
## модификатор карты, успех на 5–6, пройдено при хотя бы одном успехе.
func _roll_encounter_check(pid: String) -> Dictionary:
	var p: Dictionary = players.get(pid, {})
	var test: Dictionary = current_encounter.get("test", {})
	var skill: String = String(test.get("skill", "will"))
	var modifier: int = int(test.get("modifier", 0))

	var inv: Dictionary = Investigators.get_data(String(p.get("investigator", "")))
	var inv_skills: Dictionary = inv.get("skills", {})
	var skill_mods: Dictionary = p.get("skill_mods", {})
	var pool: int = maxi(1,
		int(inv_skills.get(skill, 1)) + int(skill_mods.get(skill, 0)) + modifier
	)

	var dice: Array = []
	var successes: int = 0
	for _i in pool:
		var d: int = randi() % 6 + 1
		dice.append(d)
		if d >= 5:
			successes += 1
	return { "dice": dice, "successes": successes, "passed": successes >= 1 }


## Применяет программу эффектов: интерпретатор — игроку, эффекты поля — здесь.
func _apply_encounter_effects(effects: Array, pid: String) -> void:
	if effects.is_empty() or not players.has(pid):
		return
	var res: Dictionary = EffectRunner.run(effects, players[pid])
	var board: Array = res.get("board", [])
	for i in range(board.size()):
		var node: Dictionary = board[i]
		_apply_board_effect(node)
	var logs: Array = res.get("logs", [])
	for i in range(logs.size()):
		GameConsole.log("[Эффект] %s" % String(logs[i]))


## Эффекты уровня поля (advanceDoom и т.п.) — интерпретатор их не трогает.
func _apply_board_effect(node: Dictionary) -> void:
	var verb: String = String(node.get("do", ""))
	var n: int = int(node.get("amount", node.get("count", 1)))
	match verb:
		"advanceDoom":
			doom += n
			GameConsole.log("[Эффект] doom +%d" % n)
		"advanceOmen", "moveOmen":
			omens_step += n
			GameConsole.log("[Эффект] омен +%d" % n)
		_:
			GameConsole.log("[Эффект] %s — пока не поддержано движком" % verb)


# ── Хост: генерация сценарной библии ──────────────────────────────────────────

## Модалка создания комнаты задаёт «зерно» будущей кампании: имя Древнего
## ("" — на выбор модели) и размер партии. Прогрев в лобби (prewarm_campaign)
## подхватит их и сбросит — зерно одноразовое.
func set_campaign_seed(ancient_one: String, player_count: int) -> void:
	_seed_ancient_one  = ancient_one
	_seed_player_count = maxi(1, player_count)


## Хост: запустить генерацию библии ЗАРАНЕЕ — из лобби, пока игроки ещё
## выбирают сыщиков. К моменту start_game библия будет готова или почти
## готова, и экран загрузки покажется меньше (или не покажется вовсе).
## Использует зерно из set_campaign_seed; без зерна (промоут в хосты) —
## Древний на выбор модели, размер партии по составу лобби.
func prewarm_campaign() -> void:
	if not _is_host():
		return
	if campaign_pending or not campaign.is_empty():
		return   # генерация уже идёт либо библия уже готова
	var pc: int = _seed_player_count
	if pc <= 0:
		pc = maxi(1, _nm.players.size())
	var ao: String = _seed_ancient_one
	_seed_ancient_one  = ""    # зерно одноразовое
	_seed_player_count = 0
	GameConsole.log("[Game] Прогрев кампании в лобби (игроков: %d)..." % pc)
	_start_campaign_generation(pc, ao)


## Хост: сброс перед новой игрой. Зовётся из lobby при входе в свежее лобби —
## чтобы prewarm следующей игры не наткнулся на библию предыдущей и зависшую
## генерацию.
func reset_pregame() -> void:
	if not _is_host():
		return
	_campaign_epoch  += 1   # инвалидирует зависшую генерацию прошлой игры
	campaign          = {}
	campaign_pending  = false
	current_encounter = {}
	active            = false


## Хост: один цикл генерации сценарной библии (~минуты). Корутина —
## вызывается без await. Эпоха защищает от устаревших результатов: если за
## время await начался новый цикл или был reset_pregame — итог отбрасываем.
func _start_campaign_generation(player_count: int, ancient_one: String) -> void:
	if not _is_host():
		return
	_campaign_epoch += 1
	var epoch: int = _campaign_epoch
	campaign         = {}
	campaign_pending = true
	_emit_changed()

	var api: Node = get_node_or_null("/root/ContentApi")
	if api == null:
		GameConsole.warn("[Game] ContentApi недоступен — кампания не сгенерирована")
		if epoch == _campaign_epoch:
			campaign_pending = false
			if active:
				_broadcast_sync()
			_emit_changed()
		return

	var req: Dictionary = _build_campaign_request(player_count, ancient_one)
	GameConsole.log("[Game] Генерация сценарной библии...")
	@warning_ignore("unsafe_method_access")
	var res: Dictionary = await api.generate_campaign(req)

	if epoch != _campaign_epoch:
		return   # перебито новым циклом или reset_pregame — результат устарел
	if bool(res.get("ok", false)):
		campaign = _campaign_summary(res.get("campaign", {}))
		var ao: Dictionary = campaign.get("ancientOne", {})
		GameConsole.log("[Game] Кампания готова — Древний: %s" % String(ao.get("name", "?")))
	else:
		GameConsole.warn("[Game] Генерация кампании не удалась: %s" % String(res.get("error", "")))
	campaign_pending = false
	# Броадкаст только если игра уже идёт; библию, прогретую ещё в лобби,
	# разошлёт _broadcast_sync() из start_game.
	if active:
		_broadcast_sync()
	_emit_changed()


## Тело запроса /campaign/generate: локации, размер партии, язык, Древний.
func _build_campaign_request(player_count: int, ancient_one: String) -> Dictionary:
	if _locations_cache.is_empty():
		_locations_cache = DataLoader.load_array("res://data/locations.json")
	var locs: Array = []
	for i in range(_locations_cache.size()):
		var loc: Dictionary = _locations_cache[i]
		locs.append({
			"name": tr(String(loc.get("realWorldLocation", loc.get("name", "")))),
			"type": String(loc.get("type", "city")),
		})
	var req: Dictionary = {
		"locations":   locs,
		"playerCount": maxi(1, player_count),
		"language":    _relay_language(),
	}
	# Древний задан в модалке создания комнаты — иначе модель придумывает сама.
	if not ancient_one.is_empty():
		req["ancientOne"] = ancient_one
	return req


## Компактная сводка библии для GameState — без тяжёлой колоды Мифов и эффектов.
## Полная библия сохранена на сервере и тянется по id при генерации встреч.
func _campaign_summary(full: Dictionary) -> Dictionary:
	var mysteries: Array = []
	var src: Array = full.get("mysteries", [])
	for i in range(src.size()):
		var m: Dictionary = src[i]
		mysteries.append({
			"act":            int(m.get("act", 0)),
			"title":          String(m.get("title", "")),
			"flavorText":     String(m.get("flavorText", "")),
			"text":           String(m.get("text", "")),
			"solveCondition": m.get("solveCondition", {}),
		})
	return {
		"id":         String(full.get("id", "")),
		"doomClock":  int(full.get("doomClock", 0)),
		"ancientOne": full.get("ancientOne", {}),
		"theme":      full.get("theme", []),
		"mysteries":  mysteries,
	}


## Текущий акт (1–3) по доле заполнения doom-часов. Трекинга прогресса
## Мистерий пока нет — акт оцениваем по doom.
func _current_act() -> int:
	var clock: int = int(campaign.get("doomClock", 0))
	if clock <= 0:
		return 1
	var ratio: float = float(doom) / float(clock)
	if ratio < 0.34:
		return 1
	if ratio < 0.67:
		return 2
	return 3


## Мистерия текущего акта ({} если кампания/тайны ещё не готовы) — для UI.
func current_mystery() -> Dictionary:
	var ms: Array = campaign.get("mysteries", [])
	if ms.is_empty():
		return {}
	var act: int = _current_act()
	for i in range(ms.size()):
		var m: Dictionary = ms[i]
		if int(m.get("act", 0)) == act:
			return m
	return ms[0]
