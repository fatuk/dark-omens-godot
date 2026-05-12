extends Node

## Менеджер локализации. Autoload /root/I18n.
##
## Текущая локаль сохраняется в settings.cfg ([i18n] locale).
## API:
##   I18n.set_locale("en")           — переключить язык + сохранить
##   I18n.get_locale()                — текущий 2-буквенный код
##   I18n.SUPPORTED                   — список поддерживаемых
## Сигнал locale_changed эмитится после смены — UI с tr()-строками,
## выставленными в _ready, должен по нему перерисоваться.
##
## tr() для перевода, например: tr("BTN_SAVE")
## .tscn-файлы автотранслируют свойство text у Label/Button если оно совпадает
## с ключом из CSV — но мы предпочитаем явный tr() в скриптах для контроля.

signal locale_changed(new_locale: String)

const SETTINGS_FILE := "user://settings.cfg"
const SECTION       := "i18n"
const KEY           := "locale"

const SUPPORTED: Array[String] = ["ru", "en"]
const DEFAULT:   String        = "ru"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# На старте — без сохранения, т.к. читаем уже сохранённое.
	_apply(_load_setting())


func get_locale() -> String:
	return TranslationServer.get_locale().substr(0, 2)


func set_locale(locale: String) -> void:
	if not SUPPORTED.has(locale):
		locale = DEFAULT
	if locale == get_locale():
		return
	_apply(locale)
	_save_setting(locale)


# ── Внутренние ───────────────────────────────────────────────────────────────

func _apply(locale: String) -> void:
	if not SUPPORTED.has(locale):
		locale = DEFAULT
	TranslationServer.set_locale(locale)
	locale_changed.emit(locale)


func _load_setting() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) != OK:
		return DEFAULT
	return cfg.get_value(SECTION, KEY, DEFAULT)


func _save_setting(locale: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_FILE)   # ок если файла нет
	cfg.set_value(SECTION, KEY, locale)
	cfg.save(SETTINGS_FILE)
