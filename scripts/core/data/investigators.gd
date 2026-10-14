class_name Investigators

## Реестр данных сыщиков. Данные локалe-агностичны (все переводимые поля —
## ключи translations.csv), кэш заполняется один раз и не инвалидируется.
##
## ФАЙЛ ГЕНЕРИРУЕТСЯ ИЗ CMS (relay scripts/export-game-content.ts), править
## его руками бессмысленно — следующий экспорт затрёт. Источник правды —
## админка. См. data/README.md.
##
## Использование:
##   Investigators.display_name("Ezra Gilman")  → "INV_EZRA_GILMAN_NAME" (ключ)
##   # При присвоении в label.text Godot сам вызовет tr() и покажет «Эзра Гилман»
##   Investigators.get_data("Ezra Gilman")     → весь словарь сыщика

const DATA_PATH := "res://data/investigators.json"

static var _by_name: Dictionary = {}


## Возвращает translation key для имени сыщика. Когда присваивается в
## Label.text, Godot автоматически переводит при рендере и обновляет при
## смене локали.
static func display_name(inv_name: String) -> String:
	if inv_name.is_empty():
		return inv_name
	_ensure_loaded()
	var inv: Dictionary = _by_name.get(inv_name, {})
	return inv.get("displayName", inv_name)


static func get_data(inv_name: String) -> Dictionary:
	_ensure_loaded()
	return _by_name.get(inv_name, {})


# ── Способности сыщика (спец-действие + пассив) ───────────────────────────────
#
# Оба поля НЕОБЯЗАТЕЛЬНЫЕ: сыщик без них ведёт себя как раньше. Форма в
# data/investigators.json:
#
#   "ability": {                      # спец-действие: тратит 1 из 2 действий, раз в раунд
#     "name": "INV_X_ABILITY_NAME",   # ключ перевода (подпись кнопки)
#     "text": "INV_X_ABILITY_TEXT",   # ключ перевода (описание)
#     "do":   [ {"do": "gainClue", "count": 1} ]   # Effect-DSL программа
#   },
#   "passive": {                      # постоянный модификатор проверок
#     "name": "INV_X_PASSIVE_NAME",
#     "text": "INV_X_PASSIVE_TEXT",
#     "mods": [ {"do": "rerollDice", "count": 1, "context": "anyTest"} ]
#   }
#
# Пассив понимает только check-mod-глаголы (см. _PASSIVE_MOD_VERBS) — они уже
# умеют разрешаться в CheckFlow. Прочие глаголы в mods игнорируются: для них
# нужен новый слой правил, а не данные.

## Глаголы, которые пассив умеет применять к проверке (зеркало AssetCatalog).
const _PASSIVE_MOD_VERBS := [
	"rollAdditionalDice",
	"addToDie",
	"convertDie",
	"improveSkill",
	"impairSkill",
	"rerollDice",
	"rerollMatching",
	"enhanceReroll",
	"minDice",
	"substituteSkill",
]


## Спец-действие сыщика ({} — нет). Ключи: name, text, do (программа Effect-DSL).
static func ability(inv_name: String) -> Dictionary:
	return get_data(inv_name).get("ability", {})


## Программа спец-действия ([] — действия нет / оно пустое).
static func ability_program(inv_name: String) -> Array:
	return ability(inv_name).get("do", [])


## Вид встроенного спец-действия ("" — обычная DSL-программа `do`).
## Встроенные виды нужны там, где действие ТРЕБУЕТ ВВОДА игрока и в данных не
## выражается. Сейчас поддержан:
##   "convertVitality" — «потратить N здоровья или рассудка и восстановить
##                       столько же другого» (Мэй Линь). Игрок выбирает
##                       направление и величину; хост валидирует.
##   "strikeMonster"   — «вы и 1 монстр на вашей локации теряете по 1 здоровью»
##                       (Фрэнк Далтон). Игрок выбирает монстра, если их несколько.
static func ability_kind(inv_name: String) -> String:
	return String(ability(inv_name).get("kind", ""))


## Есть ли у сыщика спец-действие: непустая программа ЛИБО встроенный вид.
static func has_ability(inv_name: String) -> bool:
	return (
		not (ability_program(inv_name) as Array).is_empty() or not ability_kind(inv_name).is_empty()
	)


## Триггеры пассива на событие `on` ([] — нет). Триггерный пассив срабатывает не на
## проверке, а на игровом событии. Сейчас поддержан:
##   {"on": "improveSkill", "repeat": 1} — улучшение навыка применяется ещё раз.
static func passive_triggers(inv_name: String, on: String) -> Array:
	var out: Array = []
	for t_v: Variant in passive(inv_name).get("triggers", []) as Array:
		if t_v is Dictionary and String((t_v as Dictionary).get("on", "")) == on:
			out.append(t_v)
	return out


## Сколько РАЗ дополнительно повторить улучшение навыка (0 — пассива нет).
static func extra_skill_improvements(inv_name: String) -> int:
	var n: int = 0
	for t_v: Variant in passive_triggers(inv_name, "improveSkill"):
		n += maxi(0, int((t_v as Dictionary).get("repeat", 1)))
	return n


## Пассив сыщика ({} — нет). Ключи: name, text, mods, triggers, whileOwned.
static func passive(inv_name: String) -> Dictionary:
	return get_data(inv_name).get("passive", {})


## Иммунитет пассива к статусу ("delayed" или id состояния, напр. "detained"):
## узел whileOwned {do:"immuneTo", status} (Фрэнк Далтон). «Если только не выбрали
## сами» обеспечивает EffectRunner — общий для пассива и предметов (Pocket Watch).
static func passive_immune_to(inv_name: String, status: String) -> bool:
	for n_v: Variant in passive(inv_name).get("whileOwned", []) as Array:
		if not (n_v is Dictionary):
			continue
		var n: Dictionary = n_v
		if String(n.get("do", "")) == "immuneTo" and String(n.get("status", "")) == status:
			return true
	return false


## Модификаторы пассива, подходящие под контекст проверки ("anyTest"/пусто — всегда).
## Возвращает узлы Effect-DSL как есть — CheckFlow кладёт их в active_mods.
static func passive_check_mods(inv_name: String, context: String) -> Array:
	var out: Array = []
	for n_v: Variant in passive(inv_name).get("mods", []) as Array:
		if not (n_v is Dictionary):
			continue
		var n: Dictionary = n_v
		if not _PASSIVE_MOD_VERBS.has(String(n.get("do", ""))):
			continue
		var ctx: String = String(n.get("context", ""))
		if ctx.is_empty() or ctx == "anyTest" or ctx == context:
			out.append(n)
	return out


# ── Внутренние ────────────────────────────────────────────────────────────────


static func _ensure_loaded() -> void:
	if not _by_name.is_empty():
		return
	var arr: Array = DataLoader.load_array(DATA_PATH)
	for inv: Dictionary in arr:
		var key: String = inv.get("name", "")
		if not key.is_empty():
			_by_name[key] = inv
