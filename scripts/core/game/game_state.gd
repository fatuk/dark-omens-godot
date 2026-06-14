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

signal state_changed  # любое изменение стейта
signal phase_changed(new_phase: String)  # переход фазы

const ACTIONS_PER_ROUND := 2
const MAX_TICKETS := 2  # потолок билетов на руках (ж/д + корабль суммарно), как в EH

# ── Глобальный стейт ──────────────────────────────────────────────────────────
var round_num: int = 0
var phase: String = ""  # "action" | "encounter" | "mythos" | ""
var current_idx: int = 0  # индекс в turn_order активного игрока
var turn_order: Array = []  # [user_id, ...] — отсортирован, стабилен
var doom: int = 0
var omens_step: int = 0
var active: bool = false  # игра запущена?

# Карта встречи активного игрока (фаза encounter). {} — ещё генерится либо
# встреч сейчас нет. Хост генерит через ContentApi и кладёт сюда, рассылает
# синком всем.
var current_encounter: Dictionary = {}

# Единая активная проверка (встреча/магазин/бой) — хост-авторитетна, синкается.
# Управляется CheckFlow (_check); потоки начинают проверку и читают результат.
# {} — активной проверки нет. См. check_flow.gd.
var active_check: Dictionary = {}

# Стек сохранённых проверок (хост-локальный, НЕ синкается): CheckFlow.push/pop для
# вложенного каста — incantation запускает свою spell-проверку поверх боевой, на
# «Применить» боевая возвращается. В каждый момент синкнутый active_check — видимая.
var _check_stack: Array = []

# Промпт «какие триггер-заклинания скастить» (напр. при отдыхе): { pid, event,
# options:[{index, id}] }. {} — промпта нет. Хост-авторитетно, синкается; решает
# только владелец pid (cast_trigger_spells). См. SpellFlow.prompt_trigger.
var pending_spell_cast: Dictionary = {}

# Результат последнего каста для модалки расплаты: { pid, spell, back, text (flavor-
# ключ оборота), successes, outcome:{health,sanity,clues,conditions,discarded} }.
# {} — нет. Хост-авторитетно, синкается; модалку показывает владелец pid и сам её
# закрывает (dismiss_cast_result). Не привязан к ходу. См. SpellFlow.resolve_cast.
var last_cast_result: Dictionary = {}

# Результаты флипа состояний на Расплате, per-player, для модалки: {pid: {cid, back,
# name, text}}. Заполняет ConditionFlow._flip_condition; показывает владельцу pid,
# он же закрывает (dismiss_reckoning_result). Хост-авторитетно, синкается.
var reckoning_results: Dictionary = {}

# UI-локально: «заряженная» жетоном валюта переброса ("concentration"/"clue"/"") —
# игрок закинул жетон на проверку, следующий тап по кубу тратит ИМЕННО её. Не
# синкается (намерение локального игрока), потребляется в reroll_die.
var pending_reroll_currency: String = ""

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
#   train_tickets, ship_tickets, concentration, hp, sanity, hp_max, sanity_max,
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

# Витрина магазина (синкается) — список id выложенных «лицом» ассетов. После
# покупки купленные заменяются новыми (см. _refill_shop_reserve).
const SHOP_RESERVE_SIZE: int = 4
var shop_reserve: Array = []

# ── Цикл Тайн (синкается) ────────────────────────────────────────────────────
# Активная Тайна — индекс 0/1/2 в campaign.mysteries[]. Не от doom: акт = это+1.
# Партия проходит Тайны по порядку; каждая решается набором «зачётов» помеченных
# локаций через двух-фазную mystery-встречу (см. encounter_flow + effect_runner).
var active_mystery: int = 0
# Сколько локаций активной Тайны уже зачищено (mysteryProgress). При достижении
# solveCondition.n активная Тайна решается, индекс ++ (если уже 3 → outcome).
var mystery_progress: int = 0
# id зачищенных локаций активной Тайны (чтобы они исчезли из выбора встречи).
# При решении Тайны очищается вместе с progress.
var mystery_claimed: Array = []
# Жетоны Знамения (Eldritch), перенесённые на карту активной Тайны (solveCondition
# kind=="tokensOnCard"). Растёт, когда сыщик тратит улики на клетке с жетоном;
# проверяется в конце Фазы Мифов. При решении Тайны сбрасывается.
var mystery_tokens_on_card: int = 0
# Индекс Тайны, чей onEnter уже применён (хост-локальный гард идемпотентности —
# onEnter может зваться из нескольких хуков: старт партии / приход библии / решение).
# Доступ к полю — из MysteryFlow через _gs (per-file анализатор GameState этого
# не видит и считает «неиспользуемым» — глушим).
@warning_ignore("unused_private_class_variable")
var _on_enter_applied_idx: int = -1
# Финал партии: "" — ещё идёт; "victory" — все 3 Тайны решены; "defeat" — doom
# достиг doomClock. Клиент по этому полю показывает финальные модалки.
var outcome: String = ""

