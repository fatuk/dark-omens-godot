class_name Messages

## Словарь фраз чата (в духе Dark Souls): шаблоны фраз + существительные по категориям.
## Хранятся только `id`; текст рендерится ЛОКАЛЬНО на языке клиента (en/ru) подстановкой
## {noun}/{noun2}. Грамматика плоская (именительный, наст./буд.) — любое слово × любой
## шаблон корректно. Статический загрузчик (как Conditions/SpellCatalog), не автолоад.

const DATA_PATH := "res://data/messages.json"

# Порядок категорий существительных = порядок секций веера композера.
const CATEGORY_ORDER: Array[String] = [
	"mechanic", "skill", "state", "being", "person", "thing", "place", "concept"
]

# Порядок и заголовки категорий ШАБЛОНОВ фраз (секции веера на этапе выбора шаблона).
const PHRASE_CATEGORY_ORDER: Array[String] = [
	"place", "event", "sign", "question", "cry", "special"
]
const PHRASE_CATEGORY_TITLES := {
	"place": {"en": "Place", "ru": "Место"},
	"event": {"en": "Event", "ru": "Событие"},
	"sign": {"en": "Sign", "ru": "Знак"},
	"question": {"en": "Question", "ru": "Вопрос"},
	"cry": {"en": "Cry", "ru": "Возглас"},
	"special": {"en": "Special", "ru": "Особое"},
}

# Локализованные заголовки секций (категории — UI-хром композера, не из словаря).
const CATEGORY_TITLES := {
	"mechanic": {"en": "Mechanics", "ru": "Механика"},
	"skill": {"en": "Skills", "ru": "Навыки"},
	"state": {"en": "States", "ru": "Состояния"},
	"being": {"en": "Beings", "ru": "Существа"},
	"person": {"en": "People", "ru": "Люди"},
	"thing": {"en": "Things", "ru": "Вещи"},
	"place": {"en": "Places", "ru": "Места"},
	"concept": {"en": "Concepts", "ru": "Понятия"},
}

static var _phrases: Dictionary = {}  # id -> {id, category, slots, en, ru}
static var _phrase_list: Array = []  # порядок как в JSON
static var _phrases_by_cat: Dictionary = {}  # phrase category -> [phrase dict, …]
static var _nouns: Dictionary = {}  # id -> {id, category, en, ru}
static var _nouns_by_cat: Dictionary = {}  # category -> [noun dict, …]


## Все шаблоны в порядке словаря: [{id, category, slots, en, ru}, …].
static func phrases() -> Array:
	_ensure()
	return _phrase_list


## Шаблоны категории в порядке словаря ([] если нет).
static func phrases_in(category: String) -> Array:
	_ensure()
	return _phrases_by_cat.get(category, [])


## Локализованный заголовок категории-секции шаблонов.
static func phrase_category_title(category: String, locale: String) -> String:
	var t: Dictionary = PHRASE_CATEGORY_TITLES.get(category, {})
	return String(t.get(locale, t.get("en", category)))


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


## Локализованный заголовок категории-секции.
static func category_title(category: String, locale: String) -> String:
	var t: Dictionary = CATEGORY_TITLES.get(category, {})
	return String(t.get(locale, t.get("en", category)))


## Сколько РАЗНЫХ существительных потребляет шаблон (1 или 2).
static func slots(phrase_id: String) -> int:
	return maxi(1, int(phrase(phrase_id).get("slots", 1)))


## Итоговый локализованный текст: шаблон[locale] с подстановкой выбранных слов по id.
## {noun} (может повторяться) ← noun_ids[0]; {noun2} ← noun_ids[1]. Неизвестный шаблон → "".
static func render(phrase_id: String, noun_ids: Array, locale: String) -> String:
	var words: Array = []
	for id_v: Variant in noun_ids:
		words.append(_noun_text(String(id_v), locale))
	return fill(phrase_id, words, locale)


## Подстановка уже готовых СЛОВ (или "____" для превью незаполненного слота) в шаблон.
## words[0] → все {noun}; words[1] → {noun2}. Реюз композером для живого превью.
static func fill(phrase_id: String, words: Array, locale: String) -> String:
	var ph: Dictionary = phrase(phrase_id)
	if ph.is_empty():
		return ""
	var text: String = String(ph.get(locale, ph.get("en", "")))
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


static func _ensure() -> void:
	if not _phrases.is_empty():
		return
	var data: Dictionary = DataLoader.load_dict(DATA_PATH)
	for cat: String in PHRASE_CATEGORY_ORDER:
		_phrases_by_cat[cat] = []
	for p_v: Variant in data.get("phrases", []):
		var p: Dictionary = p_v
		_phrases[String(p.get("id", ""))] = p
		_phrase_list.append(p)
		var pcat: String = String(p.get("category", ""))
		if not _phrases_by_cat.has(pcat):
			_phrases_by_cat[pcat] = []
		(_phrases_by_cat[pcat] as Array).append(p)
	for cat: String in CATEGORY_ORDER:
		_nouns_by_cat[cat] = []
	for n_v: Variant in data.get("nouns", []):
		var n: Dictionary = n_v
		_nouns[String(n.get("id", ""))] = n
		var cat: String = String(n.get("category", ""))
		if not _nouns_by_cat.has(cat):
			_nouns_by_cat[cat] = []
		(_nouns_by_cat[cat] as Array).append(n)
