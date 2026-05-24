extends Node

## Игровое состояние Dark Omens — autoload-синглтон /root/GameState.
##
## Хост-клиент авторитетный: держит стейт, применяет действия, транслирует
## изменения через relay. Не-хост — зеркало: получает game_sync и заменяет
## локальный стейт. Для своих действий не-хост шлёт game_action хосту.
##
## Фазы раунда: action → encounter → mythos → action (next round).
## В Action-фазе игроки ходят по очереди (turn_order), у каждого 2 действия.
## Доступные действия: buy_ticket, take_concentration, rest, travel, pass.
## Encounter — каждому генерится карточка, бросок проверки, эффекты.
## Mythos — хост вытягивает карту из mythosDeck, ВСЕ видят модалку, по
## кнопке «Дальше» хост применяет onDraw-эффекты и стартует новый раунд.

signal state_changed                        # любое изменение стейта
signal phase_changed(new_phase: String)     # переход фазы
signal mythos_resolved(omens_step: int, doom: int)  # для UI-уведомления

const ACTIONS_PER_ROUND := 2

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

# Кэш data/locations.json — для имени/типа локации в запросе встречи и
# проверки связности при travel. Лениво загружается через _load_locations().
var _locations_cache: Array = []

# Активная карта Мифов (синкается). {} — фаза не mythos или карта уже разрешена.
var current_mythos: Dictionary = {}

# Открытые врата по локациям (синкается). {loc_id: "red"|"green"|"blue"}.
# Меняется через _apply_board_effect("openGate"). MapLayer.set_gates рендерит
# их визуально на маркерах с вращающейся анимацией.
var gates: Dictionary = {}

# Сущности по локациям (синкается). {loc_id: [type,…]} — улики/слухи (token-ы)
# (type ∈ "clue"|"rumor"). Монстры хранятся отдельно (monsters), но на карте
# показываются тем же набором иконок (world_map склеивает вид).
var entities: Dictionary = {}

# Монстры по локациям (синкается). {loc_id: [{id, health},…]} — экземпляры из
# MonsterCatalog с текущим здоровьем (урон в бою сохраняется между встречами).
# Визуально склеиваются с entities (по количеству).
var monsters: Dictionary = {}

# «Мешок» доступных монстров (синкается) — список id, ещё не выставленных на
# поле. Спаун тянет случайный id из мешка (без повторов), смерть монстра
# возвращает его id обратно. Наполняется на старте всеми не-эпиками.
var monster_bag: Array = []

# Параметр «Наплыв монстров» (синкается) — сколько монстров лезет из каждых врат
# текущего омена при событии Наплыва. Задаётся по таблице Icon Reference на старте.
var monster_surge: int = 0

# Доступные типы встречи активного игрока в фазе encounter (синкается). Непусто
# → клиент показывает модалку выбора; выбор шлётся choose_encounter, после чего
# хост генерирует встречу выбранного kind. Очищается после выбора/смены хода.
# Элементы ∈ "general" | "research" | "gate" | "combat".
var encounter_choices: Array = []

# Подсистемы. GameState — фасад и хранитель синкаемого state; подмодули —
# host-only логика и owned state (колода мифов, эпоха генерации кампании,
# префетч встреч). _phase владеет переходами и обработкой действий — без
# собственных полей, тонкий контроллер.
var _mythos:    MythosFlow
var _campaign:  CampaignGen
var _encounter: EncounterFlow
var _phase:     PhaseController


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_nm = get_node("/root/NetworkManager")
	# Подмодули создаём ДО подписки на сигналы — иначе входящий снапшот может
	# обратиться к ним раньше, чем они инициализированы.
	_mythos    = MythosFlow.new(self)
	_campaign  = CampaignGen.new(self)
	_encounter = EncounterFlow.new(self)
	_phase     = PhaseController.new(self)
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
		"current_mythos":    current_mythos,
		"mythos_index":      _mythos.index,
		"gates":       gates,
		"entities":    entities,
		"monsters":    monsters,
		"monster_bag": monster_bag,
		"monster_surge": monster_surge,
		"encounter_choices": encounter_choices,
		"campaign":    campaign,
		"campaign_pending": campaign_pending,
		"active":      active,
	})


func _emit_changed() -> void:
	state_changed.emit()


