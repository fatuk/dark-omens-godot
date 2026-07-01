class_name ResourceLedger
extends RefCounted

## Единый учёт ресурсов игрока (улики/фокус/здоровье/рассудок + предметы). Раньше
## чтение/списание/проверка оплаты жили независимо в CheckFlow, EffectRunner,
## MysteryFlow и EncounterFlow — с расхождениями в политике «до смерти». Здесь один
## источник: канонизация синонимов ресурса, чтение, оплата и списание.
##
## Работает с dict-игроком (мутирует его напрямую), поэтому статик — без стейта.

# Синоним ресурса → поле игрока. asset/spell — особый случай (стопка items).
const _FIELD := {
	"clue": "clues",
	"clues": "clues",
	"focus": "concentration",
	"concentration": "concentration",
	"health": "hp",
	"hp": "hp",
	"sanity": "sanity",
}


## Имя поля игрока по имени ресурса (для скалярных ресурсов). Неизвестный — как есть.
static func field_of(res: String) -> String:
	return _FIELD.get(res, res)


## Сколько ресурса у игрока. asset/spell → размер стопки предметов.
static func amount_of(player: Dictionary, res: String) -> int:
	if res == "asset" or res == "spell":
		return (player.get("items", []) as Array).size()
	return int(player.get(field_of(res), 0))


## Хватает ли на оплату amt. allow_lethal=false → здоровье/рассудок нельзя опускать
## до 0 (стоимость активации карты не может убить владельца) — строгое «> amt».
static func can_pay(player: Dictionary, res: String, amt: int, allow_lethal: bool = true) -> bool:
	var have: int = amount_of(player, res)
	if not allow_lethal and (res == "health" or res == "hp" or res == "sanity"):
		return have > amt
	return have >= amt


## Списать ресурс (клампится в 0). asset/spell → снять одну карту с конца стопки.
static func spend(player: Dictionary, res: String, amt: int) -> void:
	if res == "asset" or res == "spell":
		var items: Array = player.get("items", [])
		if not (items as Array).is_empty():
			items.pop_back()
		player["items"] = items
		return
	var f: String = field_of(res)
	player[f] = maxi(0, int(player.get(f, 0)) - amt)
