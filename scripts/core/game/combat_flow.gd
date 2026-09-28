class_name CombatFlow
extends RefCounted

## Хост-only: бой сыщика с монстрами его клетки. Очередь («с каждым монстром, порядок
## выбирает сыщик»), сама схватка в два броска (Воля → Сила), фиксация итога при
## «Завершить» и боевые триггеры карт (Handcuffs и т.п.).
##
## Не знает не-боевых встреч: когда клетка чиста или монстра не оказалось, отдаёт
## управление EncounterFlow (см. begin → false, next_or_choice → NEXT_CLEAR).
## Окно preventLoss (бинты) живёт в EncounterFlow и читает отсюда sanity_loss_for /
## resolution. Стейт (current_encounter, monsters, active_check) — в GameState,
## пишем напрямую: результат обязан попасть в синк.

# Состояния боевой очереди (next_or_choice).
const NEXT_COMBAT := "combat"  # бой настроен
const NEXT_ORDER := "order"  # сыщик выбирает порядок (encounter_choices)
const NEXT_LOCKED := "locked"  # все бои отыграны, монстры остались — ход завершён
const NEXT_CLEAR := "clear"  # монстров нет — вызывающий даёт обычную встречу

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


# ── Очередь монстров на клетке ────────────────────────────────────────────────


## Хост: следующий шаг боевой очереди на клетке сыщика. Возвращает состояние:
## NEXT_COMBAT — бой настроен; NEXT_ORDER — сыщик выбирает, с кем драться первым
## (encounter_choices = "combat:<idx>"); NEXT_LOCKED — все бои отыграны, монстры
## остались (ход завершается); NEXT_CLEAR — клетка чиста, вызывающий даёт обычную
## встречу (CombatFlow не-боевых встреч не знает).
##
## Правило настолки: сыщик дерётся с каждым монстром своей клетки, порядок
## выбирает сам; поражение не освобождает от остальных. Встречу в локации он
## получает только если после боёв монстров на клетке не осталось — выживший
## монстр «запирает» локацию.
func next_or_choice(pid: String) -> String:
	var loc: String = String(_gs.players[pid].get("location", ""))
	var pending: Array = unfought_indices(loc)
	if pending.is_empty():
		if not (_gs.monsters.get(loc, []) as Array).is_empty():
			GameConsole.log(
				"[Бой] %s: все бои отыграны, монстры остались — ход завершён" % _gs.name_of(pid)
			)
			return NEXT_LOCKED
		return NEXT_CLEAR
	if pending.size() == 1:
		_gs.encounter_choices = []
		if not begin(pid, int(pending[0])):
			return NEXT_CLEAR  # монстр исчез между шагами — обычная встреча
		return NEXT_COMBAT
	# Несколько ещё не битых — сыщик выбирает, с кем драться первым. Варианты
	# едут тем же каналом, что выбор типа встречи: "combat:<индекс на клетке>".
	var choices: Array = []
	for i_v: Variant in pending:
		choices.append("combat:%d" % int(i_v))
	_gs.encounter_choices = choices
	_gs.current_encounter = {}
	GameConsole.log("[Бой] %s выбирает порядок: %d монстров" % [_gs.name_of(pid), pending.size()])
	_gs.broadcast_sync()
	_gs.emit_changed()
	return NEXT_ORDER


## Индексы монстров клетки, с которыми в этом ходу ещё не дрались.
func unfought_indices(loc: String) -> Array:
	var out: Array = []
	var mons: Array = _gs.monsters.get(loc, [])
	for i in range(mons.size()):
		var inst_v: Variant = mons[i]
		if inst_v is Dictionary and bool((inst_v as Dictionary).get("fought", false)):
			continue
		out.append(i)
	return out


## Новый ход встречи — пометки прошлого хода снимаем, иначе монстр, выживший в
## прошлый раз, считался бы «уже битым» и сегодня.
func clear_fought(loc: String) -> void:
	var mons: Array = _gs.monsters.get(loc, [])
	for i in range(mons.size()):
		if mons[i] is Dictionary:
			(mons[i] as Dictionary).erase("fought")


## Пометить экземпляр «в этом ходу бой был». Легаси-строку нормализуем в словарь,
## иначе пометку некуда положить.
func mark_fought(loc: String, idx: int) -> void:
	var mons: Array = _gs.monsters.get(loc, [])
	if idx < 0 or idx >= mons.size():
		return
	var inst_v: Variant = mons[idx]
	var inst: Dictionary = inst_v if inst_v is Dictionary else {"id": String(inst_v)}
	inst["fought"] = true
	mons[idx] = inst
	_gs.monsters[loc] = mons


