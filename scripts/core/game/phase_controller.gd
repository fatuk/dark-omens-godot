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

const REST_HEAL_HP: int = 1
const REST_HEAL_SANITY: int = 1

# Пауза перед передачей хода после последнего действия (сек). Даёт действию «вес»
# и оставляет окно под будущие эффекты — ни одно действие не крутит цикл мгновенно.
# В тестах _gs — мок вне дерева сцены, пауза пропускается (поведение синхронное).
static var TURN_DELAY: float = 1.0

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


# ── Действия игрока ──────────────────────────────────────────────────────────


## Доп. лечение отдыха за ресурсы. res_hp/res_san — заявка игрока; применяем в
## пределах resources, свободного места (max − текущее) и cannotRecover-подавления.
## Списываем ровно применённое (нереализованная заявка ресурс не тратит).
func _rest_resources(p: Dictionary, rec: Array, res_hp: int, res_san: int) -> void:
	var avail: int = int(p.get("resources", 0))
	var used: int = 0
	if not rec.has("health"):
		var hp_add: int = clampi(res_hp, 0, mini(avail - used, int(p["hp_max"]) - int(p["hp"])))
		p["hp"] = int(p["hp"]) + hp_add
		used += hp_add
	if not rec.has("sanity"):
		var san_add: int = clampi(
			res_san, 0, mini(avail - used, int(p["sanity_max"]) - int(p["sanity"]))
		)
		p["sanity"] = int(p["sanity"]) + san_add
		used += san_add
	if used > 0:
		p["resources"] = avail - used