# Сборка свежей записи игрока — общий шаблон для старта партии и поздних
# подключений. Меняешь поле здесь — оно автоматом подхватится в обоих местах.
func _make_player_dict(
	uid: String,
	pname: String,
	investigator: String,
	location: String,
	hp_max: int,
	sanity_max: int,
) -> Dictionary:
	return {
		"user_id":        uid,
		"name":           pname,
		"investigator":   investigator,
		"location":       location,
		"connected":      true,
		"actions_left":   ACTIONS_PER_ROUND,
		"actions_used":   [],
		"encounter_done": false,
		"tickets":        0,
		"concentration":  0,
		"hp":             hp_max,
		"sanity":         sanity_max,
		"hp_max":         hp_max,
		"sanity_max":     sanity_max,
		"clues":          0,
		"conditions":     [],
		"items":          [],
		"skill_mods":     {},
	}


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
		players[uid] = _make_player_dict(
			uid,
			String(p.get("name", "???")),
			String(p.get("investigator", "")),
			start_loc,
			int(p.get("hp_max", 5)),
			int(p.get("sanity_max", 5)),
		)
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
		_campaign.start_generation(turn_order.size(), "")
	_setup_board(turn_order.size())   # стартовая раскладка: врата+монстры, улики, Наплыв
	_broadcast_sync()
	_emit_changed()
	phase_changed.emit(phase)


# ── Хост: обработка действия (своего или чужого через game_action) ──────────

## Применить действие. Если ты НЕ хост, отправит запрос хосту через relay.
func perform_action(action_type: String, payload: Dictionary = {}) -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_phase.host_apply_action(my_pid, action_type, payload)
	else:
		_nm.relay_all({
			"action": "game_action", "type": action_type,
			"pid": my_pid, "payload": payload,
		})


# ── Encounter (фасады) ────────────────────────────────────────────────────────

## Игрок отмечает «встреча завершена» — передаёт ход следующему / в Mythos.
func finish_encounter() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_phase.host_apply_finish_encounter(my_pid)
	else:
		_nm.relay_all({"action": "game_finish_encounter", "pid": my_pid})


## Активный игрок бросает проверку встречи. Хост катит и применяет эффекты.
func resolve_encounter() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_encounter.host_apply_resolve(my_pid)
	else:
		_nm.relay_all({"action": "game_resolve_encounter", "pid": my_pid})


## Активный игрок выбрал тип встречи (general/research/gate/combat). Хост
## генерирует встречу выбранного kind.
func choose_encounter(kind: String) -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_encounter.host_apply_choose(my_pid, kind)
	else:
		_nm.relay_all({"action": "game_choose_encounter", "pid": my_pid, "kind": kind})


## Активный игрок переходит к следующей стадии gate-встречи (после успеха).
func advance_encounter_stage() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_encounter.host_apply_advance_stage(my_pid)
	else:
		_nm.relay_all({"action": "game_advance_stage", "pid": my_pid})


# ── Travel (фасады) ───────────────────────────────────────────────────────────

## Переместиться в связанную локацию dest (расходует действие).
func travel(dest: String) -> void:
	perform_action("travel", { "to": dest })


## Может ли локальный игрок переместиться в dest прямо сейчас (для UI сайдбара).
## Дополнительно к чистой связности проверяет, что сейчас мой ход в action-фазе
## и не израсходован travel в этом раунде.
func can_travel_to(dest: String) -> bool:
	if not is_my_turn():
		return false
	var me: Dictionary = my_player()
	if int(me.get("actions_left", 0)) <= 0:
		return false
	var used: Array = me.get("actions_used", [])
	if used.has("travel"):
		return false
	return _phase.can_travel(_nm.my_user_id, dest)


# ── Mythos (фасад) ───────────────────────────────────────────────────────────

