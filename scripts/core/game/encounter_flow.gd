class_name EncounterFlow
extends RefCounted

## Хост-only: генерация карт встреч через ContentApi (live, по выбору игрока),
## бросок проверки активного игрока, применение onSuccess/onFailure эффектов.
##
## GameState владеет полем current_encounter (синкается всем), фазами и
## turn-flow; EncounterFlow — логикой взаимодействия с ContentApi. Запись в
## _gs.current_encounter — напрямую из модуля: результат обязан попасть в синк.

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

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
func generate(kind: String = "general", site_specific: bool = false) -> void:
	if not _gs._is_host():
		return
	var pid: String = _gs._current_pid()
	if pid.is_empty() or not _gs.players.has(pid):
		return

	# Лента действий: тип не-боевой встречи (бой → _begin_combat, eldritch → _begin_eldritch_move).
	var feed_id: String = {"research": "research", "gate": "gate", "mystery": "mystery"}.get(
		kind, "encounter"
	)
	_gs.announce_action(pid, feed_id)

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
			_start_check_for_encounter(pid)
			_gs._broadcast_sync()
			_gs._emit_changed()
		return

	var req: Dictionary = _build_request(_gs.players[pid], kind, site_specific)
	# Захватываем раунд — после долгого await тот же игрок может оказаться
	# уже в новом раунде с новой встречей, и старый ответ нельзя писать.
	var captured_round: int = _gs.round_num
	GameConsole.log("[Game] Генерация встречи для %s..." % _gs._name_of(pid))
	@warning_ignore("unsafe_method_access")
	var res: Dictionary = await api.draw_encounter(req)

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
	_start_check_for_encounter(pid)
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
	elif kind == "rumor":
		_begin_rumor_encounter(pid)
	elif kind == "local":
		generate("general", true)  # локационная встреча (привязанная к клетке)
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
	var hook: Dictionary = _gs._mystery.mystery_encounter_hook(loc, pid)
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
	_gs.announce_action(pid, "eldritch")  # лента: изучает знамения места
	_start_check_for_encounter(pid)
	GameConsole.log("[Знамение] %s изучает место, чтобы связать его с Тайной" % _gs._name_of(pid))
	_gs._broadcast_sync()
	_gs._emit_changed()


# Хост: встреча-решение Слуха (solve=encounter) на клетке слуха. Имя/текст — с карты
# Слуха, проверка — из rumor.solve.test (дефолт Знание). На успехе (_commit_rumor) Слух
# развеивается. Без хука/cost (cost — следующая итерация); сейчас — навыковая проверка.
func _begin_rumor_encounter(pid: String) -> void:
	if not _gs._is_host():
		return
	var loc: String = String(_gs.players[pid].get("location", ""))
	var card: Dictionary = _gs._rumor.encounter_card_for(loc)
	if card.is_empty():
		generate("general")  # слуха тут уже нет (страховка)
		return
	var ru: bool = I18n.get_locale() == "ru"
	_gs.current_encounter = {
		"kind": "rumor",
		"name": String(card.get("name", "Слух" if ru else "Rumor")),
		"mainText": String(card.get("text", "")),
		"test": _gs._rumor.encounter_test(loc),
		"successText": "Слух развеян." if ru else "The Rumor is dispelled.",
		"failureText": "Слух не поддаётся." if ru else "The Rumor resists.",
		"rumor_loc": loc,
	}
	_gs.announce_action(pid, "research")  # лента: «ищет улики» (ближайшее по смыслу)
	_start_check_for_encounter(pid)
	GameConsole.log("[Слух] %s разыгрывает встречу-решение на %s" % [_gs._name_of(pid), loc])
	_gs._broadcast_sync()
	_gs._emit_changed()


# Итог встречи-решения Слуха: успех — развеять Слух на его локации; провал — ничего.
func _commit_rumor(_pid: String) -> void:
	if bool(_gs.active_check.get("passed", false)):
		_gs._rumor.solve_encounter_at(String(_gs.current_encounter.get("rumor_loc", "")))
	_gs._check.clear()


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
	_gs.announce_action(pid, "combat", {"monster": String(m.get("nameKey", mid))})  # лента: бой
	_start_combat_will(pid)  # проверка Воли (pre-roll) — окно активации карт до броска
	GameConsole.log("[Бой] %s vs %s (здоровье %d/%d)" % [_gs._name_of(pid), mid, cur, tough])
	_gs._broadcast_sync()
	_gs._emit_changed()


