class_name BotDriver
extends Node

## Боты офлайн-партии. Каждый бот — виртуальный клиент локального реле
## (LocalTransport): его ходы приходят хосту тем же relay-путём, что и ходы
## удалённого игрока, поэтому движок ботов не различает и ничего о них не знает.
##
## Драйвер читает GameState (он в том же процессе) и отвечает на те же состояния
## ожидания, что и модалки живого игрока: бросок, принятие, выбор ветки, «прочитал»,
## переезд, спас-бросок. В фазе действий — простая стратегия по роли:
##   • fighter — идёт к ближайшему монстру (бой случится в фазе встреч);
##   • runner  — идёт к ближайшей улике, иначе к клетке Тайны, иначе к вратам.
## Одно действие за тик с паузой — живому игроку видно, что происходит.
##
## В лобби: как только живой игрок нажал «Готов», боты берут свободных сыщиков и
## тоже готовы (set_ready через реле, как обычные игроки).

const DELAY_MIN := 1.2  # пауза перед каждым шагом бота — чтобы за ним можно было уследить
const DELAY_MAX := 2.0
const RETRY_SEC := 3.0  # то же намерение повторяем не чаще — страховка от зацикливания
# Столько раз подряд хост не принял одно и то же действие при неизменном состоянии —
# бот пасует, а не просит то же вечно (страховка на непредвиденный отказ хоста).
const STUCK_REPEATS := 3
# Встреча бота: живой игрок читает её в окне наблюдателя — бот не жмёт дальше,
# пока текст не прочитан. Время — по длине текста, в рамках [MIN, MAX].
const READ_CHARS_PER_SEC := 18.0
const READ_MIN := 2.5
const READ_MAX := 12.0
const ROLES := ["fighter", "runner"]
# Проверки бота: улики на переброс тратит только сверх этого запаса (их ждут Тайны);
# расходные карты (сброс/оплата) до броска играет, только если пул не больше RISKY_POOL.
const CLUE_RESERVE := 2
const RISKY_POOL := 2
# Владельцы active_check, где бот — сам себе игрок (лавку и касты бот не ведёт).
const _ASSIST_OWNERS := ["encounter", "combat", "effectCheck"]

const _CHOICE_ORDER := [
	"research", "mystery", "eldritch", "rumor", "belongings", "gate", "local", "general"
]

var bots: Array = []  # [{id, name, role}]
var rng := RandomNumberGenerator.new()
## Отправка сообщения от лица бота: (from_id, msg). По умолчанию — inject_relay
## локального транспорта; тесты подменяют.
var sender: Callable = Callable()

var _gs: Node = null
var _nm: Node = null
var _timer: Timer = null
var _last: Dictionary = {}  # bot id → {sig, at, count}
var _sent: Array = []  # для тестов/отладки: [{from, msg}]
var _read_text: String = ""  # что сейчас видит наблюдатель встречи бота
var _read_since: float = 0.0  # когда этот текст появился (сек)
# Попытки «помощника проверки» при данном состоянии слота: отклонённую хостом активацию
# или переброс не повторяем — иначе бот залип бы на ней, так и не бросив кубы.
var _assist_tried: Dictionary = {}

# ── Lifecycle ─────────────────────────────────────────────────────────────────


## gs/nm — GameState/NetworkManager (стабы в тестах). Звать до add_child.
func setup(ids: Array, gs: Node = null, nm: Node = null) -> void:
	bots = []
	for i: int in range(ids.size()):
		var bid: String = String(ids[i])
		bots.append({"id": bid, "role": ROLES[i % ROLES.size()]})
	_gs = gs
	_nm = nm


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _gs == null:
		_gs = get_node_or_null("/root/GameState")
	if _nm == null:
		_nm = get_node_or_null("/root/NetworkManager")
	_timer = Timer.new()
	_timer.name = "TickTimer"
	_timer.one_shot = true
	_timer.process_callback = Timer.TIMER_PROCESS_IDLE
	add_child(_timer)
	_timer.timeout.connect(_tick)
	if _gs != null and _gs.has_signal("state_changed"):
		_gs.state_changed.connect(_note_reading)
		_gs.state_changed.connect(_schedule)
	if _nm != null and _nm.has_signal("relay_received"):
		_nm.relay_received.connect(_on_relay)
	_schedule()


