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


## Хост: скопить приобретения игрока в players[pid].gains — их покажет модалка
## «вы получили» и очистит по кнопке. Копим, а не перетираем: один миф может
## выдать несколько эффектов подряд, окно должно быть одно.
static func collect_gains(gs: Node, pid: String, before: Dictionary, after: Dictionary) -> void:
	if not gs.is_host() or not gs.players.has(pid):
		return
	var got: Dictionary = gains_summary(before, after)
	if got.is_empty():
		return
	var p: Dictionary = gs.players[pid]
	var acc: Dictionary = p.get("gains", {})
	for k_v: Variant in got:
		var k: String = k_v
		if k == "items":
			var list: Array = acc.get("items", [])
			list.append_array(got["items"])
			acc["items"] = list
		else:
			acc[k] = int(acc.get(k, 0)) + int(got[k])
	p["gains"] = acc


## Хост: результат РОЗЫГРЫША карты (актив с тихим dieRoll и т.п.) — в то же окно
## «вы получили», но с карточкой, выпавшими кубами и событиями на поле, чтобы игрок
## явно увидел, что дал розыгрыш (в т.ч. «ничего»). Показывается всегда, даже без
## приобретений — в отличие от collect_gains. Затирает накопленное: розыгрыш — свой акт.
static func collect_card_result(
	gs: Node,
	pid: String,
	card_id: String,
	before: Dictionary,
	after: Dictionary,
	rolls: Array,
	events: Array
) -> void:
	if not gs.is_host() or not gs.players.has(pid):
		return
	var rec: Dictionary = gains_summary(before, after)
	rec["card"] = card_id
	rec["rolls"] = rolls
	# События сыщика (урон/состояния — их gains_summary не считает) + события поля.
	var evs: Array = delta_events(before, after)
	for e_v: Variant in events:
		evs.append(e_v)
	var kept: Array = []
	for e_v: Variant in evs:
		var e: Dictionary = e_v
		# Приросты жетонов уже показаны рядом иконок — строкой не дублируем.
		if not String(e.get("id", "")).begins_with("got_"):
			kept.append(e)
	rec["events"] = kept
	var p: Dictionary = gs.players[pid]
	p["gains"] = rec


## Приобретения игрока по diff'у — для модалки «вы получили» (мифы/Расплата, где
## выдача проходит молча). ТОЛЬКО прирост: потери и полученные состояния остаются
## лентой над фишкой. Пусто — показывать нечего.
##   {items: [id…], clues, resources, focus, hp, sanity, train, ship}
static func gains_summary(before: Dictionary, after: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for f_v: Variant in [
		["clues", "clues"],
		["resources", "resources"],
		["concentration", "focus"],
		["hp", "hp"],
		["sanity", "sanity"],
		["train_tickets", "train"],
		["ship_tickets", "ship"],
	]:
		var f: Array = f_v
		var d: int = int(after.get(f[0], 0)) - int(before.get(f[0], 0))
		if d > 0:
			out[f[1]] = d
	# Новые карты: сравниваем МУЛЬТИМНОЖЕСТВА id — одинаковых карт может быть
	# несколько, и позиция в инвентаре не гарантирована.
	var got: Array = _items_added(before.get("items", []), after.get("items", []))
	if not got.is_empty():
		out["items"] = got
	return out


# Карты, появившиеся в after и отсутствующие в before (с учётом кратности).
static func _items_added(before: Array, after: Array) -> Array:
	var pool: Array = []
	for it_v: Variant in before:
		pool.append(_item_key(it_v))
	var out: Array = []
	for it_v: Variant in after:
		var k: String = _item_key(it_v)
		var at: int = pool.find(k)
		if at >= 0:
			pool.remove_at(at)  # эта копия уже была
		else:
			out.append(it_v)
	return out


# Ключ карты для сравнения: id + признак заклинания (спелл и актив с тем же id —
# разные карты).
static func _item_key(it: Variant) -> String:
	if it is Dictionary:
		var d: Dictionary = it
		return "%s|%s" % [String(d.get("id", "")), String(d.get("kind", ""))]
	return String(it)


## Хост: применить diff как ленту исходов. gs — GameState (зовём его is_host() и
## announce_action). Не-хост / нет изменений → ничего.
static func announce_deltas(gs: Node, pid: String, before: Dictionary, after: Dictionary) -> void:
	if not gs.is_host():
		return
	for e_v: Variant in delta_events(before, after):
		var e: Dictionary = e_v
		gs.announce_action(pid, String(e.get("id", "")), e.get("params", {}))