# Подсистемы. GameState — фасад и хранитель синкаемого state; подмодули —
# host-only логика и owned state (колода мифов, эпоха генерации кампании,
# префетч встреч). _phase владеет переходами и обработкой действий — без
# собственных полей, тонкий контроллер.
var _mythos: MythosFlow
var _campaign: CampaignGen
var _encounter: EncounterFlow
var _phase: PhaseController
var _check: CheckFlow
var _cond: ConditionFlow
var _board: BoardState
var _mystery: MysteryFlow
var _target: TargetResolver
var _spell: SpellFlow

# ── Lifecycle ────────────────────────────────────────────────────────────────


func _ready() -> void:
	_nm = get_node("/root/NetworkManager")
	# Подмодули создаём ДО подписки на сигналы — иначе входящий снапшот может
	# обратиться к ним раньше, чем они инициализированы.
	_mythos = MythosFlow.new(self)
	_campaign = CampaignGen.new(self)
	_encounter = EncounterFlow.new(self)
	_phase = PhaseController.new(self)
	_check = CheckFlow.new(self)
	_cond = ConditionFlow.new(self)
	_board = BoardState.new(self)
	_mystery = MysteryFlow.new(self)
	_target = TargetResolver.new(self)
	_spell = SpellFlow.new(self)
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
	(
		_nm
		. relay_all(
			{
				"action": "game_sync",
				"round_num": round_num,
				"phase": phase,
				"current_idx": current_idx,
				"turn_order": turn_order,
				"doom": doom,
				"omens_step": omens_step,
				"players": players,
				"current_encounter": current_encounter,
				"active_check": active_check,
				"pending_spell_cast": pending_spell_cast,
				"last_cast_result": last_cast_result,
				"reckoning_results": reckoning_results,
				"current_mythos": current_mythos,
				"mythos_index": _mythos.index,
				"gates": gates,
				"entities": entities,
				"monsters": monsters,
				"monster_bag": monster_bag,
				"monster_surge": monster_surge,
				"encounter_choices": encounter_choices,
				"shop_reserve": shop_reserve,
				"campaign": campaign,
				"campaign_pending": campaign_pending,
				"active": active,
				"active_mystery": active_mystery,
				"mystery_progress": mystery_progress,
				"mystery_claimed": mystery_claimed,
				"mystery_tokens_on_card": mystery_tokens_on_card,
				"outcome": outcome,
			}
		)
	)


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
		"user_id": uid,
		"name": pname,
		"investigator": investigator,
		"location": location,
		"connected": true,
		"actions_left": ACTIONS_PER_ROUND,
		"actions_used": [],
		"encounter_done": false,
		"train_tickets": 0,
		"ship_tickets": 0,
		"concentration": 0,
		"hp": hp_max,
		"sanity": sanity_max,
		"hp_max": hp_max,
		"sanity_max": sanity_max,
		"clues": 0,
		"conditions": [],
		"conditions_flipped": {},  # {cond_id: outcome_id} — перевёрнутые в расплату
		"items": _starting_items(investigator),
		"skill_mods": {},
	}


# Стартовые карты-активы сыщика из investigators.json → в инвентарь. Токены
# (clue/focus и т.п.) пропускаем — это не карты. Формат item — инстанс
# {id, exhausted}: exhausted нужен для oncePerRound-активаций (рефреш в начале
# раунда). entry_id/deck_for_items понимают и инстанс, и старую id-строку.
func _starting_items(investigator: String) -> Array:
	var out: Array = []
	var si: Array = Investigators.get_data(investigator).get("startingItems", [])
	for entry: Variant in si:
		# Стартовое заклинание: {"spell": id} → карта-заклинание {id, kind:"spell"}
		# (как gainSpell). Сыщики-маги EH начинают игру с заклинания.
		if entry is Dictionary and (entry as Dictionary).has("spell"):
			var sid: String = String((entry as Dictionary)["spell"])
			if SpellCatalog.is_spell(sid):
				out.append({"id": sid, "kind": "spell"})
			continue
		var aid: String = AssetCatalog.entry_id(entry)
		if not aid.is_empty() and not AssetCatalog.by_id(aid).is_empty():
			out.append({"id": aid, "exhausted": false})
	return out