## Любой игрок подтверждает «Дальше» в модалке мифа. Делегат в MythosFlow.
func resolve_mythos() -> void:
	_mythos.resolve()


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
			_phase.advance_action_turn()
		elif phase == "encounter":
			_phase.advance_encounter_turn()

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
	players[uid] = _make_player_dict(
		uid,
		pname,
		investigator,
		String(inv.get("startingLocation", "")),
		hp_max,
		san_max,
	)
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
	current_mythos    = data.get("current_mythos",    {})
	_mythos.index     = int(data.get("mythos_index", 0))
	gates       = data.get("gates",       {})
	entities    = data.get("entities",    {})
	monsters    = data.get("monsters",    {})
	monster_bag = data.get("monster_bag", [])
	monster_surge = int(data.get("monster_surge", 0))
	encounter_choices = data.get("encounter_choices", [])
	campaign    = data.get("campaign",    {})
	campaign_pending = bool(data.get("campaign_pending", false))
	active      = bool(data.get("active",     false))
	_emit_changed()
	phase_changed.emit(phase)

	# Хост реджойнулся в фазу встреч, а карта в снапшоте — пустая (хост ушёл
	# в момент await api.generate_encounter, снапшот сохранился в loading-
	# состоянии). Без перезапуска генерации модалка зависнет на «загрузке».
	# call_deferred — чтобы не дёргать сеть из коллбэка снапшота.
	if _is_host() and active and phase == "encounter" and current_encounter.is_empty():
		GameConsole.log("[Game] Реджойн в фазу встреч с пустой картой — перегенерируем")
		_encounter.generate.call_deferred()

	# Реджойн хоста: колода Мифов — host-only, в снапшот не попадает. При
	# перезапуске процесса колода теряется → следующая вытяжка выпала бы в
	# заглушку. Тянем полную библию из relay-API по campaign.id и
	# восстанавливаем колоду; индекс уже подтянулся из snapshot выше.
	if _is_host() and active and _mythos.deck.is_empty() and not campaign.is_empty():
		var camp_id: String = String(campaign.get("id", ""))
		if not camp_id.is_empty():
			_mythos.restore_deck.call_deferred(camp_id)


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
				_phase.host_apply_action(pid, t, data.get("payload", {}))

		"game_finish_encounter":
			if _is_host():
				_phase.host_apply_finish_encounter(data.get("pid", ""))

		"game_resolve_encounter":
			if _is_host():
				_encounter.host_apply_resolve(data.get("pid", ""))

		"game_choose_encounter":
			if _is_host():
				_encounter.host_apply_choose(data.get("pid", ""), String(data.get("kind", "")))

		"game_advance_stage":
			if _is_host():
				_encounter.host_apply_advance_stage(data.get("pid", ""))

		"game_resolve_mythos":
			if _is_host():
				_mythos.resolve()

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


# ── Helpers, общие для подмодулей ─────────────────────────────────────────────

## Текущий язык игры названием для relay ("Russian" / "English"). Используется
## EncounterFlow и CampaignGen в теле запроса к ContentApi.
func _relay_language() -> String:
	if I18n.get_locale() == "en":
		return "English"
	return "Russian"


## Эффекты уровня поля (advanceDoom и т.п.) — интерпретатор их не трогает,
## применяются здесь, потому что меняют синкаемые поля GameState (doom,
## omens_step). Зовётся из EncounterFlow и MythosFlow.
func _apply_board_effect(node: Dictionary) -> void:
	var verb: String = String(node.get("do", ""))
	var n: int = int(node.get("amount", node.get("count", 1)))
	match verb:
		"advanceDoom":
			doom += n
			GameConsole.log("[Эффект] doom +%d" % n)
		"advanceOmen", "moveOmen":
			# На каждый шаг омена: сдвигаем, затем СРАЗУ считаем дум по вратам
			# нового цвета омена — ДО того как карта откроет новые врата, чтобы
			# только что открытые врата не влияли на дум этого сдвига.
			for _i: int in maxi(1, n):
				omens_step += 1
				resolve_omen_doom()
			GameConsole.log("[Эффект] омен +%d" % maxi(1, n))
		"openGate":
			for _i: int in n:
				_open_gate()
		"closeGate":
			_close_gate_at_active_player()
		"spawnMonster":
			for _i: int in n:
				_spawn_monster_from_gate()
		"placeClue":
			for _i: int in n:
				_place_clue()
		"placeRumor":
			for _i: int in n:
				_place_rumor()
		"monsterSurge":
			_monster_surge()
		_:
			GameConsole.log("[Эффект] %s — пока не поддержано движком" % verb)


# ── Цвета омена / врат ────────────────────────────────────────────────────────

## Порядок цветов омена. Цвет врат = знак омена; Наплыв бьёт по вратам цвета
## текущего омена. NB: соответствие шага омена цвету — заглушка по 3 цветам,
## уточнить под реальную дорожку оменов.
const OMEN_COLORS: Array = ["green", "blue", "red"]

## Цвет текущего омена (по omens_step).
func current_omen_color() -> String:
	return String(OMEN_COLORS[omens_step % OMEN_COLORS.size()])


## Сколько открытых врат заданного цвета. Для правила «омен сдвинулся → дум +
## врата нового цвета» и для Наплыва.
func _count_gates_of_color(color: String) -> int:
	var n: int = 0
	for lid_v: Variant in gates:
		if String(gates[lid_v]) == color:
			n += 1
	return n


## Дум от омена. Зовётся СРАЗУ при сдвиге омена (до открытия новых врат этой же
## картой): дум += число открытых врат текущего цвета омена. Возвращает прибавку.
func resolve_omen_doom() -> int:
	var color: String = current_omen_color()
	var matched: int = _count_gates_of_color(color)
	if matched > 0:
		doom += matched
		GameConsole.log("[Омен] цвет %s · врат: %d · doom +%d" % [color, matched, matched])
	return matched