## Хост: валидирует и применяет действие игрока. Возвращает true при успехе.
## Зовётся из GameState.perform_action (для своего действия) и из relay-router
## на game_action (для чужого).
func host_apply_action(pid: String, action_type: String, payload: Dictionary = {}) -> bool:
	if _gs.phase != Phases.ACTION:
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

	# whileHeld cannotAct (Detained / Lost in Time): любые действия запрещены, кроме
	# pass и локального действия состояния (condition_action — это escape).
	if (
		action_type != GameActions.PASS
		and action_type != GameActions.CONDITION_ACTION
		and _gs._cond.player_has_constraint(pid, "cannotAct")
	):
		GameConsole.warn("[Game] %s не может действовать (состояние)" % _gs._name_of(pid))
		return false

	# Одно и то же действие нельзя повторять в раунде (pass не в счёт). Каст заклинания
	# — исключение: за ход можно скастить несколько (каждый тратит действие), как
	# Component Action в EH; лимит — только число действий.
	var used: Array = p.get("actions_used", [])
	if (
		action_type != GameActions.PASS
		and action_type != GameActions.CAST_SPELL
		and used.has(action_type)
	):
		GameConsole.warn(
			"[Game] %s — «%s» уже использовано в этом раунде" % [_gs._name_of(pid), action_type]
		)
		return false

	match action_type:
		GameActions.BUY_TICKET:
			# Билет продаётся только в городе; тип — по дорогам города
			# (payload {"type":"train"|"ship"}): train → ж/д, ship → корабль.
			var tkt_type: String = String(payload.get("type", ""))
			if not _gs.available_ticket_types(String(p.get("location", ""))).has(tkt_type):
				GameConsole.warn(
					"[Game] %s — билет «%s» здесь не продаётся" % [_gs._name_of(pid), tkt_type]
				)
				return false
			# Потолок билетов на руках (ж/д + корабль), как в EH.
			if int(p.get("train_tickets", 0)) + int(p.get("ship_tickets", 0)) >= _gs.MAX_TICKETS:
				GameConsole.warn(
					(
						"[Game] %s — нельзя держать больше %d билетов"
						% [_gs._name_of(pid), _gs.MAX_TICKETS]
					)
				)
				return false
			var tkt_field: String = "train_tickets" if tkt_type == "train" else "ship_tickets"
			p[tkt_field] = int(p.get(tkt_field, 0)) + 1
			p["actions_left"] = int(p["actions_left"]) - 1
		GameActions.TAKE_CONCENTRATION:
			# Потолок концентрации — как у билетов; при максимуме действие не тратим.
			if int(p.get("concentration", 0)) >= _gs.MAX_CONCENTRATION:
				GameConsole.warn(
					(
						"[Game] %s — нельзя держать больше %d концентрации"
						% [_gs._name_of(pid), _gs.MAX_CONCENTRATION]
					)
				)
				return false
			p["concentration"] = int(p.get("concentration", 0)) + 1
			p["actions_left"] = int(p["actions_left"]) - 1
		GameActions.TAKE_RESOURCE:
			# Потолок ресурсов — как у концентрации; при максимуме действие не тратим.
			if int(p.get("resources", 0)) >= _gs.MAX_RESOURCES:
				GameConsole.warn(
					(
						"[Game] %s — нельзя держать больше %d ресурсов"
						% [_gs._name_of(pid), _gs.MAX_RESOURCES]
					)
				)
				return false
			p["resources"] = int(p.get("resources", 0)) + 1
			p["actions_left"] = int(p["actions_left"]) - 1
		GameActions.REST:
			# whileHeld cannotRecover + triggered on:rest (Hypothermia: не лечит здоровье
			# + бросок 4-6 сбросить). fire_triggered исполняет dieRoll/сброс и возвращает
			# дополнительные cannotRecover-статы для подавления лечения этого отдыха.
			var rec: Array = _gs._cond.player_constraints(pid).get("cannotRecover", [])
			rec.append_array(_gs._cond.fire_triggered(pid, GameActions.REST))
			if not rec.has("health"):
				p["hp"] = mini(int(p["hp_max"]), int(p["hp"]) + REST_HEAL_HP)
			if not rec.has("sanity"):
				p["sanity"] = mini(int(p["sanity_max"]), int(p["sanity"]) + REST_HEAL_SANITY)
			# Трата ресурсов на доп. лечение (payload res_hp/res_san): каждый ресурс —
			# +1 к здоровью ИЛИ рассудку; списываем ровно применённое (см. _rest_resources).
			_rest_resources(p, rec, int(payload.get("res_hp", 0)), int(payload.get("res_san", 0)))
			# onRest-заклинания НЕ кастуем автоматически — выставляем промпт выбора
			# (Healing Words и пр. опциональны). Если промпт выставлен, держим ход до
			# резолва (как магазин): передача — в host_apply_cast_trigger_spells.
			if _gs._spell.prompt_trigger(pid, "onRest"):
				p["spell_prompt"] = true
			p["actions_left"] = int(p["actions_left"]) - 1
		GameActions.TRAVEL:
			var dest: String = String(payload.get("to", ""))
			if not can_travel(pid, dest):
				GameConsole.warn("[Game] %s — недопустимое перемещение" % _gs._name_of(pid))
				return false
			# Стоимость и путь по планировщику: базовый хоп бесплатен, доп. хопы
			# оплачены билетами (train/ship). Списываем ровно израсходованное.
			var here_travel: String = String(p.get("location", ""))
			var plan: Dictionary = TravelPlanner.cost_to(
				_gs._load_locations(),
				here_travel,
				dest,
				int(p.get("train_tickets", 0)),
				int(p.get("ship_tickets", 0))
			)
			p["train_tickets"] = int(p.get("train_tickets", 0)) - int(plan.get("train", 0))
			p["ship_tickets"] = int(p.get("ship_tickets", 0)) - int(plan.get("ship", 0))
			# Путь (сегменты) — для посегментной анимации на клиентах.
			p[PlayerKeys.TRAVEL_PATH] = plan.get("path", [here_travel, dest])
			p["location"] = dest
			p["actions_left"] = int(p["actions_left"]) - 1
		GameActions.TRADE:
			# Обмен предметами/уликами с со-локационным напарником (атомарно).
			if not _apply_trade(pid, payload):
				return false
			p["actions_left"] = int(p["actions_left"]) - 1
		GameActions.ACQUIRE_ASSETS:
			# Поход в магазин — уникальное действие (раз за раунд). Фиксируется уже
			# при БРОСКЕ кубов: тратит действие сразу, поэтому отмена покупки не
			# вернёт возможность снова пойти в магазин. Сами товары выдаются позже
			# (host_apply_shop_grant по кнопке «Купить»).
			if _gs.location_type(String(p.get("location", ""))) != "city":
				GameConsole.warn("[Магазин] %s не в городе" % _gs._name_of(pid))
				return false
			p["actions_left"] = int(p["actions_left"]) - 1
			p["shopping"] = true  # не передаём ход, пока магазин открыт
			GameConsole.log("[Магазин] %s пошёл за покупками" % _gs._name_of(pid))
			# Бросок Влияния — через единую проверку (CheckFlow). Проверка уже
			# стартована при открытии магазина (pre-roll, с учётом активированных
			# карт); страховка — если её нет, стартуем здесь. Монеты = успехи.
			if String(_gs.active_check.get("owner", "")) != "shop":
				_gs._check.start("shop", pid, "influence", 0, "acquireAssets")
			_gs._check.roll(pid)
		GameActions.CONDITION_ACTION:
			# Локальное действие состояния (escape, напр. Detained: Влияние → сброс).
			# С проверкой → ОБЩИЙ движок test: видимая проверка через pending_check;
			# держим ход (condition_acting) до «Применить» (resolve_pending_check →
			# resolve_action_check → release_condition_turn). Без проверки → синхронно.
			var cond_id: String = String(payload.get("condition", ""))
			if _gs._cond.begin_action(pid, cond_id):
				p["condition_acting"] = true
				p["actions_left"] = int(p["actions_left"]) - 1
			elif _gs._cond.host_run_condition_action(pid, cond_id):
				p["actions_left"] = int(p["actions_left"]) - 1
			else:
				GameConsole.warn(
					"[Game] %s — нет локального действия состояния" % _gs._name_of(pid)
				)
				return false
		GameActions.CAST_SPELL:
			# Ritual-заклинание: каст = действие. begin_ritual стартует spell-проверку
			# (БЕЗ броска); игрок бросает/перебрасывает в модалке и жмёт «Применить»
			# (apply_cast → release_cast_turn). casting держит ход до применения, как
			# shopping для магазина. false — карта невалидна (действие не тратим).
			if not _gs._spell.begin_ritual(pid, int(payload.get("item", -1))):
				GameConsole.warn("[Заклинание] %s — нельзя прочитать" % _gs._name_of(pid))
				return false
			p["casting"] = true
			p["actions_left"] = int(p["actions_left"]) - 1
		GameActions.PASS:
			p["actions_left"] = 0
		_:
			GameConsole.warn("[Game] Неизвестное действие: %s" % action_type)
			return false

	# cast_spell не отмечаем (можно кастовать несколько за ход — лимит лишь по действиям).
	if action_type != GameActions.PASS and action_type != GameActions.CAST_SPELL:
		used.append(action_type)
		p["actions_used"] = used

	_announce_action_feed(pid, action_type, payload)  # облачко над фишкой: все видят действие

	GameConsole.log(
		(
			"[Game] %s · %s · осталось действий: %d"
			% [_gs._name_of(pid), action_type, int(p["actions_left"])]
		)
	)
	# Пока игрок в магазине (модалка открыта) или висит промпт выбора заклинаний
	# (отдых) — ход не передаём, даже если это было последнее действие. Передача:
	# host_apply_shop_close / host_apply_cast_trigger_spells.
	if (
		int(p["actions_left"]) == 0
		and not bool(p.get("shopping", false))
		and not bool(p.get("spell_prompt", false))
		and not bool(p.get("casting", false))
		and not bool(p.get("condition_acting", false))
	):
		_advance_turn_delayed()

	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# Транзиентная «лента действий»: над фишкой игрока всплывает облачко с литературным описанием
