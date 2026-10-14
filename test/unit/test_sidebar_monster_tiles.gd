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


func test_items_have_no_separators_and_no_monsters_header() -> void:
	var sb: LocationSidebar = add_child_autofree(
		load("res://scenes/ui/location_sidebar.tscn").instantiate()
	)
	var saved: Dictionary = GameState.monsters
	GameState.monsters = {"t": [{"id": "byakhee", "health": 2}]}
	sb._populate_items("t")
	GameState.monsters = saved
	assert_eq(sb.find_children("*", "HSeparator", true, false), [], "секции без линий")
	var list: Node = sb._items_list
	assert_eq(list.get_child(0).name, &"MonsterGrid", "сразу портреты, без «Монстры — N»")


func test_tiles_fill_row_width() -> void:
	for w: float in [300.0, 480.0, 560.0, 700.0]:
		var side: float = LocationSidebar.monster_tile_side(w)
		var cols: int = int((w + LocationSidebar._MON_GAP) / (side + LocationSidebar._MON_GAP))
		var used: float = cols * side + (cols - 1) * LocationSidebar._MON_GAP
		assert_true(side >= LocationSidebar._MON_TILE, "не мельче минимума (%d)" % w)
		assert_almost_eq(used, w, float(cols), "ряд от края до края (%d)" % w)
