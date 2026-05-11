extends CanvasLayer

## Боковая панель справа с инфой о выбранной локации.
## Открывается через show_location(data), закрывается close_panel() или
## кнопкой ✕. При смене локации с открытым сайдбаром просто обновляет контент
## без re-анимации.
##
## Сигналы:
##   closed              — пользователь закрыл крестиком (карта снимет подсветку)
##   neighbor_selected   — клик по соседу в списке (карта переключится туда)

signal closed
signal neighbor_selected(loc_name: String)

const PANEL_WIDTH: float = 360.0
const ANIM_TIME:   float = 0.22

# Цвета и подписи типов связей (соответствуют MapLayer.COLOR_*).
const CONN_COLORS: Dictionary = {
	"ship":      Color(0.275, 0.510, 0.706),
	"train":     Color(0.627, 0.322, 0.176),
	"uncharted": Color(1.000, 0.843, 0.000),
}
const CONN_LABELS: Dictionary = {
	"ship":      "морем",
	"train":     "поездом",
	"uncharted": "путь",
}

@onready var _panel:         PanelContainer = %Panel
@onready var _title:         Label          = %Title
@onready var _subtitle:      Label          = %Subtitle
@onready var _type_label:    Label          = %TypeLabel
@onready var _description:   Label          = %Description
@onready var _close_btn:     Button         = %CloseBtn
@onready var _neighbors_hdr: Label          = %NeighborsHeader
@onready var _neighbors:     VBoxContainer  = %NeighborsList

var _is_open: bool   = false
var _tween:   Tween  = null


func _ready() -> void:
	UIStyle.style_panel(_panel, 18)
	_style_close_button()
	_title.add_theme_color_override("font_color",         UIColors.ACCENT)
	_subtitle.add_theme_color_override("font_color",      UIColors.MUTED)
	_type_label.add_theme_color_override("font_color",    UIColors.WARNING)
	_description.add_theme_color_override("font_color",   UIColors.TEXT)
	_neighbors_hdr.add_theme_color_override("font_color", UIColors.MUTED)
	_close_btn.pressed.connect(_on_close_pressed)
	_apply_offsets(true)


# ── Public ────────────────────────────────────────────────────────────────────

func show_location(data: Dictionary) -> void:
	_title.text       = String(data.get("name", ""))
	_subtitle.text    = String(data.get("realWorldLocation", ""))
	_type_label.text  = _type_label_for(String(data.get("type", "city")))
	_description.text = String(data.get("description", ""))
	_populate_neighbors(data.get("connections", []))
	if not _is_open:
		_is_open = true
		_animate(false)


func close_panel() -> void:
	if not _is_open:
		return
	_is_open = false
	_animate(true)
	closed.emit()


func is_open() -> bool:
	return _is_open


# ── Соседи ───────────────────────────────────────────────────────────────────

func _populate_neighbors(conns: Array) -> void:
	for child in _neighbors.get_children():
		child.queue_free()

	if conns.is_empty():
		var none := Label.new()
		none.text = "—"
		none.add_theme_color_override("font_color", UIColors.MUTED)
		none.add_theme_font_size_override("font_size", 13)
		_neighbors.add_child(none)
		return

	for i: int in range(conns.size()):
		var c: Dictionary = conns[i]
		var to_name: String   = String(c.get("to", ""))
		var ctype:   String   = String(c.get("type", "ship"))
		_neighbors.add_child(_make_neighbor_row(to_name, ctype))


func _make_neighbor_row(to_name: String, ctype: String) -> Button:
	var btn := Button.new()
	btn.text = to_name
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_button(btn, CONN_COLORS.get(ctype, UIColors.BORDER))
	btn.add_theme_font_size_override("font_size", 13)
	# Подпись «морем/поездом/путь» в правом углу — добавим как дочерний Label.
	var hint := Label.new()
	hint.text = String(CONN_LABELS.get(ctype, ctype))
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", CONN_COLORS.get(ctype, UIColors.MUTED))
	hint.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	hint.offset_left   = -90.0
	hint.offset_right  = -10.0
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(hint)
	btn.pressed.connect(func() -> void: neighbor_selected.emit(to_name))
	return btn


# ── Внутренние ───────────────────────────────────────────────────────────────

func _on_close_pressed() -> void:
	close_panel()


func _animate(hide_panel: bool) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var off_left: float  = 0.0         if hide_panel else -PANEL_WIDTH
	var off_right: float = PANEL_WIDTH if hide_panel else 0.0
	_tween.tween_property(_panel, "offset_left",  off_left,  ANIM_TIME)
	_tween.tween_property(_panel, "offset_right", off_right, ANIM_TIME)


func _apply_offsets(hide_panel: bool) -> void:
	if hide_panel:
		_panel.offset_left  = 0.0
		_panel.offset_right = PANEL_WIDTH
	else:
		_panel.offset_left  = -PANEL_WIDTH
		_panel.offset_right = 0.0


func _style_close_button() -> void:
	UIStyle.style_button(_close_btn, UIColors.DANGER)
	_close_btn.add_theme_font_size_override("font_size", 18)


func _type_label_for(t: String) -> String:
	match t:
		"city":       return "ГОРОД"
		"sea":        return "МОРЕ"
		"wilderness": return "ДИКАЯ ЗЕМЛЯ"
	return t.to_upper()
