class_name Investigators

## Реестр данных сыщиков. Данные локалe-агностичны (все переводимые поля —
## ключи translations.csv), кэш заполняется один раз и не инвалидируется.
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


## Есть ли у сыщика спец-действие с непустой программой (гейт кнопки в UI).
static func has_ability(inv_name: String) -> bool:
	return not (ability_program(inv_name) as Array).is_empty()


## Пассив сыщика ({} — нет). Ключи: name, text, mods.
static func passive(inv_name: String) -> Dictionary:
	return get_data(inv_name).get("passive", {})


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