# ── Схватка: Воля → Сила ────────────────────────────────────────────────────────


## Хост: собрать боевую «карту» по монстру idx на локации игрока и открыть шаг Воли
## (или сразу Силы — у монстра без ужаса). false — драться не с кем (монстра нет /
## неизвестен): вызывающий (EncounterFlow) генерит обычную встречу.
func begin(pid: String, idx: int = 0) -> bool:
	if not _gs.is_host():
		return true
	var loc: String = String(_gs.players[pid].get("location", ""))
	var mons: Array = _gs.monsters.get(loc, [])
	if (mons as Array).is_empty():
		return false  # монстра нет — обычная встреча (страховка вызывающего)
	if idx < 0 or idx >= mons.size():
		idx = 0  # битый индекс (монстр снят между выбором и боем) — первый
	# Экземпляр может быть {id, health} (новый формат) или просто id-строкой
	# (легаси из старой сессии) — читаем устойчиво.
	var inst_v: Variant = mons[idx]
	var mid: String = String(inst_v.get("id", "")) if inst_v is Dictionary else String(inst_v)
	var inst_health: int = (
		int((inst_v as Dictionary).get("health", -1)) if inst_v is Dictionary else -1
	)
	var m: Dictionary = MonsterCatalog.by_id(mid)
	if m.is_empty():
		return false
	# Стойкость — по тому же авторитету размера партии, что и спаун (board_state),
	# иначе шкала боя расходится с hp, с которым монстр реально появился.
	var inv_count: int = _gs._campaign.balance_player_count()
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
		"monsterIndex": idx,  # какой именно экземпляр на клетке — по нему снимаем/лечим
	}
	_gs.announce_action(pid, "combat", {"monster": String(m.get("nameKey", mid))})  # лента: бой
	if String((m.get("horror", {}) as Dictionary).get("skill", "will")) == "none":
		# Монстр без ужаса (Riot, Tick Tock Men, Child of the Goat): шага Воли нет —
		# Волю «замораживаем» пустой и сразу открываем pre-roll Силы.
		var enc: Dictionary = _gs.current_encounter
		enc["will"] = {"dice": [], "successes": 0}
		enc["sanity_loss"] = 0
		enc["no_horror_step"] = true
		var cb0: Dictionary = m.get("combat", {})
		_gs._check.start(
			"combat",
			pid,
			String(cb0.get("skill", "strength")),
			int(cb0.get("modifier", 0)),
			"combatEncounter"
		)
	else:
		_start_will(pid)  # проверка Воли (pre-roll) — окно активации карт до броска
	GameConsole.log("[Бой] %s vs %s (здоровье %d/%d)" % [_gs.name_of(pid), mid, cur, tough])
	_gs.broadcast_sync()
	_gs.emit_changed()
	return true


# Старт проверки ВОЛИ боя (pre-roll, контекст combatEncounter) — единый механизм
# CheckFlow: активация карт/перебросы как у встреч. Навык/модификатор — из horror.
func _start_will(pid: String) -> void:
	var h: Dictionary = _gs.current_encounter.get("horror", {})
	_gs._check.start(
		"combat", pid, String(h.get("skill", "will")), int(h.get("modifier", 0)), "combatEncounter"
	)


