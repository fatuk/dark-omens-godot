extends HBoxContainer

## Компонент выбора сыщика.
## Загружает список из data/investigators.json, отображает сетку карточек
## и детальную панель. Генерирует investigator_selected при каждой смене выбора.

signal investigator_selected(inv_name: String)

# ── Состояние ─────────────────────────────────────────────────────────────────

var _investigators:   Array        = []
var _selected_inv:    String       = ""
var _inv_cards:       Dictionary   = {}   # name -> Button
var _inv_data:        Dictionary   = {}   # name -> Dictionary
var _placeholder_tex: ImageTexture = null

# ── Ноды детальной панели ─────────────────────────────────────────────────────

var _detail_portrait:   TextureRect = null
var _detail_name:       Label       = null
var _detail_occupation: Label       = null
var _detail_hp_val:     Label       = null
var _detail_san_val:    Label       = null
var _detail_skills:     Label       = null
var _detail_roles:      Label       = null
var _detail_quote:      Label       = null


# ── Публичный API ──────────────────────────────────────────────────────────────

func get_selected() -> String:
	return _selected_inv


func clear_selection() -> void:
	if not _selected_inv.is_empty() and _inv_cards.has(_selected_inv):
		(_inv_cards[_selected_inv] as Button).add_theme_stylebox_override("normal", _card_style(false))
	_selected_inv = ""
	_reset_detail()


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical   = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 12)
	custom_minimum_size.y = 280  # минимум, чтобы не схлопнулся
	_load_investigators()
	_build_ui()
	_preselect_saved()


# ── Данные ────────────────────────────────────────────────────────────────────

func _load_investigators() -> void:
	var text: String = FileAccess.get_file_as_string("res://data/investigators.json")
	if text.is_empty():
		push_error("InvestigatorPicker: не удалось прочитать investigators.json")
		return
	var data: Variant = JSON.parse_string(text)
	if not data is Array:
		return
	_investigators = data as Array
	for i: int in range(_investigators.size()):
		var inv: Dictionary = _investigators[i]
		_inv_data[inv.get("name", "")] = inv


func _placeholder_texture() -> ImageTexture:
	if _placeholder_tex != null:
		return _placeholder_tex
	var img: Image = Image.create(80, 100, false, Image.FORMAT_RGB8)
	img.fill(Color(0.13, 0.12, 0.20))
	for px: int in range(24, 56):
		for py: int in range(8, 42):
			img.set_pixel(px, py, Color(0.22, 0.20, 0.32))
	for px: int in range(14, 66):
		for py: int in range(42, 95):
			img.set_pixel(px, py, Color(0.22, 0.20, 0.32))
	_placeholder_tex = ImageTexture.create_from_image(img)
	return _placeholder_tex


func _load_portrait(inv_name: String) -> Texture2D:
	var path: String = "res://assets/investigators/%s.png" % inv_name
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return _placeholder_texture()


# ── Построение UI ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# self — HBoxContainer, дети добавляются напрямую
	add_child(_build_detail_panel())
	add_child(_build_cards_panel())