func bot_ids() -> Array:
	var out: Array = []
	for b: Dictionary in bots:
		out.append(String(b["id"]))
	return out


func is_bot(pid: String) -> bool:
	return bot_ids().has(pid)


# ── Лобби ─────────────────────────────────────────────────────────────────────


# Живой игрок готов → боты разбирают свободных сыщиков и тоже готовы.
func _on_relay(from_id: String, data: Dictionary) -> void:
	if String(data.get("action", "")) != RelayActions.SET_READY or _nm == null:
		return
	if is_bot(from_id):
		return
	ready_bots()


## Готовность ботов в лобби: каждому — случайный свободный сыщик своей коробки.
## Уже готовых не трогаем. Возвращает число отправленных set_ready.
func ready_bots() -> int:
	var players: Dictionary = _nm.get("players")
	var taken: Dictionary = {}
	for pid: String in players.keys():
		var info: Dictionary = players[pid]
		if bool(info.get("ready", false)):
			taken[String(info.get("investigator", ""))] = true
	var pool: Array = []
	for inv_v: Variant in SeasonGate.filter_own(
		DataLoader.load_array(Investigators.DATA_PATH), "investigators"
	):
		var inv_name: String = String((inv_v as Dictionary).get("name", ""))
		if not inv_name.is_empty() and not taken.has(inv_name):
			pool.append(inv_name)
	var sent: int = 0
	for b: Dictionary in bots:
		var bid: String = String(b["id"])
		if bool((players.get(bid, {}) as Dictionary).get("ready", false)):
			continue
		if pool.is_empty():
			break
		var pick: String = pool.pop_at(rng.randi_range(0, pool.size() - 1))
		_emit(bid, {"action": RelayActions.SET_READY, "player_id": bid, "investigator": pick})
		sent += 1
	return sent


# ── Тик ───────────────────────────────────────────────────────────────────────


func _schedule() -> void:
	if _timer != null and _timer.is_stopped():
		_timer.start(rng.randf_range(DELAY_MIN, DELAY_MAX))


func _tick() -> void:
	if _gs == null or not bool(_gs.get("active")):
		return
	var throttled: bool = false
	for b: Dictionary in bots:
		var bid: String = String(b["id"])
		var intent: Dictionary = decide(bid, String(b["role"]))
		if intent.is_empty():
			continue
		var wait: float = reading_wait(bid)
		if wait > 0.0:
			if _timer != null:
				_timer.start(wait)  # живой игрок ещё читает встречу бота
			return
		if _send(bid, intent):
			_schedule()  # одно действие за тик — следующему боту своя пауза
			return
		throttled = true
	# Намерение есть, но это повтор при том же состоянии (хост его не принял?) —
	# повторим после паузы, иначе без смены состояния тик больше не наступит.
	if throttled and _timer != null and _timer.is_stopped():
		_timer.start(RETRY_SEC)


# Отправить намерение, если оно не повтор недавнего (RETRY_SEC) при том же состоянии.
# Отпечаток состояния в подписи: одно и то же действие подряд (бросок Воли → «применить»
# → бросок Силы — всё RESOLVE_ENCOUNTER) уходит сразу, а не после паузы.
func _send(bid: String, intent: Dictionary) -> bool:
	var sig: String = JSON.stringify(intent) + "|" + _fingerprint(bid)
	var now: float = Time.get_ticks_msec() / 1000.0
	var last: Dictionary = _last.get(bid, {})
	var same: bool = String(last.get("sig", "")) == sig
	if same and now - float(last.get("at", 0.0)) < RETRY_SEC:
		return false
	var count: int = int(last.get("count", 0)) + 1 if same else 1
	_last[bid] = {"sig": sig, "at": now, "count": count}
	var msg: Dictionary = (
		(_stuck_fallback(bid, intent) if count > STUCK_REPEATS else intent).duplicate(true)
	)
	msg["pid"] = bid
	_emit(bid, msg)
	return true


# Хост раз за разом отклоняет действие фазы действий (состояние не меняется) —
# вместо вечного повтора пасуем: ход уйдёт дальше, партия не встанет.
func _stuck_fallback(bid: String, intent: Dictionary) -> Dictionary:
	if (
		String(intent.get("action", "")) != RelayActions.ACTION
		or String(intent.get("type", "")) == GameActions.PASS
	):
		return intent
	push_warning("[Бот] %s: хост не принимает «%s» — пас" % [bid, intent.get("type", "")])
	return _game_action(GameActions.PASS)