# (ActionLog) — все видят, что он делает. Зовётся ПОСЛЕ успешного коммита. params — i18n-ключи
# (локация/состояние), клиент сам tr(). pass не анонсируем (шум), исход боя — в encounter_flow.
func _announce_action_feed(pid: String, action_type: String, payload: Dictionary) -> void:
	match action_type:
		GameActions.TRAVEL:
			var dest: String = String(payload.get("to", ""))
			_gs.announce_action(pid, GameActions.TRAVEL, {"place": _gs.loc_name_key(dest)})
		GameActions.CONDITION_ACTION:
			var cid: String = String(payload.get("condition", ""))
			_gs.announce_action(
				pid, GameActions.CONDITION_ACTION, {"condition": Conditions.name_key(cid)}
			)
		GameActions.BUY_TICKET, GameActions.TAKE_CONCENTRATION, GameActions.TAKE_RESOURCE:
			_gs.announce_action(pid, action_type)
		GameActions.REST, GameActions.TRADE, GameActions.ACQUIRE_ASSETS, GameActions.CAST_SPELL:
			_gs.announce_action(pid, action_type)
		# GameActions.PASS — не анонсируем


## Хост: игрок подтвердил выбор триггер-заклинаний в промпте отдыха (item-индексы;
## пустой список — «ничего не кастить»). Резолвим выбранные касты (SpellFlow чистит
## pending_spell_cast) и, если отдых был последним действием, передаём отложенный
## ход (как закрытие магазина). Зовётся из GameState.cast_trigger_spells и relay.
func host_apply_cast_trigger_spells(pid: String, indices: Array) -> bool:
	if not _gs._spell.host_apply_trigger_spells(pid, indices):
		return false
	var p: Dictionary = _gs.players.get(pid, {})
	p.erase("spell_prompt")
	if int(p.get("actions_left", 0)) == 0 and not bool(p.get("shopping", false)):
		_advance_turn_delayed()
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# Хост: применить «Обмен» — перенос предметов/улик между активным игроком и
# со-локационным напарником. payload: {partner, give:[idx в me.items],
# take:[idx в ally.items], giveClues, takeClues}. Атомарно: всё валидируется ДО
# переноса; невалид → false (действие не тратится). Невыбранные предметы не двигаются.
func _apply_trade(pid: String, payload: Dictionary) -> bool:
	var partner: String = String(payload.get("partner", ""))
	if partner.is_empty() or partner == pid or not _gs.players.has(partner):
		return false
	var me: Dictionary = _gs.players[pid]
	var ally: Dictionary = _gs.players[partner]
	if bool(me.get("dead", false)) or bool(ally.get("dead", false)):
		return false  # Тень не торгует (ни как инициатор, ни как партнёр)
	if String(me.get("location", "")) != String(ally.get("location", "")):
		GameConsole.warn(
			"[Обмен] %s и %s не на одной локации" % [_gs._name_of(pid), _gs._name_of(partner)]
		)
		return false
	var give: Array = payload.get("give", [])
	var take: Array = payload.get("take", [])
	var my_items: Array = me.get("items", [])
	var ally_items: Array = ally.get("items", [])
	if not _valid_indices(give, my_items.size()) or not _valid_indices(take, ally_items.size()):
		return false
	var give_clues: int = maxi(0, int(payload.get("giveClues", 0)))
	var take_clues: int = maxi(0, int(payload.get("takeClues", 0)))
	if give_clues > int(me.get("clues", 0)) or take_clues > int(ally.get("clues", 0)):
		return false
	# Разнести: выбранные уходят, невыбранные остаются на местах.
	var give_set: Dictionary = {}
	for i_v: Variant in give:
		give_set[int(i_v)] = true
	var take_set: Dictionary = {}
	for i_v: Variant in take:
		take_set[int(i_v)] = true
	var out_items: Array = []
	var keep_mine: Array = []
	for i in range(my_items.size()):
		(out_items if give_set.has(i) else keep_mine).append(my_items[i])
	var in_items: Array = []
	var keep_ally: Array = []
	for i in range(ally_items.size()):
		(in_items if take_set.has(i) else keep_ally).append(ally_items[i])
	keep_mine.append_array(in_items)
	keep_ally.append_array(out_items)
	me["items"] = keep_mine
	ally["items"] = keep_ally
	me["clues"] = int(me.get("clues", 0)) - give_clues + take_clues
	ally["clues"] = int(ally.get("clues", 0)) - take_clues + give_clues
	(
		GameConsole
		. log(
			(
				"[Обмен] %s ↔ %s: отдал %d предм./%d улик, взял %d предм./%d улик"
				% [
					_gs._name_of(pid),
					_gs._name_of(partner),
					out_items.size(),
					give_clues,
					in_items.size(),
					take_clues,
				]
			)
		)
	)
	return true