# Снять истощение со всех активов игрока — Refresh-шаг начала раунда. Инстансы
# в массиве — ссылки, мутируем по месту.
func _refresh_items(p: Dictionary) -> void:
	for it_v: Variant in p.get("items", []):
		if it_v is Dictionary:
			(it_v as Dictionary)["exhausted"] = false


# ── Хост: запуск игры ────────────────────────────────────────────────────────


## Вызывается хостом после нажатия «Начать игру».
## players_init: [{ pid, user_id, name, investigator, hp_max, sanity_max }, ...]
func start_game(players_init: Array) -> void:
	if not _is_host():
		return

	players.clear()
	turn_order.clear()
	current_encounter = {}
	pending_spell_cast = {}
	last_cast_result = {}
	reckoning_results = {}
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

	round_num = 1
	phase = "action"
	current_idx = 0
	doom = 0
	omens_step = 0
	active = true

	GameConsole.log(
		"[Game] Игра начата · игроков: %d · ход: %s" % [turn_order.size(), _name_of(_current_pid())]
	)
	# Библия: прогрета в лобби — используем готовую (или дождёмся текущей
	# генерации); не прогрета — запускаем генерацию сейчас (фолбэк).
	if campaign.is_empty() and not campaign_pending:
		_campaign.start_generation(_campaign.balance_player_count(), "")
	# Раскладку и Наплыв считаем по РАЗМЕРУ КОМНАТЫ (на сколько создали), а не по
	# числу подключённых. campaign.playerCount уже = размер комнаты; фолбэк (если
	# библия ещё не готова) — тот же авторитет из CampaignGen. Соло-тест партии на
	# N раскладывает поле и задаёт Наплыв как на N.
	var setup_pc: int = int(campaign.get("playerCount", _campaign.balance_player_count()))
	_board.setup_board(maxi(1, setup_pc))  # стартовая раскладка: врата+монстры, улики, Наплыв
	_mystery.apply_mystery_on_enter()  # onEnter первой Тайны (если библия уже готова; иначе при её приходе)
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
		(
			_nm
			. relay_all(
				{
					"action": "game_action",
					"type": action_type,
					"pid": my_pid,
					"payload": payload,
				}
			)
		)


# ── Encounter (фасады) ────────────────────────────────────────────────────────


## Игрок отмечает «встреча завершена» — передаёт ход следующему / в Mythos.
func finish_encounter() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_phase.host_apply_finish_encounter(my_pid)
	else:
		_nm.relay_all({"action": "game_finish_encounter", "pid": my_pid})


## Активный игрок бросает проверку встречи. Хост катит результат (эффекты
## применяются при завершении встречи — между броском и финишем можно перебрасывать).
func resolve_encounter() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_encounter.host_apply_resolve(my_pid)
	else:
		_nm.relay_all({"action": "game_resolve_encounter", "pid": my_pid})


## Активный игрок перебрасывает ОДИН выбранный куб проверки. currency — явная
## валюта (перетащили жетон) или "" = авто-приоритет (тап по кубу).
func reroll_encounter(die_index: int, currency: String = "") -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_encounter.host_apply_reroll(my_pid, die_index, currency)
	else:
		(
			_nm
			. relay_all(
				{
					"action": "game_reroll_encounter",
					"pid": my_pid,
					"die": die_index,
					"currency": currency,
				}
			)
		)


## Тап по кубу — переброс. Если игрок «закинул» жетон (pending_reroll_currency),
## тратится ИМЕННО эта валюта (один раз). Без жетона — только БЕСПЛАТНЫЙ переброс от
## карт (concentration/улика без розыгрыша жетона не тратятся). Маршрут по владельцу.
func reroll_die(die_index: int) -> void:
	var cur: String = pending_reroll_currency
	pending_reroll_currency = ""  # потребили намерение (один жетон = один переброс)
	if cur.is_empty():
		cur = "free"  # без жетона — только бесплатный переброс от карт
	if String(active_check.get("owner", "")) == "shop":
		shop_reroll(die_index, cur)
	else:
		reroll_encounter(die_index, cur)


## UI: «зарядить» валюту переброса (закинули жетон на проверку) и перерисовать —
## чтобы кубы стали кликабельны.
func set_pending_reroll(currency: String) -> void:
	pending_reroll_currency = currency
	_emit_changed()


## Можно ли перебросить куб ПРЯМО СЕЙЧАС (тапом): есть бесплатный переброс от карт
## ИЛИ заряжен жетон. Без розыгрыша жетона/карты перебросов нет.
func can_reroll_now() -> bool:
	var c: Dictionary = active_check
	if c.is_empty() or not bool(c.get("rolled", false)):
		return false
	var free: int = int(c.get("reroll_allowance", 0)) - int(c.get("rerolls_used", 0))
	return free > 0 or not pending_reroll_currency.is_empty()


