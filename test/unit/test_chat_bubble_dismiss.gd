## Клик по облачку чата над фишкой сыщика растворяет его (тем же уходом, что по таймеру),
## а клик мимо облачка — нет (его забирает выбор локации).
extends GutTest

var _layer: MapLayer


func before_each() -> void:
	_layer = MapLayer.new()
	add_child_autofree(_layer)


func _entry(pid: String) -> Dictionary:
	return (_layer._chat_bubbles.get(pid, []) as Array)[0]


func test_click_on_bubble_dismisses_it() -> void:
	_layer._spawn_chat_bubble("p", "Привет")
	var entry: Dictionary = _entry("p")
	var node: Node2D = entry["node"]
	node.position = Vector2(500, 300)
	assert_true(_layer.try_dismiss_chat_bubble(Vector2(500, 300)), "клик съеден облачком")
	assert_true(bool(entry["dying"]), "облачко растворяется")
	assert_false(_layer.try_dismiss_chat_bubble(Vector2(500, 300)), "уходящее не ловит клик")


func test_click_beside_bubble_passes_through() -> void:
	_layer._spawn_chat_bubble("p", "Привет")
	var entry: Dictionary = _entry("p")
	(entry["node"] as Node2D).position = Vector2(500, 300)
	assert_false(_layer.try_dismiss_chat_bubble(Vector2(5000, 3000)))
	assert_false(bool(entry["dying"]), "облачко живёт")