# Хост: бой в ДВА отдельных броска (одна кнопка — один шаг). Раундов/отступления нет.
#   Шаг 1 — ВОЛЯ (ужас): успехи блокируют урон по рассудку (max(0, horror.damage − успехи)).
#   Шаг 2 — СИЛА (атака): успехи и снижают урон по сыщику (max(0, combat.damage − успехи)),
#           и наносят столько же урона монстру. Здоровье монстра сохраняется
#           между боями; при 0 — монстр повержен и снят с локации.
func resolve(pid: String) -> bool:
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
		var w_succ: int = int(c.get("successes", 0))
		enc["will"] = {"dice": (c.get("dice", []) as Array).duplicate(), "successes": w_succ}
		enc["sanity_loss"] = sanity_loss_for(enc, pid, w_succ)
		# Спец-способность: успехи проверки ужаса ранят монстра (Призрак — «отнимаете
		# здоровье, равное результату»). Урон не физический — резист не режет.
		if bool(horror.get("damageWithSuccesses", false)):
			enc["will_dealt"] = w_succ
		# Спец-способность: после проверки ужаса бросок кубика, на гранях faces монстр
		# побеждён (Цвет иных миров — «5-6»). Кубик виден в ленте и на карте боя.
		var faces: String = String(horror.get("defeatOnDie", ""))
		if not faces.is_empty():
			var die: int = Dice.roll_one()
			enc["ability_die"] = die
			_gs.announce_action(pid, "die_roll", {"value": str(die)})
			if Dice.face_matches(faces, die):
				enc["defeated_on_horror"] = true
				enc["resolution"] = {
					"won": true,
					"strength": {"dice": [], "successes": 0},
					"hp_loss": 0,
					"dealt": int(enc.get("toughness", 0)),
					"health_after": 0,
				}
				_gs._check.clear()
				GameConsole.log(
					"[Бой] %s · кубик способности %d → монстр повержен" % [_gs.name_of(pid), die]
				)
				_gs.broadcast_sync()
				_gs.emit_changed()
				return true
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
				"[Бой] %s · прошёл проверку → монстр повержен (без боя)" % _gs.name_of(pid)
			)
			_gs.broadcast_sync()
			_gs.emit_changed()
			return true
		var cb: Dictionary = enc.get("combat", {})
		# Монстр без атаки (combat.skill "none" — Призрак): шага Силы нет, итог боя —
		# сразу по урону от Воли; сыщик урона не получает.
		if String(cb.get("skill", "strength")) == "none":
			var will_dealt: int = int(enc.get("will_dealt", 0))
			var left: int = maxi(0, int(enc.get("health", 0)) - will_dealt)
			enc["no_strength_step"] = true
			enc["resolution"] = {
				"won": left <= 0,
				"strength": {"dice": [], "successes": 0},
				"hp_loss": 0,
				"dealt": will_dealt,
				"health_after": left,
			}
			_gs._check.clear()
			GameConsole.log(
				(
					"[Бой] %s · Воля %d → монстру −%d (здоровье %d), атаки нет"
					% [_gs.name_of(pid), w_succ, will_dealt, left]
				)
			)
			_gs.broadcast_sync()
			_gs.emit_changed()
			return true
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
				% [_gs.name_of(pid), w_succ, int(enc["sanity_loss"])]
			)
		)
		_gs.broadcast_sync()
		_gs.emit_changed()
		return true

	# ── Шаг 2: СИЛА (атака) ── Сила стартована в pre-roll («Дальше»). Первое нажатие —
	# бросок; затем «Завершить» (FINISH_ENCOUNTER → _commit_combat) фиксирует итог.
	if not bool(c.get("rolled", false)):
		return _gs._check.roll(pid)
	return false  # Сила брошена — дальше «Завершить»


# Итог боя из стартового здоровья монстра (enc.health) и активной проверки Силы —
# чистый расчёт без применения (для _commit_combat).
func resolution(enc: Dictionary, c: Dictionary, pid: String) -> Dictionary:
	var cb: Dictionary = enc.get("combat", {})
	var hits: int = int(c.get("successes", 0))
	# Боевой урон — ФИЗИЧЕСКИЙ: монстр с physical-резистом получает вдвое меньше.
	# (hp_loss игрока — от СЫРОГО броска: защита не зависит от резиста монстра.)
	var m: Dictionary = MonsterCatalog.by_id(String(enc.get("monsterId", "")))
	# + урон от успехов Воли (damageWithSuccesses), он резистом не режется.
	var dealt: int = (
		MonsterCatalog.apply_resistance(m, hits, "physical") + int(enc.get("will_dealt", 0))
	)
	var health_after: int = maxi(0, int(enc.get("health", 0)) - dealt)
	# Пассивная защита от урона (Fishing Net и т.п., whileOwned) — авто, урон монстра
	# по сыщику снижается ДО вычитания успехов Силы (пол min).
	var cd: int = AssetCatalog.apply_combat_reduce(
		int(cb.get("damage", 0)),
		AssetCatalog.owned_combat_reduce(
			_gs.players.get(pid, {}).get("items", []), "reduceMonsterDamage"
		)
	)
	return {
		"won": health_after <= 0,
		"strength": {"dice": (c.get("dice", []) as Array).duplicate(), "successes": hits},
		"hp_loss": maxi(0, cd - hits),
		"dealt": dealt,
		"health_after": health_after,
	}


## Урон по рассудку от ужаса монстра за вычетом успехов Воли. Пассивная защита от
## ужаса (Elder Sign и т.п., whileOwned) — авто: урон снижается ДО вычитания
## успехов (пол min). Один расчёт для заморозки Воли и для окна предотвращения.
func sanity_loss_for(enc: Dictionary, pid: String, will_successes: int) -> int:
	var hd: int = AssetCatalog.apply_combat_reduce(
		int((enc.get("horror", {}) as Dictionary).get("damage", 0)),
		AssetCatalog.owned_combat_reduce(
			_gs.players.get(pid, {}).get("items", []), "reduceMonsterHorror"
		)
	)
	return maxi(0, hd - will_successes)


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


