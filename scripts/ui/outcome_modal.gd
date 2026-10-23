extends CanvasLayer

## Финальная модалка партии — победа (все Тайны решены) или поражение по причине
## (GameState.outcome_reason: Рок / колода Мифов / все погибли / эффект). Текст —
## концовка Древнего из CMS (GameOutcome). Показывается ВСЕМ по синкнутому outcome.
## Строится кодом (без .tscn), добавляется из world_map._build_outcome_modal.

var _backdrop: ColorRect
var _panel: PanelContainer
var _title: Label
var _body: Label
var _btn: Button
var _shown_for: String = ""  # за какой outcome:причина модалка уже показана


func _ready() -> void:
	layer = 90  # поверх всех игровых слоёв и модалок
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


func _build() -> void:
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.color = Color(0, 0, 0, 0.78)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP  # блокируем клики по карте
	add_child(_backdrop)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.custom_minimum_size = Vector2(560, 0)
	UIStyle.style_modal_panel(_panel)
	center.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 14)
	_panel.add_child(vbox)

	_title = UIStyle.modal_title("")
	vbox.add_child(_title)
	UIStyle.separator(vbox)

	_body = Label.new()
	_body.name = "Body"
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIFonts.apply(_body, UIFonts.BODY)
	_body.add_theme_color_override("font_color", UIColors.TEXT)
	vbox.add_child(_body)

	UIStyle.separator(vbox)
	_btn = UIStyle.button("OUTCOME_TO_MENU", UIColors.ACCENT)
	_btn.name = "MenuBtn"
	_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn.pressed.connect(_go_menu)
	vbox.add_child(_btn)

	_backdrop.visible = false


func _refresh() -> void:
	var o: String = GameState.outcome
	if o.is_empty():
		UIStyle.modal_set_visible(_backdrop, _panel, false)
		_shown_for = ""
		return
	var reason: String = GameState.outcome_reason
	var key: String = "%s:%s" % [o, reason]  # другая причина — другая концовка
	if key == _shown_for:
		return
	_shown_for = key
	_title.text = GameOutcome.title_key(o, reason)
	var won: bool = o == GameOutcome.VICTORY
	_title.add_theme_color_override("font_color", UIColors.SUCCESS if won else UIColors.DANGER)
	# Концовка Древнего из библии (CMS: victory / awakening / timeUp / allFallen) по
	# причине; нет поля — общий текст причины.
	var ao: Dictionary = GameState.campaign.get("ancientOne", {})
	_body.text = tr(GameOutcome.body_text(ao, o, reason))
	SfxManager.play(SfxManager.SFX_MYTHOS_START)  # тревожный аккорд финала
	UIStyle.modal_set_visible(_backdrop, _panel, true)


func _go_menu() -> void:
	var nm: Node = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.leave_room()
	SceneManager.go("main_menu")
