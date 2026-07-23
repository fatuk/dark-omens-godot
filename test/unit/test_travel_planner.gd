extends GutTest

## TravelPlanner: базовый ход — ПЕРВЫЙ хоп (любой сосед, любой тип, бесплатно),
## дальше только по train/ship за билет; uncharted дальше первого хода непроходим.
## Граф:
##   A =train= B =train= C
##   A =ship=  D
##   A =uncharted= F        (тропа-сосед — проходится базовым ходом)
##   B =uncharted= E        (тропа за городом — билетами НЕ дотянуть)
var _locs: Array = [
	{
		"id": "A",
		"connections":
		[
			{"to": "B", "type": "train"},
			{"to": "D", "type": "ship"},
			{"to": "F", "type": "uncharted"},
		]
	},
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
	{"id": "F", "connections": [{"to": "A", "type": "uncharted"}]},
]


func test_base_hop_reaches_neighbors_free_any_type() -> void:
	var r: Dictionary = TravelPlanner.plan(_locs, "A", 0, 0)
	assert_true(r.has("B"), "сосед B (train) базовым ходом")
	assert_true(r.has("D"), "сосед D (ship) базовым ходом")
	assert_true(r.has("F"), "сосед F (тропа) базовым ходом — любой тип")
	assert_eq(int(r["F"]["train"]), 0, "базовый хоп бесплатен")
	assert_eq(int(r["F"]["ship"]), 0)
	assert_false(r.has("A"), "origin в результат не входит")
	assert_false(r.has("C"), "C за билет — без билетов недостижим")
	assert_false(r.has("E"), "E за тропой города — без билетов недостижим")


func test_train_ticket_unlocks_second_hop() -> void:
	var r: Dictionary = TravelPlanner.plan(_locs, "A", 1, 0)
	assert_true(r.has("C"), "C достижим за 1 ж/д-билет")
	assert_eq(int(r["C"]["train"]), 1, "второй хоп A→B→C оплачен билетом")
	assert_eq(r["C"]["path"], ["A", "B", "C"], "путь через B")


func test_uncharted_not_reachable_via_ticket_chain() -> void:
	# E — тропа ЗА городом B (не сосед origin). Даже с билетами до E не добраться:
	# базовый ход уже потрачен на hop1, а тропу билетом не оплатить. Это фикс бага
	# «Форт-Провиденс подсвечивался»: тропу нельзя «дотянуть» билетами.
	assert_false(
		TravelPlanner.plan(_locs, "A", 2, 2).has("E"), "тропу за городом билетами не пройти"
	)
	# А вот тропа-СОСЕД (F) базовым ходом проходится всегда.
	assert_true(TravelPlanner.plan(_locs, "A", 0, 0).has("F"), "тропа-сосед — базовым ходом")


func test_ship_ticket_does_not_unlock_train() -> void:
	var r: Dictionary = TravelPlanner.plan(_locs, "A", 0, 1)
	assert_true(r.has("B") and r.has("D") and r.has("F"), "соседи по базе")
	assert_false(r.has("C"), "морской билет не оплачивает train-связь")


func test_cost_to_unreachable_returns_empty() -> void:
	assert_eq(TravelPlanner.cost_to(_locs, "A", "C", 0, 0), {}, "C без билетов недостижим")
	var c: Dictionary = TravelPlanner.cost_to(_locs, "A", "C", 2, 0)
	assert_eq(int(c["train"]), 1, "нужен только 1 билет, хоть на руках 2")
