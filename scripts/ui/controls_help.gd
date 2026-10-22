class_name ControlsHelp
extends ColorRect

## Справочник «Управление» (пункт меню паузы): что делают клавиши и мышь, что —
## кнопки геймпада. Иконки рисует InputGlyph; у геймпада — переключатель рода
## (PlayStation / Xbox / Nintendo), по умолчанию — подключённый контроллер.
## Закрытие — крестик, Esc или ○/B; сигнал closed.

signal closed

const _ROW_FS: int = 18
const _HEAD_FS: int = 22
const _GLYPH_H: float = 34.0
const _GLYPH_COL_W: float = 150.0  # колонка иконок — описания встают ровно
const _COL_W: float = 600.0

# Клавиатура и мышь: [кейкапы], ключ описания.
const _KEYBOARD := [
	[["CONTROLS_KEY_LMB"], "CONTROLS_KB_CLICK"],
	[["CONTROLS_KEY_LMB", "CONTROLS_KEY_MMB"], "CONTROLS_KB_DRAG"],
	[["CONTROLS_KEY_WHEEL"], "CONTROLS_KB_WHEEL"],
	[["Tab"], "CONTROLS_HAND"],
	[["←", "→"], "CONTROLS_SECTIONS"],
	[["C"], "CONTROLS_CHAT"],
	[["Esc"], "CONTROLS_KB_ESC"],
	[["Enter"], "CONTROLS_KB_ENTER"],
	[["CONTROLS_KEY_HOVER"], "CONTROLS_KB_PEEK"],
	[["CONTROLS_KEY_LMB"], "CONTROLS_KB_PANEL"],
]

# Геймпад: [кнопки (JOY_BUTTON_* / псевдокоды InputGlyph и GameInput)], ключ описания.
const _PAD := [
	[[InputGlyph.STICK_L, InputGlyph.DPAD_ANY], "CONTROLS_PAD_MOVE"],
	[[JOY_BUTTON_A], "CONTROLS_PAD_ACCEPT"],
	[[JOY_BUTTON_B], "CONTROLS_PAD_BACK"],
	[[JOY_BUTTON_Y], "CONTROLS_HAND"],
	[[JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER], "CONTROLS_SECTIONS"],
	[[GameInput.TRIGGER_RIGHT], "CONTROLS_PAD_ACTIONS"],
	[[GameInput.TRIGGER_LEFT], "CONTROLS_PAD_PANEL"],
	[[InputGlyph.STICK_R], "CONTROLS_PAD_RSTICK"],
	[[JOY_BUTTON_START], "CONTROLS_PAD_PAUSE"],
	[[JOY_BUTTON_BACK], "CONTROLS_CHAT"],
	[[JOY_BUTTON_X, JOY_BUTTON_Y], "CONTROLS_PAD_PICKER"],
]

const _FAMILY_KEYS := {
	InputDevice.PLAYSTATION: "CONTROLS_FAMILY_PS",
	InputDevice.XBOX: "CONTROLS_FAMILY_XBOX",
	InputDevice.NINTENDO: "CONTROLS_FAMILY_NINTENDO",
}

var _family: String = InputDevice.XBOX
var _pad_rows: VBoxContainer
var _family_btns: Dictionary = {}  # род → Button


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # открывается из паузы
	color = Color(0, 0, 0, 0.0)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_family = InputDevice.family()
	_build()


# Esc / ○ / B — как крестик.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed(GameInput.BACK):
		get_viewport().set_input_as_handled()
		close()


func close() -> void:
	closed.emit()
	queue_free()


func _build() -> void:
	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	UIStyle.style_modal_panel(panel)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)
	vbox.add_child(UIStyle.modal_header("CONTROLS_TITLE", close))
	UIStyle.separator(vbox)

	var cols := HBoxContainer.new()
	cols.name = "Columns"
	cols.add_theme_constant_override("separation", 48)
	vbox.add_child(cols)

	var kb := _column(cols, "Keyboard", "CONTROLS_KEYBOARD")
	for row_v: Variant in _KEYBOARD:
		var row: Array = row_v
		var glyphs: Array = []
		for t: String in row[0]:
			glyphs.append(InputGlyph.key_text(tr(t), _GLYPH_H))
		kb.add_child(_row(glyphs, String(row[1])))

	var pad := _column(cols, "Gamepad", "CONTROLS_GAMEPAD")
	var fams := HBoxContainer.new()
	fams.name = "Families"
	fams.add_theme_constant_override("separation", 8)
	pad.add_child(fams)
	for fam: String in InputDevice.FAMILIES:
		var b := UIStyle.button(String(_FAMILY_KEYS[fam]), UIColors.ACCENT)
		b.name = "Family_%s" % fam
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_set_family.bind(fam))
		fams.add_child(b)
		_family_btns[fam] = b
	_pad_rows = VBoxContainer.new()
	_pad_rows.name = "Rows"
	_pad_rows.add_theme_constant_override("separation", 8)
	pad.add_child(_pad_rows)
	_set_family(_family)
	(_family_btns[_family] as Button).grab_focus.call_deferred()  # геймпад: сразу в окне


func _column(parent: Control, node_name: String, title_key: String) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.name = node_name
	col.custom_minimum_size.x = _COL_W
	col.add_theme_constant_override("separation", 8)
	parent.add_child(col)
	var title := UIStyle.label(title_key, _HEAD_FS, UIColors.ACCENT)
	title.name = "Title"
	col.add_child(title)
	return col


# Строка справочника: иконки слева (колонка фиксированной ширины), описание справа.
func _row(glyphs: Array, desc_key: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 14)
	var icons := HBoxContainer.new()
	icons.name = "Icons"
	icons.custom_minimum_size.x = _GLYPH_COL_W
	icons.add_theme_constant_override("separation", 6)
	for g: Control in glyphs:
		icons.add_child(g)
	row.add_child(icons)
	var desc := UIStyle.label(desc_key, _ROW_FS, UIColors.TEXT)
	desc.name = "Desc"
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(desc)
	return row


# Пересобрать колонку геймпада под род fam (иконки кнопок разные).
func _set_family(fam: String) -> void:
	_family = fam
	for f: String in _family_btns:
		var b: Button = _family_btns[f]
		b.set_pressed_no_signal(f == fam)
		# Выбранный род — в полную силу, прочие — притушены (у стиля кнопок нет вида
		# «нажата», а цвет текста перебивает подсветка фокуса).
		b.modulate = Color.WHITE if f == fam else Color(1, 1, 1, 0.45)
	for c: Node in _pad_rows.get_children():
		_pad_rows.remove_child(c)
		c.queue_free()
	for row_v: Variant in _PAD:
		var row: Array = row_v
		var glyphs: Array = []
		for b: int in row[0]:
			glyphs.append(InputGlyph.pad(b, _GLYPH_H, fam))
		_pad_rows.add_child(_row(glyphs, String(row[1])))