## Есть ли ВООБЩЕ чем перебросить (бесплатно / концентрация / улика) — для скрытия
## исхода: пока игрок может разыграть жетон, провал не показываем.
func has_reroll_resource() -> bool:
	var c: Dictionary = active_check
	if c.is_empty() or not bool(c.get("rolled", false)):
		return false
	var free: int = int(c.get("reroll_allowance", 0)) - int(c.get("rerolls_used", 0))
	var me: Dictionary = my_player()
	return free > 0 or int(me.get("concentration", 0)) > 0 or int(me.get("clues", 0)) > 0


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


## Активный игрок выбрал ветку интерактивного choice в эффектах встречи (index —
## номер ветки в pending_choice.options). Хост записывает выбор и доигрывает.
func choose_effect(index: int) -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_phase.host_apply_effect_choice(my_pid, index)
	else:
		_nm.relay_all({"action": "game_choose_effect", "pid": my_pid, "index": index})


## Активный игрок активирует карту руки (item_index в player.items) во время
## проверки встречи — её способность правит текущий бросок. Хост применяет.
func activate_card(item_index: int) -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_check.activate(my_pid, item_index)  # единая активная проверка (встреча/магазин/бой)
	else:
		_nm.relay_all({"action": "game_activate_card", "pid": my_pid, "index": item_index})


## UI: каст заклинания из веера. Ritual → действие cast_spell (тратит действие,
## обычный action-роутинг); Incantation → контекстный (combat), хост-локально или
## через relay (game_cast_incantation).
func cast_spell(item_index: int) -> void:
	var items: Array = my_player().get("items", [])
	if item_index < 0 or item_index >= items.size():
		return
	var spell: Dictionary = SpellCatalog.by_id(AssetCatalog.entry_id(items[item_index]))
	if spell.is_empty():
		return
	var subtype: String = String(spell.get("subtype", ""))
	if subtype == "ritual":
		perform_action("cast_spell", {"item": item_index})
		return
	var my_pid: String = _nm.my_user_id
	if subtype == "glamour":
		# Каст glamour (вне проверки): exhaust + тест Lore. Аура применяется отдельно
		# (тап по glamour во время проверки → activate_card, см. world_map).
		if _is_host():
			if _spell.cast_glamour(my_pid, item_index):
				_broadcast_sync()
				_emit_changed()
		else:
			_nm.relay_all({"action": "game_cast_glamour", "pid": my_pid, "index": item_index})
		return
	if _is_host():  # incantation
		if _spell.cast_incantation(my_pid, item_index):
			_broadcast_sync()
			_emit_changed()
	else:
		_nm.relay_all({"action": "game_cast_incantation", "pid": my_pid, "index": item_index})


## Активный игрок подтвердил выбор триггер-заклинаний (item-индексы) в промпте
## pending_spell_cast (напр. при отдыхе): хост кастует только выбранные и чистит
## промпт. Пустой список — «ничего не кастить» (промпт всё равно закрывается).
func cast_trigger_spells(indices: Array) -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_phase.host_apply_cast_trigger_spells(my_pid, indices)
	else:
		_nm.relay_all({"action": "game_cast_trigger_spells", "pid": my_pid, "spells": indices})


## Владелец результата каста закрыл модалку расплаты — хост чистит last_cast_result.
func dismiss_cast_result() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_host_dismiss_cast_result(my_pid)
	else:
		_nm.relay_all({"action": "game_dismiss_cast_result", "pid": my_pid})


# Хост: очистить результат каста, если его закрыл владелец (pid совпал).
func _host_dismiss_cast_result(pid: String) -> void:
	if String(last_cast_result.get("pid", "")) != pid:
		return
	last_cast_result = {}
	_broadcast_sync()
	_emit_changed()


## Игрок закрыл модалку результата флипа состояния — хост убирает его запись.
func dismiss_reckoning_result() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_host_dismiss_reckoning(my_pid)
	else:
		_nm.relay_all({"action": "game_dismiss_reckoning", "pid": my_pid})


# Хост: убрать запись результата флипа игрока (по закрытию модалки).
func _host_dismiss_reckoning(pid: String) -> void:
	if not reckoning_results.has(pid):
		return
	reckoning_results.erase(pid)
	_broadcast_sync()
	_emit_changed()


## Активный игрок перебрасывает ВСЕ провальные кубы разом — эффект карты
## «перебросить сколько угодно кубов» (Счастливый талисман). Бесплатно (одно
## использование на активацию такой карты). Работает в любой проверке.
func reroll_all_dice() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_check.reroll_all(my_pid)
	else:
		_nm.relay_all({"action": "game_reroll_all", "pid": my_pid})