# Все элементы idx — валидные позиции массива размера size (0..size−1).
func _valid_indices(idx: Array, size: int) -> bool:
	for i_v: Variant in idx:
		var i: int = int(i_v)
		if i < 0 or i >= size:
			return false
	return true


## Хост: выдать купленные ассеты. Действие уже потрачено при броске
## (acquire_assets в actions_used), поэтому очередь/лимит тут не проверяем — только
## что игрок реально начал поход в магазин в этом раунде и стоит в городе.
func host_apply_shop_grant(pid: String, assets: Array) -> bool:
	if not _gs.players.has(pid) or assets.is_empty():
		return false
	var p: Dictionary = _gs.players[pid]
	if not (p.get("actions_used", []) as Array).has(GameActions.ACQUIRE_ASSETS):
		return false
	if _gs.location_type(String(p.get("location", ""))) != "city":
		return false
	# Валидируем покупку по авторитетным данным хоста, а не по доверию клиенту:
	# успехи считаем только из активной проверки магазина (иначе монеты неизвестны).
	if String(_gs.active_check.get("owner", "")) != "shop":
		return false
	# Монеты = успехи броска + бонус за «Долг» (как считает клиент, shop_modal._coins).
	# Долг из прошлого похода мог бы дать лишние +2, но повторный debt запрещён —
	# в худшем случае переоценка на 2, что безопаснее ложного отказа в покупке.
	var coins: int = int(_gs.active_check.get("successes", 0))
	if (p.get("conditions", []) as Array).has("debt"):
		coins += 2
	coins += int(_gs.active_check.get("shop_resource_coins", 0))  # потраченные ресурсы = монеты
	# Каждый товар обязан лежать на витрине (shop_reserve), суммарная стоимость —
	# укладываться в монеты. Иначе баг/чит клиента выдал бы бесплатные или чужие карты.
	var reserve: Array = _gs.shop_reserve
	var total_cost: int = 0
	for aid_v: Variant in assets:
		var aid: String = String(aid_v)
		var a: Dictionary = AssetCatalog.by_id(aid)
		if a.is_empty() or not reserve.has(aid):
			GameConsole.log(
				"[Магазин] %s: товар %s не на витрине — отказ" % [_gs._name_of(pid), aid]
			)
			return false
		total_cost += int(a.get("cost", 0))
	if total_cost > coins:
		GameConsole.log(
			(
				"[Магазин] %s: не хватает монет (%d > %d) — отказ"
				% [_gs._name_of(pid), total_cost, coins]
			)
		)
		return false
	for aid_v: Variant in assets:
		_gs._cond.host_grant_asset(pid, String(aid_v))  # исполнит onGain (сервисы срабатывают и сбрасываются)
	_gs._refill_shop_reserve(assets)  # купленные → заменить новыми
	GameConsole.log(
		"[Магазин] %s купил %d товар(ов) за %d" % [_gs._name_of(pid), assets.size(), total_cost]
	)
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