# ── Фиксация итога ──────────────────────────────────────────────────────────────


# Применение итогов боя при завершении: потеря рассудка (Воля) + урон сыщику и
# судьба монстра (Сила). Эффекты отвязаны от бросков ради переброса.
func commit(pid: String) -> void:
	var enc: Dictionary = _gs.current_encounter
	var p: Dictionary = _gs.players[pid]
	var before_combat: Dictionary = (p as Dictionary).duplicate(true)
	var sl: int = maxi(0, int(enc.get("sanity_loss", 0)) - int(enc.get("prevented_sanity", 0)))
	if sl > 0:
		p["sanity"] = maxi(0, int(p.get("sanity", 0)) - sl)
	# Зафиксировать итог Силы из активной проверки (если ещё не зафиксирован).
	if not enc.has("resolution"):
		enc["resolution"] = resolution(enc, _gs.active_check, pid)
	var r: Dictionary = enc["resolution"]
	var won: bool = bool(r.get("won", false))
	var mon_name: String = String(enc.get("monsterName", ""))
	_gs.announce_action(pid, "combat_won" if won else "combat_lost", {"monster": mon_name})
	# Предотвращённое бинтами (и подобным) вычитаем ДО списания: карты играются в
	# окне между броском и «Завершить», их вклад копится в prevented_hp.
	var hp_loss: int = maxi(0, int(r.get("hp_loss", 0)) - int(enc.get("prevented_hp", 0)))
	if hp_loss > 0:
		p["hp"] = maxi(0, int(p.get("hp", 0)) - hp_loss)
	ActionFeed.announce_deltas(_gs, pid, before_combat, p)  # лента: урон/рассудок от боя
	var loc: String = String(p.get("location", ""))
	var idx: int = int(enc.get("monsterIndex", 0))
	if bool(r.get("won", false)):
		_remove_monster_instance(loc, idx)
		_gs._board.return_monster_to_bag(String(enc.get("monsterId", "")))  # монстр умер → в мешок
		_gs._rumor.notify_monster_defeated(loc)  # Слух с solve=monsterDefeated развеян
	else:
		_set_monster_health(loc, idx, int(r.get("health_after", 0)))
		mark_fought(loc, idx)  # выжил — но повторно в этом ходу не предлагается
	_gs._check.clear()  # проверка боя завершена — снять active_check


# ── Боевые триггеры карт (effect.triggered on:combatEncounter) ──────────────────


## Хост: боевой триггер карты (effect.triggered, on:"combatEncounter") — напр.
## Handcuffs: потратить фокус → победить монстра ДО проверки Силы, если его стойкость
## ≤ n. true — триггер применён (монстр повержен). false — карта не подходит (нет
## триггера / монстр крепче / нечем платить) → роутер пробует обычный check-mod
## (CheckFlow.activate). Зовётся из GameState.activate_card / relay-router.
func try_trigger(pid: String, item_index: int) -> bool:
	if not _gs.is_host():
		return false
	var node: Dictionary = trigger_node_ready(pid, item_index)
	if node.is_empty():
		return false  # карта не подходит (нет триггера / монстр крепче / нечем платить)
	var p: Dictionary = _gs.players[pid]
	var enc: Dictionary = _gs.current_encounter
	# Стоимость (напр. фокус) — уже проверена в combat_trigger_node_ready, списываем.
	var cost: Dictionary = node.get("cost", {})
	if cost.has("spend"):
		ResourceLedger.spend(p, String(cost.get("spend", "")), int(cost.get("amount", 1)))
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
	GameConsole.log("[Бой] %s · карта-триггер → монстр повержен (без боя)" % _gs.name_of(pid))
	_gs.broadcast_sync()
	_gs.emit_changed()
	return true


## Узел defeatMonster применимого СЕЙЧАС боевого триггера карты (предикат стойкости и
## оплата проходят). {} — карта не подходит. Read-only (без списаний/мутаций) — годится
## и для подсветки карты в веере (любой клиент), и для try_combat_trigger перед
## применением. БЕЗ host-гарда: это логическая применимость, авторитет — у вызывателя.
func trigger_node_ready(pid: String, item_index: int) -> Dictionary:
	if _gs.phase != Phases.ENCOUNTER or _gs.current_pid() != pid or not _gs.players.has(pid):
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
		if not ResourceLedger.can_pay(p, String(cost.get("spend", "")), int(cost.get("amount", 1))):
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
