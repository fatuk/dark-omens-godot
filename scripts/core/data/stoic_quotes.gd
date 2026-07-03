class_name StoicQuotes
extends RefCounted

## Цитаты стоиков для карт Концентрации (небольшое разнообразие — случайная подпись).
## Литеральный ru/en текст (НЕ ключи перевода) — выбираем половину по текущей локали.
## Данные: data/stoic_quotes.json.

const PATH := "res://data/stoic_quotes.json"

static var _list: Array = []


static func _ensure_loaded() -> void:
	if _list.is_empty():
		_list = DataLoader.load_dict(PATH).get("stoic_quotes", [])


## Случайная цитата под текущую локаль: { author, source, text }. {} — данных нет.
static func random() -> Dictionary:
	_ensure_loaded()
	if _list.is_empty():
		return {}
	return localized(_list[randi() % _list.size()])


## Локализованный вид записи цитаты: автор/источник/текст по локали (ru → *_ru/ru,
## иначе английские поля). source «Размышления / Meditations …» → половина по локали.
static func localized(q: Dictionary) -> Dictionary:
	var ru: bool = TranslationServer.get_locale().begins_with("ru")
	return {
		"author": String(q.get("author_ru" if ru else "author_en", "")),
		"source": _work(String(q.get("source", "")), ru),
		"text": String(q.get("ru" if ru else "en", "")),
	}


# «Размышления / Meditations IV.49» → «Размышления» (ru) либо «Meditations IV.49» (en).
static func _work(source: String, ru: bool) -> String:
	var parts: PackedStringArray = source.split(" / ", false)
	if parts.size() >= 2:
		return parts[0] if ru else parts[1]
	return source