## Хост: каст применён («Применить») — снимаем удержание хода casting и, если
## действий не осталось, передаём отложенный ход (как закрытие магазина). Зовётся из
## SpellFlow.apply_cast (только ritual — glamour/incantation не тратят действие).
func release_cast_turn(pid: String) -> void:
	if not _gs.players.has(pid):
		return
	var p: Dictionary = _gs.players[pid]
	var was_casting: bool = bool(p.get("casting", false))
	p["casting"] = false
	if was_casting and int(p.get("actions_left", 0)) == 0:
		_advance_turn_delayed()


## Хост: локальное действие состояния завершено — снимаем удержание хода condition_acting
## и, если действий не осталось, передаём отложенный ход. Зовётся из
## ConditionFlow._run_action_program (зеркало release_cast_turn).
func release_condition_turn(pid: String) -> void:
	if not _gs.players.has(pid):
		return
	var p: Dictionary = _gs.players[pid]
	var was_acting: bool = bool(p.get("condition_acting", false))
	p["condition_acting"] = false
	if was_acting and int(p.get("actions_left", 0)) == 0:
		_advance_turn_delayed()


## Хост: магазин закрыт. Снимаем флаг shopping и, если действий не осталось,
## только теперь передаём ход (отложенная передача после похода в магазин).
func host_apply_shop_close(pid: String) -> bool:
	if not _gs.players.has(pid):
		return false
	var p: Dictionary = _gs.players[pid]
	# Магазин могли открыть без броска (проверка стартует на открытии) — снимаем
	# pre-roll проверку в любом случае.
	if String(_gs.active_check.get("owner", "")) == "shop":
		_gs._check.clear()
	var was_shopping: bool = bool(p.get("shopping", false))
	p["shopping"] = false
	if was_shopping and int(p.get("actions_left", 0)) == 0:
		_advance_turn_delayed()
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


