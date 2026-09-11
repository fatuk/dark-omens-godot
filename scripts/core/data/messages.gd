class_name Messages

## Словарь фраз чата (в духе Dark Souls): шаблоны фраз + существительные по категориям.
## Хранятся только `id`; текст рендерится ЛОКАЛЬНО на языке клиента (en/ru) подстановкой
## {noun}/{noun2}. Два яруса (tier): functional — координация («Да», «Иду: {noun}»,
## «{noun} на исходе»), flavor — атмосфера («Грядёт {noun}»). Слотов 0, 1 или 2.
## Грамматика: слова в именительном; функциональные фразы без глагола, согласуемого
## со словом (телеграф), — любое слово × любая такая фраза; у flavor-фраз с глаголом
## есть en_pl/ru_pl для слов, помеченных множественным (noun.pl: ["ru"] — «Врата»).
## Порядок и заголовки категорий-секций композера — тоже в словаре
## (phrase_categories / noun_categories): правится в JSON, не в коде.
## Статический загрузчик (как Conditions/SpellCatalog), не автолоад.

const DATA_PATH := "res://data/messages.json"

static var _phrases: Dictionary = {}  # id -> {id, tier, category, slots, en, ru[, en_pl, ru_pl]}
static var _phrase_list: Array = []  # порядок как в JSON
static var _phrases_by_cat: Dictionary = {}  # phrase category -> [phrase dict, …]
static var _phrase_cats: Array = []  # [{id, tier, en, ru}, …] в порядке UI
static var _nouns: Dictionary = {}  # id -> {id, tier, category, en, ru[, pl]}
static var _nouns_by_cat: Dictionary = {}  # category -> [noun dict, …]
static var _noun_cats: Array = []  # [{id, tier, en, ru}, …] в порядке UI


## Все шаблоны в порядке словаря: [{id, category, slots, en, ru}, …].
static func phrases() -> Array:
	_ensure()
	return _phrase_list


## Шаблоны категории в порядке словаря ([] если нет).
static func phrases_in(category: String) -> Array:
	_ensure()
	return _phrases_by_cat.get(category, [])


## id категорий шаблонов в порядке секций композера (phrase_categories словаря; не
## перечисленные там, но встречающиеся у фраз — в хвосте).
static func phrase_categories() -> Array:
	_ensure()
	return _ids(_phrase_cats)


## Локализованный заголовок категории-секции шаблонов (нет в словаре — сам id).
static func phrase_category_title(category: String, locale: String) -> String:
	_ensure()
	return _cat_title(_phrase_cats, category, locale)


## Шаблон по id ({} если нет).
static func phrase(id: String) -> Dictionary:
	_ensure()
	return _phrases.get(id, {})


## Существительное по id ({} если нет).
static func noun(id: String) -> Dictionary:
	_ensure()
	return _nouns.get(id, {})


## Существительные категории в порядке словаря ([] если нет).
static func nouns_in(category: String) -> Array:
	_ensure()
	return _nouns_by_cat.get(category, [])


## id категорий существительных в порядке секций композера (noun_categories словаря).
static func noun_categories() -> Array:
	_ensure()
	return _ids(_noun_cats)


## Локализованный заголовок категории-секции существительных (нет в словаре — сам id).
static func category_title(category: String, locale: String) -> String:
	_ensure()
	return _cat_title(_noun_cats, category, locale)


## Сколько РАЗНЫХ существительных потребляет шаблон (0, 1 или 2). 0 — готовая
## реплика («Да», «Мой ход»): композер шлёт её сразу, без выбора слов.
static func slots(phrase_id: String) -> int:
	return clampi(int(phrase(phrase_id).get("slots", 1)), 0, 2)


## Слово стоит во множественном числе в этом языке (noun.pl содержит locale) —
## тогда flavor-фраза берёт форму {locale}_pl («Грядут Врата», а не «Грядёт Врата»).
static func is_plural(noun_id: String, locale: String) -> bool:
	return (noun(noun_id).get("pl", []) as Array).has(locale)


