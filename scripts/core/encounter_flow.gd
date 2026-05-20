class_name EncounterFlow
extends RefCounted

## Хост-only: генерация карт встреч через ContentApi (с префетчем фоном),
## бросок проверки активного игрока, применение onSuccess/onFailure эффектов.
##
## GameState владеет полем current_encounter (синкается всем), фазами и
## turn-flow; EncounterFlow владеет host-only префетч-кэшем и логикой
## взаимодействия с ContentApi. Запись в _gs.current_encounter — напрямую
## из модуля: при успехе результат обязан попасть в синк.

const _EffectRunner = preload("res://scripts/core/effect_runner.gd")

var _gs: Node

# Префетч карт встречи — host-only. Как только игрок исчерпал свои действия,
# запускаем фоновую генерацию его встречи; к моменту его очереди в фазе
# encounter карта уже готова и применяется без ожидания. Не синкается; при
# реджойне хоста — fallback на обычную live-генерацию.
var _prefetched: Dictionary = {}    # uid -> card
var _in_flight:  Dictionary = {}    # uid -> bool


func _init(gs: Node) -> void:
	_gs = gs


# ── Public API (host-only) ───────────────────────────────────────────────────

## Хост: сгенерировать карту встречи для игрока, чей сейчас ход на встречу,
## и разослать её. Сначала смотрит в префетч — карта могла быть подготовлена
## фоном ещё в action-фазе; тогда показываем мгновенно. Иначе ждём префетч,
## если он в полёте, либо запускаем live. Корутина: вызывается без await
## (fire-and-forget) из encounter-флоу.
func generate() -> void:
	if not _gs._is_host():
		return
	var pid: String = _gs._current_pid()
	if pid.is_empty() or not _gs.players.has(pid):
		return

	# Префетч уже готов — применяем мгновенно.
	if _prefetched.has(pid):
		_gs.current_encounter = _prefetched[pid]
		_prefetched.erase(pid)
		GameConsole.log("[Game] Встреча для %s взята из префетча: %s" % [
			_gs._name_of(pid), String(_gs.current_encounter.get("name", ""))
		])
		_gs._broadcast_sync()
		_gs._emit_changed()
		return

	_gs.current_encounter = {}        # состояние «загрузка»
	_gs._broadcast_sync()
	_gs._emit_changed()

	# Префетч ещё идёт — карту поставит его completion-handler, новой
	# генерации не запускаем.
	if _in_flight.get(pid, false):
		GameConsole.log("[Game] Ждём префетч встречи для %s..." % _gs._name_of(pid))
		return

	var api: Node = _gs.get_node_or_null("/root/ContentApi")
	if api == null:
		GameConsole.warn("[Game] ContentApi недоступен — ставим встречу-заглушку")
		_gs.current_encounter = _fallback_card()
		_gs._broadcast_sync()
		_gs._emit_changed()
		return

	var req: Dictionary = _build_request(_gs.players[pid])
	# Захватываем раунд — после долгого await тот же игрок может оказаться
	# уже в новом раунде с новой встречей, и старый ответ нельзя писать.
	var captured_round: int = _gs.round_num
	GameConsole.log("[Game] Генерация встречи для %s..." % _gs._name_of(pid))
	@warning_ignore("unsafe_method_access")
	var res: Dictionary = await api.generate_encounter(req)

	# Проверяем, что за время await ничего не сменилось: фаза, активный
	# игрок и раунд. Старый ответ — в мусор.
	if _gs.phase != "encounter" or _gs._current_pid() != pid or _gs.round_num != captured_round:
		return

	var encs: Array = res.get("encounters", [])
	if bool(res.get("ok", false)) and not encs.is_empty():
		_gs.current_encounter = encs[0]
		GameConsole.log("[Game] Встреча готова: %s" % String(_gs.current_encounter.get("name", "")))
	else:
		_gs.current_encounter = _fallback_card()
		GameConsole.warn("[Game] Генерация встречи не удалась: %s" % String(res.get("error", "")))
	_gs._broadcast_sync()
	_gs._emit_changed()