## Хост: игрок тратит ресурс в магазине — −1 ресурс, +1 монета (успех) в этой
## сессии магазина. Копится в active_check.shop_resource_coins (синкается; учитывается
## host_apply_shop_grant при валидации покупки, как бонус долга). Только пока магазин
## открыт (active_check.owner == "shop") и у сыщика есть ресурс.
func host_apply_shop_spend_resource(pid: String) -> bool:
	if not _gs.players.has(pid):
		return false
	# Только активный покупатель (владелец shop-проверки) тратит свой ресурс.
	if String(_gs.active_check.get("owner", "")) != "shop":
		return false
	if String(_gs.active_check.get("pid", "")) != pid:
		return false
	var p: Dictionary = _gs.players[pid]
	if int(p.get("resources", 0)) <= 0:
		return false
	p["resources"] = int(p.get("resources", 0)) - 1
	_gs.active_check["shop_resource_coins"] = (
		int(_gs.active_check.get("shop_resource_coins", 0)) + 1
	)
	GameConsole.log("[Магазин] %s потратил ресурс (+1 монета)" % _gs._name_of(pid))
	_gs._broadcast_sync()
	_gs._emit_changed()
	return true


# Переброс куба магазина теперь идёт через единый CheckFlow.reroll (active_check):
# бесплатные перебросы от карт → концентрация → улика. См. GameState.shop_reroll.


## Хост: игрок завершил встречу — отметить и передать ход дальше.
## Возвращает true при успехе. Зовётся из GameState.finish_encounter и из
## relay-router на game_finish_encounter.
func host_apply_finish_encounter(pid: String) -> bool:
	if _gs.phase != Phases.ENCOUNTER:
		return false
	if not _gs.players.has(pid):
		return false
	if _gs.players[pid].get("encounter_done", false):
		return false
	# Встречи проходят по очереди — только активный игрок может завершить.
	if _gs._current_pid() != pid:
		GameConsole.warn("[Game] %s завершает встречу не в свой ход" % _gs._name_of(pid))
		return false
	return _commit_and_advance(pid)


## Хост: игрок выбрал ветку интерактивного choice в эффектах встречи. Записываем
## решение и переигрываем коммит (если выбор закрыл паузу — ход идёт дальше).
## Зовётся из GameState.choose_effect и relay-router на game_choose_effect.
func host_apply_effect_choice(pid: String, index: int) -> bool:
	if _gs.phase != Phases.ENCOUNTER or not _gs.players.has(pid):
		return false
	if _gs._current_pid() != pid:
		return false
	if not _gs._encounter.record_effect_choice(pid, index):
		return false
	return _commit_and_advance(pid)


## Хост: сыщик выбрал ветку в forEach-проходе Мифов. Клампим индекс к числу веток,
## кладём в mythos_decision.picked и будим ожидающую корутину MythosFlow сигналом.
## Зовётся из GameState.decide_mythos и relay-router на game_mythos_decide.
func host_apply_mythos_decision(pid: String, index: int) -> void:
	var md: Dictionary = _gs.mythos_decision
	if not bool(md.get("active", false)) or String(md.get("pid", "")) != pid:
		return
	var opts: Array = md.get("options", [])
	var safe: int = clampi(index, 0, maxi(0, (opts as Array).size() - 1))
	md["picked"] = safe
	_gs.mythos_decision = md
	_gs.mythos_decided.emit(safe)