# Старт проверки ВОЛИ боя (pre-roll, контекст combatEncounter) — единый механизм
# CheckFlow: активация карт/перебросы как у встреч. Навык/модификатор — из horror.
func _start_combat_will(pid: String) -> void:
	var h: Dictionary = _gs.current_encounter.get("horror", {})
	_gs._check.start(
		"combat", pid, String(h.get("skill", "will")), int(h.get("modifier", 0)), "combatEncounter"
	)


# Хост: бой в ДВА отдельных броска (одна кнопка — один шаг). Раундов/отступления нет.
#   Шаг 1 — ВОЛЯ (ужас): успехи блокируют урон по рассудку (max(0, horror.damage − успехи)).
#   Шаг 2 — СИЛА (атака): успехи и снижают урон по сыщику (max(0, combat.damage − успехи)),
#           и наносят столько же урона монстру. Здоровье монстра сохраняется
#           между боями; при 0 — монстр повержен и снят с локации.
func _resolve_combat(pid: String) -> bool:
	var enc: Dictionary = _gs.current_encounter
	if enc.has("resolution"):
		return false
	var c: Dictionary = _gs.active_check

	# ── Шаг 1: ВОЛЯ (ужас) ── Бросок и заморозка снимка; рассудок применяется при
	# завершении (_commit_combat). Между бросками доступны активация карт/перебросы.
	if not enc.has("will"):
		# Первое нажатие — бросаем Волю (проверка стартована в _begin_combat, pre-roll).
		if not bool(c.get("rolled", false)):
			return _gs._check.roll(pid)
		# «Дальше»: замораживаем Волю (+ потеря рассудка) и стартуем проверку Силы в
		# PRE-ROLL — окно для карт усиления (оружие +Сила применяется ДО броска), сам
		# бросок Силы — следующим нажатием.
		var horror: Dictionary = enc.get("horror", {})
		var hd: int = int(horror.get("damage", 0))
		var w_succ: int = int(c.get("successes", 0))
		enc["will"] = {"dice": (c.get("dice", []) as Array).duplicate(), "successes": w_succ}
		enc["sanity_loss"] = maxi(0, hd - w_succ)
		# Спец-способность монстра: пройденный horror-тест (Crazed Mob — Влияние)
		# сразу побеждает монстра — шаг атаки (Сила) пропускаем.
		if bool(c.get("passed", false)) and bool(horror.get("defeatOnPass", false)):
			enc["defeated_on_horror"] = true
			enc["resolution"] = {
				"won": true,
				"strength": {"dice": [], "successes": 0},
				"hp_loss": 0,
				"dealt": int(enc.get("toughness", 0)),
				"health_after": 0,
			}
			_gs._check.clear()  # шага Силы нет
			GameConsole.log(
				"[Бой] %s · прошёл проверку → монстр повержен (без боя)" % _gs._name_of(pid)
			)
			_gs._broadcast_sync()
			_gs._emit_changed()
			return true
		var cb: Dictionary = enc.get("combat", {})
		_gs._check.start(
			"combat",
			pid,
			String(cb.get("skill", "strength")),
			int(cb.get("modifier", 0)),
			"combatEncounter"
		)
		GameConsole.log(
			(
				"[Бой] %s · Воля %d · рассудок −%d"
				% [_gs._name_of(pid), w_succ, int(enc["sanity_loss"])]
			)
		)
		_gs._broadcast_sync()
		_gs._emit_changed()
		return true

	# ── Шаг 2: СИЛА (атака) ── Сила стартована в pre-roll («Дальше»). Первое нажатие —
	# бросок; затем «Завершить» (finish_encounter → _commit_combat) фиксирует итог.
	if not bool(c.get("rolled", false)):
		return _gs._check.roll(pid)
	return false  # Сила брошена — дальше «Завершить»