# ── Стартовая раскладка кампании (Icon Reference) ─────────────────────────────

## Таблица Icon Reference (Набор A): по числу сыщиков — сколько врат открыть,
## улик разложить и значение Наплыва на старте.
const REFERENCE: Dictionary = {
	1: { "gates": 1, "clues": 2, "surge": 1 },
	2: { "gates": 1, "clues": 1, "surge": 1 },
	3: { "gates": 2, "clues": 2, "surge": 1 },
	4: { "gates": 2, "clues": 2, "surge": 1 },
	5: { "gates": 2, "clues": 3, "surge": 1 },
	6: { "gates": 3, "clues": 3, "surge": 1 },
	7: { "gates": 3, "clues": 4, "surge": 1 },
	8: { "gates": 3, "clues": 4, "surge": 1 },
}

func _reference_for(player_count: int) -> Dictionary:
	return REFERENCE.get(clampi(player_count, 1, 8), REFERENCE[1])


## Хост: начальная раскладка поля. Открыть врата (каждые → 1 монстр), разложить
## улики (≤1 на локацию), записать Наплыв. Зовётся из start_game до _broadcast_sync.
func _setup_board(player_count: int) -> void:
	if not _is_host():
		return
	gates = {}
	entities = {}
	monsters = {}
	# Наполняем «мешок» всеми не-эпическими монстрами (по одному id).
	monster_bag = []
	var pool: Array = MonsterCatalog.non_epic()
	for i: int in range(pool.size()):
		monster_bag.append(String(pool[i].get("id", "")))
	var ref: Dictionary = _reference_for(player_count)
	monster_surge = int(ref.get("surge", 1))
	for _i: int in int(ref.get("gates", 1)):
		_open_gate()
	for _i: int in int(ref.get("clues", 1)):
		_place_clue()
	GameConsole.log("[Старт] Раскладка: врат %d, улик %d, Наплыв %d (игроков %d)" % [
		int(ref.get("gates", 1)), int(ref.get("clues", 1)), monster_surge, player_count])


# ── Врата / монстры / улики (host-only мутации синкаемого state) ──────────────

## Открыть врата. loc_id пустой → случайная свободная локация; color пустой →
## по циклу цветов омена. Каждые новые врата выпускают 1 монстра.
func _open_gate(loc_id: String = "", color: String = "") -> void:
	if not _is_host():
		return
	var lid: String = loc_id
	if lid.is_empty():
		var candidates: Array = []
		var locations: Array = _load_locations()
		for i: int in range(locations.size()):
			var did: String = String(locations[i].get("id", ""))
			if not did.is_empty() and not gates.has(did):
				candidates.append(did)
		if candidates.is_empty():
			GameConsole.warn("[Врата] все локации уже с вратами")
			return
		lid = String(candidates[randi() % candidates.size()])
	var col: String = color
	if col.is_empty():
		col = String(OMEN_COLORS[gates.size() % OMEN_COLORS.size()])
	gates[lid] = col
	GameConsole.log("[Врата] открылись (%s) на %s" % [col, lid])
	_spawn_monster(lid)   # каждые новые врата → 1 монстр


## Закрыть врата на локации активного игрока (эффект closeGate финальной стадии
## gate-встречи). Врата привязаны к месту, где сыщик прошёл Иной мир.
func _close_gate_at_active_player() -> void:
	if not _is_host():
		return
	var pid: String = _current_pid()
	if pid.is_empty():
		return
	var loc: String = String(players.get(pid, {}).get("location", ""))
	if gates.has(loc):
		gates.erase(loc)
		GameConsole.log("[Врата] закрыты на %s" % loc)


## Заспаунить монстра на локации, ВЫТЯНУВ случайный id из «мешка» (без повторов).
## Экземпляр хранит здоровье ({id, health}); смерть вернёт id в мешок. Мешок
## пуст → спауна нет (как пустой котёл монстров в EH).
func _spawn_monster(loc_id: String) -> void:
	if not _is_host() or loc_id.is_empty():
		return
	if monster_bag.is_empty():
		GameConsole.warn("[Спаун] мешок монстров пуст — спаун пропущен")
		return
	var idx: int = randi() % monster_bag.size()
	var mid: String = String(monster_bag[idx])
	# Культистов много (повторяются) — не вынимаем из мешка; остальные уникальны.
	if mid != "cultist":
		monster_bag.remove_at(idx)
	var m: Dictionary = MonsterCatalog.by_id(mid)
	@warning_ignore("unsafe_method_access")
	var hp: int = maxi(1, MonsterCatalog.toughness_for(m, maxi(1, players.size())) if not m.is_empty() else 1)
	var arr: Array = monsters.get(loc_id, [])
	arr.append({ "id": mid, "health": hp })
	monsters[loc_id] = arr
	GameConsole.log("[Спаун] монстр %s (стойкость %d) на %s · в мешке %d" % [mid, hp, loc_id, monster_bag.size()])


