class_name EncounterFlow
extends RefCounted

## Хост-only: генерация карт встреч через ContentApi (live, по выбору игрока),
## бросок проверки активного игрока, применение onSuccess/onFailure эффектов.
##
## GameState владеет полем current_encounter (синкается всем), фазами и
## turn-flow; EncounterFlow — логикой взаимодействия с ContentApi. Запись в
## _gs.current_encounter — напрямую из модуля: результат обязан попасть в синк.

const _EffectRunner = preload("res://scripts/core/effect_runner.gd")

var _gs: Node

# Токен генерации: каждый новый generate() инкрементит его. После await писать
# current_encounter может только тот вызов, чей токен всё ещё актуален —
# любой более ранний (перекрытый) ответ отбрасывается. Убивает гонку, даже
# если два generate() как-то перекрылись.
var _gen_token: int = 0


func _init(gs: Node) -> void:
	_gs = gs


# ── Public API (host-only) ───────────────────────────────────────────────────

## Хост: сгенерировать карту встречи (kind) для игрока, чей сейчас ход на
## встречу, и разослать её. Корутина: вызывается без await (fire-and-forget)
## из encounter-флоу.
func generate(kind: String = "general") -> void:
	if not _gs._is_host():
		return
	var pid: String = _gs._current_pid()
	if pid.is_empty() or not _gs.players.has(pid):
		return

	# Новый токен — инвалидирует любой предыдущий generate(), ещё висящий в await.
	_gen_token += 1
	var token: int = _gen_token

	_gs.current_encounter = {}        # состояние «загрузка»
	_gs._broadcast_sync()
	_gs._emit_changed()

	var api: Node = _gs.get_node_or_null("/root/ContentApi")
	if api == null:
		GameConsole.warn("[Game] ContentApi недоступен — ставим встречу-заглушку")
		if token == _gen_token:
			_gs.current_encounter = _fallback_card()
			_gs._broadcast_sync()
			_gs._emit_changed()
		return

	var req: Dictionary = _build_request(_gs.players[pid], kind)
	# Захватываем раунд — после долгого await тот же игрок может оказаться
	# уже в новом раунде с новой встречей, и старый ответ нельзя писать.
	var captured_round: int = _gs.round_num
	GameConsole.log("[Game] Генерация встречи для %s..." % _gs._name_of(pid))
	@warning_ignore("unsafe_method_access")
	var res: Dictionary = await api.generate_encounter(req)

	# Перекрыт более новым generate() — этот ответ устарел, выбрасываем.
	if token != _gen_token:
		return
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


## Хост: начать ход встречи активного игрока. Считает доступные типы встречи
## по содержимому его клетки. Если выбор есть (>1) — выставляет encounter_choices
## и ждёт выбора игрока; иначе сразу генерирует единственную (general).
func begin_turn() -> void:
	if not _gs._is_host():
		return
	var pid: String = _gs._current_pid()
	if pid.is_empty() or not _gs.players.has(pid):
		return
	var choices: Array = _compute_choices(pid)
	if choices.size() <= 1:
		_gs.encounter_choices = []
		generate("general")
	else:
		_gs.encounter_choices = choices
		_gs.current_encounter = {}
		GameConsole.log("[Game] %s выбирает тип встречи: %s" % [_gs._name_of(pid), str(choices)])
		_gs._broadcast_sync()
		_gs._emit_changed()


## Хост: игрок выбрал тип встречи — генерируем её. combat (бой) — пока заглушка.
func host_apply_choose(pid: String, kind: String) -> bool:
	if _gs.phase != "encounter" or _gs._current_pid() != pid:
		return false
	if (_gs.encounter_choices as Array).is_empty() or not (_gs.encounter_choices as Array).has(kind):
		return false
	_gs.encounter_choices = []
	GameConsole.log("[Game] %s выбрал встречу: %s" % [_gs._name_of(pid), kind])
	if kind == "combat":
		_begin_combat(pid)
	else:
		generate(kind)
	return true


# ── Бой (локально, по статам монстра из MonsterCatalog) ───────────────────────

