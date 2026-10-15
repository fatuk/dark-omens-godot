## Пины соседних локаций перекрываются корректно: у пина портрет и рамка на одном
## слое (рамка соседа не сквозит поверх портрета), нижний на карте — поверх.
extends GutTest


func test_portrait_and_frame_share_one_layer() -> void:
	var pin: InvestigatorPin = add_child_autofree(InvestigatorPin.new())
	pin.setup(null)
	var portrait: CanvasItem = pin.get_node("Portrait")
	var frame: CanvasItem = pin.get_node("Frame")
	assert_eq(portrait.z_index, frame.z_index, "один слой — порядок по дереву")
	assert_lt(portrait.get_index(), frame.get_index(), "рамка поверх своего портрета")


func test_lower_location_pin_drawn_on_top() -> void:
	var layer: MapLayer = add_child_autofree(MapLayer.new())
	var low := Node2D.new()
	low.name = "Low"
	var high := Node2D.new()
	high.name = "High"
	layer.add_child(low)
	layer.add_child(high)
	layer._inv_markers = [
		{"sprite": low, "base": Vector2(0, 500)}, {"sprite": high, "base": Vector2(0, 100)}
	]
	layer._order_pins_by_depth()
	assert_gt(low.get_index(), high.get_index(), "ниже на карте — позже в дереве, поверх")