# Срез состояния, от которого зависит намерение бота: смена любого поля → новое
# намерение не считается повтором.
func _fingerprint(bid: String) -> String:
	var p: Dictionary = (_gs.get("players") as Dictionary).get(bid, {})
	var ac: Dictionary = _gs.get("active_check")
	var enc: Dictionary = _gs.get("current_encounter")
	return (
		JSON
		. stringify(
			[
				_gs.get("phase"),
				_gs.get("round_num"),
				_gs.get("current_idx"),
				ac.get("rolled", false),
				ac.get("reroll_nonce", 0),
				ac.get("owner", ""),
				enc.get("id", ""),
				enc.has("will"),
				enc.has("resolution"),
				enc.get("stage", 0),
				(enc.get("pending_choice", {}) as Dictionary).is_empty(),
				(_gs.get("pending_check") as Dictionary).get("pid", ""),
				(_gs.get("mythos_read") as Array).size(),
				(_gs.get("current_mythos") as Dictionary).get("id", ""),
				p.get(PlayerKeys.ACTIONS_LEFT, 0),
				p.get(PlayerKeys.ENCOUNTER_DONE, false),
				p.get(PlayerKeys.TRAVEL_ANIM, false),
				(p.get("reckoning_check", {}) as Dictionary).get("rolled", null),
				(p.get("reckoning_check", {}) as Dictionary).get("reroll_nonce", 0),
			]
		)
	)


func _emit(from_id: String, msg: Dictionary) -> void:
	_sent.append({"from": from_id, "msg": msg})
	if sender.is_valid():
		sender.call(from_id, msg)
		return
	var t: Node = _nm.call("local_transport") if _nm != null else null
	if t != null:
		t.call("inject_relay", from_id, msg)


# ── Решение ───────────────────────────────────────────────────────────────────


## Что бот сделал бы прямо сейчас: {action, …payload} без pid, {} — ждать.
func decide(pid: String, role: String = "fighter") -> Dictionary:
	var players: Dictionary = _gs.get("players")
	var p: Dictionary = players.get(pid, {})
	if p.is_empty() or bool(p.get(PlayerKeys.DEAD, false)):
		return {}  # Тень за ботов не играем

	# Порог: спас-бросок уже брошен хостом — принимаем.
	if not (p.get(PlayerKeys.DEATH_SAVE_CHECK, {}) as Dictionary).is_empty():
		return {"action": RelayActions.DEATH_SAVE_APPLY}

	# Своя проверка: до броска — карты под пул, после неудачного — карты на результат,
	# +1 на куб и перебросы. Иначе ниже — обычный бросок / применение.
	var assist: Dictionary = check_assist(pid, p)
	if not assist.is_empty():
		return assist

	# Параллельная Расплата: свой слот проверки → бросить, затем применить.
	var rc: Dictionary = p.get("reckoning_check", {})
	if not rc.is_empty():
		return {
			"action":
			(
				RelayActions.RECKONING_APPLY
				if bool(rc.get("rolled", false))
				else RelayActions.RECKONING_ROLL
			)
		}
	if (_gs.get("reckoning_results") as Dictionary).has(pid):
		return {"action": RelayActions.DISMISS_RECKONING}

	if p.has("gains"):
		return {"action": RelayActions.DISMISS_GAINS}
	# Предложение обмена боту — в кооперативе бот соглашается всегда.
	if String((_gs.get("trade_offer") as Dictionary).get("to", "")) == pid:
		return {"action": RelayActions.TRADE_RESPOND, "accept": true}
	if String((_gs.get("last_cast_result") as Dictionary).get("pid", "")) == pid:
		return {"action": RelayActions.DISMISS_CAST_RESULT}

	# Решение (ветка Мифа / выбор монстра-клетки): случайная опция.
	var md: Dictionary = _gs.get("mythos_decision")
	if bool(md.get("active", false)) and String(md.get("pid", "")) == pid:
		return {"action": RelayActions.MYTHOS_DECIDE, "index": _rand_index(md.get("options", []))}

	# Проверка движка (test в эффектах): бросить, затем применить.
	var pc: Dictionary = _gs.get("pending_check")
	if String(pc.get("pid", "")) == pid:
		var ac: Dictionary = _gs.get("active_check")
		var rolled: bool = (
			String(ac.get("owner", "")) == "effectCheck" and bool(ac.get("rolled", false))
		)
		return {"action": RelayActions.RESOLVE_PENDING_CHECK if rolled else RelayActions.CHECK_ROLL}

	if bool(p.get("spell_prompt", false)):
		return {"action": RelayActions.CAST_TRIGGER_SPELLS, "spells": []}

	match String(_gs.get("phase")):
		Phases.MYTHOS:
			var cm: Dictionary = _gs.get("current_mythos")
			if not cm.is_empty() and not (_gs.get("mythos_read") as Array).has(pid):
				return {"action": RelayActions.RESOLVE_MYTHOS}
		Phases.ACTION:
			if _gs.current_pid() != pid:
				return {}
			if bool(p.get(PlayerKeys.TRAVEL_ANIM, false)):
				return {"action": RelayActions.TRAVEL_ARRIVED}
			if _held(p) or int(p.get(PlayerKeys.ACTIONS_LEFT, 0)) <= 0:
				return {}
			return _action_intent(pid, p, role)
		Phases.ENCOUNTER:
			if _gs.current_pid() != pid or bool(p.get(PlayerKeys.ENCOUNTER_DONE, false)):
				return {}
			if _held(p):
				return {}
			return _encounter_intent(pid, p, role)
	return {}


