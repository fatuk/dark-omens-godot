extends CanvasLayer

## UI Тени («Мир духов») — показывается погибшему игроку (my_player.dead).
## Даёт акт раунда «Оставить улику» (случайная улика после ближайшего Мифа),
## просмотр ВСЕХ Тайн Древнего и 3 БЛИЖАЙШИХ Мифов (Тень — оракул) и подсказку
## про чат. Ближайшие Мифы host режет из host-only колоды в синкаемое
## GameState.ghost_upcoming (только при наличии Тени) — читаем его напрямую.
## Код, монтируется из world_map.
##
## TODO(i18n): тексты литералами (translations.csv занят) — вынести в DEATH_*.

# Единственный размер вне лесенки — см. комментарий у места использования.
const _HEAD_FS: int = 51

var _root: Control
var _budget_lbl: Label
var _clue_btn: Button
var _myst_veil: ColorRect  # оверлей со всеми Тайнами (тоггл)
var _myst_list: VBoxContainer
var _mythos_veil: ColorRect  # оверлей с ближайшими Мифами (тоггл)
var _mythos_list: VBoxContainer


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
	# Полноэкранный «якорь»: без него anchors PanelContainer как ПРЯМОГО ребёнка
	# CanvasLayer не считаются от вьюпорта — панель прилипала к верху и клипалась.
	var anchor := Control.new()
	anchor.name = "GhostWrap"
	anchor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE  # клики идут к карте, ловит только панель
	add_child(anchor)

	# Нижняя панель-плашка Тени (сама тянется по контенту, дно — над краем экрана).
	var panel := PanelContainer.new()
	panel.name = "GhostPanel"
	UIStyle.style_modal_panel(panel)
	panel.set_anchors_and_offsets_preset(
		Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_KEEP_SIZE, 18
	)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	anchor.add_child(panel)
	_root = panel

	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var title := UIStyle.label(
		"Мир духов", UIStyle.MODAL_FS_TITLE, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER
	)
	title.name = "Title"
	vb.add_child(title)

	_budget_lbl = UIStyle.label(
		"", UIStyle.MODAL_FS_BODY, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER
	)
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

	var mythos_btn := UIStyle.button("Ближайшие Мифы", UIColors.WARNING)
	mythos_btn.name = "MythosBtn"
	mythos_btn.pressed.connect(_on_show_mythos)
	row.add_child(mythos_btn)

	var hint := UIStyle.label(
		"Шёпот живым — через чат (C)",
		UIStyle.MODAL_FS_HINT,
		UIColors.MUTED,
		HORIZONTAL_ALIGNMENT_CENTER
	)
	hint.name = "Hint"
	vb.add_child(hint)

	var myst: Array = _build_list_overlay("Все Тайны Древнего")
	_myst_veil = myst[0]
	_myst_veil.name = "MysteriesVeil"
	_myst_list = myst[1]
	var mythos: Array = _build_list_overlay("Ближайшие Мифы")
	_mythos_veil = mythos[0]
	_mythos_veil.name = "MythosVeil"
	_mythos_list = mythos[1]


# Полноэкранный оверлей-список (оракул Тени). Возвращает [veil, list_vbox].
func _build_list_overlay(title_text: String) -> Array:
	var veil := ColorRect.new()
	veil.name = "Veil"
	veil.color = Color(0, 0, 0, 0.8)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	veil.visible = false
	add_child(veil)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.add_child(center)

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

	vb.add_child(UIStyle.ornate_title(title_text))

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)

	var list := VBoxContainer.new()
	list.name = "List"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 14)
	scroll.add_child(list)

	var close := UIStyle.button("Закрыть", UIColors.MUTED)
	close.name = "Close"
	close.pressed.connect(func() -> void: veil.visible = false)
	vb.add_child(close)

	return [veil, list]


# Строка заголовка + тело в список оверлея (единый стиль оракула).
func _add_list_entry(list: VBoxContainer, head: String, body_text: String, head_col: Color) -> void:
	# Крупнее самой верхней ступени лесенки: это не заголовок окна, а название
	# ближайшего Мифа во весь бок панели Тени — единственное исключение.
	list.add_child(UIStyle.label(head, _HEAD_FS, head_col, HORIZONTAL_ALIGNMENT_LEFT))
	var body := UIStyle.label(body_text, UIStyle.MODAL_FS_HERO, UIColors.TEXT)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	list.add_child(body)


# ── Обновление ────────────────────────────────────────────────────────────────


func _refresh() -> void:
	var ghost: bool = _is_ghost()
	if is_instance_valid(_root):
		_root.visible = ghost
	if not ghost:
		if is_instance_valid(_myst_veil):
			_myst_veil.visible = false
		if is_instance_valid(_mythos_veil):
			_mythos_veil.visible = false
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
		_add_list_entry(_myst_list, head, String(m.get("text", "")), col)
	_myst_veil.visible = true


func _on_show_mythos() -> void:
	if not is_instance_valid(_mythos_veil) or not is_instance_valid(_mythos_list):
		return
	_populate_mythos()
	_mythos_veil.visible = true


# 3 ближайших Мифа — из синкаемого GameState.ghost_upcoming (host режет host-only
# колоду и кладёт только name/text, лишь когда в партии есть Тень).
func _populate_mythos() -> void:
	for c in _mythos_list.get_children():
		c.queue_free()
	var upcoming: Array = GameState.ghost_upcoming
	if upcoming.is_empty():
		_mythos_list.add_child(
			UIStyle.label(
				"Завеса тиха — ближайших Мифов не видно.", UIStyle.MODAL_FS_HERO, UIColors.MUTED
			)
		)
		return
	for i in range(upcoming.size()):
		var card: Dictionary = upcoming[i]
		_add_list_entry(
			_mythos_list,
			"%d. %s" % [i + 1, String(card.get("name", ""))],
			String(card.get("text", "")),
			UIColors.ACCENT
		)