# ── Travel (фасады) ───────────────────────────────────────────────────────────


## Переместиться в связанную локацию dest (расходует действие).
func travel(dest: String) -> void:
	perform_action("travel", {"to": dest})


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


# ── Магазин (фасады) ──────────────────────────────────────────────────────────


## Доступен ли магазин: мой ход, город, мой сыщик там, есть действие и покупка
## («acquire_assets») ещё не сделана в этом раунде (уникальное действие — раз за раунд).
func can_shop(loc_id: String) -> bool:
	if loc_id.is_empty() or not is_my_turn():
		return false
	var me: Dictionary = my_player()
	if int(me.get("actions_left", 0)) <= 0:
		return false
	if (me.get("actions_used", []) as Array).has("acquire_assets"):
		return false
	if location_type(loc_id) != "city":
		return false
	return String(me.get("location", "")) == loc_id


## Можно ли купить билет в loc_id прямо сейчас (для кнопок сайдбара). Условия как у
## магазина: мой ход, мой текущий город, есть действие, buy_ticket ещё не сделан в
## этом раунде. Конкретные типы билетов — available_ticket_types(loc_id).
func can_buy_ticket(loc_id: String) -> bool:
	if loc_id.is_empty() or not is_my_turn():
		return false
	var me: Dictionary = my_player()
	if int(me.get("actions_left", 0)) <= 0:
		return false
	if (me.get("actions_used", []) as Array).has("buy_ticket"):
		return false
	if String(me.get("location", "")) != loc_id:
		return false
	# Потолок: на руках максимум MAX_TICKETS билетов (ж/д + корабль).
	if int(me.get("train_tickets", 0)) + int(me.get("ship_tickets", 0)) >= MAX_TICKETS:
		return false
	return not available_ticket_types(loc_id).is_empty()


## Купить билет типа ticket_type ("train"|"ship") — действие хосту.
func buy_ticket(ticket_type: String) -> void:
	perform_action("buy_ticket", {"type": ticket_type})


## Открытие магазина — старт проверки Влияния в pre-roll состоянии (БЕЗ траты
## действия), чтобы карты руки можно было активировать до броска. Действие
## тратится только на «Бросить кубы» (shop_begin → acquire_assets).
func shop_open() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_check.start("shop", my_pid, "influence", 0, "acquireAssets")
		_broadcast_sync()
		_emit_changed()
	else:
		_nm.relay_all({"action": "game_shop_open", "pid": my_pid})


## Бросок кубов = совершение действия «acquire_assets» (раз за раунд). Тратит
## действие сразу — отмена покупки уже не вернёт поход в магазин в этом раунде.
func shop_begin() -> void:
	perform_action("acquire_assets", {})


## Выдать купленные ассеты (по «Купить»). Действие уже потрачено на броске.
func shop_grant(assets: Array) -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_phase.host_apply_shop_grant(my_pid, assets)
	else:
		_nm.relay_all({"action": "game_shop_grant", "pid": my_pid, "assets": assets})


## Закрытие магазина — снимает отложенную передачу хода (если магазин был
## последним действием, ход уйдёт только сейчас). Безопасно вызывать всегда.
func shop_close() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_phase.host_apply_shop_close(my_pid)
	else:
		_nm.relay_all({"action": "game_shop_close", "pid": my_pid})


## Взять долг — вешает состояние «Долг» (без дублей).
func shop_take_debt() -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_phase.host_apply_shop_debt(my_pid)
	else:
		_nm.relay_all({"action": "game_shop_debt", "pid": my_pid})


## Переброс куба магазина (die_index) — через общий механизм проверки (бесплатные
## от карт → концентрация → улика). Хост авторитетно правит active_check.
func shop_reroll(die_index: int, currency: String = "") -> void:
	var my_pid: String = _nm.my_user_id
	if _is_host():
		_check.reroll(my_pid, die_index, currency)
	else:
		(
			_nm
			. relay_all(
				{
					"action": "game_shop_reroll",
					"pid": my_pid,
					"die": die_index,
					"currency": currency,
				}
			)
		)


## Хост: заполнить витрину магазина до SHOP_RESERVE_SIZE случайными ассетами.
func _fill_shop_reserve() -> void:
	shop_reserve = []
	_draw_shop_assets(SHOP_RESERVE_SIZE)