## Итоговый локализованный текст: шаблон[locale] с подстановкой выбранных слов по id.
## {noun} (может повторяться) ← noun_ids[0]; {noun2} ← noun_ids[1]. Неизвестный шаблон → "".
static func render(phrase_id: String, noun_ids: Array, locale: String) -> String:
	var words: Array = []
	for id_v: Variant in noun_ids:
		words.append(_noun_text(String(id_v), locale))
	var plural: bool = not noun_ids.is_empty() and is_plural(String(noun_ids[0]), locale)
	return fill(phrase_id, words, locale, plural)


## Подстановка уже готовых СЛОВ (или "____" для превью незаполненного слота) в шаблон.
## words[0] → все {noun}; words[1] → {noun2}. plural — первое слово во множественном
## числе: берётся форма {locale}_pl, если у шаблона она есть. Реюз композером для превью.
static func fill(phrase_id: String, words: Array, locale: String, plural: bool = false) -> String:
	var ph: Dictionary = phrase(phrase_id)
	if ph.is_empty():
		return ""
	var text: String = String(ph.get(locale, ph.get("en", "")))
	if plural and ph.has(locale + "_pl"):
		text = String(ph[locale + "_pl"])
	var w1: String = String(words[0]) if (words as Array).size() > 0 else ""
	var w2: String = String(words[1]) if (words as Array).size() > 1 else ""
	text = text.replace("{noun2}", w2)  # сначала {noun2} (не подстрока {noun})
	text = text.replace("{noun}", w1)
	return text


# ── Внутреннее ────────────────────────────────────────────────────────────────


static func _noun_text(id: String, locale: String) -> String:
	var n: Dictionary = noun(id)
	if n.is_empty():
		return ""
	return String(n.get(locale, n.get("en", "")))


static func _ids(cats: Array) -> Array:
	var out: Array = []
	for c_v: Variant in cats:
		out.append(String((c_v as Dictionary).get("id", "")))
	return out


static func _cat_title(cats: Array, category: String, locale: String) -> String:
	for c_v: Variant in cats:
		var c: Dictionary = c_v
		if String(c.get("id", "")) == category:
			return String(c.get(locale, c.get("en", category)))
	return category


# Категории из словаря в его порядке + те, что встречаются у записей, но не
# перечислены (в хвосте, заголовок = id) — чтобы новая категория не пропала из UI.
static func _cats(declared: Array, by_cat: Dictionary) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for c_v: Variant in declared:
		if c_v is Dictionary and not String((c_v as Dictionary).get("id", "")).is_empty():
			out.append(c_v)
			seen[String((c_v as Dictionary).get("id", ""))] = true
	for cat: Variant in by_cat:
		if not seen.has(cat):
			out.append({"id": cat})
	return out


static func _ensure() -> void:
	if not _phrases.is_empty():
		return
	var data: Dictionary = DataLoader.load_dict(DATA_PATH)
	for p_v: Variant in data.get("phrases", []):
		var p: Dictionary = p_v
		_phrases[String(p.get("id", ""))] = p
		_phrase_list.append(p)
		var pcat: String = String(p.get("category", ""))
		if not _phrases_by_cat.has(pcat):
			_phrases_by_cat[pcat] = []
		(_phrases_by_cat[pcat] as Array).append(p)
	for n_v: Variant in data.get("nouns", []):
		var n: Dictionary = n_v
		_nouns[String(n.get("id", ""))] = n
		var cat: String = String(n.get("category", ""))
		if not _nouns_by_cat.has(cat):
			_nouns_by_cat[cat] = []
		(_nouns_by_cat[cat] as Array).append(n)
	_phrase_cats = _cats(data.get("phrase_categories", []), _phrases_by_cat)
	_noun_cats = _cats(data.get("noun_categories", []), _nouns_by_cat)
