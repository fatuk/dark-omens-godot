class_name GameRecap
extends RefCounted

## Итоги партии для экрана «Итоги» после финала. Копит ленту действий
## (GameState.action_announced) и вехи из стейта: в каком раунде пал сыщик и когда
## решена Тайна. Лента приходит любому клиенту (хост эмитит её себе сам, остальные
## получают через реле), поэтому итоги одинаково работают онлайн, офлайн и в демо,
## без сервера. Транзиентно: на диск не пишем, сброс — со стартом новой партии.

## Титулы: [ключ перевода, счётчик]. Каждый титул — одному сыщику (максимум > 0,
## при равенстве — кто раньше в очереди хода), у сыщика не больше одного титула.
## Порядок = приоритет.
const TITLES := [
	["RECAP_TITLE_HUNTER", "kills"],
	["RECAP_TITLE_SCHOLAR", "clues"],
	["RECAP_TITLE_MARTYR", "wounds"],
	["RECAP_TITLE_MYSTIC", "spells"],
	["RECAP_TITLE_WANDERER", "travels"],
]

## Счётчики сыщика (порядок = порядок строк на карточке итогов).
const COUNTERS := ["kills", "clues", "wounds", "encounters", "spells", "travels"]

# Действия ленты, которые считаются «встречей» (тип не-боевой встречи — encounter_flow).
const _ENCOUNTER_IDS := ["encounter", "research", "gate", "mystery", "eldritch"]

var _tracking: bool = false
var _started_ms: int = 0
var _ended_ms: int = 0
var _stats: Dictionary = {}  # pid -> {counter: int}
var _fell: Dictionary = {}  # pid -> раунд гибели
var _solved: Array = []  # [{index, round}] — решённые Тайны по порядку
var _last_mystery: int = 0


func reset() -> void:
	_tracking = false
	_started_ms = 0
	_ended_ms = 0
	_stats = {}
	_fell = {}
	_solved = []
	_last_mystery = 0


## Действие из ленты (pid, id ActionLog, params — плейсхолдер → значение).
func on_action(pid: String, action_id: String, params: Dictionary) -> void:
	var s: Dictionary = _stats_of(pid)
	var amount: int = maxi(1, int(String(params.get("amount", "1"))))
	match action_id:
		"combat_won":
			s["kills"] += 1
		"hurt", "sanity_hit":
			s["wounds"] += amount
		"got_clue":
			s["clues"] += amount
		"cast_spell":
			s["spells"] += 1
		"travel":
			s["travels"] += 1
		_:
			if _ENCOUNTER_IDS.has(action_id):
				s["encounters"] += 1


## Свериться со стейтом (зовётся на каждый state_changed). gs — GameState или мок с
## полями active/outcome/round_num/active_mystery/players.
func observe(gs: Object, now_ms: int = -1) -> void:
	var now: int = Time.get_ticks_msec() if now_ms < 0 else now_ms
	var outcome: String = String(gs.get("outcome"))
	if not bool(gs.get("active")):
		if outcome.is_empty():
			_tracking = false  # лобби / меню — следующая партия начнётся с чистого листа
		return
	if not _tracking:
		if not outcome.is_empty():
			return  # зашли уже на финал — копить нечего
		reset()
		_tracking = true
		_started_ms = now
		_last_mystery = int(gs.get("active_mystery"))
	var round_num: int = int(gs.get("round_num"))
	var players: Dictionary = gs.get("players")
	for pid_v: Variant in players:
		var pid: String = pid_v
		if bool((players[pid] as Dictionary).get(PlayerKeys.DEAD, false)) and not _fell.has(pid):
			_fell[pid] = round_num
	var mystery: int = int(gs.get("active_mystery"))
	while _last_mystery < mystery:
		_solved.append({"index": _last_mystery, "round": round_num})
		_last_mystery += 1
	if not outcome.is_empty() and _ended_ms == 0:
		_ended_ms = now


## Сводка для экрана итогов:
##   {rounds, doom, doom_clock, minutes, mysteries_solved, mysteries_total,
##    players: [{pid, name, investigator, bot, dead, fell_round, stats, title}],
##    moments: [{round, kind: "mystery"|"fallen", index?, pid?}]}
func summary(gs: Object, now_ms: int = -1) -> Dictionary:
	var now: int = Time.get_ticks_msec() if now_ms < 0 else now_ms
	var campaign: Dictionary = gs.get("campaign")
	var players: Dictionary = gs.get("players")
	var total: int = (campaign.get("mysteries", []) as Array).size()
	var end: int = _ended_ms if _ended_ms > 0 else now
	var rows: Array = []
	for pid_v: Variant in _order(gs):
		var pid: String = pid_v
		var p: Dictionary = players.get(pid, {})
		(
			rows
			. append(
				{
					"pid": pid,
					"name": String(p.get(PlayerKeys.NAME, pid)),
					"investigator": String(p.get(PlayerKeys.INVESTIGATOR, "")),
					"bot": pid.begins_with(OfflineSession.BOT_PREFIX),
					"dead": bool(p.get(PlayerKeys.DEAD, false)),
					"fell_round": int(_fell.get(pid, 0)),
					"stats": _stats_of(pid).duplicate(),
					"title": "",
				}
			)
		)
	_assign_titles(rows)
	var moments: Array = []
	for s_v: Variant in _solved:
		var s: Dictionary = s_v
		moments.append({"round": s["round"], "kind": "mystery", "index": s["index"]})
	for pid_v: Variant in _fell:
		moments.append({"round": _fell[pid_v], "kind": "fallen", "pid": pid_v})
	moments.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["round"] < b["round"])
	return {
		"rounds": int(gs.get("round_num")),
		"doom": int(gs.get("doom")),
		"doom_clock": int(campaign.get("doomClock", 0)),
		"minutes": maxi(0, (end - _started_ms) / 60000) if _tracking else 0,
		"mysteries_solved": mini(int(gs.get("active_mystery")), total),
		"mysteries_total": total,
		"players": rows,
		"moments": moments,
	}


func _stats_of(pid: String) -> Dictionary:
	if not _stats.has(pid):
		var s: Dictionary = {}
		for c: String in COUNTERS:
			s[c] = 0
		_stats[pid] = s
	return _stats[pid]


# Порядок сыщиков: очередь хода, затем остальные (поздние подключения).
func _order(gs: Object) -> Array:
	var out: Array = (gs.get("turn_order") as Array).duplicate()
	for pid_v: Variant in gs.get("players"):
		if not out.has(pid_v):
			out.append(pid_v)
	return out


static func _assign_titles(rows: Array) -> void:
	for t_v: Variant in TITLES:
		var t: Array = t_v
		var best: Dictionary = {}
		var best_n: int = 0
		for r_v: Variant in rows:
			var r: Dictionary = r_v
			var n: int = int((r["stats"] as Dictionary).get(t[1], 0))
			if String(r["title"]).is_empty() and n > best_n:
				best = r
				best_n = n
		if not best.is_empty():
			best["title"] = t[0]