func _build_detail_panel() -> PanelContainer:
	var panel := UIStyle.panel(12)
	# 25% ширины пикера через stretch ratio (cards = 3 части, detail = 1 часть)
	panel.size_flags_horizontal    = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical      = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.0

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	_detail_portrait = TextureRect.new()
	_detail_portrait.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_portrait.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_detail_portrait.custom_minimum_size   = Vector2(0, 120)
	_detail_portrait.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
	_detail_portrait.stretch_mode  = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_detail_portrait.texture = _placeholder_texture()
	vbox.add_child(_detail_portrait)

	_detail_name = Label.new()
	_detail_name.text = "— Не выбран —"
	_detail_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_name.add_theme_font_size_override("font_size", 28)
	_detail_name.add_theme_color_override("font_color", UIColors.TEXT)
	_detail_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_detail_name)

	_detail_occupation = Label.new()
	_detail_occupation.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_occupation.add_theme_font_size_override("font_size", 22)
	_detail_occupation.add_theme_color_override("font_color", UIColors.MUTED)
	vbox.add_child(_detail_occupation)

	UIStyle.separator(vbox)

	# HP / SAN
	var stats_row := HBoxContainer.new()
	stats_row.alignment = BoxContainer.ALIGNMENT_CENTER
	stats_row.add_theme_constant_override("separation", 16)
	vbox.add_child(stats_row)

	var hp_box := HBoxContainer.new()
	hp_box.add_theme_constant_override("separation", 4)
	stats_row.add_child(hp_box)
	var hp_icon := Label.new()
	hp_icon.text = "❤"
	hp_icon.add_theme_font_size_override("font_size", 26)
	hp_icon.add_theme_color_override("font_color", Color(0.9, 0.25, 0.25))
	hp_box.add_child(hp_icon)
	_detail_hp_val = Label.new()
	_detail_hp_val.text = "-"
	_detail_hp_val.add_theme_font_size_override("font_size", 26)
	_detail_hp_val.add_theme_color_override("font_color", UIColors.TEXT)
	hp_box.add_child(_detail_hp_val)

	var san_box := HBoxContainer.new()
	san_box.add_theme_constant_override("separation", 4)
	stats_row.add_child(san_box)
	var san_icon := Label.new()
	san_icon.text = "✦"
	san_icon.add_theme_font_size_override("font_size", 26)
	san_icon.add_theme_color_override("font_color", Color(0.3, 0.6, 0.9))
	san_box.add_child(san_icon)
	_detail_san_val = Label.new()
	_detail_san_val.text = "-"
	_detail_san_val.add_theme_font_size_override("font_size", 26)
	_detail_san_val.add_theme_color_override("font_color", UIColors.TEXT)
	san_box.add_child(_detail_san_val)

	_detail_skills = Label.new()
	_detail_skills.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_skills.add_theme_font_size_override("font_size", 22)
	_detail_skills.add_theme_color_override("font_color", UIColors.MUTED)
	_detail_skills.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_detail_skills)

	_detail_roles = Label.new()
	_detail_roles.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_roles.add_theme_font_size_override("font_size", 22)
	_detail_roles.add_theme_color_override("font_color", UIColors.ACCENT)
	_detail_roles.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_detail_roles)

	UIStyle.separator(vbox)

	_detail_quote = Label.new()
	_detail_quote.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_quote.add_theme_font_size_override("font_size", 20)
	_detail_quote.add_theme_color_override("font_color", UIColors.MUTED)
	_detail_quote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_detail_quote)

	return panel


func _build_cards_panel() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal   = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical     = Control.SIZE_EXPAND_FILL
	scroll.size_flags_stretch_ratio = 3.0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO

	var flow := HFlowContainer.new()
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	scroll.add_child(flow)

	for i: int in range(_investigators.size()):
		var inv: Dictionary = _investigators[i]
		var card: Button    = _make_inv_card(inv)
		flow.add_child(card)
		_inv_cards[inv.get("name", "")] = card

	return scroll


# ── Карточки ──────────────────────────────────────────────────────────────────

func _make_inv_card(inv: Dictionary) -> Button:
	var inv_name: String = inv.get("name", "")

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(200, 296)
	btn.flat     = false
	btn.clip_contents = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_stylebox_override("normal",   _card_style(false))
	btn.add_theme_stylebox_override("hover",    _card_style_hover())
	btn.add_theme_stylebox_override("pressed",  _card_style(true))
	btn.add_theme_stylebox_override("disabled", _card_style(false))
	btn.pressed.connect(func() -> void: _on_card_pressed(inv_name))

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 0)
	btn.add_child(vbox)

	var portrait := TextureRect.new()
	portrait.mouse_filter     = Control.MOUSE_FILTER_IGNORE
	portrait.custom_minimum_size = Vector2(200, 236)
	portrait.expand_mode      = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode     = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.texture          = _load_portrait(inv_name)
	vbox.add_child(portrait)

	var name_lbl := Label.new()
	name_lbl.mouse_filter            = Control.MOUSE_FILTER_IGNORE
	name_lbl.text                    = inv_name.split(" ")[0].replace("\"", "")
	name_lbl.horizontal_alignment    = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.vertical_alignment      = VERTICAL_ALIGNMENT_CENTER
	name_lbl.custom_minimum_size.y   = 60
	name_lbl.add_theme_font_size_override("font_size", 26)
	name_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	vbox.add_child(name_lbl)

	return btn


