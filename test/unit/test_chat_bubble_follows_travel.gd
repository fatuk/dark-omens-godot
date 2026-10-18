## Облачко чата над фишкой едет вместе с сыщиком: во время перемещения статичный пин
## спрятан на старой клетке, а летит временная копия — облачко держится над ней (и
## между сегментами билетного маршрута), пока пины не расставлены заново.
extends GutTest

var _layer: MapLayer
var _pin: Node2D


func before_each() -> void:
	_layer = MapLayer.new()
	add_child_autofree(_layer)
	_pin = Node2D.new()
	_pin.name = "StaticPin"
	_pin.position = Vector2(100, 200)
	_layer.add_child(_pin)
	_layer._inv_markers = [{"pid": "p", "sprite": _pin}]


func test_bubble_sits_over_static_pin() -> void:
	assert_eq(_layer._chat_anchor("p", 100.0), Vector2(100, 200))


func test_bubble_follows_travelling_pin() -> void:
	_pin.visible = false  # hide_investigator: статичный пин спрятан на старой клетке
	_layer._travel_anchor["p"] = Vector2(900, 400)  # летящий пин (_travel_step)
	assert_eq(_layer._chat_anchor("p", 900.0), Vector2(900, 400), "над летящим пином")
	_layer._spawn_chat_bubble("p", "Еду")
	_layer._layout_chat_bubbles(1.0, 1.0)
	var node: Node2D = (_layer._chat_bubbles["p"] as Array)[0]["node"]
	assert_eq(node.position.x, 900.0, "облачко уехало вместе с фишкой")


func test_travel_anchor_released_when_pins_rebuilt() -> void:
	_layer._travel_anchor["p"] = Vector2(900, 400)
	_layer.set_investigators([])
	assert_false(_layer._travel_anchor.has("p"), "доехал — облачко снова над обычным пином")
