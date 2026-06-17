extends GutTest

## Юнит-тесты словаря чата (scripts/core/data/messages.gd): рендер фразы на en/ru,
## 1/2 слота, двойной {noun} (одно слово в оба места), неизвестные id, секции категорий.
## Данные грузятся из data/messages.json статическим загрузчиком (class_name Messages).


func test_render_one_slot_en() -> void:
	# noun_here: "{noun} here" / "Здесь {noun}".
	assert_eq(Messages.render("noun_here", ["shoggoth"], "en"), "Shoggoth here")


func test_render_one_slot_ru() -> void:
	assert_eq(Messages.render("noun_here", ["shoggoth"], "ru"), "Здесь Шоггот")


func test_render_two_slots() -> void:
	# telegraph_pair: "{noun}, {noun2}" — два РАЗНЫХ слова.
	assert_eq(Messages.render("telegraph_pair", ["gate", "monster"], "en"), "Gate, Monster")
	assert_eq(Messages.render("telegraph_pair", ["gate", "monster"], "ru"), "Врата, Монстр")


func test_render_double_noun_same_word() -> void:
	# invocation_double: ОБА {noun} заполняются ОДНИМ выбранным словом.
	assert_eq(
		Messages.render("invocation_double", ["ancient_one"], "en"),
		"O The Ancient One, The Ancient One!"
	)
	assert_eq(Messages.render("invocation_double", ["ancient_one"], "ru"), "Древний, о Древний!")


func test_render_unknown_phrase_is_empty() -> void:
	assert_eq(Messages.render("no_such_phrase", ["doom"], "en"), "")


func test_render_unknown_noun_blank() -> void:
	# Неизвестное слово → пустая подстановка (каркас фразы остаётся).
	assert_eq(Messages.render("noun_here", ["nope"], "en"), " here")


func test_slots_count() -> void:
	assert_eq(Messages.slots("noun_here"), 1)
	assert_eq(Messages.slots("telegraph_pair"), 2)
	assert_eq(Messages.slots("invocation_double"), 1, "двойной {noun} — всё равно 1 слот")


func test_nouns_in_category() -> void:
	var skills: Array = Messages.nouns_in("skill")
	assert_eq(skills.size(), 5, "5 навыков")
	var ids: Array = []
	for s_v: Variant in skills:
		ids.append(String((s_v as Dictionary).get("id", "")))
	assert_true(ids.has("will") and ids.has("lore"), "влияние/знание в навыках")


func test_category_title_localized() -> void:
	assert_eq(Messages.category_title("being", "ru"), "Существа")
	assert_eq(Messages.category_title("being", "en"), "Beings")


func test_fill_preview_with_blank() -> void:
	# Превью незаполненного слота: подставляем "____".
	assert_eq(Messages.fill("noun_here", ["____"], "en"), "____ here")
