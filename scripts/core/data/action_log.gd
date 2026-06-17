class_name ActionLog

## Словарь «ленты действий» (scripts/core/data/action_log.json): литературные шаблоны на
## стандартные действия сыщика. Хост анонсирует действие (GameState.announce_action) — над
## фишкой действующего игрока у ВСЕХ всплывает облачко с описанием. Транзиентно, НЕ часть
## snapshot. Статический загрузчик (как Messages/Conditions/SpellCatalog), не автолоад.
##
## Текст рендерится ЛОКАЛЬНО на языке клиента: шаблон[locale] + подстановка params, где
## значения params — это i18n-КЛЮЧИ (LOC_*_NAME / MONSTER_*_NAME / COND_*_NAME), которые мы
## переводим через TranslationServer в текущей локали. Имена-параметры стоят в шаблоне как
## номинативные приложения (через многоточие/точку) — грамматически верно для любого имени.

const DATA_PATH := "res://data/action_log.json"

static var _entries: Dictionary = {}  # id -> {id, en, ru}


## Запись действия по id ({} если нет). Используется как валидатор в relay-роутере.
static func entry(id: String) -> Dictionary:
	_ensure()
	return _entries.get(id, {})


## Итоговый локализованный текст действия: шаблон[locale] с подстановкой params.
## params — {placeholder: value}; value — i18n-ключ (переводим) или готовая строка.
## Неизвестное действие → "" (облачко не рисуем).
static func render(action_id: String, params: Dictionary, locale: String) -> String:
	var e: Dictionary = entry(action_id)
	if e.is_empty():
		return ""
	var text: String = String(e.get(locale, e.get("en", "")))
	for key_v: Variant in params.keys():
		var token: String = "{%s}" % String(key_v)
		# tr() значения: i18n-ключ → перевод в текущей локали; не-ключ → строка без изменений.
		text = text.replace(token, TranslationServer.translate(String(params[key_v])))
	return text


# ── Внутреннее ────────────────────────────────────────────────────────────────


static func _ensure() -> void:
	if not _entries.is_empty():
		return
	var data: Dictionary = DataLoader.load_dict(DATA_PATH)
	for a_v: Variant in data.get("actions", []):
		var a: Dictionary = a_v
		_entries[String(a.get("id", ""))] = a