## Гарантирует непустую витрину (на случай партий, начатых до появления резерва).
## Только дотягивает недостающее — выложенные карты остаются на местах.
func ensure_shop_reserve() -> void:
	if not _is_host() or shop_reserve.size() >= SHOP_RESERVE_SIZE:
		return
	_draw_shop_assets(SHOP_RESERVE_SIZE - shop_reserve.size())
	_broadcast_sync()
	_emit_changed()


## Хост: после покупки убрать купленные id и дотянуть витрину новыми.
func _refill_shop_reserve(bought: Array) -> void:
	if not _is_host():
		return
	for b: Variant in bought:
		shop_reserve.erase(String(b))
	_draw_shop_assets(SHOP_RESERVE_SIZE - shop_reserve.size())


## Добавляет n случайных ассетов в витрину. Карты не повторяются: исключаем уже
## выложенные И уже принадлежащие любому игроку — каждый ассет на поле уникален.
func _draw_shop_assets(n: int) -> void:
	if n <= 0:
		return
	var taken: Dictionary = {}
	for r: Variant in shop_reserve:
		taken[String(r)] = true
	for pid: Variant in players:
		for it: Variant in players[pid].get("items", []) as Array:
			taken[AssetCatalog.entry_id(it)] = true  # item — инстанс {id,…} или id-строка
	var pool: Array = []
	for a in AssetCatalog.all():
		var aid: String = String((a as Dictionary).get("id", ""))
		if not aid.is_empty() and not taken.has(aid):
			pool.append(aid)
	pool.shuffle()
	for i: int in mini(n, pool.size()):
		shop_reserve.append(pool[i])


## Тип локации по id (city|wilderness|sea), "" если не найдена.
func location_type(loc_id: String) -> String:
	for loc in _load_locations():
		if String((loc as Dictionary).get("id", "")) == loc_id:
			return String((loc as Dictionary).get("type", ""))
	return ""


## Какие билеты можно купить в локации (по типам исходящих дорог). Билеты продаются
## ТОЛЬКО в городах: дорога type "train" → ж/д билет ("train"), "ship" → билет на
## корабль ("ship"). Возвращает подмножество ["train","ship"] (пусто — не город или
## нет таких дорог). Источник для UI (кнопки в сайдбаре) и валидации buy_ticket.
func available_ticket_types(loc_id: String) -> Array:
	if location_type(loc_id) != "city":
		return []
	var types: Array = []
	for loc in _load_locations():
		if String((loc as Dictionary).get("id", "")) != loc_id:
			continue
		for c in (loc as Dictionary).get("connections", []):
			var t: String = String((c as Dictionary).get("type", ""))
			if (t == "train" or t == "ship") and not types.has(t):
				types.append(t)
		break
	return types


## Аффинити бонусов локации (data/locations.json → rewardAffinity): { verb: weight }.
## Пусто → у локации нет бонусов. Используется EncounterFlow для бонуса на успехе.
func location_reward_affinity(loc_id: String) -> Dictionary:
	for loc in _load_locations():
		if String((loc as Dictionary).get("id", "")) == loc_id:
			return (loc as Dictionary).get("rewardAffinity", {})
	return {}


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
	var inv: String = String(data.get("investigator", ""))
	if conn_id.is_empty() or inv.is_empty():
		return
	var uid: String = conn_id
	var pname: String = conn_id
	var lobby: Dictionary = _nm.players
	if lobby.has(conn_id):
		var rec: Dictionary = lobby[conn_id]
		var u: String = String(rec.get("user_id", ""))
		if not u.is_empty():
			uid = u
		pname = String(rec.get("name", conn_id))
	if players.has(uid):
		return  # уже участник — обычный set_ready, не поздний вход
	_add_player_mid_game(uid, pname, inv)


## Хост: добавить нового игрока в идущую партию. Слот ставится в конец
## turn_order — поздний игрок получает ход в текущем же раунде после остальных.
func _add_player_mid_game(uid: String, pname: String, investigator: String) -> void:
	if uid.is_empty() or investigator.is_empty() or players.has(uid):
		return
	var inv: Dictionary = Investigators.get_data(investigator)
	var hp_max: int = int(inv.get("health", 5))
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
	GameConsole.log("[Game] %s присоединился к партии (игроков: %d)" % [pname, turn_order.size()])
	_broadcast_sync()
	_emit_changed()


# ── Применить снапшот (от хоста через relay ИЛИ от сервера через joined_room) ─


