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
	for c_v: Variant in after.get("conditions", []):
		if not before_c.has(c_v):
			out.append(
				{"id": "afflicted", "params": {"condition": Conditions.name_key(String(c_v))}}
			)
	if int(after.get("clues", 0)) > int(before.get("clues", 0)):
		out.append({"id": "got_clue", "params": {}})
	if int(after.get("concentration", 0)) > int(before.get("concentration", 0)):
		out.append({"id": "got_focus", "params": {}})
	if int(after.get("resources", 0)) > int(before.get("resources", 0)):
		out.append({"id": "got_resource", "params": {}})
	return out


## Хост: применить diff как ленту исходов. gs — GameState (зовём его _is_host() и
## announce_action). Не-хост / нет изменений → ничего.
static func announce_deltas(gs: Node, pid: String, before: Dictionary, after: Dictionary) -> void:
	if not gs._is_host():
		return
	for e_v: Variant in delta_events(before, after):
		var e: Dictionary = e_v
		gs.announce_action(pid, String(e.get("id", "")), e.get("params", {}))
