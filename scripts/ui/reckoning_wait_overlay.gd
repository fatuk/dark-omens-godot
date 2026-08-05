extends CanvasLayer

## Оверлей «ждём других сыщиков» в ПАРАЛЛЕЛЬНОЙ Расплате: виден тому, кто уже ЗАКОНЧИЛ
## свою Расплату (players[me].reckoning_done — не мигает между своими картами), пока идёт
## reckoning_active. Ловит клики — нельзя действовать, пока фаза не завершится у всех.
## Под модалкой проверки (layer 85 < 86). Строится кодом, монтируется из world_map.

const _TITLE_WIDTH: float = 380.0  # ширина строки заголовка (до ×1.5 scale_modal_text)

var _root: ColorRect
var _panel: PanelContainer


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

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	UIStyle.style_modal_panel(_panel)
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	_panel.add_child(margin)

	# Заголовок с автопереносом сам по себе имеет минимальную ширину в 1px, и
	# панель схлопывается в вертикальную колонку по букве в строке. Задаём ширину
	# явно — по ней и переносим.
	var title := UIStyle.modal_title("RECK_WAIT")
	title.custom_minimum_size.x = _TITLE_WIDTH
	margin.add_child(title)
	UIStyle.scale_modal_text(_panel)


func _refresh() -> void:
	# Видим, когда идёт параллельная Расплата, а МОЯ уже завершена (reckoning_done), но
	# другие сыщики ещё резолвят. reckoning_done (а не «pending пуст») — чтобы оверлей не
	# мигал в паузе между моими собственными картами.
	var waiting: bool = (
		bool(GameState.reckoning_active)
		and bool(GameState.my_player().get("reckoning_done", false))
	)
	UIStyle.modal_set_visible(_root, _panel, waiting)
