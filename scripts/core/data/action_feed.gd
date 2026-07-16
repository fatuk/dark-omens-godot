class_name ActionFeed
extends RefCounted

## Лента исходов эффектов: diff состояния сыщика ДО/ПОСЛЕ применения эффектов →
## облачка над фишкой (видят все) через GameState.announce_action. Отделено от
## GameState, чтобы не раздувать его публичный API. Зовётся из мест применения
## ЭФФЕКТОВ (встречи/мифы/бой), НЕ из действий — иначе дублировались бы облачка
## «взять фокус/ресурс».


## Чистый diff состояния → список событий ленты [{id, params}]. hp/sanity: вниз =
## урон (hurt/sanity_hit), вверх = лечение (healed/sanity_healed); новые состояния =
## afflicted (имя из COND_*_NAME); прирост жетонов (улика/фокус/ресурс) = got_*.
static func delta_events(before: Dictionary, after: Dictionary) -> Array:
	var out: Array = []
	var hp_d: int = int(after.get("hp", 0)) - int(before.get("hp", 0))
	if hp_d < 0:
		out.append({"id": "hurt", "params": {"amount": str(-hp_d)}})
	elif hp_d > 0:
		out.append({"id": "healed", "params": {"amount": str(hp_d)}})
	var san_d: int = int(after.get("sanity", 0)) - int(before.get("sanity", 0))
	if san_d < 0:
		out.append({"id": "sanity_hit", "params": {"amount": str(-san_d)}})
	elif san_d > 0:
		out.append({"id": "sanity_healed", "params": {"amount": str(san_d)}})
	var before_c: Array = before.get("conditions", [])
	var after_c: Array = after.get("conditions", [])
	for c_v: Variant in after_c:
		if not before_c.has(c_v):  # новое состояние
			out.append(
				{"id": "afflicted", "params": {"condition": Conditions.name_key(String(c_v))}}
			)
	for c_v: Variant in before_c:
		if not after_c.has(c_v):  # снятое состояние
			out.append({"id": "cured", "params": {"condition": Conditions.name_key(String(c_v))}})
	# Жетоны: прирост = got_*, трата = spent_* (с числом).
	for tok_v: Variant in [
		["clues", "got_clue", "spent_clue"],
		["concentration", "got_focus", "spent_focus"],
		["resources", "got_resource", "spent_resource"],
	]:
		var tok: Array = tok_v
		var d: int = int(after.get(tok[0], 0)) - int(before.get(tok[0], 0))
		if d > 0:
			out.append({"id": String(tok[1]), "params": {}})
		elif d < 0:
			out.append({"id": String(tok[2]), "params": {"amount": str(-d)}})
	return out


## Хост: применить diff как ленту исходов. gs — GameState (зовём его _is_host() и
## announce_action). Не-хост / нет изменений → ничего.
static func announce_deltas(gs: Node, pid: String, before: Dictionary, after: Dictionary) -> void:
	if not gs._is_host():
		return
	for e_v: Variant in delta_events(before, after):
		var e: Dictionary = e_v
		gs.announce_action(pid, String(e.get("id", "")), e.get("params", {}))