# Ход держат магазин / каст / действие состояния / актива — ждём (боты их не начинают,
# но триггеры активов могут).
func _held(p: Dictionary) -> bool:
	return (
		bool(p.get("shopping", false))
		or bool(p.get("casting", false))
		or bool(p.get("condition_acting", false))
		or bool(p.get("asset_acting", false))
	)


# ── Фаза действий ─────────────────────────────────────────────────────────────


func _action_intent(pid: String, p: Dictionary, role: String) -> Dictionary:
	var used: Array = p.get(PlayerKeys.ACTIONS_USED, [])
	# Состояние запрещает действия (Заключение, Затерянный во времени): хост примет
	# только пас и действие самого состояния. Раньше бот просил отдых — и вечно.
	if _gs.player_has_constraint(pid, "cannotAct"):
		var cid: String = _condition_with_action(p)
		if not cid.is_empty() and not used.has(GameActions.CONDITION_ACTION):
			return _game_action(GameActions.CONDITION_ACTION, {"condition": cid})
		return _game_action(GameActions.PASS)
	var hp: int = int(p.get(PlayerKeys.HP, 0))
	var san: int = int(p.get(PlayerKeys.SANITY, 0))
	# С монстром на клетке хост отдых отклонит — не просим (иначе бот зациклится).
	var can_rest: bool = (
		not used.has(GameActions.REST)
		and not _gs.has_monster_at(String(p.get(PlayerKeys.LOCATION, "")))
	)
	# Еле живой — сначала отдых.
	if can_rest and (hp <= 2 or san <= 2):
		return _game_action(GameActions.REST)
	if not used.has(GameActions.TRAVEL) and not _gs.player_has_constraint(pid, "cannotMove"):
		var dest: String = travel_target(pid, p, role)
		if not dest.is_empty():
			return _game_action(GameActions.TRAVEL, {"to": dest})
	if (
		not used.has(GameActions.TAKE_CONCENTRATION)
		and int(p.get(PlayerKeys.CONCENTRATION, 0)) < GameState.MAX_CONCENTRATION
	):
		return _game_action(GameActions.TAKE_CONCENTRATION)
	if (
		can_rest
		and (hp < int(p.get(PlayerKeys.HP_MAX, hp)) or san < int(p.get(PlayerKeys.SANITY_MAX, san)))
	):
		return _game_action(GameActions.REST)
	return _game_action(GameActions.PASS)


# Первое состояние на руках с локальным действием (Заключение: проверка Влияния →
# сброс). Перевёрнутые лицом вниз не действуют. "" — таких нет.
func _condition_with_action(p: Dictionary) -> String:
	var flipped: Dictionary = p.get("conditions_flipped", {})
	for c_v: Variant in p.get("conditions", []):
		var cid: String = String(c_v)
		if flipped.has(cid):
			continue
		if not (Conditions.get_def(cid).get("action", []) as Array).is_empty():
			return cid
	return ""


