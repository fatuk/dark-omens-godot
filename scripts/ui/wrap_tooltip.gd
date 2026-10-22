class_name WrapTooltip
extends Control

## Контрол со своей всплывающей подсказкой вместо стандартной Godot:
##   • текст переносится — ширина по тексту, но не больше MAX_W (монстр со
##     способностью иначе тянулся строкой на весь экран);
##   • чёткий шрифт — подсказка рисуется в основном вьюпорте, где текст масштабируется
##     вместе с игрой. Стандартная живёт в отдельном окне-попапе, рендерится в 1× и
##     растягивается до экрана — буквы мылятся;
##   • плотный фон — сквозь стандартную просвечивало то, что под ней.
## Встаёт правее курсора (его ширина), у краёв экрана переносится внутрь.
## Геймпад: если контрол фокусируем (focus_mode) — в фокусе с геймпада подсказка
## встаёт рядом с ним (курсора нет), а сам он обводится рамкой.
##
##   var tile := WrapTooltip.new()
##   tile.tooltip_text = "…"   # текст храним там же, стандартная подсказка подавлена

const MAX_W: float = 460.0
const _FS: int = 18
const _PAD := Vector2(14, 10)
const _CURSOR := preload("res://scripts/ui/custom_cursor.gd")

# Один слой подсказок на всё дерево: поверх модалок (80–100), под курсором (128).
static var _layer: CanvasLayer = null
static var _panel: PanelContainer = null
static var _owner_id: int = 0  # чья подсказка сейчас на экране

var _timer: SceneTreeTimer = null
var _ring: Panel = null  # рамка фокуса с геймпада (поверх детей)


func _ready() -> void:
	mouse_entered.connect(_on_enter)
	mouse_exited.connect(_hide)
	focus_entered.connect(_on_focus)
	focus_exited.connect(_on_unfocus)
	visibility_changed.connect(_on_visibility)
	tree_exiting.connect(_hide)


## Стандартную подсказку Godot не показываем — свою рисуем сами.
func _get_tooltip(_at: Vector2) -> String:
	return ""


func _on_visibility() -> void:
	if not is_visible_in_tree():
		_hide()


func _on_enter() -> void:
	if tooltip_text.is_empty():
		return
	var delay: float = float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec", 0.5))
	_timer = get_tree().create_timer(delay)
	var t: SceneTreeTimer = _timer
	t.timeout.connect(_on_delay.bind(t))


# Задержка вышла: мышь всё ещё над контролом — показать.
func _on_delay(t: SceneTreeTimer) -> void:
	if (
		t == _timer
		and is_inside_tree()
		and get_global_rect().has_point(get_global_mouse_position())
	):
		_show()


func _show(beside: bool = false) -> void:
	var panel: PanelContainer = _ensure_layer(get_tree())
	var lbl: Label = panel.get_child(0)
	lbl.text = tooltip_text
	lbl.custom_minimum_size.x = text_width(tooltip_text, lbl)
	panel.reset_size()
	panel.visible = true
	_owner_id = get_instance_id()
	# Размер с переносом строк известен после раскладки.
	if beside:
		_place_beside.call_deferred(panel)
	else:
		_place.call_deferred(panel)


# Фокус с геймпада: рамка и подсказка сразу (без задержки — курсора нет).
func _on_focus() -> void:
	if not InputDevice.using_pad():
		return
	if _ring == null:
		_ring = Panel.new()
		_ring.name = "FocusRing"
		_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var sb := StyleBoxFlat.new()
		sb.draw_center = false
		sb.border_color = UIColors.ACCENT
		sb.set_border_width_all(3)
		_ring.add_theme_stylebox_override("panel", sb)
		add_child(_ring)
	move_child(_ring, -1)  # поверх арта и чисел
	_ring.visible = true
	if not tooltip_text.is_empty():
		_show(true)


func _on_unfocus() -> void:
	if _ring != null:
		_ring.visible = false
	_hide()


# Рядом с контролом: справа от него, не влезает — слева; по вертикали — вровень с
# его верхом, в пределах экрана.
func _place_beside(panel: PanelContainer) -> void:
	if not is_instance_valid(panel) or not panel.visible:
		return
	panel.reset_size()
	var vp: Vector2 = get_viewport_rect().size
	var r: Rect2 = get_global_rect()
	var pos := Vector2(r.end.x + 10.0, r.position.y)
	if pos.x + panel.size.x > vp.x:
		pos.x = r.position.x - panel.size.x - 10.0
	pos.y = clampf(pos.y, 4.0, maxf(4.0, vp.y - panel.size.y - 4.0))
	panel.position = Vector2(maxf(4.0, pos.x), pos.y)


func _hide() -> void:
	_timer = null
	if _owner_id == get_instance_id() and is_instance_valid(_panel):
		_panel.visible = false
		_owner_id = 0


# Правее курсора; не влезает справа — левее точки мыши, снизу — выше неё.
func _place(panel: PanelContainer) -> void:
	if not is_instance_valid(panel) or not panel.visible:
		return
	panel.reset_size()
	var vp: Vector2 = get_viewport_rect().size
	var mouse: Vector2 = get_viewport().get_mouse_position()
	var off: Vector2 = _CURSOR.TOOLTIP_OFFSET
	var pos: Vector2 = mouse + off
	if pos.x + panel.size.x > vp.x:
		pos.x = mouse.x - panel.size.x - 8.0
	if pos.y + panel.size.y > vp.y:
		pos.y = vp.y - panel.size.y - 4.0
	panel.position = Vector2(maxf(4.0, pos.x), maxf(4.0, pos.y))


## Ширина текста подсказки: своя, но не больше MAX_W (дальше — перенос по словам).
static func text_width(text: String, lbl: Label) -> float:
	var font: Font = lbl.get_theme_font("font")
	var natural: float = font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _FS).x
	return minf(ceilf(natural) + 2.0, MAX_W)


static func _ensure_layer(tree: SceneTree) -> PanelContainer:
	if is_instance_valid(_panel):
		return _panel
	_layer = CanvasLayer.new()
	_layer.name = "TooltipLayer"
	_layer.layer = 120
	tree.root.add_child(_layer)
	_panel = PanelContainer.new()
	_panel.name = "Tooltip"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.055, 0.052, 0.045, 0.97)
	sb.border_color = UIColors.BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = _PAD.x
	sb.content_margin_right = _PAD.x
	sb.content_margin_top = _PAD.y
	sb.content_margin_bottom = _PAD.y
	_panel.add_theme_stylebox_override("panel", sb)
	_layer.add_child(_panel)
	var lbl := Label.new()
	lbl.name = "Text"
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", _FS)
	lbl.add_theme_color_override("font_color", UIColors.TEXT)
	_panel.add_child(lbl)
	return _panel
