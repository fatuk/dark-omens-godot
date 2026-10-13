extends CanvasLayer

## Окно предложения обмена (GameState.trade_offer). Партнёру — что он получит и что
## отдаст, с кнопками «Принять / Отклонить» (TRADE_RESPOND). Инициатору — то же
## предложение с «Ждём ответа» и «Отозвать» (TRADE_CANCEL). Остальным не видно.
## Строится кодом, монтируется из world_map.

const _MIN_W: float = 460.0

var _root: ColorRect
var _panel: PanelContainer
var _box: VBoxContainer
var _sig: String = ""  # что уже показано — не пересобираем на каждом синке


func _ready() -> void:
	layer = 88
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


func _build() -> void:
	_root = ColorRect.new()
	_root.name = "Root"
	_root.color = Color(0, 0, 0, 0.55)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = false
	add_child(_root)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.custom_minimum_size.x = _MIN_W
	UIStyle.style_modal_panel(_panel)
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	_panel.add_child(margin)

	_box = VBoxContainer.new()
	_box.name = "Box"
	_box.add_theme_constant_override("separation", 12)
	margin.add_child(_box)


func _refresh() -> void:
	var o: Dictionary = GameState.trade_offer
	var me: String = GameState.local_pid()
	var role: String = ""
	if not o.is_empty():
		if String(o.get("to", "")) == me:
			role = "to"
		elif String(o.get("from", "")) == me:
			role = "from"
	if role.is_empty():
		_sig = ""
		UIStyle.modal_set_visible(_root, _panel, false)
		return
	var sig: String = role + JSON.stringify(o)
	if sig != _sig:
		_sig = sig
		_fill(o, role)
	UIStyle.modal_set_visible(_root, _panel, true)


func _fill(o: Dictionary, role: String) -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	var from: String = String(o.get("from", ""))
	var to: String = String(o.get("to", ""))
	_box.add_child(UIStyle.modal_title("TRADE_OFFER_TITLE"))
	var lead: String = (
		tr("TRADE_OFFER_FROM") % GameState.name_of(from)
		if role == "to"
		else tr("TRADE_OFFER_WAITING") % GameState.name_of(to)
	)
	_box.add_child(_label(lead, UIStyle.MODAL_FS_LEAD, UIColors.TEXT))

	# С точки зрения партнёра: получает то, что отдаёт инициатор, и наоборот.
	var from_items: Array = GameState.players.get(from, {}).get("items", [])
	var to_items: Array = GameState.players.get(to, {}).get("items", [])
	var give_lines: Array = _lines(from_items, o.get("give", []), int(o.get("giveClues", 0)))
	var take_lines: Array = _lines(to_items, o.get("take", []), int(o.get("takeClues", 0)))
	var get_lines: Array = give_lines if role == "to" else take_lines
	var give_away: Array = take_lines if role == "to" else give_lines
	_section("TRADE_OFFER_YOU_GET", get_lines)
	_section("TRADE_OFFER_YOU_GIVE", give_away)

	var row := HBoxContainer.new()
	row.name = "Buttons"
	row.add_theme_constant_override("separation", 12)
	_box.add_child(row)
	if role == "to":
		row.add_child(_button("TRADE_OFFER_ACCEPT", UIColors.ACCENT, true))
		row.add_child(_button("TRADE_OFFER_DECLINE", UIColors.MUTED, false))
	else:
		var cancel := Button.new()
		cancel.name = "CancelBtn"
		cancel.text = "TRADE_OFFER_CANCEL"
		cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIStyle.style_button(cancel)
		cancel.pressed.connect(func() -> void: GameState.act(RelayActions.TRADE_CANCEL))
		row.add_child(cancel)


func _section(title_key: String, lines: Array) -> void:
	_box.add_child(_label(tr(title_key), UIStyle.MODAL_FS_BODY, UIColors.ACCENT))
	if lines.is_empty():
		_box.add_child(
			_label("— " + tr("TRADE_OFFER_NOTHING"), UIStyle.MODAL_FS_BODY, UIColors.MUTED)
		)
		return
	for l_v: Variant in lines:
		_box.add_child(_label("• " + String(l_v), UIStyle.MODAL_FS_BODY, UIColors.TEXT))


# Строки предметов по индексам + улики.
func _lines(items: Array, idx: Array, clues: int) -> Array:
	var out: Array = []
	for i_v: Variant in idx:
		var i: int = int(i_v)
		if i >= 0 and i < items.size():
			out.append(_item_label(items[i]))
	if clues > 0:
		out.append(tr("TRADE_OFFER_CLUES") % clues)
	return out


# Отображаемое имя предмета: актив → nameKey, заклинание → name, иначе id.
func _item_label(it: Variant) -> String:
	var id: String = AssetCatalog.entry_id(it)
	var a: Dictionary = AssetCatalog.by_id(id)
	if not a.is_empty():
		return tr(String(a.get("nameKey", id)))
	var s: Dictionary = SpellCatalog.by_id(id)
	if not s.is_empty():
		return tr(String(s.get("name", id)))
	var art: Dictionary = ArtifactCatalog.by_id(id)
	if not art.is_empty():
		return tr(String(art.get("nameKey", id)))
	return id


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.name = "Line"
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _button(key: String, color: Color, accept: bool) -> Button:
	var b := Button.new()
	b.name = "AcceptBtn" if accept else "DeclineBtn"
	b.text = key
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_button(b, color)
	b.pressed.connect(
		func() -> void:
			UIStyle.modal_set_visible(_root, _panel, false)  # не ждём синка
			GameState.act(RelayActions.TRADE_RESPOND, {"accept": accept})
	)
	return b
