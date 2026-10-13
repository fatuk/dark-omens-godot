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
