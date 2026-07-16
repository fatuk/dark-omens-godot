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


# ── Лента исходов (ActionFeed.delta_events + новые записи словаря) ───────────────


func test_render_new_outcome_ids() -> void:
	assert_eq(ActionLog.render("hurt", {"amount": "2"}, "ru"), "Ранен. −2.")
	assert_eq(ActionLog.render("sanity_hit", {"amount": "1"}, "en"), "Sanity reels. −1.")
	assert_true(
		ActionLog.render("afflicted", {"condition": "COND_POISONED_NAME"}, "en").begins_with(
			"Afflicted"
		)
	)
	assert_false(ActionLog.entry("got_resource").is_empty(), "got_resource есть в словаре")


func test_delta_events_damage_and_condition() -> void:
	var before: Dictionary = {"hp": 5, "sanity": 5, "conditions": []}
	var after: Dictionary = {"hp": 3, "sanity": 5, "conditions": ["poisoned"]}
	var ev: Array = ActionFeed.delta_events(before, after)
	assert_eq(ev.size(), 2, "урон + состояние")
	assert_eq(String((ev[0] as Dictionary)["id"]), "hurt")
	assert_eq(String(((ev[0] as Dictionary)["params"] as Dictionary)["amount"]), "2")
	assert_eq(String((ev[1] as Dictionary)["id"]), "afflicted")


func test_delta_events_heal_and_tokens() -> void:
	var before: Dictionary = {"hp": 3, "sanity": 3, "clues": 0, "resources": 0}
	var after: Dictionary = {"hp": 5, "sanity": 5, "clues": 1, "resources": 1}
	var ids: Array = []
	for e_v: Variant in ActionFeed.delta_events(before, after):
		ids.append(String((e_v as Dictionary)["id"]))
	assert_true(ids.has("healed"), "лечение hp")
	assert_true(ids.has("sanity_healed"), "лечение рассудка")
	assert_true(ids.has("got_clue"), "улика")
	assert_true(ids.has("got_resource"), "ресурс")


func test_delta_events_no_change_is_empty() -> void:
	var s: Dictionary = {"hp": 5, "sanity": 5, "conditions": ["poisoned"], "clues": 2}
	assert_eq(ActionFeed.delta_events(s, s).size(), 0, "нет изменений — нет событий")
