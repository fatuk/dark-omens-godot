class_name MonsterCatalog
extends RefCounted

## Статический каталог монстров (data/monsters.json). Загружается лениво и
## кэшируется.
##
## ФАЙЛ ГЕНЕРИРУЕТСЯ ИЗ CMS (relay scripts/export-game-content.ts), править
## его руками бессмысленно — следующий экспорт затрёт. Источник правды —
## админка (данные когда-то были сняты с вики Eldritch Horror, но с переезда
## каталогов в CMS вики источником быть перестала). См. data/README.md.
##
## Модель:
##   {
##     id, nameKey,
##     toughness:int,
##     toughnessPerInvestigator:int,  # опц.: стойкость += это×(число сыщиков)
##     epic:bool,                      # опц.: эпик-монстр (спавнится по имени)
##     resist: "physical"|"magical",   # опц.: сопротивление урону типа (получает вдвое)
##     horror:{ skill, modifier:int, damage:int },   # проверка рассудка
##     combat:{ skill, modifier:int, damage:int },    # проверка боя
##     ability:{ trigger, textKey }
##   }
## skill ∈ "will" | "lore" | "influence" | "observation" | "strength" |
##         "none" (нет проверки, например только бой).
## trigger ∈ "onSpawn" | "movement" | "onDefeat" | "reckoning" | "special" |
##           "passive" | "none" (эвристика; авторитетен textKey).
## Cultist — особый: вместо статов { "useAncientOne": true } (берутся с листа
## Древнего). Эпики (toughnessPerInvestigator) масштабируют стойкость по числу
## сыщиков в партии.
##
## Использование:
##   var all:   Array = MonsterCatalog.all()
##   var m:     Dictionary = MonsterCatalog.by_id("zombie")
##   var epics: Array = MonsterCatalog.epics()        # только эпик-монстры
##   var norm:  Array = MonsterCatalog.non_epic()     # обычные (для Monster cup)

const PATH := "res://data/monsters.json"

static var _list: Array = []
static var _by_id: Dictionary = {}


## Все монстры (список словарей). Лениво грузит и кэширует.
static func all() -> Array:
	if _list.is_empty():
		_load()
	return _list


## Монстр по id ({} если не найден).
static func by_id(id: String) -> Dictionary:
	if _by_id.is_empty():
		_load()
	return _by_id.get(id, {})


## Только эпик-монстры (спавнятся по имени, не из общего пула).
static func epics() -> Array:
	var out: Array = []
	for i in range(all().size()):
		var m: Dictionary = _list[i]
		if bool(m.get("epic", false)):
			out.append(m)
	return out


## Обычные (не-эпик) монстры — пул для спауна из врат/Наплыва.
static func non_epic() -> Array:
	var out: Array = []
	for i in range(all().size()):
		var m: Dictionary = _list[i]
		if not bool(m.get("epic", false)):
			out.append(m)
	return out


## Программа Расплаты монстра (data onReckoning) по id. [] — нет. Зовётся шагом
## Расплаты (ReckoningFlow) для каждого монстра на доске.
static func reckoning_of(id: String) -> Array:
	return by_id(id).get("onReckoning", [])


## Эффективная стойкость с учётом эпик-масштабирования по числу сыщиков.
static func toughness_for(m: Dictionary, investigator_count: int) -> int:
	return (
		int(m.get("toughness", 0)) + int(m.get("toughnessPerInvestigator", 0)) * investigator_count
	)


## Сопротивляется ли монстр урону типа dmg_type ("physical"|"magical"). resist в
## данных — строка ("physical") или массив (["physical","magical"]).
static func resists(m: Dictionary, dmg_type: String) -> bool:
	var r: Variant = m.get("resist", "")
	if r is Array:
		return (r as Array).has(dmg_type)
	return String(r) == dmg_type


## Урон ПОСЛЕ сопротивления: совпал тип resist → вдвое (округление вниз), иначе без
## изменений. Единая точка правила: физ-урон (бой/Сила) и маг-урон (заклинания,
## damageMonster) зовут её. Делает урон ДРУГОГО типа ценным против резистентных.
static func apply_resistance(m: Dictionary, amount: int, dmg_type: String) -> int:
	if amount <= 0:
		return amount
	if not resists(m, dmg_type):
		return amount
	@warning_ignore("integer_division")
	return amount / 2  # совпал тип сопротивления → вдвое, округление вниз


static func _load() -> void:
	_list = DataLoader.load_array(PATH)
	_by_id.clear()
	for i in range(_list.size()):
		var m: Dictionary = _list[i]
		_by_id[String(m.get("id", ""))] = m
