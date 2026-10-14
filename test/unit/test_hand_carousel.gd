extends GutTest

## HandCarousel: пересборка карт не должна оставлять их в (0,0) непрозрачными.
## Регрессия: после розыгрыша с руки веер пересобирается во время анимации закрытия
## (слой ещё visible) — новые карты промигивали в левом верхнем углу экрана.

var _fan: HandCarousel


func before_each() -> void:
	_fan = HandCarousel.new()
	add_child_autofree(_fan)


func _cards(n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({"kind": "asset", "title": "Card %d" % i, "item_index": i})
	return out


func _card_nodes() -> Array:
	var out: Array = []
	for c: Node in _fan.get_children():
		if c is GameCard:
			out.append(c)
	return out


func _assert_hidden_below(cards: Array, why: String) -> void:
	var vp_h: float = _fan.get_viewport().get_visible_rect().size.y
	for i in range(cards.size()):
		var card: Control = cards[i]
		assert_eq(card.modulate.a, 0.0, "%s: карта %d прозрачна" % [why, i])
		assert_gt(card.position.y, vp_h - HandCarousel.CARD_H, "%s: карта %d внизу" % [why, i])


func test_rebuild_when_closed_starts_hidden_below() -> void:
	_fan.set_cards(_cards(3))
	var cards: Array = _card_nodes()
	assert_eq(cards.size(), 3)
	_assert_hidden_below(cards, "закрытый веер")


func test_rebuild_during_close_does_not_flash_top_left() -> void:
	_fan.set_cards(_cards(3))
	_fan.open()
	_fan.close()  # слой остаётся visible до конца твина закрытия
	_fan.set_cards(_cards(2))  # пересборка от state_changed после розыгрыша
	var cards: Array = []
	for c: Variant in _card_nodes():
		if not (c as Node).is_queued_for_deletion():
			cards.append(c)
	assert_eq(cards.size(), 2)
	_assert_hidden_below(cards, "во время закрытия")
