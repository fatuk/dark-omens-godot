class_name ShopReserve
extends RefCounted

## Запас активов (хост-only): колода (asset_deck) и витрина магазина (shop_reserve).
## Вынесено из GameState. Обе — синкаемые поля GameState, модуль мутирует их через
## _gs. Сброс активов не хранится, а выводится (discard_ids): поддержанные карты
## минус колода, витрина и руки — так утечка из запаса невозможна по определению.
## Зовут: BoardState.setup_board (fill), PhaseController / AssetActionFlow после
## покупки (refill), GameState-фасады ensure_shop_reserve / asset_discard_ids для UI.

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


## Хост: заполнить витрину магазина до SHOP_RESERVE_SIZE случайными ассетами.
func fill() -> void:
	_gs.shop_reserve = []
	_reset_deck()
	_draw(_gs.SHOP_RESERVE_SIZE)


## Сброс активов ВЫВОДИТСЯ, а не хранится: карта уходит от игрока семью разными
## путями (discardSelf, loseAsset, loseAllPossessions, гибель сыщика…), и любой
## пропущенный путь означал бы утечку из запаса. Сброс = все поддержанные карты
## минус колода, витрина и руки — по определению, поэтому протечь не может.
func discard_ids() -> Array:
	var taken: Dictionary = _in_play()
	for a: Variant in _gs.asset_deck:
		taken[String(a)] = true
	var out: Array = []
	for aid: Variant in AssetCatalog.available_ids():
		if not taken.has(String(aid)):
			out.append(String(aid))
	return out


# Карты, которые сейчас НЕ в колоде и не в сбросе: витрина магазина и руки игроков.
func _in_play() -> Dictionary:
	var taken: Dictionary = {}
	for r: Variant in _gs.shop_reserve:
		taken[String(r)] = true
	for pid: Variant in _gs.players:
		for it: Variant in _gs.players[pid].get("items", []) as Array:
			taken[AssetCatalog.entry_id(it)] = true  # item — инстанс {id,…} или id-строка
	return taken


# Свежая колода: все ПОЛНОСТЬЮ поддержанные карты (с нереализованными эффектами в
# игру не вводим) за вычетом уже разобранных — стартовые предметы сыщиков выдаются
# при входе игрока, ДО раскладки поля.
func _reset_deck() -> void:
	var taken: Dictionary = _in_play()
	_gs.asset_deck = []
	for aid: Variant in AssetCatalog.available_ids():
		if not taken.has(String(aid)):
			_gs.asset_deck.append(String(aid))
	_gs.asset_deck.shuffle()


# Убрать из колоды карты, уже оказавшиеся в игре (поздний вход со стартовым
# предметом): иначе один и тот же актив жил бы и в руке, и в колоде.
func _prune_deck() -> void:
	var taken: Dictionary = _in_play()
	var kept: Array = []
	for a: Variant in _gs.asset_deck:
		if not taken.has(String(a)):
			kept.append(String(a))
	_gs.asset_deck = kept


## Гарантирует непустую витрину (на случай партий, начатых до появления резерва).
## Только дотягивает недостающее — выложенные карты остаются на местах.
func ensure() -> void:
	if not _gs.is_host() or _gs.shop_reserve.size() >= _gs.SHOP_RESERVE_SIZE:
		return
	_draw(_gs.SHOP_RESERVE_SIZE - _gs.shop_reserve.size())
	_gs.broadcast_sync()
	_gs.emit_changed()


## Хост: после покупки убрать купленные id и дотянуть витрину новыми.
func refill(bought: Array) -> void:
	if not _gs.is_host():
		return
	for b: Variant in bought:
		_gs.shop_reserve.erase(String(b))
	_draw(_gs.SHOP_RESERVE_SIZE - _gs.shop_reserve.size())


## Хост: карту забрал эффект (gainAsset from:"reserve" — встреча, розыгрыш актива):
## снять её с витрины и из колоды, дотянуть витрину.
func take(asset_id: String) -> void:
	if not _gs.is_host():
		return
	(_gs.asset_deck as Array).erase(asset_id)
	refill([asset_id])


## Добавляет n случайных ассетов в витрину. Карты не повторяются: исключаем уже
## выложенные И уже принадлежащие любому игроку — каждый ассет на поле уникален.
func _draw(n: int) -> void:
	if n <= 0:
		return
	_prune_deck()
	for _i: int in n:
		if _gs.asset_deck.is_empty():
			# Колода кончилась — замешиваем сброс (всё, что не в колоде, витрине и
			# руках). Пусто и там — вводить в игру больше нечего.
			_gs.asset_deck = discard_ids()
			_gs.asset_deck.shuffle()
			if _gs.asset_deck.is_empty():
				GameConsole.warn("[Магазин] карты активов кончились")
				return
			GameConsole.log("[Активы] колода замешана из сброса: %d" % _gs.asset_deck.size())
		_gs.shop_reserve.append(String(_gs.asset_deck.pop_back()))