## Вернуть монстра в «мешок» (после гибели/снятия с поля). Культист всегда в
## мешке (его не вынимали) — не дублируем.
func return_monster_to_bag(mid: String) -> void:
	if not _is_host() or mid.is_empty() or mid == "cultist":
		return
	monster_bag.append(mid)


## Монстр из мифа: спаун на случайных открытых вратах; если врат нет — открыть.
func _spawn_monster_from_gate() -> void:
	if not _is_host():
		return
	if gates.is_empty():
		_open_gate()
		return
	var keys: Array = gates.keys()
	_spawn_monster(String(keys[randi() % keys.size()]))


## Положить улику на случайную локацию без улики (≤1 улика на локацию).
func _place_clue() -> void:
	if not _is_host():
		return
	var candidates: Array = []
	var locations: Array = _load_locations()
	for i: int in range(locations.size()):
		var lid: String = String(locations[i].get("id", ""))
		if lid.is_empty():
			continue
		var arr: Array = entities.get(lid, [])
		if not (arr as Array).has("clue"):
			candidates.append(lid)
	if candidates.is_empty():
		return
	var pick: String = String(candidates[randi() % candidates.size()])
	var cell: Array = entities.get(pick, [])
	cell.append("clue")
	entities[pick] = cell
	GameConsole.log("[Улика] на %s" % pick)


## Положить слух на случайную локацию.
func _place_rumor() -> void:
	if not _is_host():
		return
	var locations: Array = _load_locations()
	if locations.is_empty():
		return
	var lid: String = String(locations[randi() % locations.size()].get("id", ""))
	if lid.is_empty():
		return
	var cell: Array = entities.get(lid, [])
	cell.append("rumor")
	entities[lid] = cell
	GameConsole.log("[Слух] на %s" % lid)


## Наплыв монстров: из каждых врат цвета текущего омена лезет monster_surge
## монстров; если таких врат нет — открываются одни новые врата (= 1 монстр).
func _monster_surge() -> void:
	if not _is_host():
		return
	var color: String = current_omen_color()
	var matched: Array = []
	for lid_v: Variant in gates:
		if String(gates[lid_v]) == color:
			matched.append(String(lid_v))
	if matched.is_empty():
		GameConsole.log("[Наплыв] нет врат цвета %s — открываются новые" % color)
		_open_gate()
		return
	for i: int in range(matched.size()):
		for _j: int in monster_surge:
			_spawn_monster(matched[i])
	GameConsole.log("[Наплыв] из %d врат (%s) по %d монстров" % [matched.size(), color, monster_surge])


# ── Сценарная библия (фасады в CampaignGen) ───────────────────────────────────

## Модалка создания комнаты задаёт «зерно» будущей кампании. Делегат.
func set_campaign_seed(ancient_one: String, player_count: int) -> void:
	_campaign.set_seed(ancient_one, player_count)


## Хост: прогрев библии в лобби. Делегат.
func prewarm_campaign() -> void:
	_campaign.prewarm()


## Мистерия текущего акта ({} если кампания/тайны ещё не готовы) — для UI.
func current_mystery() -> Dictionary:
	return _campaign.current_mystery()


## Хост: сброс перед новой игрой. Зовётся из lobby при входе в свежее лобби —
## чтобы prewarm следующей игры не наткнулся на библию предыдущей и зависшую
## генерацию. Чистит собственный state GameState; campaign и мифос — через
## модули (там живут их «приватные» поля типа epoch/seed).
func reset_pregame() -> void:
	if not _is_host():
		return
	_campaign.reset()
	current_encounter = {}
	current_mythos    = {}
	_mythos.deck      = []
	_mythos.index     = 0
	gates             = {}
	entities          = {}
	monsters          = {}
	monster_bag       = []
	monster_surge     = 0
	encounter_choices = []
	active            = false


# ── Helpers для подмодулей ───────────────────────────────────────────────────

## Лениво загружает data/locations.json и кэширует. Используется travel-flow
## (проверка связности, имя/тип в запросе встречи) и CampaignGen (список
## локаций в запросе библии).
func _load_locations() -> Array:
	if _locations_cache.is_empty():
		_locations_cache = DataLoader.load_array("res://data/locations.json")
	return _locations_cache
