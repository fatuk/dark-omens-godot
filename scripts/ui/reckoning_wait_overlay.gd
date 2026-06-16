extends CanvasLayer

## Оверлей «ждём других сыщиков» в ПАРАЛЛЕЛЬНОЙ Расплате: виден тому, кто уже закончил
## свою Расплату (или у него нет карт), пока идёт reckoning_active и его per-player слот
## reckoning_pending пуст. Ловит клики — нельзя действовать, пока фаза не завершится у
## всех. Под модалкой проверки (layer 85 < 86). Строится кодом, монтируется из world_map.

var _root: ColorRect


func _ready() -> void:
	layer = 85  # под модалкой проверки (check_roll_modal = 86)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


func _build() -> void:
	_root = ColorRect.new()
	_root.name = "Root"
	_root.color = Color(0, 0, 0, 0.45)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP  # блокируем действия ожидающего
	_root.visible = false
	add_child(_root)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	UIStyle.style_modal_panel(panel)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)

	margin.add_child(UIStyle.modal_title("RECK_WAIT"))
	UIStyle.scale_modal_text(panel)


func _refresh() -> void:
	# Видим, когда идёт параллельная Расплата, а у МЕНЯ нет активной проверки (закончил
	# или без карт), но другие сыщики ещё резолвят.
	_root.visible = (
		bool(GameState.reckoning_active)
		and (GameState.my_player().get("reckoning_pending", {}) as Dictionary).is_empty()
	)