# Применить итоговые эффекты встречи и, если они полностью применились (не ждут
# выбора игрока), передать ход дальше. Если коммит встал на паузу из-за choice —
# просто синкаем состояние с pending_choice (модалка покажет выбор), ход замирает.
func _commit_and_advance(pid: String) -> bool:
	# Применяем итоговые эффекты встречи ЗДЕСЬ (не при броске) — чтобы между
	# броском и завершением был доступен переброс за концентрацию.
	_gs._encounter._commit_outcome(pid)

	# Интерактивный choice не разрешён — ход замирает, ждём выбора игрока.
	if not bool(_gs.current_encounter.get("committed", false)):
		_gs._broadcast_sync()
		_gs._emit_changed()
		return true

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
	_gs.pending_spell_cast = {}  # абандон висящего spell-промпта при смене хода
	_gs.current_idx += 1
	if not skip_disconnected():
		enter_encounter()


## Передать ход с паузой TURN_DELAY: клиенты успевают «доиграть» действие/эффект,
## только потом ход уходит. В тестах (_gs вне дерева) — сразу, без паузы, а
## бродкаст делает вызывающий (как раньше). В игре — ждём таймер, затем сами
## бродкастим уже сменившийся ход (вызывающий бродкастнул состояние до паузы).
func _advance_turn_delayed() -> void:
	if TURN_DELAY > 0.0 and _gs.is_inside_tree():
		await _gs.get_tree().create_timer(TURN_DELAY).timeout
		advance_action_turn()
		_gs._broadcast_sync()
		_gs._emit_changed()
	else:
		advance_action_turn()


## Войти в фазу encounter с первого подключённого игрока. Сбрасывает
## encounter_done у всех, запускает _encounter.generate. Если живых игроков
## не осталось — пропуск сразу в mythos.
func enter_encounter() -> void:
	_gs.phase = Phases.ENCOUNTER
	_gs.current_idx = 0  # первый игрок начинает встречу, остальные ждут своей очереди
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
	_gs.round_num += 1
	_gs.phase = Phases.ACTION
	_gs.current_idx = 0
	_gs.pending_spell_cast = {}
	for pid: String in _gs.players:
		_gs.players[pid]["actions_left"] = _gs.ACTIONS_PER_ROUND
		_gs.players[pid]["actions_used"] = []
		_gs.players[pid]["encounter_done"] = false
		_gs.players[pid]["ghost_acted_this_round"] = false  # Тень снова может действовать
		_gs._refresh_items(_gs.players[pid])  # снять истощение активов (Refresh-шаг)
	_gs._death.clear_grace()  # новый раунд — снять иммунитет выживших на Пороге
	skip_disconnected()  # начинаем раунд с первого подключённого игрока
	GameConsole.log("[Game] Раунд %d · ход: %s" % [_gs.round_num, _gs._name_of(_gs._current_pid())])
	_gs.phase_changed.emit(_gs.phase)


## Прокрутить current_idx мимо отключённых И погибших (Тень не берёт обычный ход).
## true — остановились на живом подключённом игроке; false — досмотрели turn_order
## до конца (ходить некому — все отключены/мертвы).
func skip_disconnected() -> bool:
	while _gs.current_idx < _gs.turn_order.size():
		var pid: String = _gs.turn_order[_gs.current_idx]
		var p: Dictionary = _gs.players.get(pid, {})
		if not p.is_empty() and bool(p.get("connected", true)) and not bool(p.get("dead", false)):
			return true
		_gs.current_idx += 1
	return false


# ── Travel ──────────────────────────────────────────────────────────────────


## Проверка связности: dest достижима из текущей локации игрока pid.
func can_travel(pid: String, dest: String) -> bool:
	if dest.is_empty() or not _gs.players.has(pid):
		return false
	if _gs._cond.player_has_constraint(pid, "cannotMove"):
		return false  # whileHeld cannotMove (Detained / Lost in Time)
	var p: Dictionary = _gs.players[pid]
	var here: String = String(p.get("location", ""))
	if dest == here:
		return false
	# Достижим базовым ходом (1 хоп) ИЛИ доп. хопами, оплаченными билетами на руках.
	return not (
		TravelPlanner
		. cost_to(
			_gs._load_locations(),
			here,
			dest,
			int(p.get("train_tickets", 0)),
			int(p.get("ship_tickets", 0))
		)
		. is_empty()
	)
