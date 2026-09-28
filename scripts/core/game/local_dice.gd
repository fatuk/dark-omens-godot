class_name LocalDice
extends RefCounted

## Кубы ЛОКАЛЬНОГО игрока в проверке: что он видит и по чему тапает. UI-слой над
## CheckFlow — read-only запросы для кликабельности (can_reroll/can_add/has_resource)
## плюс два намерения: «зарядить» жетон на переброс и тап по кубу. Живёт в
## GameState.dice. Ничего здесь не синкается: заряженный жетон — намерение локального
## игрока, а сам переброс уходит хосту через GameState.act().
##
## reckoning=true во всех запросах — проверка Расплаты (per-player слот
## players[pid].reckoning_check, параллельная), иначе единая active_check.

var _gs: Node
var _check: CheckFlow

## «Заряженная» жетоном валюта переброса ("concentration"/"clue"/"") — игрок закинул
## жетон на проверку, следующий тап по кубу тратит ИМЕННО её (один раз).
var pending_currency: String = ""


func _init(gs: Node, check: CheckFlow) -> void:
	_gs = gs
	_check = check


## Проверка, с которой локальный игрок работает прямо сейчас: сначала per-player слот
## Расплаты, потом единая active_check. UI обязан смотреть сюда: в Расплате
## active_check пуст, и веер считал бы применимыми вообще все карты.
func current_check() -> Dictionary:
	var r: Dictionary = _slot(true)
	return r if not r.is_empty() else _gs.active_check


## Можно ли перебросить куб ПРЯМО СЕЙЧАС (тапом): есть бесплатный переброс от карт
## ИЛИ заряжен жетон. Без розыгрыша жетона/карты перебросов нет.
func can_reroll(reckoning: bool = false) -> bool:
	var c: Dictionary = _slot(reckoning)
	if c.is_empty() or not bool(c.get("rolled", false)):
		return false
	return _free_rerolls(c) > 0 or not pending_currency.is_empty()


## Есть ли незаряженный +1 (addToDie) — куб можно улучшить тапом.
func can_add(reckoning: bool = false) -> bool:
	return _check.add_available(_slot(reckoning)) > 0


## Есть ли ВООБЩЕ чем перебросить (бесплатно / концентрация / улика) — для скрытия
## исхода: пока игрок может разыграть жетон, провал не показываем.
func has_resource() -> bool:
	var c: Dictionary = _gs.active_check
	if c.is_empty() or not bool(c.get("rolled", false)):
		return false
	var me: Dictionary = _gs.my_player()
	return (
		_free_rerolls(c) > 0 or int(me.get("concentration", 0)) > 0 or int(me.get("clues", 0)) > 0
	)


## «Зарядить» валюту переброса (закинули жетон на проверку) и перерисовать — чтобы
## кубы стали кликабельны.
func charge(currency: String) -> void:
	pending_currency = currency
	_gs.emit_changed()


## Тап по кубу. Приоритет: заряжен +1 (addToDie) и куб < 6 — кладём +1, а не
## перебрасываем (игрок зарядил карту осознанно; сперва тратим её). Иначе переброс:
## заряженный жетон тратится ИМЕННО он (один раз); без жетона — только БЕСПЛАТНЫЙ
## переброс от карт (концентрация/улика без розыгрыша жетона не тратятся).
func tap(die_index: int, reckoning: bool = false) -> void:
	var pid: String = _gs._nm.my_user_id
	var c: Dictionary = _slot(reckoning)
	if _check.die_can_add(pid, die_index, c):
		_gs.act(
			RelayActions.RECKONING_ADD_DIE if reckoning else RelayActions.ADD_DIE,
			{"die": die_index}
		)
		return
	# Гард ДО списания заряда: клик по НЕперебрасываемому кубу (успех по порогу
	# проверки / вне диапазона / ещё не брошено) не должен «съедать» заряженный жетон
	# и засчитывать попытку. Валидируем по ЖИВОЙ проверке — как сделает хост.
	if not _check.die_is_rerollable(pid, die_index, c):
		return
	var cur: String = pending_currency
	pending_currency = ""  # потребили намерение (один жетон = один переброс)
	if cur.is_empty():
		cur = "free"
	_gs.act(_reroll_action(reckoning, c), {"die": die_index, "currency": cur})


# Relay-действие переброса по владельцу проверки: у каждой свой адаптер в роутере.
func _reroll_action(reckoning: bool, c: Dictionary) -> String:
	if reckoning:
		return RelayActions.RECKONING_REROLL
	match String(c.get("owner", "")):
		"shop":
			return RelayActions.SHOP_REROLL
		"spell":
			return RelayActions.SPELL_CAST_REROLL
		"effectCheck":
			return RelayActions.CHECK_REROLL
	return RelayActions.REROLL_ENCOUNTER


# Слот проверки: per-player Расплата ({} если нет) либо единая active_check.
func _slot(reckoning: bool) -> Dictionary:
	if reckoning:
		return (_gs.players.get(_gs._nm.my_user_id, {}) as Dictionary).get("reckoning_check", {})
	return _gs.active_check


static func _free_rerolls(c: Dictionary) -> int:
	return int(c.get("reroll_allowance", 0)) - int(c.get("rerolls_used", 0))
