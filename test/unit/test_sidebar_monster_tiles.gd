## Монстры локации в сайдбаре — квадратные портреты как в модалке боя: арт, ужас
## (слева) и урон (справа); полные статы — в подсказке.
extends GutTest

var _sb: LocationSidebar


func before_each() -> void:
	_sb = LocationSidebar.new()
	autofree(_sb)


func test_tile_is_square_with_two_numbers() -> void:
	var tile: Control = autofree(_sb._make_monster_tile(MonsterCatalog.by_id("byakhee"), 1))
	assert_eq(tile.custom_minimum_size.x, tile.custom_minimum_size.y, "квадрат")
	assert_not_null(tile.get_node_or_null("Art"), "арт монстра")
	assert_eq((tile.get_node("Horror") as Label).text, "1", "ужас")
	assert_eq((tile.get_node("Damage") as Label).text, "2", "урон")
	assert_string_contains(tile.tooltip_text, "1 /", "текущая стойкость в подсказке")


func test_ancient_dependent_monster_has_no_numbers() -> void:
	var tile: Control = autofree(_sb._make_monster_tile(MonsterCatalog.by_id("cultist")))
	assert_null(tile.get_node_or_null("Horror"), "статы зависят от Древнего — чисел нет")
	assert_null(tile.get_node_or_null("Damage"))
