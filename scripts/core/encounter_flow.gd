class_name EncounterFlow
extends RefCounted

## Хост-only: генерация карт встреч через ContentApi (live, по выбору игрока),
## бросок проверки активного игрока, применение onSuccess/onFailure эффектов.
##
## GameState владеет полем current_encounter (синкается всем), фазами и
## turn-flow; EncounterFlow — логикой взаимодействия с ContentApi. Запись в
## _gs.current_encounter — напрямую из модуля: результат обязан попасть в синк.

const _EffectRunner = preload("res://scripts/core/effect_runner.gd")

# Шанс, что бонус локации (rewardAffinity) сработает на успехе встречи (Вариант A).
const _LOC_BONUS_CHANCE := 0.5
const _SKILLS := ["lore", "influence", "observation", "strength", "will"]

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

	_gs.current_encounter = {}  # состояние «загрузка»
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


## Хост: начать ход встречи активного игрока. Если на клетке есть монстры —
## БОЙ обязателен и первым (без выбора); монстры отыгрываются последовательно
## (см. continue_encounter_turn). Когда монстров нет — обычный выбор/генерация
## не-боевой встречи.
func begin_turn() -> void:
	if not _gs._is_host():
		return
	var pid: String = _gs._current_pid()
	if pid.is_empty() or not _gs.players.has(pid):
		return
	var loc: String = String(_gs.players[pid].get("location", ""))
	if not (_gs.monsters.get(loc, []) as Array).is_empty():
		# Монстры на клетке — встреча с монстром всегда первой.
		_gs.encounter_choices = []
		_begin_combat(pid)
		return
	_begin_noncombat(pid)


## Не-боевая встреча: выбор типа (без combat) по содержимому клетки. Один вариант
## → генерим сразу; несколько → выставляем encounter_choices и ждём выбора.
func _begin_noncombat(pid: String) -> void:
	var choices: Array = _compute_choices(pid)
	choices.erase("combat")  # бой отыгрывается отдельно, не как выбор
	if choices.size() <= 1:
		_gs.encounter_choices = []
		generate(String(choices[0]) if not choices.is_empty() else "general")
	else:
		_gs.encounter_choices = choices
		_gs.current_encounter = {}
		GameConsole.log("[Game] %s выбирает тип встречи: %s" % [_gs._name_of(pid), str(choices)])
		_gs._broadcast_sync()
		_gs._emit_changed()


## Хост: после завершения встречи решает — продолжить ход того же игрока или
## передать дальше. Возвращает true, если ход ПРОДОЛЖАЕТСЯ (настроил следующую
## под-встречу): монстр повержен и остались ещё монстры → следующий бой; все
## монстры повержены → выбор не-боевой встречи. False → ход завершается
## (монстр выжил, либо не-боевая встреча отыграна). Зовётся из
## PhaseController.host_apply_finish_encounter ПОСЛЕ _commit_outcome.
func continue_encounter_turn(pid: String) -> bool:
	if not _gs.players.has(pid):
		return false
	var enc: Dictionary = _gs.current_encounter
	if String(enc.get("kind", "")) != "combat":
		return false  # не-боевая встреча отыграна — ход дальше
	# Монстр выжил (не повержен) — ход сыщика заканчивается, монстр остаётся.
	if not bool((enc.get("resolution", {}) as Dictionary).get("won", false)):
		return false
	# Монстр повержен (снят в _commit_combat). Ещё монстры на клетке?
	var loc: String = String(_gs.players[pid].get("location", ""))
	if not (_gs.monsters.get(loc, []) as Array).is_empty():
		_begin_combat(pid)  # следующий монстр — тот же игрок
		return true
	# Все монстры повержены — теперь выбор не-боевой встречи.
	_begin_noncombat(pid)
	return true


## Хост: игрок выбрал тип встречи — генерируем её. combat (бой) — пока заглушка.
func host_apply_choose(pid: String, kind: String) -> bool:
	if _gs.phase != "encounter" or _gs._current_pid() != pid:
		return false
	if (
		(_gs.encounter_choices as Array).is_empty()
		or not (_gs.encounter_choices as Array).has(kind)
	):
		return false
	_gs.encounter_choices = []
	GameConsole.log("[Game] %s выбрал встречу: %s" % [_gs._name_of(pid), kind])
	if kind == "combat":
		_begin_combat(pid)
	elif kind == "eldritch":
		_begin_eldritch_move(pid)
	else:
		generate(kind)
	return true