static func _card_style(selected: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color     = Color(0.14, 0.12, 0.22) if selected else Color(0.10, 0.09, 0.16)
	s.border_color = UIColors.ACCENT if selected else UIColors.BORDER
	s.set_border_width_all(2 if selected else 1)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(0)
	return s


static func _card_style_hover() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color     = Color(0.18, 0.15, 0.28)
	s.border_color = Color(0.78, 0.66, 0.29, 0.6)
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(0)
	return s


# ── Персистентность выбора ────────────────────────────────────────────────────

const _PREFS_PATH    := "user://dark_omens_prefs.cfg"
const _PREFS_SECTION := "player"


func _save_selection(inv_name: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_PREFS_PATH)   # ок, если файла нет
	cfg.set_value(_PREFS_SECTION, "last_investigator", inv_name)
	cfg.save(_PREFS_PATH)


func _load_saved_selection() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(_PREFS_PATH) != OK:
		return ""
	return cfg.get_value(_PREFS_SECTION, "last_investigator", "") as String


func _preselect_saved() -> void:
	var saved: String = _load_saved_selection()
	if not saved.is_empty() and _inv_data.has(saved):
		_on_card_pressed(saved)
		# Прокручиваем карточку в видимую зону
		var card: Button = _inv_cards.get(saved, null) as Button
		if is_instance_valid(card):
			card.grab_focus()


# ── Логика выбора ──────────────────────────────────────────────────────────────

func _on_card_pressed(inv_name: String) -> void:
	if not _selected_inv.is_empty() and _inv_cards.has(_selected_inv):
		(_inv_cards[_selected_inv] as Button).add_theme_stylebox_override("normal", _card_style(false))

	_selected_inv = inv_name

	if _inv_cards.has(inv_name):
		(_inv_cards[inv_name] as Button).add_theme_stylebox_override("normal", _card_style(true))

	_update_detail()
	_save_selection(inv_name)
	investigator_selected.emit(inv_name)


func _update_detail() -> void:
	if _selected_inv.is_empty() or not _inv_data.has(_selected_inv):
		return
	var inv: Dictionary = _inv_data[_selected_inv]

	_detail_portrait.texture  = _load_portrait(_selected_inv)
	_detail_name.text         = inv.get("name", "")
	_detail_occupation.text   = inv.get("occupation", "")
	_detail_hp_val.text       = str(inv.get("health", 0))
	_detail_san_val.text      = str(inv.get("sanity", 0))

	var sk: Dictionary = inv.get("skills", {})
	_detail_skills.text = "Lore %d  ·  Infl %d  ·  Obs %d\nStr %d  ·  Will %d" % [
		int(sk.get("lore", 0)), int(sk.get("influence", 0)),
		int(sk.get("observation", 0)), int(sk.get("strength", 0)),
		int(sk.get("will", 0)),
	]

	_detail_roles.text = "  ·  ".join(inv.get("role", []))
	_detail_quote.text = "«%s»" % inv.get("quote", "")


func _reset_detail() -> void:
	_detail_portrait.texture  = _placeholder_texture()
	_detail_name.text         = "— Не выбран —"
	_detail_occupation.text   = ""
	_detail_hp_val.text       = "-"
	_detail_san_val.text      = "-"
	_detail_skills.text       = ""
	_detail_roles.text        = ""
	_detail_quote.text        = ""