func _game_action(type: String, payload: Dictionary = {}) -> Dictionary:
	return {"action": RelayActions.ACTION, "type": type, "payload": payload}


## Первый шаг (сосед) по пути к ближайшей цели роли; "" — цели нет или мы уже на ней.
func travel_target(_pid: String, p: Dictionary, role: String) -> String:
	var here: String = String(p.get(PlayerKeys.LOCATION, ""))
	var layers: Array = _goal_layers(role)
	for goals_v: Variant in layers:
		var goals: Dictionary = goals_v
		if goals.is_empty():
			continue
		if goals.has(here):
			return ""  # уже на цели — стоим (бой/улика случатся в фазе встреч)
		var hop: String = first_hop(here, goals)
		if not hop.is_empty():
			return hop
	return ""


# Слои целей по убыванию приоритета: {loc: true}.
func _goal_layers(role: String) -> Array:
	var monsters: Dictionary = {}
	for loc: String in (_gs.get("monsters") as Dictionary).keys():
		if not ((_gs.get("monsters") as Dictionary)[loc] as Array).is_empty():
			monsters[loc] = true
	var clues: Dictionary = {}
	for loc: String in (_gs.get("entities") as Dictionary).keys():
		if ((_gs.get("entities") as Dictionary)[loc] as Array).has("clue"):
			clues[loc] = true
	var gates: Dictionary = {}
	for loc: String in (_gs.get("gates") as Dictionary).keys():
		gates[loc] = true
	var mystery: Dictionary = {}
	var claimed: Array = _gs.get("mystery_claimed")
	for loc_v: Variant in _gs.current_mystery().get("locations", []):
		if not claimed.has(String(loc_v)):
			mystery[String(loc_v)] = true
	if role == "runner":
		return [clues, mystery, gates]
	# Боец: «врата открыты — иду в круг» (у врат же и монстры).
	return [gates, monsters, clues]


## BFS по дорогам карты: первый шаг от `from` к ближайшей из goals ("" — недостижимо).
func first_hop(from: String, goals: Dictionary) -> String:
	var map: LocationGraph = _gs.get("map")
	var prev: Dictionary = {from: ""}
	var queue: Array = [from]
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		for n_v: Variant in map.neighbors(cur):
			var n: String = String(n_v)
			if prev.has(n):
				continue
			prev[n] = cur
			if goals.has(n):
				var x: String = n
				while String(prev[x]) != from:
					x = String(prev[x])
				return x
			queue.append(n)
	return ""


# ── Пауза на чтение ───────────────────────────────────────────────────────────


## Сколько читать текст: по длине, в рамках [READ_MIN, READ_MAX].
static func reading_time(text: String) -> float:
	if text.strip_edges().is_empty():
		return 0.0
	return clampf(text.length() / READ_CHARS_PER_SEC, READ_MIN, READ_MAX)


## Сколько ещё ждать, прежде чем бот нажмёт дальше на своей встрече: живой игрок
## должен успеть прочитать то, что сейчас в окне наблюдателя. 0 — можно.
func reading_wait(bid: String) -> float:
	_note_reading()
	var text: String = watched_text(bid)
	if text.is_empty() or text != _read_text:
		return 0.0
	var now: float = Time.get_ticks_msec() / 1000.0
	return maxf(0.0, reading_time(text) - (now - _read_since))


# Запомнить момент, когда в окне наблюдателя сменился текст (зовётся на каждом синке).
func _note_reading() -> void:
	if _gs == null:
		return
	var pid: String = String(_gs.call("current_pid")) if _gs.has_method("current_pid") else ""
	var text: String = watched_text(pid) if is_bot(pid) else ""
	if text != _read_text:
		_read_text = text
		_read_since = Time.get_ticks_msec() / 1000.0