# Хост: собрать боевую «карту» по первому монстру на локации игрока.
func _begin_combat(pid: String) -> void:
	if not _gs._is_host():
		return
	var loc: String = String(_gs.players[pid].get("location", ""))
	var mons: Array = _gs.monsters.get(loc, [])
	if (mons as Array).is_empty():
		generate("general")   # монстра нет — обычная встреча (страховка)
		return
	# Экземпляр может быть {id, health} (новый формат) или просто id-строкой
	# (легаси из старой сессии) — читаем устойчиво.
	var inst_v: Variant = mons[0]   # сражаемся с первым монстром локации
	var mid: String = String(inst_v.get("id", "")) if inst_v is Dictionary else String(inst_v)
	var inst_health: int = int((inst_v as Dictionary).get("health", -1)) if inst_v is Dictionary else -1
	var m: Dictionary = MonsterCatalog.by_id(mid)
	if m.is_empty():
		generate("general")
		return
	var inv_count: int = maxi(1, _gs.players.size())
	@warning_ignore("unsafe_method_access")
	var tough: int = MonsterCatalog.toughness_for(m, inv_count)
	var cur: int = inst_health if inst_health >= 0 else tough   # легаси/без health → полное
	var ability: Dictionary = m.get("ability", {})
	_gs.current_encounter = {
		"kind":        "combat",
		"monsterId":   mid,
		"monsterName": String(m.get("nameKey", mid)),
		"abilityKey":  String(ability.get("textKey", "")),
		"combat":      m.get("combat", {}),
		"horror":      m.get("horror", {}),
		"toughness":   tough,   # изначальная стойкость (для шкалы)
		"health":      cur,     # текущее здоровье экземпляра
	}
	GameConsole.log("[Бой] %s vs %s (здоровье %d/%d)" % [_gs._name_of(pid), mid, cur, tough])
	_gs._broadcast_sync()
	_gs._emit_changed()


# Хост: бой в ДВА отдельных броска (одна кнопка — один шаг). Раундов/отступления нет.
#   Шаг 1 — ВОЛЯ (ужас): успехи блокируют урон по рассудку (max(0, horror.damage − успехи)).
#   Шаг 2 — СИЛА (атака): успехи и снижают урон по сыщику (max(0, combat.damage − успехи)),
#           и наносят столько же урона монстру. Здоровье монстра сохраняется
#           между боями; при 0 — монстр повержен и снят с локации.
func _resolve_combat(pid: String) -> bool:
	var enc: Dictionary = _gs.current_encounter
	if enc.has("resolution"):
		return false
	var p: Dictionary = _gs.players[pid]

	# ── Шаг 1: бросок ВОЛИ (если ещё не катали) ──
	if not enc.has("will"):
		var h: Dictionary = enc.get("horror", {})
		var w_roll: Dictionary = _roll_check(pid, { "skill": h.get("skill", "will"), "modifier": int(h.get("modificator", 0)) })
		var sanity_loss: int = maxi(0, int(h.get("damage", 0)) - int(w_roll["successes"]))
		if sanity_loss > 0:
			p["sanity"] = maxi(0, int(p.get("sanity", 0)) - sanity_loss)
		enc["will"] = w_roll
		enc["sanity_loss"] = sanity_loss
		GameConsole.log("[Бой] %s · Воля %d · рассудок −%d" % [_gs._name_of(pid), int(w_roll["successes"]), sanity_loss])
		_gs._broadcast_sync()
		_gs._emit_changed()
		return true

	# ── Шаг 2: бросок СИЛЫ (атака) ──
	var c: Dictionary = enc.get("combat", {})
	var s_roll: Dictionary = _roll_check(pid, { "skill": c.get("skill", "strength"), "modifier": int(c.get("modificator", 0)) })
	var hits: int = int(s_roll["successes"])
	var health_before: int = int(enc.get("health", 0))
	var health_after: int = maxi(0, health_before - hits)
	var won: bool = health_after <= 0
	var hp_loss: int = maxi(0, int(c.get("damage", 0)) - hits)
	if hp_loss > 0:
		p["hp"] = maxi(0, int(p.get("hp", 0)) - hp_loss)

	var loc: String = String(p.get("location", ""))
	if won:
		_remove_monster_instance(loc, 0)
		_gs.return_monster_to_bag(String(enc.get("monsterId", "")))   # монстр умер → обратно в мешок
	else:
		_set_monster_health(loc, 0, health_after)

	enc["health"] = health_after
	enc["resolution"] = {
		"won":          won,
		"strength":     s_roll,
		"hp_loss":      hp_loss,
		"dealt":        hits,
		"health_after": health_after,
	}
	GameConsole.log("[Бой] %s · %s (атака %d, монстр %d→%d, здоровье −%d)" % [
		_gs._name_of(pid), "повержен" if won else "выжил",
		hits, health_before, health_after, hp_loss,
	])
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# Снять экземпляр монстра по индексу с локации (синкаемое monsters).
func _remove_monster_instance(loc_id: String, idx: int) -> void:
	if loc_id.is_empty() or not _gs.monsters.has(loc_id):
		return
	var arr: Array = _gs.monsters[loc_id]
	if idx < 0 or idx >= arr.size():
		return
	arr.remove_at(idx)
	if (arr as Array).is_empty():
		_gs.monsters.erase(loc_id)
	else:
		_gs.monsters[loc_id] = arr


