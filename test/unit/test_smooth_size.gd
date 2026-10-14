## SmoothSize: окно (панель модалки) меняет размер плавно — первая раскладка сразу,
## дальше видимый размер догоняет содержимое твином: и по высоте, и по ширине.
extends GutTest


func _panel_with_box() -> Array:
	var panel := PanelContainer.new()
	panel.name = "Panel"
	var box := VBoxContainer.new()
	box.name = "VBox"
	panel.add_child(box)
	var first := Control.new()
	first.name = "First"
	first.custom_minimum_size = Vector2(200, 100)
	box.add_child(first)
	add_child_autofree(panel)
	var ss: SmoothSize = SmoothSize.wrap(panel)
	return [panel, box, ss]


func test_wrap_inserts_between_panel_and_content() -> void:
	var parts: Array = _panel_with_box()
	var ss: SmoothSize = parts[2]
	assert_eq(ss.get_parent(), parts[0], "контейнер — ребёнок панели")
	assert_eq((parts[1] as Node).get_parent(), ss, "содержимое — внутри контейнера")
	assert_eq(SmoothSize.wrap(parts[0]), ss, "повторная обёртка не плодит контейнеры")


func test_first_layout_is_instant_then_growth_is_animated() -> void:
	var parts: Array = _panel_with_box()
	var ss: SmoothSize = parts[2]
	await wait_process_frames(2)
	assert_eq(ss.shown_size().y, 100.0, "первая раскладка — сразу")
	var more := Control.new()
	more.name = "More"
	more.custom_minimum_size = Vector2(200, 80)
	(parts[1] as Node).add_child(more)
	await wait_process_frames(2)
	var target: float = (parts[1] as Control).get_combined_minimum_size().y  # 100+отступ+80
	assert_lt(ss.shown_size().y, target, "растёт плавно, а не скачком")
	await wait_seconds(0.6)
	assert_almost_eq(ss.shown_size().y, target, 0.5, "догнал содержимое")


func test_width_growth_is_animated() -> void:
	# Пул кубов шире арта: окно расширяется плавно, а не скачком.
	var parts: Array = _panel_with_box()
	var ss: SmoothSize = parts[2]
	await wait_process_frames(2)
	assert_eq(ss.shown_size().x, 200.0)
	var wide := Control.new()
	wide.name = "Wide"
	wide.custom_minimum_size = Vector2(500, 20)
	(parts[1] as Node).add_child(wide)
	await wait_process_frames(2)
	assert_lt(ss.shown_size().x, 500.0, "ширина растёт плавно")
	assert_gt(ss.shown_size().x, 200.0, "и уже начала расти")
	await wait_seconds(0.6)
	assert_almost_eq(ss.shown_size().x, 500.0, 0.5, "догнал содержимое")