## Текст, который видит наблюдатель встречи бота до «Завершить» (зеркало
## encounter_watch_modal): только текст встречи — исход телеграмма показывает лишь
## после фиксации, и время на его чтение даёт пауза хоста перед передачей хода
## (PhaseController.outcome_hold). Бой окно не показывает — "".
func watched_text(bid: String) -> String:
	if _gs == null or String(_gs.get("phase")) != Phases.ENCOUNTER:
		return ""
	if String(_gs.call("current_pid")) != bid:
		return ""
	if not (_gs.get("encounter_choices") as Array).is_empty():
		return ""
	var card: Dictionary = _gs.get("current_encounter")
	var kind: String = String(card.get("kind", ""))
	if card.is_empty() or kind == "combat":
		return ""
	var node: Dictionary = card
	if kind == "gate" or kind == "mystery":
		node = (
			card.get("stage1", {})
			if int(card.get("stage", 0)) <= 0
			else (card.get("branches", {}) as Dictionary).get(
				String(card.get("branch", "success")), {}
			)
		)
	return String(node.get("mainText", "")).strip_edges()


# ── Помощник проверки ─────────────────────────────────────────────────────────


## Ход бота внутри СВОЕЙ проверки (слот Расплаты или active_check с его pid): до броска
## разыграть подходящую карту; после неудачного броска — карту на результат, +1 на куб,
## «перебросить все», поштучный переброс (бесплатно → концентрация → улика сверх
## CLUE_RESERVE). {} — помогать нечем (или прошла) — бросаем/применяем как обычно.
## Карты не автоприменяются (даже пассивы whileOwned) — бот играет их сам, как игрок.
func check_assist(pid: String, p: Dictionary) -> Dictionary:
	var rc: Dictionary = p.get("reckoning_check", {})
	var reck: bool = not rc.is_empty()
	var c: Dictionary = rc if reck else (_gs.get("active_check") as Dictionary)
	if c.is_empty() or String(c.get("pid", "")) != pid:
		return {}
	if not reck and not _ASSIST_OWNERS.has(String(c.get("owner", ""))):
		return {}
	var rolled: bool = bool(c.get("rolled", false))
	if rolled and bool(c.get("passed", false)):
		return {}  # прошла — тратить нечего
	var state: String = _assist_state(c, p)
	var activate: String = (
		RelayActions.RECKONING_ACTIVATE_CARD if reck else RelayActions.ACTIVATE_CARD
	)
	var card: int = _card_to_play(p, c, rolled, state, activate)
	if card >= 0:
		return _assist_try({"action": activate, "index": card}, state)
	if not rolled:
		return {}
	var failing: Array = _failing_dice(c, p)  # по убыванию грани: [0] — ближе к успеху
	if failing.is_empty():
		return {}
	var add_left: int = (
		Dice.add_charges(c.get("active_mods", []), String(c.get("skill", ""))).size()
		- (c.get("add_targets", []) as Array).size()
	)
	if add_left > 0:
		var add_action: String = RelayActions.RECKONING_ADD_DIE if reck else RelayActions.ADD_DIE
		var add: Dictionary = _assist_try({"action": add_action, "die": int(failing[0])}, state)
		if not add.is_empty():
			return add
	if int(c.get("reroll_all_allowance", 0)) - int(c.get("reroll_all_used", 0)) > 0:
		var all_action: String = (
			RelayActions.RECKONING_REROLL_ALL if reck else RelayActions.REROLL_ALL
		)
		var all: Dictionary = _assist_try({"action": all_action}, state)
		if not all.is_empty():
			return all
	var currency: String = _reroll_currency(p, c)
	if currency.is_empty():
		return {}
	var action: String = RelayActions.RECKONING_REROLL
	if not reck:
		action = (
			RelayActions.REROLL_ENCOUNTER
			if ["encounter", "combat"].has(String(c.get("owner", "")))
			else RelayActions.CHECK_REROLL
		)
	# Перебрасываем самый слабый провальный куб.
	var weakest: int = int(failing[failing.size() - 1])
	return _assist_try({"action": action, "die": weakest, "currency": currency}, state)


# Намерение помощника — если при ЭТОМ состоянии слота его ещё не пробовали. Хост
# отклонил (состояние не сдвинулось) → повторно не шлём, бот идёт дальше по проверке.
func _assist_try(intent: Dictionary, state: String) -> Dictionary:
	var key: String = JSON.stringify(intent) + "|" + state
	if _assist_tried.has(key):
		return {}
	if _assist_tried.size() > 512:
		_assist_tried.clear()  # долгую партию не копим
	_assist_tried[key] = true
	return intent


