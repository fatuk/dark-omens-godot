extends GutTest

## TravelPlanner: базовый ход бесплатен (любой тип, один раз), дальше платим
## билетами по типу связи; uncharted оплатить нельзя. Граф:
##   A =train= B =train= C
##   A =ship=  D
##   B =uncharted= E
var _locs: Array = [
	{"id": "A", "connections": [{"to": "B", "type": "train"}, {"to": "D", "type": "ship"}]},
	{
		"id": "B",
		"connections":
		[
			{"to": "A", "type": "train"},
			{"to": "C", "type": "train"},
			{"to": "E", "type": "uncharted"},
		]
	},
	{"id": "C", "connections": [{"to": "B", "type": "train"}]},
	{"id": "D", "connections": [{"to": "A", "type": "ship"}]},
	{"id": "E", "connections": [{"to": "B", "type": "uncharted"}]},
]


func test_base_hop_reaches_neighbors_free() -> void:
	var r: Dictionary = TravelPlanner.plan(_locs, "A", 0, 0)
	assert_true(r.has("B"), "сосед B по базовому ходу")
	assert_true(r.has("D"), "сосед D по базовому ходу")
	assert_eq(int(r["B"]["train"]), 0, "базовый хоп бесплатен")
	assert_eq(int(r["B"]["ship"]), 0)
	assert_false(r.has("A"), "origin в результат не входит")
	assert_false(r.has("C"), "C за билет — без билетов недостижим")
	assert_false(r.has("E"), "E только через uncharted после базы — недостижим")


func test_train_ticket_unlocks_second_hop() -> void:
	var r: Dictionary = TravelPlanner.plan(_locs, "A", 1, 0)
	assert_true(r.has("C"), "C достижим за 1 ж/д-билет")
	assert_eq(int(r["C"]["train"]), 1, "второй хоп A→B→C оплачен билетом")
	assert_eq(r["C"]["path"], ["A", "B", "C"], "путь через B")


func test_base_deferred_to_cover_uncharted() -> void:
	# E за B по uncharted. Оптимум: A→B ОПЛАТИТЬ ж/д, B→E пройти БАЗОЙ (база
	# приберегается под неоплачиваемый сегмент). Так E достижим за 1 ж/д-билет.
	var r: Dictionary = TravelPlanner.plan(_locs, "A", 1, 0)
	assert_true(r.has("E"), "E достижим: базу тратим на uncharted-сегмент")
	assert_eq(int(r["E"]["train"]), 1, "оплачен train-сегмент A→B")
	assert_eq(r["E"]["path"], ["A", "B", "E"])


func test_ship_ticket_does_not_unlock_train_or_uncharted() -> void:
	var r: Dictionary = TravelPlanner.plan(_locs, "A", 0, 1)
	assert_true(r.has("B") and r.has("D"), "соседи по базе")
	assert_false(r.has("C"), "морской билет не оплачивает train-связь")
	assert_false(r.has("E"), "и не оплачивает uncharted")


func test_cost_to_unreachable_returns_empty() -> void:
	assert_eq(TravelPlanner.cost_to(_locs, "A", "C", 0, 0), {}, "C без билетов недостижим")
	var c: Dictionary = TravelPlanner.cost_to(_locs, "A", "C", 2, 0)
	assert_eq(int(c["train"]), 1, "нужен только 1 билет, хоть на руках 2")
