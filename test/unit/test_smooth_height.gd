## SmoothHeight: окно (панель модалки) меняет высоту плавно — первая раскладка
## сразу, дальше видимая высота догоняет содержимое твином.
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
	var sh: SmoothHeight = SmoothHeight.wrap(panel)
	return [panel, box, sh]


func test_wrap_inserts_between_panel_and_content() -> void:
	var parts: Array = _panel_with_box()
	var sh: SmoothHeight = parts[2]
	assert_eq(sh.get_parent(), parts[0], "контейнер — ребёнок панели")
	assert_eq((parts[1] as Node).get_parent(), sh, "содержимое — внутри контейнера")
	assert_eq(SmoothHeight.wrap(parts[0]), sh, "повторная обёртка не плодит контейнеры")


func test_first_layout_is_instant_then_growth_is_animated() -> void:
	var parts: Array = _panel_with_box()
	var sh: SmoothHeight = parts[2]
	await wait_process_frames(2)
	assert_eq(sh.shown_height(), 100.0, "первая раскладка — сразу")
	var more := Control.new()
	more.name = "More"
	more.custom_minimum_size = Vector2(200, 80)
	(parts[1] as Node).add_child(more)
	await wait_process_frames(2)
	var target: float = (parts[1] as Control).get_combined_minimum_size().y  # 100+отступ+80
	assert_lt(sh.shown_height(), target, "растёт плавно, а не скачком")
	await wait_seconds(0.6)
	assert_almost_eq(sh.shown_height(), target, 0.5, "догнал содержимое")