func _apply_snapshot(data: Dictionary) -> void:
	round_num = int(data.get("round_num", 0))
	phase = String(data.get("phase", ""))
	current_idx = int(data.get("current_idx", 0))
	turn_order = data.get("turn_order", [])
	doom = int(data.get("doom", 0))
	omens_step = int(data.get("omens_step", 0))
	players = data.get("players", {})
	current_encounter = data.get("current_encounter", {})
	active_check = data.get("active_check", {})
	pending_spell_cast = data.get("pending_spell_cast", {})
	last_cast_result = data.get("last_cast_result", {})
	reckoning_results = data.get("reckoning_results", {})
	current_mythos = data.get("current_mythos", {})
	_mythos.index = int(data.get("mythos_index", 0))
	gates = data.get("gates", {})
	entities = data.get("entities", {})
	monsters = data.get("monsters", {})
	monster_bag = data.get("monster_bag", [])
	monster_surge = int(data.get("monster_surge", 0))
	encounter_choices = data.get("encounter_choices", [])
	shop_reserve = data.get("shop_reserve", [])
	campaign = data.get("campaign", {})
	campaign_pending = bool(data.get("campaign_pending", false))
	active = bool(data.get("active", false))
	active_mystery = int(data.get("active_mystery", 0))
	mystery_progress = int(data.get("mystery_progress", 0))
	mystery_claimed = data.get("mystery_claimed", [])
	mystery_tokens_on_card = int(data.get("mystery_tokens_on_card", 0))
	outcome = String(data.get("outcome", ""))
	_emit_changed()
	phase_changed.emit(phase)

	# Хост реджойнулся в фазу встреч, а карта в снапшоте — пустая (хост ушёл
	# в момент await api.draw_encounter, снапшот сохранился в loading-
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
				var t: String = data.get("type", "")
				_phase.host_apply_action(pid, t, data.get("payload", {}))

		"game_finish_encounter":
			if _is_host():
				_phase.host_apply_finish_encounter(data.get("pid", ""))

		"game_resolve_encounter":
			if _is_host():
				_encounter.host_apply_resolve(data.get("pid", ""))

		"game_reroll_encounter":
			if _is_host():
				_encounter.host_apply_reroll(
					data.get("pid", ""), int(data.get("die", -1)), String(data.get("currency", ""))
				)

		"game_choose_encounter":
			if _is_host():
				_encounter.host_apply_choose(data.get("pid", ""), String(data.get("kind", "")))

		"game_advance_stage":
			if _is_host():
				_encounter.host_apply_advance_stage(data.get("pid", ""))

		"game_choose_effect":
			if _is_host():
				_phase.host_apply_effect_choice(data.get("pid", ""), int(data.get("index", -1)))

		"game_activate_card":
			if _is_host():
				_check.activate(data.get("pid", ""), int(data.get("index", -1)))

		"game_cast_incantation":
			if _is_host():
				if _spell.cast_incantation(String(data.get("pid", "")), int(data.get("index", -1))):
					_broadcast_sync()
					_emit_changed()

		"game_cast_glamour":
			if _is_host():
				if _spell.cast_glamour(String(data.get("pid", "")), int(data.get("index", -1))):
					_broadcast_sync()
					_emit_changed()

		"game_cast_trigger_spells":
			if _is_host():
				_phase.host_apply_cast_trigger_spells(
					String(data.get("pid", "")), data.get("spells", [])
				)

		"game_dismiss_cast_result":
			if _is_host():
				_host_dismiss_cast_result(String(data.get("pid", "")))

		"game_dismiss_reckoning":
			if _is_host():
				_host_dismiss_reckoning(String(data.get("pid", "")))

		"game_shop_grant":
			if _is_host():
				_phase.host_apply_shop_grant(data.get("pid", ""), data.get("assets", []))

		"game_shop_close":
			if _is_host():
				_phase.host_apply_shop_close(data.get("pid", ""))

		"game_shop_debt":
			if _is_host():
				_phase.host_apply_shop_debt(data.get("pid", ""))

		"game_shop_open":
			if _is_host():
				_check.start("shop", data.get("pid", ""), "influence", 0, "acquireAssets")
				_broadcast_sync()
				_emit_changed()

		"game_shop_reroll":
			if _is_host():
				_check.reroll(
					data.get("pid", ""), int(data.get("die", -1)), String(data.get("currency", ""))
				)

		"game_reroll_all":
			if _is_host():
				_check.reroll_all(data.get("pid", ""))

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
	return (
		active
		and phase == "encounter"
		and _current_pid() == _nm.my_user_id
		and not have_finished_encounter()
	)


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
	# Адресные эффекты (target lead/each/eachOn*/chosenInvestigator) и передачи
	# активов/улик — применяются к разрешённым сыщикам, а не к доске.
	if _target.is_targeted_effect(node):
		_target.apply_targeted_effect(node)
		return
	# Повтор уровня поля (repeat по источнику разрешён интерпретатором в _times).
	var times: int = maxi(1, int(node.get("_times", 1)))
	for _t in range(times):
		_apply_board_verb(node, verb)


