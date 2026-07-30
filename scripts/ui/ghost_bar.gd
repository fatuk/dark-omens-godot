extends CanvasLayer

## UI Тени («Мир духов») — показывается погибшему игроку (my_player.dead).
## Даёт акт раунда «Оставить улику» (случайная улика после ближайшего Мифа),
## просмотр ВСЕХ Тайн Древнего (Тень — оракул) и подсказку про чат.
## Мифы Тень по замыслу тоже видит целиком, но адресный синк колоды — отдельный
## кусок (пока не сделан). Код, монтируется из world_map.
##
## TODO(i18n): тексты литералами (translations.csv занят) — вынести в DEATH_*.

var _root: Control
var _budget_lbl: Label
var _clue_btn: Button
var _myst_veil: ColorRect  # оверлей со всеми Тайнами (тоггл)
var _myst_list: VBoxContainer


func _ready() -> void:
	layer = 80  # над картой, под модалками проверок/Порога
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


func _is_ghost() -> bool:
	return bool(GameState.my_player().get(PlayerKeys.DEAD, false))


# ── Сборка ────────────────────────────────────────────────────────────────────


func _build() -> void:
	# Нижняя панель-плашка Тени.
	var panel := PanelContainer.new()
	panel.name = "GhostPanel"
	UIStyle.style_modal_panel(panel)
	panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.offset_top = -132
	panel.offset_bottom = -18
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	_root = panel

	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var title := UIStyle.label("Мир духов", 20, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	title.name = "Title"
	vb.add_child(title)

	_budget_lbl = UIStyle.label("", 14, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_budget_lbl.name = "Budget"
	vb.add_child(_budget_lbl)

	var row := HBoxContainer.new()
	row.name = "Buttons"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vb.add_child(row)

	_clue_btn = UIStyle.button("Оставить улику", UIColors.ACCENT)
	_clue_btn.name = "ClueBtn"
	_clue_btn.pressed.connect(_on_place_clue)
	row.add_child(_clue_btn)

	var myst_btn := UIStyle.button("Тайны Древнего", UIColors.WARNING)
	myst_btn.name = "MysteriesBtn"
	myst_btn.pressed.connect(_on_show_mysteries)
	row.add_child(myst_btn)

	var hint := UIStyle.label(
		"Шёпот живым — через чат (C)", 12, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER
	)
	hint.name = "Hint"
	vb.add_child(hint)

	UIStyle.scale_modal_text(panel)

	_build_mysteries_overlay()


# Полноэкранный оверлей со списком ВСЕХ Тайн (оракул Тени).
func _build_mysteries_overlay() -> void:
	_myst_veil = ColorRect.new()
	_myst_veil.name = "MysteriesVeil"
	_myst_veil.color = Color(0, 0, 0, 0.8)
	_myst_veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_myst_veil.mouse_filter = Control.MOUSE_FILTER_STOP
	_myst_veil.visible = false
	add_child(_myst_veil)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_myst_veil.add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	UIStyle.style_modal_panel(panel)
	panel.custom_minimum_size = Vector2(720, 620)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 10)
	margin.add_child(vb)

	vb.add_child(UIStyle.modal_title("Все Тайны Древнего"))

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)

	_myst_list = VBoxContainer.new()
	_myst_list.name = "List"
	_myst_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_myst_list.add_theme_constant_override("separation", 14)
	scroll.add_child(_myst_list)

	var close := UIStyle.button("Закрыть", UIColors.MUTED)
	close.name = "Close"
	close.pressed.connect(func() -> void: _myst_veil.visible = false)
	vb.add_child(close)

	UIStyle.scale_modal_text(panel)


# ── Обновление ────────────────────────────────────────────────────────────────


func _refresh() -> void:
	var ghost: bool = _is_ghost()
	if is_instance_valid(_root):
		_root.visible = ghost
	if not ghost:
		if is_instance_valid(_myst_veil):
			_myst_veil.visible = false
		return
	var me: Dictionary = GameState.my_player()
	var budget: int = int(me.get(PlayerKeys.GHOST_CLUE_BUDGET, 0))
	var acted: bool = bool(me.get(PlayerKeys.GHOST_ACTED, false))
	if is_instance_valid(_budget_lbl):
		_budget_lbl.text = (
			"Улик в запасе: %d   ·   акт за раунд: %s"
			% [budget, "использован" if acted else "доступен"]
		)
	if is_instance_valid(_clue_btn):
		_clue_btn.disabled = acted or budget <= 0


# ── Действия ───────────────────────────────────────────────────────────────────


func _on_place_clue() -> void:
	GameState.ghost_place_clue()


func _on_show_mysteries() -> void:
	if not is_instance_valid(_myst_list):
		return
	for c in _myst_list.get_children():
		c.queue_free()
	var mysteries: Array = GameState.campaign.get("mysteries", [])
	for i in range(mysteries.size()):
		var m: Dictionary = mysteries[i]
		var solved: bool = i < GameState.active_mystery
		var head := "%d. %s%s" % [i + 1, String(m.get("title", "")), "  ✓" if solved else ""]
		var col: Color = UIColors.MUTED if solved else UIColors.ACCENT
		_myst_list.add_child(UIStyle.label(head, 17, col, HORIZONTAL_ALIGNMENT_LEFT))
		var body := UIStyle.label(String(m.get("text", "")), 13, UIColors.TEXT)
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_myst_list.add_child(body)
	_myst_veil.visible = true
