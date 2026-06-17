extends GutTest

## Юнит-тесты словаря «ленты действий» (scripts/core/data/action_log.gd): рендер шаблона на
## en/ru, подстановка параметра, безпараметровые действия, неизвестный id, валидатор entry().
## Параметры в тестах — литералы (не i18n-ключи), поэтому TranslationServer.translate возвращает
## их без изменений, и проверка детерминирована без зависимости от таблиц перевода.


func test_render_no_param_en() -> void:
	assert_eq(ActionLog.render("rest", {}, "en"), "Stops to rest.")


func test_render_no_param_ru() -> void:
	assert_eq(ActionLog.render("rest", {}, "ru"), "Переводит дух.")


func test_render_with_place_param() -> void:
	assert_eq(ActionLog.render("travel", {"place": "Tokyo"}, "en"), "Sets out — Tokyo.")
	assert_eq(ActionLog.render("travel", {"place": "Токио"}, "ru"), "Держит путь… Токио.")


func test_render_with_monster_param() -> void:
	assert_eq(ActionLog.render("combat", {"monster": "Cultist"}, "en"), "A clash! Cultist.")
	assert_eq(ActionLog.render("combat", {"monster": "Культист"}, "ru"), "Схватка! Культист.")


func test_render_with_condition_param() -> void:
	assert_eq(
		ActionLog.render("condition_action", {"condition": "Болезнь"}, "ru"),
		"Силится одолеть… Болезнь."
	)


func test_render_locale_fallback_to_en() -> void:
	# Несуществующая локаль → берём en.
	assert_eq(ActionLog.render("rest", {}, "zz"), "Stops to rest.")


func test_render_unknown_action_is_empty() -> void:
	assert_eq(ActionLog.render("no_such_action", {"place": "X"}, "en"), "")


func test_entry_known_and_unknown() -> void:
	assert_false(ActionLog.entry("combat_won").is_empty(), "combat_won есть в словаре")
	assert_true(ActionLog.entry("no_such_action").is_empty(), "неизвестное действие — {}")
