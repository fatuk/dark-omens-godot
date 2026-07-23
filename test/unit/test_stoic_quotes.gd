extends GutTest

## StoicQuotes — случайная цитата для карт Концентрации, локализованная по локали.

var _loc: String = ""


func before_each() -> void:
	_loc = TranslationServer.get_locale()


func after_each() -> void:
	TranslationServer.set_locale(_loc)


func test_random_returns_localized_fields() -> void:
	var q: Dictionary = StoicQuotes.random()
	assert_false(q.is_empty(), "цитата возвращена")
	assert_false(String(q.get("author", "")).is_empty(), "автор не пуст")
	assert_false(String(q.get("text", "")).is_empty(), "текст не пуст")
	assert_false(String(q.get("source", "")).is_empty(), "источник не пуст")


func test_at_is_deterministic_by_index() -> void:
	# at(index) — та же цитата на тот же индекс (привязка к слоту жетона, без
	# ре-рандома на рендере). Разные индексы обычно дают разные записи.
	var a: Dictionary = StoicQuotes.at(7)
	var b: Dictionary = StoicQuotes.at(7)
	assert_eq(a, b, "тот же индекс → та же цитата")
	assert_false(a.is_empty(), "цитата возвращена")
	# Отрицательный/большой индекс не падает (берётся по модулю).
	assert_false(StoicQuotes.at(-3).is_empty(), "отрицательный индекс ок")
	assert_eq(StoicQuotes.at(1000000), StoicQuotes.at(1000000), "детерминированно для любого")


func test_localized_picks_half_of_source_by_locale() -> void:
	var q: Dictionary = {
		"author_ru": "Марк Аврелий",
		"author_en": "Marcus Aurelius",
		"source": "Размышления / Meditations IV.49",
		"ru": "рус",
		"en": "eng",
	}
	TranslationServer.set_locale("ru")
	var ru: Dictionary = StoicQuotes.localized(q)
	assert_eq(ru["author"], "Марк Аврелий")
	assert_eq(ru["source"], "Размышления", "ru-половина источника")
	assert_eq(ru["text"], "рус")
	TranslationServer.set_locale("en")
	var en: Dictionary = StoicQuotes.localized(q)
	assert_eq(en["author"], "Marcus Aurelius")
	assert_eq(en["source"], "Meditations IV.49", "en-половина источника")
	assert_eq(en["text"], "eng")
