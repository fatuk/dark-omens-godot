class_name TravelPlanner
extends RefCounted

## Планировщик перемещения с билетами. Базовый ход — ПЕРВЫЙ хоп: любой сосед
## origin бесплатно, по связи любого типа (в т.ч. `uncharted`-тропа). Дальше —
## только по train/ship за билет соответствующего типа. `uncharted` дальше первого
## хода непроходим: тропу можно пройти лишь базовым ходом с текущей клетки, её
## нельзя «дотянуть» билетами. Возвращает минимально-билетную стоимость и путь до
## каждой достижимой локации (в пределах билетов на руках).
##
## Чистая функция от (граф, старт, билеты) — один и тот же результат на клиенте
## (показ стоимости/маршрута) и на хосте (валидация и списание). Граф крошечный,
## а сумма билетов ≤ MAX_TICKETS, поэтому путь ≤ 1(база)+train+ship хопов.

# Типы связей, оплачиваемые билетами (порядок ↔ поле билета в игроке).
const TICKET_FOR := {"train": "train_tickets", "ship": "ship_tickets"}


## Достижимые локации из origin: {dest_id: {"train":int, "ship":int, "path":[ids]}}.
## path включает origin первым элементом (сегменты — соседние пары). Дешевле по
## суммарному числу билетов; origin в результат не входит.
static func plan(locations: Array, origin: String, held_train: int, held_ship: int) -> Dictionary:
	var adj: Dictionary = _adjacency(locations)
	var result: Dictionary = {}
	# hop1 — базовый ход: все соседи origin бесплатно, ЛЮБОЙ тип связи.
	var frontier: Array = []
	for e_v: Variant in adj.get(origin, []):
		var to0: String = String((e_v as Dictionary).get("to", ""))
		if to0.is_empty() or to0 == origin:
			continue
		frontier.append({"node": to0, "t": 0, "s": 0, "path": [origin, to0], "total": 0})
	# hop2+ — только train/ship за билет. Раскрываем по возрастанию суммы билетов
	# (pop-min), поэтому первый заход в узел — минимальный, его и фиксируем.
	while not frontier.is_empty():
		var bi: int = 0
		for i in range(frontier.size()):
			if int(frontier[i]["total"]) < int(frontier[bi]["total"]):
				bi = i
		var cur: Dictionary = frontier.pop_at(bi)
		var node: String = String(cur["node"])
		if result.has(node):
			continue  # уже зафиксирован с не большей стоимостью — не раскрываем повторно
		result[node] = {
			"train": int(cur["t"]),
			"ship": int(cur["s"]),
			"path": (cur["path"] as Array).duplicate()
		}
		for e_v2: Variant in adj.get(node, []):
			var e: Dictionary = e_v2
			var to: String = String(e.get("to", ""))
			var ty: String = String(e.get("type", ""))
			if to.is_empty() or (cur["path"] as Array).has(to):
				continue  # без циклов по пути
			var next_path: Array = (cur["path"] as Array) + [to]
			if ty == "train" and int(cur["t"]) < held_train:
				frontier.append(
					{
						"node": to,
						"t": int(cur["t"]) + 1,
						"s": int(cur["s"]),
						"path": next_path,
						"total": int(cur["total"]) + 1
					}
				)
			elif ty == "ship" and int(cur["s"]) < held_ship:
				frontier.append(
					{
						"node": to,
						"t": int(cur["t"]),
						"s": int(cur["s"]) + 1,
						"path": next_path,
						"total": int(cur["total"]) + 1
					}
				)
	return result


## Локации в пределах hops шагов от origin — для эффектов «переместитесь на N
## локаций» (Чартерный рейс): билеты не нужны, тип связи не важен. hops <= 0 —
## перемещение куда угодно (Частный рейс): отдаём все локации, кроме origin.
## `uncharted`-тропа, как и в plan(), проходима только ПЕРВЫМ шагом.
static func within_hops(locations: Array, origin: String, hops: int) -> Array:
	if hops <= 0:
		var all: Array = []
		for loc_v: Variant in locations:
			var id: String = String((loc_v as Dictionary).get("id", ""))
			if not id.is_empty() and id != origin:
				all.append(id)
		return all
	var adj: Dictionary = _adjacency(locations)
	var seen: Dictionary = {origin: true}
	var out: Array = []
	var frontier: Array = [origin]
	for step in range(hops):
		var next_frontier: Array = []
		for node_v: Variant in frontier:
			for e_v: Variant in adj.get(String(node_v), []):
				var e: Dictionary = e_v
				var to: String = String(e.get("to", ""))
				if to.is_empty() or seen.has(to):
					continue
				if String(e.get("type", "")) == "uncharted" and step > 0:
					continue  # тропу можно пройти только базовым шагом
				seen[to] = true
				out.append(to)
				next_frontier.append(to)
		frontier = next_frontier
	return out


## Стоимость и путь до dest, либо {} если недостижим при данных билетах.
static func cost_to(
	locations: Array, origin: String, dest: String, held_train: int, held_ship: int
) -> Dictionary:
	return plan(locations, origin, held_train, held_ship).get(dest, {})


static func _total(entry: Dictionary) -> int:
	return int(entry.get("train", 0)) + int(entry.get("ship", 0))


# {loc_id: [{to, type}, …]} из массива локаций.
static func _adjacency(locations: Array) -> Dictionary:
	var adj: Dictionary = {}
	for loc_v: Variant in locations:
		var loc: Dictionary = loc_v
		adj[String(loc.get("id", ""))] = loc.get("connections", [])
	return adj