# Записать текущее здоровье экземпляра монстра (idx) на локации. Легаси-строку
# (старый формат) попутно нормализуем в {id, health}.
func _set_monster_health(loc_id: String, idx: int, health: int) -> void:
	if loc_id.is_empty() or not _gs.monsters.has(loc_id):
		return
	var arr: Array = _gs.monsters[loc_id]
	if idx < 0 or idx >= arr.size():
		return
	var inst_v: Variant = arr[idx]
	var inst: Dictionary = inst_v if inst_v is Dictionary else { "id": String(inst_v) }
	inst["health"] = health
	arr[idx] = inst
	_gs.monsters[loc_id] = arr


# Доступные типы встречи по содержимому клетки игрока. general — всегда;
# combat — если есть монстр; research — если есть улика; gate — если врата.
func _compute_choices(pid: String) -> Array:
	var loc: String = String(_gs.players[pid].get("location", ""))
	var out: Array = ["general"]
	var mons: Array = _gs.monsters.get(loc, [])
	if not (mons as Array).is_empty():
		out.append("combat")
	var ents: Array = _gs.entities.get(loc, [])
	if (ents as Array).has("clue"):
		out.append("research")
	if _gs.gates.has(loc):
		out.append("gate")
	return out


## Хост: разрешить встречу активного игрока — катит проверку, применяет
## onSuccess/onFailure, кладёт результат в current_encounter.resolution и
## рассылает синком. Зовётся из GameState.resolve_encounter (фасад) или
## напрямую из relay-router при game_resolve_encounter.
func host_apply_resolve(pid: String) -> bool:
	if _gs.phase != "encounter" or not _gs.players.has(pid):
		return false
	if _gs._current_pid() != pid:
		return false
	if _gs.current_encounter.is_empty():
		return false   # карта ещё генерится

	var enc_kind: String = String(_gs.current_encounter.get("kind", ""))
	# gate — двухстадийная встреча Иного мира; combat — локальный бой по раундам.
	if enc_kind == "gate":
		return _resolve_gate_stage(pid)
	if enc_kind == "combat":
		return _resolve_combat(pid)

	if _gs.current_encounter.has("resolution"):
		return false   # уже разрешена

	var roll: Dictionary = _roll_check(pid, _gs.current_encounter.get("test", {}))
	var branch: Array = _gs.current_encounter.get(
		"onSuccess" if roll["passed"] else "onFailure", []
	)
	var clues_before: int = int(_gs.players[pid].get("clues", 0))
	_apply_effects(branch, pid)
	var clues_gained: int = int(_gs.players[pid].get("clues", 0)) - clues_before

	# Исследование: забранная улика исчезает с локации игрока.
	if clues_gained > 0 and String(_gs.current_encounter.get("kind", "")) == "research":
		_remove_clues_at(String(_gs.players[pid].get("location", "")), clues_gained)

	_gs.current_encounter["resolution"] = roll
	GameConsole.log("[Game] %s · встреча %s · успехов: %d" % [
		_gs._name_of(pid),
		"пройдена" if roll["passed"] else "провалена",
		int(roll["successes"]),
	])
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# Резолв текущей стадии gate-встречи. Катит проверку стадии, применяет её
# onSuccess/onFailure, кладёт результат в current_encounter.stage_resolution.
# Переход на следующую стадию — отдельным действием (host_apply_advance_stage).
func _resolve_gate_stage(pid: String) -> bool:
	var stages: Array = _gs.current_encounter.get("stages", [])
	var stage: int = int(_gs.current_encounter.get("stage", 0))
	if stage < 0 or stage >= stages.size():
		return false
	if _gs.current_encounter.has("stage_resolution"):
		return false   # текущая стадия уже разрешена — ждём «Дальше»/«Завершить»
	var st: Dictionary = stages[stage]
	var roll: Dictionary = _roll_check(pid, st.get("test", {}))
	var branch: Array = st.get("onSuccess" if roll["passed"] else "onFailure", [])
	_apply_effects(branch, pid)
	_gs.current_encounter["stage_resolution"] = roll
	GameConsole.log("[Game] %s · врата, стадия %d %s · успехов: %d" % [
		_gs._name_of(pid), stage + 1,
		"пройдена" if roll["passed"] else "провалена", int(roll["successes"]),
	])
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