## Хост: фоновая генерация карты встречи для игрока, который только что
## исчерпал свои действия. Карта прячется в префетч-кэше до начала его
## encounter-очереди. Идемпотентно: повторные вызовы для того же pid
## пропускаются (карта уже есть или ещё в полёте).
func prefetch(pid: String) -> void:
	if not _gs._is_host() or pid.is_empty() or not _gs.players.has(pid):
		return
	if _prefetched.has(pid) or _in_flight.get(pid, false):
		return
	var api: Node = _gs.get_node_or_null("/root/ContentApi")
	if api == null:
		return

	_in_flight[pid] = true
	var req: Dictionary = _build_request(_gs.players[pid])
	# Запомнить раунд — между запуском префетча и его resolve может пройти
	# целый action-phase + encounter-phase + mythos + новый раунд; в этом
	# случае стейт игрока (location/conditions) уже не тот, и карту
	# применять/класть нельзя.
	var captured_round: int = _gs.round_num
	GameConsole.log("[Game] Префетч встречи для %s..." % _gs._name_of(pid))
	@warning_ignore("unsafe_method_access")
	var res: Dictionary = await api.generate_encounter(req)
	_in_flight.erase(pid)

	# Раунд сменился — результат устарел.
	if _gs.round_num != captured_round:
		GameConsole.log("[Game] Префетч для %s устарел (раунд сменился) — отбрасываем" % _gs._name_of(pid))
		return

	var encs: Array = res.get("encounters", [])
	if not bool(res.get("ok", false)) or encs.is_empty():
		GameConsole.warn("[Game] Префетч для %s не удался: %s" % [
			_gs._name_of(pid), String(res.get("error", ""))
		])
		return
	var card: Dictionary = encs[0]

	# Если уже стоит очередь этого игрока на encounter, а карта пустая
	# (loading) — показываем её сразу, без отдельного generate-цикла.
	# Иначе припрятываем до начала его encounter-хода.
	if _gs.phase == "encounter" and _gs._current_pid() == pid and _gs.current_encounter.is_empty():
		_gs.current_encounter = card
		GameConsole.log("[Game] Префетч готов и применён: %s" % String(card.get("name", "")))
		_gs._broadcast_sync()
		_gs._emit_changed()
	else:
		_prefetched[pid] = card
		GameConsole.log("[Game] Префетч готов: %s" % String(card.get("name", "")))


## Хост: разрешить встречу активного игрока — катит проверку, применяет
## onSuccess/onFailure, кладёт результат в current_encounter.resolution и
## рассылает синком. Зовётся из GameState.resolve_encounter (фасад) или
## напрямую из relay-router при game_resolve_encounter.
func host_apply_resolve(pid: String) -> bool:
	if _gs.phase != "encounter" or not _gs.players.has(pid):
		return false
	if _gs._current_pid() != pid:
		return false
	if _gs.current_encounter.is_empty() or _gs.current_encounter.has("resolution"):
		return false   # карта ещё генерится либо уже разрешена

	var roll: Dictionary = _roll_check(pid)
	var branch: Array = _gs.current_encounter.get(
		"onSuccess" if roll["passed"] else "onFailure", []
	)
	_apply_effects(branch, pid)

	_gs.current_encounter["resolution"] = roll
	GameConsole.log("[Game] %s · встреча %s · успехов: %d" % [
		_gs._name_of(pid),
		"пройдена" if roll["passed"] else "провалена",
		int(roll["successes"]),
	])
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


## Чистит префетч (вызывается из _start_new_round и reset_pregame в GameState).
func clear_prefetch() -> void:
	_prefetched.clear()
	_in_flight.clear()


# ── Сборка запроса и фолбэк ──────────────────────────────────────────────────

# Тело запроса /encounters/generate для игрока.
func _build_request(p: Dictionary) -> Dictionary:
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
		"language":     _gs._relay_language(),
	}
	# Библия готова — встреча несёт контекст кампании (Древний, акт, doom).
	var cid: String = String(_gs.campaign.get("id", ""))
	if not cid.is_empty():
		req["campaignId"] = cid
		req["act"]        = _gs._campaign.current_act()
		req["doom"]       = _gs.doom
	return req


# Реальное (локализованное) имя и тип локации по её id из locations.json.
func _location_info(loc_name: String) -> Dictionary:
	var locations: Array = _gs._load_locations()
	for i in range(locations.size()):
		var loc: Dictionary = locations[i]
		if String(loc.get("name", "")) == loc_name:
			return {
				"name": tr(String(loc.get("realWorldLocation", loc_name))),
				"type": String(loc.get("type", "city")),
			}
	return { "name": loc_name, "type": "city" }


# Запасная карта на случай сбоя генерации — игра не должна вставать.
func _fallback_card() -> Dictionary:
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


# ── Бросок и эффекты ─────────────────────────────────────────────────────────

# Бросок основной проверки: пул d6 = навык сыщика + модификаторы навыка +
# модификатор карты, успех на 5–6, пройдено при хотя бы одном успехе.
func _roll_check(pid: String) -> Dictionary:
	var p: Dictionary = _gs.players.get(pid, {})
	var test: Dictionary = _gs.current_encounter.get("test", {})
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


# Применяет программу эффектов: интерпретатор — игроку, эффекты поля — через
# _gs._apply_board_effect (общая точка с MythosFlow).
func _apply_effects(effects: Array, pid: String) -> void:
	if effects.is_empty() or not _gs.players.has(pid):
		return
	var res: Dictionary = _EffectRunner.run(effects, _gs.players[pid])
	var board: Array = res.get("board", [])
	for i in range(board.size()):
		var node: Dictionary = board[i]
		_gs._apply_board_effect(node)
	var logs: Array = res.get("logs", [])
	for i in range(logs.size()):
		GameConsole.log("[Эффект] %s" % String(logs[i]))