# Хост: собрать локальную карту bind-хода (без relay) из применимого хука набора.
# Проверка/стоимость/эффект берутся из данных хука (data.progress). На успехе
# (_commit_eldritch) списывается cost и применяется effect (жетон на карту Тайны);
# для Азатота заодно снимается board-жетон с клетки. Тексты локализуем сразу.
func _begin_eldritch_move(pid: String) -> void:
	if not _gs._is_host():
		return
	var loc: String = String(_gs.players[pid].get("location", ""))
	# Применимый encounter-хук набора (cost/test/effect — из данных карточки).
	var hook: Dictionary = _gs.mystery_encounter_hook(loc, pid)
	if hook.is_empty():
		generate("general")  # хук уже неприменим (страховка)
		return
	# Проверка — из хука; нет test → по умолчанию Знание.
	var test: Dictionary = hook.get("test", {"skill": "lore", "modifier": 0})
	_gs.current_encounter = {
		"kind": "eldritch",
		"name": _gs.tr("ENCOUNTER_ELDRITCH_NAME"),
		"mainText": _gs.tr("ENCOUNTER_ELDRITCH_BODY"),
		"test": test,
		"successText": _gs.tr("ENCOUNTER_ELDRITCH_SUCCESS"),
		"failureText": _gs.tr("ENCOUNTER_ELDRITCH_FAILURE"),
		"eldritch_loc": loc,
		"hook": hook,
	}
	GameConsole.log("[Знамение] %s изучает место, чтобы связать его с Тайной" % _gs._name_of(pid))
	_gs._broadcast_sync()
	_gs._emit_changed()


# ── Бой (локально, по статам монстра из MonsterCatalog) ───────────────────────


