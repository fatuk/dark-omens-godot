class_name TargetResolver
extends RefCounted

## Подсистема адресных эффектов (target) и передач между сыщиками. Вынесена из
## GameState. Игровой verb с целью lead/each/eachOn*/chosenInvestigator применяется
## к КАЖДОМУ разрешённому сыщику; give* (giveAsset/giveClue) — передача от активного
## игрока выбранному. Зовётся из GameState._apply_board_effect.
##
## Доступ к стейту — через _gs: _gs.players, _gs.turn_order, _gs._current_pid(),
## _gs._name_of(), _gs._load_locations(). Создаётся в GameState (поле _target).

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


## Эффект адресован конкретным сыщикам (не доске): игровой verb с целью
## lead/each/eachOn*/chosenInvestigator, либо передача актива/улики (give*).
func is_targeted_effect(node: Dictionary) -> bool:
	var verb: String = String(node.get("do", ""))
	if verb == "giveAsset" or verb == "giveClue":
		return true
	var target: String = String(node.get("target", ""))
	if target.is_empty() or target == "self":
		return false
	return _EffectRunner.is_player_verb(verb)


## Применить адресный эффект ко всем разрешённым сыщикам. give* — передача от
## активного игрока выбранному; прочие игровые verb'ы — каждому из целей.
func apply_targeted_effect(node: Dictionary) -> void:
	var verb: String = String(node.get("do", ""))
	var times: int = maxi(1, int(node.get("_times", 1)))
	var targets: Array = _resolve_targets(node)
	if (targets as Array).is_empty():
		return
	for pid_v: Variant in targets:
		var pid: String = String(pid_v)
		if not _gs.players.has(pid):
			continue
		for _t in range(times):
			if verb == "giveAsset" or verb == "giveClue":
				_apply_give(verb, node, pid)
			else:
				var logs: Array = _EffectRunner.apply_player_verb(verb, node, _gs.players[pid])
				for log_msg: Variant in logs:
					GameConsole.log("[Эффект→%s] %s" % [_gs._name_of(pid), String(log_msg)])


# Список сыщиков-целей по target. lead → ведущий (turn_order[0]); each → все
# подключённые; eachOn* → подключённые на локации указанного типа;
# chosenInvestigator/chosen → заранее выбранный (_target_pid); иначе → активный.
func _resolve_targets(node: Dictionary) -> Array:
	var target: String = String(node.get("target", ""))
	match target:
		"lead":
			# Ведущий = turn_order[0], но если он Тень — берём первого живого.
			var live: Array = _connected_pids()
			return [String(live[0])] if not live.is_empty() else []
		"each":
			return _connected_pids()
		"eachOnCity":
			return _pids_on_loc_type("city")
		"eachOnWilderness":
			return _pids_on_loc_type("wilderness")
		"eachOnSea":
			return _pids_on_loc_type("sea")
		"eachOnSpace":
			return _pids_on_loc_type("space")
		"chosenInvestigator", "chosen":
			var pid: String = String(node.get("_target_pid", ""))
			return [pid] if not pid.is_empty() and _gs.players.has(pid) else []
		"rightNeighbor":
			return _neighbor(_anchor_pid(node), 1)
		"leftNeighbor":
			return _neighbor(_anchor_pid(node), -1)
		_:
			var a: String = _gs._current_pid()
			return [a] if not a.is_empty() else []


# Якорь относительных целей: явный _anchor_pid (ставит forEach-драйвер Мифов) либо
# активный игрок (встречи). Сосед считается ОТ него.
func _anchor_pid(node: Dictionary) -> String:
	return String(node.get("_anchor_pid", _gs._current_pid()))


# Сосед якоря среди подключённых (порядок turn_order, со wrap): dir +1 — по часовой
# (следующий), −1 — против. Якоря нет в списке / игрок один → пусто.
func _neighbor(anchor: String, dir: int) -> Array:
	if anchor.is_empty():
		return []
	var pids: Array = _connected_pids()
	var n: int = (pids as Array).size()
	if n <= 1:
		return []
	var idx: int = (pids as Array).find(anchor)
	if idx < 0:
		return []
	return [String(pids[((idx + dir) % n + n) % n])]


## Прочие живые сыщики как [{pid, name}] — варианты интерактивного выбора цели
## (target chosenInvestigator: передача активов/улик).
func other_pids(exclude_pid: String) -> Array:
	var out: Array = []
	for pid_v: Variant in _connected_pids():
		var pid: String = String(pid_v)
		if pid != exclude_pid:
			out.append({"pid": pid, "name": _gs._name_of(pid)})
	return out


# Подключённые ЖИВЫЕ сыщики (id), в порядке turn_order. Тень (dead) — не тело,
# не цель для эффектов/решений/Мифов, поэтому исключается наравне с отключёнными.
func _connected_pids() -> Array:
	var out: Array = []
	for pid_v: Variant in _gs.turn_order:
		var pid: String = String(pid_v)
		if (
			_gs.players.has(pid)
			and bool(_gs.players[pid].get("connected", true))
			and not bool(_gs.players[pid].get("dead", false))
		):
			out.append(pid)
	return out


# Подключённые сыщики на локации заданного типа (city/wilderness/sea/space).
func _pids_on_loc_type(loc_type: String) -> Array:
	var out: Array = []
	for pid_v: Variant in _connected_pids():
		var pid: String = String(pid_v)
		if _loc_type_of(String(_gs.players[pid].get("location", ""))) == loc_type:
			out.append(pid)
	return out


# Тип локации по id (из data/locations.json). Пусто → "".
func _loc_type_of(loc_id: String) -> String:
	if loc_id.is_empty():
		return ""
	var locations: Array = _gs._load_locations()
	for i in range(locations.size()):
		var loc: Dictionary = locations[i]
		if String(loc.get("id", "")) == loc_id:
			return String(loc.get("type", ""))
	return ""


# Передача от активного игрока выбранному: giveClue — улики (сколько есть, до n);
# giveAsset — один предмет (с конца стопки). Источник — активный игрок встречи.
func _apply_give(verb: String, node: Dictionary, target_pid: String) -> void:
	var src: String = _gs._current_pid()
	if src.is_empty() or not _gs.players.has(src) or src == target_pid:
		return
	if verb == "giveClue":
		var want: int = int(node.get("count", node.get("amount", 1)))
		var avail: int = int(_gs.players[src].get("clues", 0))
		var moved: int = mini(want, avail)
		if moved <= 0:
			return
		_gs.players[src]["clues"] = avail - moved
		_gs.players[target_pid]["clues"] = int(_gs.players[target_pid].get("clues", 0)) + moved
		GameConsole.log(
			"[Эффект] %s → %s: улик %d" % [_gs._name_of(src), _gs._name_of(target_pid), moved]
		)
	elif verb == "giveAsset":
		var items: Array = _gs.players[src].get("items", [])
		if (items as Array).is_empty():
			return
		var it: Variant = items.pop_back()
		_gs.players[src]["items"] = items
		var titems: Array = _gs.players[target_pid].get("items", [])
		titems.append(it)
		_gs.players[target_pid]["items"] = titems
		GameConsole.log("[Эффект] %s → %s: предмет" % [_gs._name_of(src), _gs._name_of(target_pid)])
