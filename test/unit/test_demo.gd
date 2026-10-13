## Demo: в демо-сборке меню комнат и вход недоступны — переходы уводят на главную.
extends GutTest


func after_each() -> void:
	Demo.forced = false


func test_redirect_only_in_demo() -> void:
	assert_eq(Demo.redirect("main_menu"), "main_menu", "полная игра — как есть")
	Demo.forced = true
	assert_true(Demo.active())
	assert_eq(Demo.redirect("main_menu"), "home")
	assert_eq(Demo.redirect("login"), "home")
	assert_eq(Demo.redirect("lobby"), "lobby", "выбор сыщика остаётся")
	assert_eq(Demo.redirect("world_map"), "world_map")
	assert_eq(Demo.SEATS, 3, "гость + 2 бота")


func test_demo_content_narrows_pools_only_in_demo() -> void:
	Demo.set_content({"assets": ["38_revolver"], "investigators": ["Frank Dalton"]})
	var rev := {"id": "38_revolver", "season": "core"}
	var axe := {"id": "axe", "season": "core"}
	var frank := {"name": "Frank Dalton", "season": "core"}
	var mei := {"name": "Mei Lin", "season": "core"}
	var spell := {"id": "wither", "season": "core"}
	assert_true(SeasonGate.room_allows(axe, "assets"), "полная игра — без сужения")
	Demo.forced = true
	assert_true(SeasonGate.room_allows(rev, "assets"))
	assert_false(SeasonGate.room_allows(axe, "assets"), "не в демо-наборе")
	assert_true(SeasonGate.room_allows(spell, "spells"), "вида нет в наборе — не ограничен")
	assert_true(SeasonGate.room_allows(axe), "без вида — без сужения")
	assert_eq(SeasonGate.filter_own([frank, mei], "investigators"), [frank])
	assert_false(
		SeasonGate.room_allows({"id": "38_revolver", "season": "mom"}, "assets"), "сезон важнее"
	)
	Demo.set_content({})
