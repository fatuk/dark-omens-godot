class_name TravelPlanner
extends RefCounted

## Планировщик перемещения с билетами. Базовый ход бесплатен (ОДИН раз, по связи
## любого типа), каждый следующий хоп оплачивается билетом типа связи: train →
## ж/д-билет, ship → морской. `uncharted` билетом оплатить нельзя — только базовым
## ходом. Возвращает минимально-билетную стоимость и путь до каждой достижимой
## локации (в пределах билетов на руках).
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
	# Состояние поиска: узел + израсходовано (база/поезд/корабль). Раскрываем по
	# возрастанию суммы потраченных билетов — первый заход в узел даёт минимум.
	var best_state: Dictionary = {}  # "node|base|t|s" -> min total (защита от циклов состояний)
	var frontier: Array = [
		{"node": origin, "base": false, "t": 0, "s": 0, "path": [origin], "total": 0}
	]
	while not frontier.is_empty():
		var bi: int = 0
		for i in range(frontier.size()):
			if int(frontier[i]["total"]) < int(frontier[bi]["total"]):
				bi = i
		var cur: Dictionary = frontier.pop_at(bi)
		var skey: String = (
			"%s|%d|%d|%d" % [cur["node"], int(cur["base"]), int(cur["t"]), int(cur["s"])]
		)
		if best_state.has(skey) and int(best_state[skey]) <= int(cur["total"]):
			continue
		best_state[skey] = int(cur["total"])
		# Записываем минимальную стоимость достижения узла (origin пропускаем).
		var node: String = String(cur["node"])
		if node != origin:
			if not result.has(node) or int(cur["total"]) < _total(result[node]):
				result[node] = {
					"train": int(cur["t"]),
					"ship": int(cur["s"]),
					"path": (cur["path"] as Array).duplicate()
				}
		# Раскрываем соседей.
		for e_v: Variant in adj.get(node, []):
			var e: Dictionary = e_v
			var to: String = String(e.get("to", ""))
			var ty: String = String(e.get("type", ""))
			if (cur["path"] as Array).has(to):
				continue  # без циклов по пути
			var next_path: Array = (cur["path"] as Array) + [to]
			# База: один бесплатный ход по связи ЛЮБОГО типа.
			if not bool(cur["base"]):
				frontier.append(
					{
						"node": to,
						"base": true,
						"t": int(cur["t"]),
						"s": int(cur["s"]),
						"path": next_path,
						"total": int(cur["total"])
					}
				)
			# Билет: следующий хоп по train/ship, если билет есть в запасе.
			if ty == "train" and int(cur["t"]) < held_train:
				frontier.append(
					{
						"node": to,
						"base": bool(cur["base"]),
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
						"base": bool(cur["base"]),
						"t": int(cur["t"]),
						"s": int(cur["s"]) + 1,
						"path": next_path,
						"total": int(cur["total"]) + 1
					}
				)
	return result


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