# Итог боя из стартового здоровья монстра (enc.health) и активной проверки Силы —
# чистый расчёт без применения (для _commit_combat).
func _combat_resolution(enc: Dictionary, c: Dictionary) -> Dictionary:
	var cb: Dictionary = enc.get("combat", {})
	var hits: int = int(c.get("successes", 0))
	# Боевой урон — ФИЗИЧЕСКИЙ: монстр с physical-резистом получает вдвое меньше.
	# (hp_loss игрока — от СЫРОГО броска: защита не зависит от резиста монстра.)
	var m: Dictionary = MonsterCatalog.by_id(String(enc.get("monsterId", "")))
	var dealt: int = MonsterCatalog.apply_resistance(m, hits, "physical")
	var health_after: int = maxi(0, int(enc.get("health", 0)) - dealt)
	return {
		"won": health_after <= 0,
		"strength": {"dice": (c.get("dice", []) as Array).duplicate(), "successes": hits},
		"hp_loss": maxi(0, int(cb.get("damage", 0)) - hits),
		"dealt": dealt,
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
	# Локационная встреча: на клетке есть авторская site-встреча (список из библии).
	# Игрок выберет «общая» (без привязки) vs «локационная» (привязанная к клетке).
	if (_gs.campaign.get("siteEncounterLocations", []) as Array).has(loc):
		out.append("local")
	# Тайна (location-счётчик): локация помечена И не зачищена. Для tokensOnCard
	# этот путь не используется — там прогресс через bind-ход (ниже).
	var mystery: Dictionary = _gs._campaign.current_mystery()
	var locs: Array = mystery.get("locations", [])
	var is_tokens: bool = _gs._mystery.mystery_kind() == "tokensOnCard"
	if not is_tokens and locs.has(loc) and not (_gs.mystery_claimed as Array).has(loc):
		out.append("mystery")
	# Bind-ход: encounter-хук набора жетонов применим на этой клетке (жетон Знамения
	# или метка Тайны) и игрок может оплатить cost — см. GameState.mystery_encounter_hook.
	if not _gs._mystery.mystery_encounter_hook(loc, pid).is_empty():
		out.append("eldritch")
	# Слух с solve=encounter: игрок на клетке слуха может разыграть встречу-решение.
	if not _gs._rumor.encounter_location_for(pid).is_empty():
		out.append("rumor")
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
	if enc_kind == "combat":
		return _resolve_combat(pid)  # бой — отдельный поток (свой resolution)

	# Плоская встреча и врата — единая проверка (active_check). Проверка стартована
	# при показе карты; здесь только бросок (страховка — стартуем, если её нет).
	if bool(_gs.active_check.get("rolled", false)):
		return false  # уже брошено
	if String(_gs.active_check.get("owner", "")) != "encounter":
		_start_check_for_encounter(pid)
	if not _gs._check.roll(pid):
		return false
	(
		GameConsole
		. log(
			(
				"[Game] %s · проверка %s · успехов: %d"
				% [
					_gs._name_of(pid),
					"пройдена" if _gs.active_check.get("passed", false) else "провалена",
					int(_gs.active_check.get("successes", 0)),
				]
			)
		)
	)
	return true


# Активный узел двухфазных врат: стадия 0 → stage1 (маршрутизация), стадия 1 →
# ветка по результату первой проверки (branches.success / branches.failure).
func _gate_node(card: Dictionary, stage: int) -> Dictionary:
	if stage <= 0:
		return card.get("stage1", {})
	var branches: Dictionary = card.get("branches", {})
	var branch: String = String(card.get("branch", "success"))
	return branches.get(branch, {})


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
	if not bool(_gs.active_check.get("rolled", false)):
		return false  # первую проверку ещё не катили
	var branch: String = "success" if bool(_gs.active_check.get("passed", false)) else "failure"
	_gs.current_encounter["branch"] = branch
	_gs.current_encounter["stage"] = 1
	# Вторая проверка — новая (свои модификаторы/перебросы/истощение). _start
	# перетирает active_check проверкой стадии 2 (pre-roll).
	_start_check_for_encounter(pid)
	GameConsole.log("[Game] %s · врата, ветка → %s" % [_gs._name_of(pid), branch])
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# Старт проверки встречи (pre-roll) для текущей карты — окно активации карт ДО
# броска. Активация/перебросы/модификаторы — единый механизм CheckFlow
# (active_check). Бой не использует active_check (отдельный поток); пустую карту
# пропускаем. Зовётся при показе карты (generate/eldritch) и на смене стадии врат.
func _start_check_for_encounter(pid: String) -> void:
	var enc: Dictionary = _gs.current_encounter
	if enc.is_empty() or String(enc.get("kind", "")) == "combat":
		return
	var test: Dictionary = _active_test(enc)
	_gs._check.start(
		"encounter",
		pid,
		String(test.get("skill", "will")),
		int(test.get("modifier", 0)),
		_check_context()
	)


# Контекст текущей проверки для сопоставления способностей активов: research →
# researchEncounter, gate → otherWorldEncounter, прочее (general/mystery/eldritch)
# → generalEncounter. Бой (combat_modal) сюда не относится.
func _check_context() -> String:
	match String(_gs.current_encounter.get("kind", "")):
		"research":
			return "researchEncounter"
		"gate":
			return "otherWorldEncounter"
		_:
			return "generalEncounter"


# Текущая проверка встречи (навык/контекст): плоская — enc.test; врата — узел стадии.
func _active_test(enc: Dictionary) -> Dictionary:
	if String(enc.get("kind", "")) in ["gate", "mystery"]:
		return _gate_node(enc, int(enc.get("stage", 0))).get("test", {})
	return enc.get("test", {})


## Хост: применить ИТОГОВЫЕ эффекты встречи. Зовётся при завершении (из
## PhaseController.host_apply_finish_encounter) — эффекты отвязаны от броска,
## чтобы между ними был доступен переброс за фокус. Идемпотентна (флаг committed).
## combat применяет свои эффекты сам (в _resolve_combat) — здесь пропускается.
##
## Резюмируемость: если программа эффектов содержит интерактивный choice, слот
## ставит current_encounter.pending_choice и НЕ ставит committed — ход замирает,
## модалка показывает выбор. После записи решения (record_effect_choice) функция
## зовётся снова и переигрывает программу детерминированно (см. _run_effect_slot).
func _commit_outcome(pid: String) -> void:
	var enc: Dictionary = _gs.current_encounter
	if bool(enc.get("committed", false)) or enc.is_empty():
		return
	var kind: String = String(enc.get("kind", ""))
	# Атомарные ветки (без интерактивного выбора эффектов) — как раньше.
	if kind == "combat":
		enc["committed"] = true
		_commit_combat(pid)
		return
	if kind == "eldritch":
		enc["committed"] = true
		_commit_eldritch(pid)
		return
	if kind == "rumor":
		enc["committed"] = true
		_commit_rumor(pid)
		return
	var passed: bool = bool(_gs.active_check.get("passed", false))
	if kind == "gate" or kind == "mystery":
		var branches: Dictionary = enc.get("branches", {})
		var node: Dictionary = branches.get(String(enc.get("branch", "success")), {})
		var key: String = "onSuccess" if passed else "onFailure"
		if not _run_effect_slot(node.get(key, []), pid, "main"):
			return  # ждём выбор игрока
	else:
		var key: String = "onSuccess" if passed else "onFailure"
		if not _run_effect_slot(enc.get(key, []), pid, "main"):
			return  # ждём выбор игрока
		# Исследование: забранная улика исчезает с локации (один раз, после слота).
		_apply_research_clue_removal(pid, kind)
	enc["committed"] = true
	_gs._check.clear()  # проверка завершена — снять active_check


# Применение итогов боя при завершении: потеря рассудка (Воля) + урон сыщику и
# судьба монстра (Сила). Эффекты отвязаны от бросков ради переброса.
func _commit_combat(pid: String) -> void:
	var enc: Dictionary = _gs.current_encounter
	var p: Dictionary = _gs.players[pid]
	var sl: int = int(enc.get("sanity_loss", 0))
	if sl > 0:
		p["sanity"] = maxi(0, int(p.get("sanity", 0)) - sl)
	# Зафиксировать итог Силы из активной проверки (если ещё не зафиксирован).
	if not enc.has("resolution"):
		enc["resolution"] = _combat_resolution(enc, _gs.active_check)
	var r: Dictionary = enc["resolution"]
	var won: bool = bool(r.get("won", false))
	var mon_name: String = String(enc.get("monsterName", ""))
	_gs.announce_action(pid, "combat_won" if won else "combat_lost", {"monster": mon_name})
	var hp_loss: int = int(r.get("hp_loss", 0))
	if hp_loss > 0:
		p["hp"] = maxi(0, int(p.get("hp", 0)) - hp_loss)
	var loc: String = String(p.get("location", ""))
	if bool(r.get("won", false)):
		_remove_monster_instance(loc, 0)
		_gs._board.return_monster_to_bag(String(enc.get("monsterId", "")))  # монстр умер → в мешок
		_gs._rumor.notify_monster_defeated(loc)  # Слух с solve=monsterDefeated развеян
	else:
		_set_monster_health(loc, 0, int(r.get("health_after", 0)))
	_gs._check.clear()  # проверка боя завершена — снять active_check


## Хост: боевой триггер карты (effect.triggered, on:"combatEncounter") — напр.
## Handcuffs: потратить фокус → победить монстра ДО проверки Силы, если его стойкость
## ≤ n. true — триггер применён (монстр повержен). false — карта не подходит (нет
## триггера / монстр крепче / нечем платить) → роутер пробует обычный check-mod
## (CheckFlow.activate). Зовётся из GameState.activate_card / relay-router.
func try_combat_trigger(pid: String, item_index: int) -> bool:
	if not _gs._is_host():
		return false
	var node: Dictionary = combat_trigger_node_ready(pid, item_index)
	if node.is_empty():
		return false  # карта не подходит (нет триггера / монстр крепче / нечем платить)
	var p: Dictionary = _gs.players[pid]
	var enc: Dictionary = _gs.current_encounter
	# Стоимость (напр. фокус) — уже проверена в combat_trigger_node_ready, списываем.
	var cost: Dictionary = node.get("cost", {})
	if cost.has("spend"):
		var resf: String = _cost_field(String(cost.get("spend", "")))
		p[resf] = int(p.get(resf, 0)) - int(cost.get("amount", 1))
	# Монстр повержен без проверки Силы (как defeatOnPass). Победную резолюцию доводит
	# _commit_combat при «Завершить»: снимет монстра, вернёт в мешок, развеет Слух.
	enc["defeated_by_trigger"] = true
	enc["resolution"] = {
		"won": true,
		"strength": {"dice": [], "successes": 0},
		"hp_loss": 0,
		"dealt": int(enc.get("toughness", 0)),
		"health_after": 0,
	}
	_gs._check.clear()  # шага Силы не будет
	GameConsole.log("[Бой] %s · карта-триггер → монстр повержен (без боя)" % _gs._name_of(pid))
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


## Узел defeatMonster применимого СЕЙЧАС боевого триггера карты (предикат стойкости и
## оплата проходят). {} — карта не подходит. Read-only (без списаний/мутаций) — годится
## и для подсветки карты в веере (любой клиент), и для try_combat_trigger перед
## применением. БЕЗ host-гарда: это логическая применимость, авторитет — у вызывателя.
func combat_trigger_node_ready(pid: String, item_index: int) -> Dictionary:
	if _gs.phase != "encounter" or _gs._current_pid() != pid or not _gs.players.has(pid):
		return {}
	var enc: Dictionary = _gs.current_encounter
	if (
		String(enc.get("kind", "")) != "combat"
		or enc.has("resolution")
		or bool(enc.get("committed", false))
	):
		return {}  # только в активном бою до фиксации итога («перед проверкой Силы»)
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	if item_index < 0 or item_index >= items.size():
		return {}
	var it: Dictionary = items[item_index]
	if bool(it.get("exhausted", false)):
		return {}
	var node: Dictionary = _combat_trigger_node(AssetCatalog.by_id(AssetCatalog.entry_id(it)))
	if node.is_empty():
		return {}
	# Предикат: монстр достаточно слаб (стойкость ≤ n).
	var when_v: Dictionary = node.get("when", {})
	if (
		String(when_v.get("kind", "")) == "monsterToughnessAtMost"
		and int(enc.get("toughness", 99)) > int(when_v.get("n", 0))
	):
		return {}
	# Стоимость (напр. фокус) — есть ли чем платить.
	var cost: Dictionary = node.get("cost", {})
	if cost.has("spend"):
		if int(p.get(_cost_field(String(cost.get("spend", ""))), 0)) < int(cost.get("amount", 1)):
			return {}
	return node


# Первый узел do=="defeatMonster" из триггера on=="combatEncounter" актива. {} — нет.
func _combat_trigger_node(asset: Dictionary) -> Dictionary:
	for t_v: Variant in (asset.get("effect", {}) as Dictionary).get("triggered", []):
		if not (t_v is Dictionary):
			continue
		if String((t_v as Dictionary).get("on", "")) != "combatEncounter":
			continue
		for d_v: Variant in (t_v as Dictionary).get("do", []) as Array:
			if d_v is Dictionary and String((d_v as Dictionary).get("do", "")) == "defeatMonster":
				return d_v
	return {}


# Поле-ресурс игрока для cost.spend ("focus"→"concentration" и т.п.).
func _cost_field(spend: String) -> String:
	match spend:
		"focus", "concentration":
			return "concentration"
		"clue", "clues":
			return "clues"
		"health", "hp":
			return "hp"
		"sanity":
			return "sanity"
		_:
			return spend


## Хост: переброс ОДНОГО выбранного куба (die_index) активной проверки. currency —
## явная валюта (жетон) или "" = авто-приоритет. Куб должен быть провальным.
## Доступен, пока встреча не зафиксирована. Зовётся из GameState.reroll_encounter /
## relay-router. Возвращает true при перебросе.
func host_apply_reroll(pid: String, die_index: int, currency: String = "") -> bool:
	if _gs.phase != "encounter" or _gs._current_pid() != pid or not _gs.players.has(pid):
		return false
	var enc: Dictionary = _gs.current_encounter
	if enc.is_empty() or bool(enc.get("committed", false)):
		return false
	# Единый механизм перебросов для ВСЕХ проверок (включая бой). Активная проверка —
	# текущий шаг (Воля или Сила).
	return _gs._check.reroll(pid, die_index, currency)


# Итог Eldritch-хода. Успех: −2 улики, жетон Знамения с клетки → на карту Тайны.
# Провал: ничего не теряем (жетон остаётся). Решение Тайны проверяется в конце
# Фазы Мифов (GameState.check_mystery_tokens_solve), не здесь.
func _commit_eldritch(pid: String) -> void:
	var enc: Dictionary = _gs.current_encounter
	if not bool(_gs.active_check.get("passed", false)):
		return  # провал — ничего не теряем
	var hook: Dictionary = enc.get("hook", {})
	if hook.is_empty():
		return
	var loc: String = String(enc.get("eldritch_loc", _gs.players[pid].get("location", "")))
	# Снимаем жетон с клетки → на карту, ЕСЛИ хук велит (consumeToken, дефолт true).
	# Источник жетона — entity eldritch_token (Мифы) ИЛИ метка локации Тайны; метку
	# «снимаем» через mystery_claimed (world_map её не рисует, повторно не зайти).
	# consumeToken:false — жетон/метка остаются: клетку можно переиспользовать (гейт — cost).
	if bool(hook.get("consumeToken", true)):
		if (_gs.entities.get(loc, []) as Array).has("eldritch_token"):
			_remove_eldritch_at(loc)
		var mlocs: Array = _gs._campaign.current_mystery().get("locations", [])
		if (mlocs as Array).has(loc) and not (_gs.mystery_claimed as Array).has(loc):
			(_gs.mystery_claimed as Array).append(loc)
	# Списать cost + применить effect (placeEldritchToken where:self → счётчик).
	_gs._mystery.mystery_apply_hook(hook, pid)
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


# Тело запроса /encounters/draw для игрока (kind ∈ general/research/gate).
# site_specific=true → локационная встреча (привязанная к клетке тегом location:<id>).
func _build_request(
	p: Dictionary, kind: String = "general", site_specific: bool = false
) -> Dictionary:
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
		"siteSpecific": site_specific,
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


# ── Эффекты ──────────────────────────────────────────────────────────────────


# Применяет программу эффектов ОДНИМ слотом (транзакционно и резюмируемо).
# Возвращает true — слот завершён (мутации игрока зафиксированы, поле и логи
# применены); false — встретился интерактивный choice, выставлен
# current_encounter.pending_choice, мутации отброшены (ждём решения игрока).
#
# Детерминизм при возобновлении: бросаем по копии игрока (dup), эффекты пишем
# обратно только при полном завершении слота; решения/броски хранятся в
# current_encounter (effect_decisions/effect_rolls) и переигрываются. Завершённые
# слоты помечаются в effect_done_slots и при повторном заходе пропускаются —
# иначе ранее применённые мутации наложились бы повторно.
func _run_effect_slot(effects: Array, pid: String, slot: String) -> bool:
	var enc: Dictionary = _gs.current_encounter
	var done: Array = enc.get("effect_done_slots", [])
	if (done as Array).has(slot):
		return true
	if effects.is_empty() or not _gs.players.has(pid):
		done.append(slot)
		enc["effect_done_slots"] = done
		return true
	# Транзакция: применяем к копии игрока — на паузе (choice) копия отбрасывается.
	var dup: Dictionary = (_gs.players[pid] as Dictionary).duplicate(true)
	var flow: Dictionary = {
		"interactive": true,
		"checks_visible": true,  # вложенный test → ВИДИМАЯ проверка (общий движок)
		"decisions": enc.get("effect_decisions", {}),
		"rolls": enc.get("effect_rolls", {}),
		"pending": {},
		"slot": slot + "/",
	}
	var clues_before: int = int(dup.get("clues", 0))
	var res: Dictionary = _EffectRunner.run(effects, dup, _effect_ctx(pid), flow)
	enc["effect_rolls"] = flow.get("rolls", {})  # сохранить записанные броски
	var pending: Dictionary = res.get("pending", {})
	if not pending.is_empty():
		if String(pending.get("kind", "")) == "check":
			# Вложенная проверка эффекта: сохраняем основную проверку встречи в стек и
			# стартуем видимую (общая модалка); resolve_encounter_check вернёт её pop'ом.
			_gs._check.push()
			_gs._check.start(
				"effectCheck",
				pid,
				String(pending.get("skill", "influence")),
				int(pending.get("modifier", 0)),
				"encounterEffect"
			)
			_gs.pending_check = {
				"pid": pid,
				"driver": "encounter",
				"path": String(pending.get("path", "")),
				"subject": {},
			}
		else:
			enc["pending_choice"] = pending  # модалка покажет выбор; ход замирает
		return false
	# Слот завершён — фиксируем мутации игрока, поле и логи.
	_gs.players[pid] = dup
	if slot == "main":
		enc["_clues_gained"] = int(dup.get("clues", 0)) - clues_before
	var board: Array = res.get("board", [])
	for i in range(board.size()):
		_gs._apply_board_effect(board[i] as Dictionary)
	var logs: Array = res.get("logs", [])
	for i in range(logs.size()):
		GameConsole.log("[Эффект] %s" % String(logs[i]))
	done.append(slot)
	enc["effect_done_slots"] = done
	return true


# Исследование: снять с локации забранные в основном слоте улики (один раз).
func _apply_research_clue_removal(pid: String, kind: String) -> void:
	var enc: Dictionary = _gs.current_encounter
	if kind != "research" or bool(enc.get("_clues_removed", false)):
		return
	var gained: int = int(enc.get("_clues_gained", 0))
	if gained > 0:
		_remove_clues_at(String(_gs.players[pid].get("location", "")), gained)
	enc["_clues_removed"] = true


## Хост: записать решение игрока по активному choice. Возвращает true, если
## решение принято (далее зовущий переигрывает _commit_outcome). Зовётся из
## PhaseController.host_apply_effect_choice.
func record_effect_choice(pid: String, index: int) -> bool:
	if _gs.phase != "encounter" or _gs._current_pid() != pid:
		return false
	var enc: Dictionary = _gs.current_encounter
	var pending: Dictionary = enc.get("pending_choice", {})
	if pending.is_empty():
		return false
	var options: Array = pending.get("options", [])
	if index < 0 or index >= (options as Array).size():
		return false
	# choice → индекс ветки; target → id сыщика; monster → ref монстра (читает _run_action).
	var value: Variant = index
	var kind: String = String(pending.get("kind", "choice"))
	if kind == "target":
		value = String((options[index] as Dictionary).get("pid", ""))
	elif kind == "monster":
		value = String((options[index] as Dictionary).get("ref", ""))
	var dec: Dictionary = enc.get("effect_decisions", {})
	dec[String(pending.get("path", ""))] = value
	enc["effect_decisions"] = dec
	enc["pending_choice"] = {}  # снято — _commit_outcome переиграет с решением
	return true


## Хост: записать результат ВИДИМОЙ проверки эффекта встречи (диспетч из
## GameState.resolve_pending_check) и переиграть исход. Возвращает основную проверку
## встречи из стека (pop) и переигрывает _commit_outcome через _commit_and_advance.
func resolve_encounter_check(pid: String, path: String, passed: bool) -> bool:
	if _gs.phase != "encounter" or _gs._current_pid() != pid:
		return false
	if String(_gs.pending_check.get("driver", "")) != "encounter":
		return false
	var enc: Dictionary = _gs.current_encounter
	var dec: Dictionary = enc.get("effect_decisions", {})
	dec[path] = passed
	enc["effect_decisions"] = dec
	_gs.pending_check = {}
	_gs._check.pop()  # вернуть основную проверку встречи (её читает _commit_outcome)
	return _gs._phase._commit_and_advance(pid)


# Контекст исполнения Effect-DSL для активного игрока: навыки, тип локации, роль
# ведущего и срез поля (врата/монстры/улики). Нужен интерпретатору для реального
# test, предикатов when и счётчиков repeat (см. effect_runner.gd).
func _effect_ctx(pid: String) -> Dictionary:
	var p: Dictionary = _gs.players.get(pid, {})
	var loc: String = String(p.get("location", ""))
	var inv: Dictionary = Investigators.get_data(String(p.get("investigator", "")))
	var ctx: Dictionary = {
		"skills": inv.get("skills", {}),
		"loc_type": _location_info(loc).get("type", "city"),
		"is_lead": (not (_gs.turn_order as Array).is_empty()) and String(_gs.turn_order[0]) == pid,
		"gates_matching_omen": _gs._board.count_gates_of_color(_gs._board.current_omen_color()),
		"gates_on_board": (_gs.gates as Dictionary).size(),
		"monsters_on_board": _count_all_monsters(),
		"clues_on_board": _count_all_entities("clue"),
	}
	var tough: int = _active_monster_toughness(loc)
	if tough >= 0:
		ctx["monster_toughness"] = tough
	ctx["other_pids"] = _other_investigators(pid)
	ctx["monster_choices"] = _gs._board.monster_choices()  # для chosenMonster
	return ctx


# Прочие подключённые сыщики (кроме активного) как [{pid, name}] — варианты для
# интерактивного выбора цели (передача активов/улик: target chosenInvestigator).
func _other_investigators(active_pid: String) -> Array:
	var out: Array = []
	for pid_v: Variant in _gs.turn_order:
		var pid: String = String(pid_v)
		if pid == active_pid or not _gs.players.has(pid):
			continue
		if not bool(_gs.players[pid].get("connected", true)):
			continue
		out.append({"pid": pid, "name": _gs._name_of(pid)})
	return out


# Всего экземпляров монстров на поле (по всем локациям).
func _count_all_monsters() -> int:
	var n: int = 0
	for lid_v: Variant in _gs.monsters:
		n += (_gs.monsters[lid_v] as Array).size()
	return n


# Сколько меток tag (напр. "clue") лежит на поле суммарно.
func _count_all_entities(tag: String) -> int:
	var n: int = 0
	for lid_v: Variant in _gs.entities:
		for e_v: Variant in _gs.entities[lid_v] as Array:
			if String(e_v) == tag:
				n += 1
	return n


# Стойкость первого монстра на локации (для when/repeat по монстру). −1 — монстра нет.
func _active_monster_toughness(loc: String) -> int:
	var mons: Array = _gs.monsters.get(loc, [])
	if (mons as Array).is_empty():
		return -1
	var inst_v: Variant = mons[0]
	var mid: String = String(inst_v.get("id", "")) if inst_v is Dictionary else String(inst_v)
	var m: Dictionary = MonsterCatalog.by_id(mid)
	if m.is_empty():
		return -1
	@warning_ignore("unsafe_method_access")
	return MonsterCatalog.toughness_for(m, maxi(1, _gs.players.size()))
