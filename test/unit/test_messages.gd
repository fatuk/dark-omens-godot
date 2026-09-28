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
	assert_eq(Messages.render("invocation_double", ["doom"], "en"), "O Doom, Doom!")
	assert_eq(Messages.render("invocation_double", ["doom"], "ru"), "Рок, о Рок!")


func test_render_unknown_phrase_is_empty() -> void:
	assert_eq(Messages.render("no_such_phrase", ["doom"], "en"), "")


func test_render_unknown_noun_blank() -> void:
	# Неизвестное слово → пустая подстановка (каркас фразы остаётся).
	assert_eq(Messages.render("noun_here", ["nope"], "en"), " here")


func test_slots_count() -> void:
	assert_eq(Messages.slots("noun_here"), 1)
	assert_eq(Messages.slots("telegraph_pair"), 2)
	assert_eq(Messages.slots("invocation_double"), 1, "двойной {noun} — всё равно 1 слот")
	assert_eq(Messages.slots("yes"), 0, "готовая реплика — без слов")


func test_render_zero_slot_phrase() -> void:
	assert_eq(Messages.render("your_turn", [], "ru"), "Ходи!")
	assert_eq(Messages.render("yes", [], "en"), "Yes")


func test_render_plural_noun_uses_pl_form() -> void:
	# «Врата» — множественное в RU (noun.pl), flavor-фраза с глаголом берёт ru_pl;
	# в EN «Gate» единственное — обычная форма.
	assert_true(Messages.is_plural("gate", "ru"))
	assert_false(Messages.is_plural("gate", "en"))
	assert_eq(Messages.render("noun_comes", ["gate"], "ru"), "Грядут Врата")
	assert_eq(Messages.render("noun_comes", ["gate"], "en"), "Gate comes")
	assert_eq(Messages.render("noun_comes", ["doom"], "ru"), "Грядёт Рок")
	# Функциональная фраза без глагола — формы _pl нет, обычная.
	assert_eq(Messages.render("noun_low", ["mythos"], "ru"), "Мифы на исходе")


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


func test_phrases_in_category() -> void:
	assert_eq(Messages.phrases_in("status").size(), 7, "7 шаблонов статуса")
	assert_eq(Messages.phrases_in("pair").size(), 2, "telegraph_pair + route")


func test_phrase_category_title_localized() -> void:
	assert_eq(Messages.phrase_category_title("status", "ru"), "Статус")
	assert_eq(Messages.phrase_category_title("cry", "en"), "Cry")
	assert_eq(Messages.phrase_category_title("nope", "ru"), "nope", "нет в словаре — сам id")


func test_category_order_from_dictionary() -> void:
	# Порядок секций задаёт словарь: functional-категории первыми, flavor в хвосте.
	var pc: Array = Messages.phrase_categories()
	assert_eq(pc[0], "speech")
	assert_true(pc.find("status") < pc.find("event"), "functional раньше flavor")
	var nc: Array = Messages.noun_categories()
	assert_eq(nc[0], "mechanic")
	assert_true(nc.find("direction") < nc.find("being"))


func test_phrase_categories_cover_all() -> void:
	var total: int = 0
	for cat: String in Messages.phrase_categories():
		total += Messages.phrases_in(cat).size()
	assert_eq(total, Messages.phrases().size(), "все шаблоны попадают в какую-то секцию")


func test_noun_categories_cover_all() -> void:
	var total: int = 0
	for cat: String in Messages.noun_categories():
		total += Messages.nouns_in(cat).size()
	var all_n: int = 0
	for cat: Variant in Messages._nouns_by_cat:
		all_n += (Messages._nouns_by_cat[cat] as Array).size()
	assert_eq(total, all_n, "все слова попадают в какую-то секцию")