# Отпечаток слота проверки и ресурсов бота: меняется после любой удачной помощи.
func _assist_state(c: Dictionary, p: Dictionary) -> String:
	var spent: Array = []
	var items: Array = p.get("items", [])
	for i in range(items.size()):
		if items[i] is Dictionary and bool((items[i] as Dictionary).get("exhausted", false)):
			spent.append(i)
	return (
		JSON
		. stringify(
			[
				c.get("owner", ""),
				c.get("skill", ""),
				c.get("context", ""),
				c.get("rolled", false),
				c.get("dice", []),
				(c.get("active_mods", []) as Array).size(),
				c.get("exhausted_cards", []),
				c.get("add_targets", []),
				c.get("rerolls_used", 0),
				c.get("reroll_all_used", 0),
				p.get(PlayerKeys.CONCENTRATION, 0),
				p.get(PlayerKeys.CLUES, 0),
				items.size(),
				spent,
			]
		)
	)


# Индекс карты руки, которую стоит сыграть в эту проверку сейчас (-1 — нечего). Тот же
# фильтр, что у веера (контекст, навык шага, тайминг до/после броска); у истощённой
# карты работает только пассив. Расходные (сброс/оплата) до броска — лишь при малом пуле.
func _card_to_play(
	p: Dictionary, c: Dictionary, rolled: bool, state: String, activate: String
) -> int:
	var ctx: String = String(c.get("context", ""))
	var skill: String = String(c.get("skill", ""))
	var used: Array = c.get("exhausted_cards", [])
	var items: Array = p.get("items", [])
	var small_pool: bool = _pool(p, c) <= RISKY_POOL
	for i in range(items.size()):
		var it: Variant = items[i]
		if not (it is Dictionary) or used.has(i):
			continue
		var asset: Dictionary = AssetCatalog.by_id(AssetCatalog.entry_id(it))
		if asset.is_empty():
			continue  # заклинания (glamour) бот пока не играет
		var spent: bool = bool((it as Dictionary).get("exhausted", false))
		var action_mods: Array = [] if spent else AssetCatalog.action_check_mods(asset, ctx)
		if not _mods_fit(action_mods, asset, ctx, skill, rolled):
			continue
		var costly: bool = false
		var payable: bool = true
		for m_v: Variant in action_mods:
			var cost: Dictionary = (m_v as Dictionary).get("cost", {})
			if bool(cost.get("discardSelf", false)):
				costly = true
			if cost.has("spend"):
				costly = true
				var res: String = String(cost.get("spend", ""))
				var amt: int = int(cost.get("amount", 1))
				payable = payable and ResourceLedger.can_pay(p, res, amt, false)
		if not payable or (costly and not rolled and not small_pool):
			continue
		var key: String = JSON.stringify({"action": activate, "index": i}) + "|" + state
		if _assist_tried.has(key):
			continue  # эту карту при этом состоянии хост уже не принял
		return i
	return -1


# Подходит ли карта шагу: есть мод под навык и момент (до броска — усиление пула,
# после — результат/перебросы/доп. кубы). action_mods пусты у истощённой карты.
func _mods_fit(
	action_mods: Array, asset: Dictionary, ctx: String, skill: String, rolled: bool
) -> bool:
	var mods: Array = action_mods.duplicate()
	mods.append_array(AssetCatalog.passive_check_mods(asset, ctx))
	for m_v: Variant in mods:
		var m: Dictionary = m_v
		var timing: bool = Dice.mod_usable_after_roll(m) if rolled else Dice.mod_is_pre_roll(m)
		if Dice.mod_skill_ok(m, skill) and timing:
			return true
	return false


# Провальные кубы проверки по отображаемым граням, по убыванию грани.
func _failing_dice(c: Dictionary, p: Dictionary) -> Array:
	var shown: Array = c.get("dice", c.get("base", []))
	var thr: int = Conditions.success_threshold(
		p.get("conditions", []), p.get("conditions_flipped", {})
	)
	var out: Array = []
	for i in range(shown.size()):
		if int(shown[i]) < thr:
			out.append(i)
	out.sort_custom(func(a: int, b: int) -> bool: return int(shown[a]) > int(shown[b]))
	return out