# Хост: собрать боевую «карту» по первому монстру на локации игрока.
func _begin_combat(pid: String) -> void:
	if not _gs._is_host():
		return
	var loc: String = String(_gs.players[pid].get("location", ""))
	var mons: Array = _gs.monsters.get(loc, [])
	if (mons as Array).is_empty():
		generate("general")  # монстра нет — обычная встреча (страховка)
		return
	# Экземпляр может быть {id, health} (новый формат) или просто id-строкой
	# (легаси из старой сессии) — читаем устойчиво.
	var inst_v: Variant = mons[0]  # сражаемся с первым монстром локации
	var mid: String = String(inst_v.get("id", "")) if inst_v is Dictionary else String(inst_v)
	var inst_health: int = (
		int((inst_v as Dictionary).get("health", -1)) if inst_v is Dictionary else -1
	)
	var m: Dictionary = MonsterCatalog.by_id(mid)
	if m.is_empty():
		generate("general")
		return
	var inv_count: int = maxi(1, _gs.players.size())
	@warning_ignore("unsafe_method_access")
	var tough: int = MonsterCatalog.toughness_for(m, inv_count)
	var cur: int = inst_health if inst_health >= 0 else tough  # легаси/без health → полное
	var ability: Dictionary = m.get("ability", {})
	_gs.current_encounter = {
		"kind": "combat",
		"monsterId": mid,
		"monsterName": String(m.get("nameKey", mid)),
		"abilityKey": String(ability.get("textKey", "")),
		"combat": m.get("combat", {}),
		"horror": m.get("horror", {}),
		"toughness": tough,  # изначальная стойкость (для шкалы)
		"health": cur,  # текущее здоровье экземпляра
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

	# ── Шаг 1: бросок ВОЛИ (если ещё не катали) ──
	# Только бросок + расчёт; рассудок/здоровье/монстр применяются при завершении
	# (_commit_outcome), чтобы между бросками был доступен переброс за концентрацию.
	if not enc.has("will"):
		var h: Dictionary = enc.get("horror", {})
		var w_roll: Dictionary = _roll_check(
			pid, {"skill": h.get("skill", "will"), "modifier": int(h.get("modificator", 0))}
		)
		enc["will"] = w_roll
		enc["sanity_loss"] = maxi(0, int(h.get("damage", 0)) - int(w_roll["successes"]))
		GameConsole.log(
			(
				"[Бой] %s · Воля %d · рассудок −%d"
				% [_gs._name_of(pid), int(w_roll["successes"]), int(enc["sanity_loss"])]
			)
		)
		_gs._broadcast_sync()
		_gs._emit_changed()
		return true

	# ── Шаг 2: бросок СИЛЫ (атака) ── (enc.health — здоровье монстра НА СТАРТЕ боя,
	# не мутируем; health_after хранится в resolution и применяется при завершении).
	var c: Dictionary = enc.get("combat", {})
	var s_roll: Dictionary = _roll_check(
		pid, {"skill": c.get("skill", "strength"), "modifier": int(c.get("modificator", 0))}
	)
	enc["resolution"] = _combat_strength_result(enc, s_roll)
	var r: Dictionary = enc["resolution"]
	(
		GameConsole
		. log(
			(
				"[Бой] %s · %s (атака %d, монстр %d→%d, здоровье −%d)"
				% [
					_gs._name_of(pid),
					"повержен" if bool(r["won"]) else "выжил",
					int(r["dealt"]),
					int(enc.get("health", 0)),
					int(r["health_after"]),
					int(r["hp_loss"]),
				]
			)
		)
	)
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# Производные значения броска СИЛЫ из стартового здоровья монстра (enc.health) —
# чистый расчёт без применения (для resolve и переброса).
func _combat_strength_result(enc: Dictionary, s_roll: Dictionary) -> Dictionary:
	var c: Dictionary = enc.get("combat", {})
	var hits: int = int(s_roll["successes"])
	var health_after: int = maxi(0, int(enc.get("health", 0)) - hits)
	return {
		"won": health_after <= 0,
		"strength": s_roll,
		"hp_loss": maxi(0, int(c.get("damage", 0)) - hits),
		"dealt": hits,
		"health_after": health_after,
	}


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
	var inst: Dictionary = inst_v if inst_v is Dictionary else {"id": String(inst_v)}
	inst["health"] = health
	arr[idx] = inst
	_gs.monsters[loc_id] = arr


# Доступные НЕ-БОЕВЫЕ типы встречи по содержимому клетки. general — всегда;
# research — если есть улика; gate — если врата; mystery — если локация помечена
# активной Тайной и ещё не зачищена. (Бой не входит — он принудительный и первым,
# см. begin_turn / continue_encounter_turn.)
func _compute_choices(pid: String) -> Array:
	var loc: String = String(_gs.players[pid].get("location", ""))
	var out: Array = ["general"]
	var ents: Array = _gs.entities.get(loc, [])
	if (ents as Array).has("clue"):
		out.append("research")
	if _gs.gates.has(loc):
		out.append("gate")
	# Тайна (location-счётчик): локация помечена И не зачищена. Для tokensOnCard
	# этот путь не используется — там прогресс через bind-ход (ниже).
	var mystery: Dictionary = _gs._campaign.current_mystery()
	var locs: Array = mystery.get("locations", [])
	var is_tokens: bool = _gs.mystery_kind() == "tokensOnCard"
	if not is_tokens and locs.has(loc) and not (_gs.mystery_claimed as Array).has(loc):
		out.append("mystery")
	# Bind-ход: encounter-хук набора жетонов применим на этой клетке (жетон Знамения
	# или метка Тайны) и игрок может оплатить cost — см. GameState.mystery_encounter_hook.
	if not _gs.mystery_encounter_hook(loc, pid).is_empty():
		out.append("eldritch")
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
		return false  # карта ещё генерится

	var enc_kind: String = String(_gs.current_encounter.get("kind", ""))
	# gate / mystery — двухфазные ветвящиеся (общая структура); combat — отдельно.
	if enc_kind == "gate" or enc_kind == "mystery":
		return _resolve_gate_stage(pid)
	if enc_kind == "combat":
		return _resolve_combat(pid)

	if _gs.current_encounter.has("resolution"):
		return false  # уже разрешена

	# Только бросок — эффекты применяются при завершении (_commit_outcome), чтобы
	# между броском и «Завершить» можно было перебрасывать за концентрацию.
	var roll: Dictionary = _roll_check(pid, _gs.current_encounter.get("test", {}))
	_gs.current_encounter["resolution"] = roll
	_update_loc_bonus(pid, bool(roll["passed"]))  # бонус локации на успехе
	(
		GameConsole
		. log(
			(
				"[Game] %s · встреча %s · успехов: %d"
				% [
					_gs._name_of(pid),
					"пройдена" if roll["passed"] else "провалена",
					int(roll["successes"]),
				]
			)
		)
	)
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# Активный узел двухфазных врат: стадия 0 → stage1 (маршрутизация), стадия 1 →
# ветка по результату первой проверки (branches.success / branches.failure).
func _gate_node(card: Dictionary, stage: int) -> Dictionary:
	if stage <= 0:
		return card.get("stage1", {})
	var branches: Dictionary = card.get("branches", {})
	var branch: String = String(card.get("branch", "success"))
	return branches.get(branch, {})


# Резолв текущей фазы gate-встречи (дерево глубины 2). Стадия 0 — ТОЛЬКО
# маршрутизация: катим проверку, эффектов нет, исход решает, в какую ветку идём
# (переход — host_apply_advance_stage). Стадия 1 — вторая проверка ветки: катим
# и применяем её onSuccess/onFailure (положительный исход закрывает врата).
func _resolve_gate_stage(pid: String) -> bool:
	if _gs.current_encounter.has("stage_resolution"):
		return false  # фаза уже разрешена — ждём «Дальше»/«Завершить»
	var stage: int = int(_gs.current_encounter.get("stage", 0))
	var node: Dictionary = _gate_node(_gs.current_encounter, stage)
	if node.is_empty():
		return false
	# Только бросок. Эффекты второй проверки применяются при завершении встречи
	# (_commit_outcome) — между броском и «Завершить» доступен переброс за фокус.
	var roll: Dictionary = _roll_check(pid, node.get("test", {}))
	_gs.current_encounter["stage_resolution"] = roll
	(
		GameConsole
		. log(
			(
				"[Game] %s · врата, фаза %d %s · успехов: %d"
				% [
					_gs._name_of(pid),
					stage + 1,
					"пройдена" if roll["passed"] else "провалена",
					int(roll["successes"]),
				]
			)
		)
	)
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


## Хост: после первой проверки врат перейти ко второй. В отличие от линейной
## модели, переход происходит при ЛЮБОМ исходе первой проверки — успех ведёт в
## ветку success, провал — в ветку failure (обе дают вторую проверку).
## Зовётся из GameState.advance_encounter_stage / relay-router.
func host_apply_advance_stage(pid: String) -> bool:
	if _gs.phase != "encounter" or _gs._current_pid() != pid:
		return false
	var k: String = String(_gs.current_encounter.get("kind", ""))
	if k != "gate" and k != "mystery":
		return false
	if int(_gs.current_encounter.get("stage", 0)) != 0:
		return false  # переход только с первой проверки на вторую
	var res: Dictionary = _gs.current_encounter.get("stage_resolution", {})
	if res.is_empty():
		return false  # первую проверку ещё не катили
	var branch: String = "success" if bool(res.get("passed", false)) else "failure"
	_gs.current_encounter["branch"] = branch
	_gs.current_encounter["stage"] = 1
	_gs.current_encounter.erase("stage_resolution")
	GameConsole.log("[Game] %s · врата, ветка → %s" % [_gs._name_of(pid), branch])
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


## Хост: применить ИТОГОВЫЕ эффекты встречи. Зовётся при завершении (из
## PhaseController.host_apply_finish_encounter) — эффекты отвязаны от броска,
## чтобы между ними был доступен переброс за фокус. Идемпотентна (флаг committed).
## combat применяет свои эффекты сам (в _resolve_combat) — здесь пропускается.
func _commit_outcome(pid: String) -> void:
	var enc: Dictionary = _gs.current_encounter
	if bool(enc.get("committed", false)) or enc.is_empty():
		return
	var kind: String = String(enc.get("kind", ""))
	enc["committed"] = true
	if kind == "combat":
		_commit_combat(pid)
		return
	if kind == "eldritch":
		_commit_eldritch(pid)
		return
	if kind == "gate" or kind == "mystery":
		var branches: Dictionary = enc.get("branches", {})
		var node: Dictionary = branches.get(String(enc.get("branch", "success")), {})
		var res: Dictionary = enc.get("stage_resolution", {})
		_apply_effects(
			node.get("onSuccess" if bool(res.get("passed", false)) else "onFailure", []), pid
		)
	else:
		var res: Dictionary = enc.get("resolution", {})
		var arr: Array = enc.get("onSuccess" if bool(res.get("passed", false)) else "onFailure", [])
		var clues_before: int = int(_gs.players[pid].get("clues", 0))
		_apply_effects(arr, pid)
		var clues_gained: int = int(_gs.players[pid].get("clues", 0)) - clues_before
		# Исследование: забранная улика исчезает с локации игрока.
		if clues_gained > 0 and kind == "research":
			_remove_clues_at(String(_gs.players[pid].get("location", "")), clues_gained)
		# Бонус локации (на успехе) — поверх результата карточки.
		if bool(res.get("passed", false)):
			_apply_effects(enc.get("loc_bonus", []), pid)


# Применение итогов боя при завершении: потеря рассудка (Воля) + урон сыщику и
# судьба монстра (Сила). Эффекты отвязаны от бросков ради переброса.
func _commit_combat(pid: String) -> void:
	var enc: Dictionary = _gs.current_encounter
	var p: Dictionary = _gs.players[pid]
	var sl: int = int(enc.get("sanity_loss", 0))
	if sl > 0:
		p["sanity"] = maxi(0, int(p.get("sanity", 0)) - sl)
	if enc.has("resolution"):
		var r: Dictionary = enc["resolution"]
		var hp_loss: int = int(r.get("hp_loss", 0))
		if hp_loss > 0:
			p["hp"] = maxi(0, int(p.get("hp", 0)) - hp_loss)
		var loc: String = String(p.get("location", ""))
		if bool(r.get("won", false)):
			_remove_monster_instance(loc, 0)
			_gs.return_monster_to_bag(String(enc.get("monsterId", "")))  # монстр умер → в мешок
		else:
			_set_monster_health(loc, 0, int(r.get("health_after", 0)))


## Хост: переброс ОДНОГО выбранного куба (die_index) активной проверки за 1
## концентрацию. Куб должен быть провальным (d<5) — успех (≥5) не перебрасывается.
## Доступен, пока встреча не зафиксирована. Зовётся из GameState.reroll_encounter /
## relay-router. Возвращает true при перебросе.
func host_apply_reroll(pid: String, die_index: int) -> bool:
	if _gs.phase != "encounter" or _gs._current_pid() != pid or not _gs.players.has(pid):
		return false
	var enc: Dictionary = _gs.current_encounter
	if enc.is_empty() or bool(enc.get("committed", false)):
		return false
	var p: Dictionary = _gs.players[pid]
	if int(p.get("concentration", 0)) <= 0:
		return false  # нет концентрации
	var kind: String = String(enc.get("kind", ""))

	if kind == "combat":
		return _reroll_combat_die(pid, die_index)

	# Активный бросок: для ветвящихся — stage_resolution, иначе resolution.
	var key: String = "stage_resolution" if (kind == "gate" or kind == "mystery") else "resolution"
	if not enc.has(key):
		return false  # ещё не бросали
	var roll: Dictionary = enc[key]
	var dice: Array = roll.get("dice", [])
	if not Dice.reroll_failure(dice, die_index):
		return false
	roll = Dice.result(dice)
	enc[key] = roll
	if key == "resolution":
		_update_loc_bonus(pid, bool(roll["passed"]))  # переоценка бонуса локации
	p["concentration"] = int(p.get("concentration", 0)) - 1
	GameConsole.log(
		(
			"[Переброс] %s · фокус −1 · куб #%d · успехов: %d"
			% [_gs._name_of(pid), die_index, int(roll["successes"])]
		)
	)
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# Переброс одного куба активной проверки боя: пока нет resolution — Воля (пересчёт
# sanity_loss), иначе Сила (пересчёт исхода атаки). Тратит 1 концентрацию.
func _reroll_combat_die(pid: String, die_index: int) -> bool:
	var enc: Dictionary = _gs.current_encounter
	var p: Dictionary = _gs.players[pid]
	if enc.has("resolution"):
		var s: Dictionary = (enc["resolution"] as Dictionary).get("strength", {})
		var dice: Array = s.get("dice", [])
		if not Dice.reroll_failure(dice, die_index):
			return false
		enc["resolution"] = _combat_strength_result(enc, Dice.result(dice))
		GameConsole.log("[Переброс] %s · бой/Сила · куб #%d" % [_gs._name_of(pid), die_index])
	elif enc.has("will"):
		var w: Dictionary = enc["will"]
		var dice: Array = w.get("dice", [])
		if not Dice.reroll_failure(dice, die_index):
			return false
		w = Dice.result(dice)
		enc["will"] = w
		var hd: int = int((enc.get("horror", {}) as Dictionary).get("damage", 0))
		enc["sanity_loss"] = maxi(0, hd - int(w["successes"]))
		GameConsole.log("[Переброс] %s · бой/Воля · куб #%d" % [_gs._name_of(pid), die_index])
	else:
		return false  # ещё не бросали
	p["concentration"] = int(p.get("concentration", 0)) - 1
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# Итог Eldritch-хода. Успех: −2 улики, жетон Знамения с клетки → на карту Тайны.
# Провал: ничего не теряем (жетон остаётся). Решение Тайны проверяется в конце
# Фазы Мифов (GameState.check_mystery_tokens_solve), не здесь.
func _commit_eldritch(pid: String) -> void:
	var enc: Dictionary = _gs.current_encounter
	if not bool((enc.get("resolution", {}) as Dictionary).get("passed", false)):
		return  # провал — ничего не теряем
	var hook: Dictionary = enc.get("hook", {})
	if hook.is_empty():
		return
	var loc: String = String(enc.get("eldritch_loc", _gs.players[pid].get("location", "")))
	# Азатот: переносим board-жетон (снимаем с клетки). Тунгуска: жетона нет → no-op.
	if (_gs.entities.get(loc, []) as Array).has("eldritch_token"):
		_remove_eldritch_at(loc)
	# Списать cost + применить effect (placeEldritchToken where:self → счётчик).
	_gs.mystery_apply_hook(hook, pid)
	GameConsole.log(
		(
			"[Знамение] %s связал место с Тайной (на карте: %d)"
			% [_gs._name_of(pid), _gs.mystery_tokens_on_card]
		)
	)


# Снимает один жетон Знамения с локации (синкаемое entities).
func _remove_eldritch_at(loc_id: String) -> void:
	if loc_id.is_empty() or not _gs.entities.has(loc_id):
		return
	var arr: Array = _gs.entities[loc_id]
	if (arr as Array).has("eldritch_token"):
		arr.erase("eldritch_token")
	if (arr as Array).is_empty():
		_gs.entities.erase(loc_id)
	else:
		_gs.entities[loc_id] = arr


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
	var inv_id: String = String(p.get("investigator", ""))
	var inv: Dictionary = Investigators.get_data(inv_id)
	var inv_name: String = tr(String(inv.get("displayName", inv_id)))
	var background: String = tr(String(inv.get("occupation", "")))
	if background.is_empty():
		background = tr("ENCOUNTER_DEFAULT_BG")
	# Трекинга позиции сыщика ещё нет — берём его стартовую локацию.
	var loc: Dictionary = _location_info(String(p.get("location", "Arkham")))
	# В LLM отдаём игровое имя ("Аркхэм") как основное, а реальный прообраз
	# ("Уэнэм, Массачусетс, США") — отдельным flavor-полем для контекста модели.
	var real_loc: Dictionary = {
		"id": String(loc.get("id", "")),  # ← для locationAffinities на relay
		"name": loc["name"],
		"locationType": loc["type"],
	}
	if not String(loc.get("flavor", "")).is_empty():
		real_loc["flavor"] = loc["flavor"]
	var req: Dictionary = {
		"kind": kind,
		"investigator": {"name": inv_name, "background": background},
		"realLocation": real_loc,
		"conditions": [],
		"count": 1,
		"language": _gs._relay_language(),
	}
	# Библия готова — встреча несёт контекст кампании (Древний, акт, doom).
	var cid: String = String(_gs.campaign.get("id", ""))
	if not cid.is_empty():
		req["campaignId"] = cid
		req["act"] = _gs._campaign.current_act()
		req["doom"] = _gs.doom
	return req


# Локализованное игровое имя ("Аркхэм") + реальный прообраз ("Уэнэм, Массачусетс")
# по id локации. Матч по `id`, а не `name` — name теперь translation key.
func _location_info(loc_id: String) -> Dictionary:
	var locations: Array = _gs._load_locations()
	for i in range(locations.size()):
		var loc: Dictionary = locations[i]
		if String(loc.get("id", "")) == loc_id:
			return {
				"id": loc_id,
				"name": tr(String(loc.get("name", loc_id))),
				"flavor": tr(String(loc.get("realWorldLocation", ""))),
				"type": String(loc.get("type", "city")),
			}
	return {"id": loc_id, "name": loc_id, "flavor": "", "type": "city"}


# Запасная карта на случай сбоя генерации — игра не должна вставать.
func _fallback_card() -> Dictionary:
	return {
		"id": "fallback",
		"name": "ENCOUNTER_FALLBACK_NAME",
		"mainText": "ENCOUNTER_FALLBACK_MAIN",
		"test": {"skill": "will", "modifier": 0},
		"successText": "ENCOUNTER_FALLBACK_SUCCESS",
		"failureText": "ENCOUNTER_FALLBACK_FAILURE",
		"onSuccess": [],
		"onFailure": [],
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
	var pool: int = maxi(
		1, int(inv_skills.get(skill, 1)) + int(skill_mods.get(skill, 0)) + modifier
	)

	return Dice.result(Dice.roll(pool))


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


# ── Бонус локации (Вариант A: rewardAffinity в data/locations.json) ───────────────


# Пересчёт бонуса по текущему исходу. Решается ОДИН раз при переходе в успех
# (кэш loc_bonus_decided) — чтобы перебросы не «мигали» бонусом. Провал → нет бонуса.
func _update_loc_bonus(pid: String, passed: bool) -> void:
	var enc: Dictionary = _gs.current_encounter
	if not passed:
		enc["loc_bonus"] = []
		enc["loc_bonus_decided"] = false
		return
	if bool(enc.get("loc_bonus_decided", false)):
		return
	enc["loc_bonus"] = _location_bonus(pid)
	enc["loc_bonus_decided"] = true


# С шансом _LOC_BONUS_CHANCE взвешенно выбираем глагол из rewardAffinity локации
# игрока и строим эффект-ноду. [] — бонуса нет (нет affinity или не выпал шанс).
func _location_bonus(pid: String) -> Array:
	var loc_id: String = String(_gs.players[pid].get("location", ""))
	var aff: Dictionary = _gs.location_reward_affinity(loc_id)
	if aff.is_empty() or randf() >= _LOC_BONUS_CHANCE:
		return []
	var verb: String = _weighted_pick(aff)
	return [_bonus_node(verb)] if not verb.is_empty() else []


func _weighted_pick(weights: Dictionary) -> String:
	var total: float = 0.0
	for k: Variant in weights:
		total += maxf(0.0, float(weights[k]))
	if total <= 0.0:
		return ""
	var r: float = randf() * total
	for k: Variant in weights:
		r -= maxf(0.0, float(weights[k]))
		if r < 0.0:
			return String(k)
	return ""


# Эффект-нода бонуса по спецификации "verb" или "verb:param":
#   improveSkill:observation — качает КОНКРЕТНЫЙ навык (без param — случайный);
#   gainClue:2 / placeClue:2 / healSanity:2 — param как количество.
# Поддержаны проверенные глаголы (board placeClue + player gainClue/improveSkill/
# gainFocus/healSanity/gainAsset).
func _bonus_node(spec: String) -> Dictionary:
	var parts: PackedStringArray = spec.split(":")
	var verb: String = parts[0]
	var param: String = parts[1] if parts.size() > 1 else ""
	var n: int = maxi(1, param.to_int()) if param.is_valid_int() else 1
	match verb:
		"placeClue":
			return {"do": "placeClue", "count": n}
		"gainClue":
			return {"do": "gainClue", "count": n}
		"improveSkill":
			var skill: String = param if _SKILLS.has(param) else _SKILLS[randi() % _SKILLS.size()]
			return {"do": "improveSkill", "skill": skill, "amount": 1}
		"gainFocus":
			return {"do": "gainFocus", "amount": n}
		"healSanity":
			return {"do": "healSanity", "amount": n}
		"gainAsset":
			return {"do": "gainAsset"}
		_:
			return {"do": verb, "count": n}
