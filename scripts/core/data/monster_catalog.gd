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
##       horror.defeatOnPass:true        — пройденный тест ужаса побеждает монстра (Crazed Mob)
##       horror.damageWithSuccesses:true — успехи теста ужаса ранят монстра (Призрак)
##       horror.defeatOnDie:"5-6"        — после теста ужаса кубик; на этих гранях монстр
##                                         побеждён (Цвет иных миров)
##       horror.skill "none"             — теста ужаса нет, бой начинается с шага Силы
##     combat:{ skill, modifier:int, damage:int },    # проверка боя; skill "none" — атаки нет,
##                                                    # бой кончается шагом ужаса (Призрак)
##     ability:{ trigger, textKey }
##   }
## skill ∈ "will" | "lore" | "influence" | "observation" | "strength" |
##         "none" (нет проверки, например только бой).
## trigger ∈ "onSpawn" | "movement" | "onDefeat" | "reckoning" | "special" |
##           "passive" | "none" (эвристика; авторитетен textKey).
## Cultist — особый: вместо статов { "useAncientOne": true } — статы, резист и
## onReckoning берутся с листа Древнего (campaign.ancientOne.cultist, см. resolve;
## в игре — GameState.monster_def). Эпики (toughnessPerInvestigator, может быть
## дробным: 0.5 = «+1 за каждых двух») масштабируют стойкость по числу сыщиков.
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


## Арт монстра по конвенции имени файла: assets/monsters/<Id Capitalized>.png
## (id "star_spawn" → "Star Spawn.png"), @2× как все карты. Нет файла → null.
static func card_art(id: String) -> Texture2D:
	if id.is_empty():
		return null
	var path: String = "res://assets/monsters/%s.png" % id.capitalize()
	return load(path) if ResourceLoader.exists(path) else null


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


## Эффективная стойкость с учётом эпик-масштабирования по числу сыщиков:
## toughness + ceil(per × N). per дробный допустим (0.5 → +1 за каждых двух сыщиков).
static func toughness_for(m: Dictionary, investigator_count: int) -> int:
	var per: float = float(m.get("toughnessPerInvestigator", 0))
	return int(m.get("toughness", 0)) + int(ceil(per * investigator_count))


# Поля листа Древнего, которыми культист перекрывает каталог.
const _CULTIST_FIELDS := [
	"toughness", "toughnessPerInvestigator", "horror", "combat", "onReckoning", "resist"
]
# Нет листа / блока — безопасные дефолты (базовый культист: 1 / Воля 0 → 1 / Сила 0 → 1).
const _CULTIST_DEFAULTS := {
	"toughness": 1,
	"horror": {"skill": "will", "modifier": 0, "damage": 1},
	"combat": {"skill": "strength", "modifier": 0, "damage": 1},
}


## Определение монстра с учётом листа Древнего: монстр с useAncientOne (культист)
## получает статы/резист/Расплату из ancient.cultist, остальные — как в каталоге.
## Чистая функция: ancient — campaign.ancientOne (может быть {}).
static func resolve(m: Dictionary, ancient: Dictionary) -> Dictionary:
	if m.is_empty() or not bool(m.get("useAncientOne", false)):
		return m
	var out: Dictionary = m.duplicate(true)
	var sheet: Dictionary = ancient.get("cultist", {})
	for k: String in _CULTIST_FIELDS:
		if sheet.has(k):
			out[k] = sheet[k]
		elif _CULTIST_DEFAULTS.has(k) and not out.has(k):
			out[k] = _CULTIST_DEFAULTS[k]
	return out


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
