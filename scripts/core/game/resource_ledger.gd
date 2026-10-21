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
## Недостающее может покрыть подмена из пассива сыщика (см. swap_for).
static func can_pay(player: Dictionary, res: String, amt: int, allow_lethal: bool = true) -> bool:
	var have: int = amount_of(player, res)
	if not allow_lethal and (res == "health" or res == "hp" or res == "sanity"):
		return have > amt
	if have >= amt:
		return true
	return have + int(swap_for(player, res).get("amount", 0)) >= amt


## Списать ресурс (клампится в 0). asset/spell → снять одну карту с конца стопки.
## Своего не хватает — недостающее (в пределах подмены) берётся ресурсом подмены.
static func spend(player: Dictionary, res: String, amt: int) -> void:
	if res == "asset" or res == "spell":
		var items: Array = player.get("items", [])
		if not (items as Array).is_empty():
			items.pop_back()
		player["items"] = items
		return
	var f: String = field_of(res)
	var have: int = int(player.get(f, 0))
	var swap: Dictionary = swap_for(player, res)
	var short: int = amt - have
	if short > 0 and short <= int(swap.get("amount", 0)):
		pay_with_swap(player, res, amt)
		return
	player[f] = maxi(0, have - amt)


## Подмена ресурса пассивом сыщика: «раз в раунд можно потратить 1 рассудок вместо
## 1 улики» (Клайв Эштон — passive.whileOwned substituteResource {fromResource,
## toResource, amount}). {from, amount} — сколько единиц res можно покрыть чем; {} —
## нечем (пассива нет, уже в этом раунде, платить рассудком смертельно).
static func swap_for(player: Dictionary, res: String) -> Dictionary:
	if bool(player.get(PlayerKeys.RESOURCE_SWAP_USED, false)):
		return {}
	var inv: String = String(player.get(PlayerKeys.INVESTIGATOR, ""))
	for n_v: Variant in Investigators.passive(inv).get("whileOwned", []) as Array:
		if not (n_v is Dictionary):
			continue
		var n: Dictionary = n_v
		if String(n.get("do", "")) != "substituteResource":
			continue
		if field_of(String(n.get("toResource", ""))) != field_of(res):
			continue
		var from: String = String(n.get("fromResource", ""))
		var units: int = maxi(1, int(n.get("amount", 1)))
		if can_pay(player, from, units, false):  # подмена не может убить
			return {"from": from, "amount": units}
	return {}


## Оплатить amt ресурса res, покрыв подменой столько единиц, сколько она позволяет
## (игрок сам решил платить подменой — «можете потратить 1 рассудок вместо улики»).
## Подмены нет — обычная оплата.
static func pay_with_swap(player: Dictionary, res: String, amt: int) -> void:
	var swap: Dictionary = swap_for(player, res)
	if swap.is_empty():
		spend(player, res, amt)
		return
	var units: int = mini(amt, int(swap.get("amount", 0)))
	var f: String = field_of(res)
	player[f] = maxi(0, int(player.get(f, 0)) - (amt - units))
	var from: String = field_of(String(swap.get("from", "")))
	player[from] = maxi(0, int(player.get(from, 0)) - units)
	player[PlayerKeys.RESOURCE_SWAP_USED] = true