# Чем перебросить: бесплатный запас от карт → концентрация → улика сверх запаса.
func _reroll_currency(p: Dictionary, c: Dictionary) -> String:
	if int(c.get("rerolls_used", 0)) < int(c.get("reroll_allowance", 0)):
		return "free"
	if int(p.get(PlayerKeys.CONCENTRATION, 0)) > 0:
		return "concentration"
	if int(p.get(PlayerKeys.CLUES, 0)) > CLUE_RESERVE:
		return "clue"
	return ""


# Пул проверки — зеркало CheckFlow.pool (навык сыщика + модификаторы + доп. кубы карт).
func _pool(p: Dictionary, c: Dictionary) -> int:
	if c.has("fixed_pool"):
		return maxi(1, int(c["fixed_pool"]))
	var skill: String = String(c.get("skill", "will"))
	var active: Array = c.get("active_mods", [])
	var stat: String = Dice.substituted_skill(active, skill)
	var inv: Dictionary = Investigators.get_data(String(p.get(PlayerKeys.INVESTIGATOR, "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get(stat, 1))
	var mods: int = int((p.get(PlayerKeys.SKILL_MODS, {}) as Dictionary).get(stat, 0))
	var bonus: int = Dice.pre_roll_bonus(active, skill)
	return maxi(1, base + mods + int(c.get("modifier", 0)) + bonus)


# ── Фаза встреч ───────────────────────────────────────────────────────────────


func _encounter_intent(_pid: String, _p: Dictionary, role: String = "runner") -> Dictionary:
	var choices: Array = _gs.get("encounter_choices")
	if not choices.is_empty():
		return {"action": RelayActions.CHOOSE_ENCOUNTER, "kind": pick_choice(choices, role)}
	var enc: Dictionary = _gs.get("current_encounter")
	if enc.is_empty():
		return {}  # карта ещё генерится
	var pending: Dictionary = enc.get("pending_choice", {})
	if not pending.is_empty():
		return {
			"action": RelayActions.CHOOSE_EFFECT, "index": _rand_index(pending.get("options", []))
		}
	var ac: Dictionary = _gs.get("active_check")
	var rolled: bool = bool(ac.get("rolled", false))
	var kind: String = String(enc.get("kind", ""))
	if kind == "combat":
		# Зеркало combat_modal: Воля → (Сила) → завершить.
		var has_will: bool = enc.has("will")
		var done: bool = enc.has("resolution")
		var skip_str: bool = (
			bool(enc.get("defeated_on_horror", false))
			or bool(enc.get("defeated_by_trigger", false))
			or bool(enc.get("no_strength_step", false))
		)
		var str_step: bool = has_will and not skip_str
		if done or (str_step and rolled):
			return {"action": RelayActions.FINISH_ENCOUNTER}
		return {"action": RelayActions.RESOLVE_ENCOUNTER}
	if kind == "gate" or kind == "mystery":
		var stage: int = int(enc.get("stage", 0))
		var branch: Dictionary = (enc.get("branches", {}) as Dictionary).get(
			String(enc.get("branch", "success")), {}
		)
		if stage == 1 and (branch.get("test", {}) as Dictionary).is_empty():
			return {"action": RelayActions.FINISH_ENCOUNTER}  # ветка без проверки
		if not rolled:
			return {"action": RelayActions.RESOLVE_ENCOUNTER}
		if int(enc.get("stage", 0)) == 0:
			return {"action": RelayActions.ADVANCE_STAGE}
		return {"action": RelayActions.FINISH_ENCOUNTER}
	# Плоская карта: без проверки — сразу завершить; иначе бросить, потом завершить.
	if (enc.get("test", {}) as Dictionary).is_empty() or rolled:
		return {"action": RelayActions.FINISH_ENCOUNTER}
	return {"action": RelayActions.RESOLVE_ENCOUNTER}


## Вид встречи из предложенных: порядок боёв — первый; боец выбирает врата (круг)
## раньше улики, остальные — по _CHOICE_ORDER.
func pick_choice(choices: Array, role: String = "runner") -> String:
	for c_v: Variant in choices:
		if String(c_v).begins_with("combat"):
			return String(c_v)
	if role == "fighter" and choices.has("gate"):
		return "gate"
	for want: String in _CHOICE_ORDER:
		if choices.has(want):
			return want
	return String(choices[0])


func _rand_index(options: Array) -> int:
	if options.is_empty():
		return 0
	return rng.randi_range(0, options.size() - 1)