## Хост: перейти к следующей стадии gate-встречи (после успешной нефинальной
## стадии). Зовётся из GameState.advance_encounter_stage / relay-router.
func host_apply_advance_stage(pid: String) -> bool:
	if _gs.phase != "encounter" or _gs._current_pid() != pid:
		return false
	if String(_gs.current_encounter.get("kind", "")) != "gate":
		return false
	var res: Dictionary = _gs.current_encounter.get("stage_resolution", {})
	if not bool(res.get("passed", false)):
		return false   # перейти можно только после успеха
	var stages: Array = _gs.current_encounter.get("stages", [])
	var stage: int = int(_gs.current_encounter.get("stage", 0))
	if stage + 1 >= stages.size():
		return false   # это была последняя стадия — переходить некуда
	_gs.current_encounter["stage"] = stage + 1
	_gs.current_encounter.erase("stage_resolution")
	GameConsole.log("[Game] %s · врата, стадия → %d" % [_gs._name_of(pid), stage + 2])
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# Снимает до n улик ("clue") с локации (синкаемое entities). Зовётся, когда
# улику забрали в research-встрече.
func _remove_clues_at(loc_id: String, n: int) -> void:
	if loc_id.is_empty() or not _gs.entities.has(loc_id):
		return
	var arr: Array = _gs.entities[loc_id]
	var removed: int = 0
	while removed < n and (arr as Array).has("clue"):
		arr.erase("clue")
		removed += 1
	if (arr as Array).is_empty():
		_gs.entities.erase(loc_id)
	else:
		_gs.entities[loc_id] = arr
	if removed > 0:
		GameConsole.log("[Улика] забрана с %s (×%d)" % [loc_id, removed])


# ── Сборка запроса и фолбэк ──────────────────────────────────────────────────

# Тело запроса /encounters/generate для игрока (kind ∈ general/research/gate).
func _build_request(p: Dictionary, kind: String = "general") -> Dictionary:
	var inv_id: String  = String(p.get("investigator", ""))
	var inv: Dictionary = Investigators.get_data(inv_id)
	var inv_name: String   = tr(String(inv.get("displayName", inv_id)))
	var background: String = tr(String(inv.get("occupation", "")))
	if background.is_empty():
		background = tr("ENCOUNTER_DEFAULT_BG")
	# Трекинга позиции сыщика ещё нет — берём его стартовую локацию.
	var loc: Dictionary = _location_info(String(p.get("location", "Arkham")))
	# В LLM отдаём игровое имя ("Аркхэм") как основное, а реальный прообраз
	# ("Уэнэм, Массачусетс, США") — отдельным flavor-полем для контекста модели.
	var real_loc: Dictionary = {
		"name":         loc["name"],
		"locationType": loc["type"],
	}
	if not String(loc.get("flavor", "")).is_empty():
		real_loc["flavor"] = loc["flavor"]
	var req: Dictionary = {
		"kind":         kind,
		"investigator": { "name": inv_name, "background": background },
		"realLocation": real_loc,
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


# Локализованное игровое имя ("Аркхэм") + реальный прообраз ("Уэнэм, Массачусетс")
# по id локации. Матч по `id`, а не `name` — name теперь translation key.
func _location_info(loc_id: String) -> Dictionary:
	var locations: Array = _gs._load_locations()
	for i in range(locations.size()):
		var loc: Dictionary = locations[i]
		if String(loc.get("id", "")) == loc_id:
			return {
				"name":   tr(String(loc.get("name", loc_id))),
				"flavor": tr(String(loc.get("realWorldLocation", ""))),
				"type":   String(loc.get("type", "city")),
			}
	return { "name": loc_id, "flavor": "", "type": "city" }


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

# Бросок проверки: пул d6 = навык сыщика + модификаторы навыка + модификатор
# карты, успех на 5–6, пройдено при хотя бы одном успехе. test — словарь
# {skill, modifier} текущей проверки (плоская встреча или стадия gate).
func _roll_check(pid: String, test: Dictionary) -> Dictionary:
	var p: Dictionary = _gs.players.get(pid, {})
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