# Один проход board-verb'а (без учёта _times — его разворачивает _apply_board_effect).
func _apply_board_verb(node: Dictionary, verb: String) -> void:
	var n: int = int(node.get("amount", node.get("count", 1)))
	match verb:
		"advanceDoom":
			doom += n
			GameConsole.log("[Эффект] doom +%d" % n)
			_mystery.check_defeat()
		"advanceOmen", "moveOmen":
			# На каждый шаг омена: сдвигаем, затем СРАЗУ считаем дум по вратам
			# нового цвета омена — ДО того как карта откроет новые врата, чтобы
			# только что открытые врата не влияли на дум этого сдвига.
			for _i: int in maxi(1, n):
				omens_step += 1
				_board.resolve_omen_doom()
			GameConsole.log("[Эффект] омен +%d" % maxi(1, n))
		"openGate":
			for _i: int in n:
				_board.open_gate()
		"closeGate":
			_board.close_gate_at_active_player()
		"spawnMonster":
			for _i: int in n:
				_board.spawn_monster_from_gate()
		"placeClue":
			for _i: int in n:
				_board.place_clue()
		"placeRumor":
			for _i: int in n:
				_board.place_rumor()
		"placeEldritchToken":
			# where=="self" → жетон(ы) на карту активной Тайны (счётчик).
			# Иначе → разложить N жетонов Знамения на случайные поля.
			if String(node.get("where", "")) == "self":
				mystery_tokens_on_card += n
				GameConsole.log("[Тайна] жетонов на карте Тайны: %d" % mystery_tokens_on_card)
			else:
				for _i: int in n:
					_board.place_eldritch_token()
		"monsterSurge":
			_board.monster_surge()
		"mysteryProgress":
			# Зачёт текущей локации активного игрока в активную Тайну. Выдаётся
			# только из mystery-встреч (см. relay encounter-tables). За пределами
			# фазы encounter — тихо игнорируем.
			if phase != "encounter":
				GameConsole.log("[Эффект] mysteryProgress вне фазы encounter — игнор")
			else:
				_mystery.apply_mystery_progress()
		"retreatDoom":
			doom = maxi(0, doom - n)
			GameConsole.log("[Эффект] doom −%d (откат) → %d" % [n, doom])
		"discardGate":
			_board.discard_gate()
		"discardMonster":
			if String(node.get("maxToughness", "")) == "testResult":
				_board.remove_monsters_by_toughness(false, int(node.get("_successes", 0)))
			else:
				_board.remove_monster_at_active(false, n)  # снять без боя
		"defeatMonster":
			if String(node.get("maxToughness", "")) == "testResult":
				_board.remove_monsters_by_toughness(true, int(node.get("_successes", 0)))
			else:
				_board.remove_monster_at_active(true, n)  # победить (вернуть id в мешок)
		"damageMonster":
			_board.damage_monster_at_active(n)
		"resolveReckoning":
			_cond.host_resolve_reckoning()
		"gainSpell":
			# Активный сыщик тянет заклинание (реальная карта, не маркер).
			_spell.grant_spell(_current_pid(), String(node.get("spell", "")))
		_:
			GameConsole.log("[Эффект] %s — пока не поддержано движком" % verb)


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


## Текущий акт (1–3) — по индексу активной Тайны. Делегат в CampaignGen.
func current_act() -> int:
	return _campaign.current_act()


## Хост: сброс перед новой игрой. Зовётся из lobby при входе в свежее лобби —
## чтобы prewarm следующей игры не наткнулся на библию предыдущей и зависшую
## генерацию. Чистит собственный state GameState; campaign и мифос — через
## модули (там живут их «приватные» поля типа epoch/seed).
func reset_pregame() -> void:
	if not _is_host():
		return
	_campaign.reset()
	current_encounter = {}
	pending_spell_cast = {}
	last_cast_result = {}
	reckoning_results = {}
	current_mythos = {}
	_mythos.deck = []
	_mythos.index = 0
	gates = {}
	entities = {}
	monsters = {}
	monster_bag = []
	monster_surge = 0
	encounter_choices = []
	active = false


# ── Helpers для подмодулей ───────────────────────────────────────────────────


## Лениво загружает data/locations.json и кэширует. Используется travel-flow
## (проверка связности, имя/тип в запросе встречи) и CampaignGen (список
## локаций в запросе библии).
func _load_locations() -> Array:
	if _locations_cache.is_empty():
		_locations_cache = DataLoader.load_array("res://data/locations.json")
	return _locations_cache
