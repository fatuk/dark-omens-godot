class_name GuideHint
extends CanvasLayer

## Наставник-подсказка: профессор Армитедж выходит справа, стоит на верхнем краю
## нижней панели и указывает на рамку с текстом (стандартная рамка модалок).
## Реплики идут по очереди: клик (или Пробел/Enter) — следующая, после последней
## окно гаснет и шлёт finished. Esc — закрыть сразу.
##
##   GuideHint.say(self, ["GUIDE_WELCOME", "GUIDE_ACTIONS"])
##
## Реплика — ключ перевода (Label переводит сам) или готовая строка. Карта под
## подсказкой не реагирует: окно в реестре модалок (UIStyle.mark_modal).

signal finished

const _ART := preload("res://assets/guide/armitadge.png")
# Кончик указательного пальца в пикселях исходника.
const _FINGER := Vector2(47, 350)
# Нижняя полоса HUD (InvestigatorPanel.BAR_H): профессор стоит на её верхнем крае.
const _HUD_H: float = 248.0
const _FRAME_MIN_H: float = 150.0

# Раскладка — крутится в панели тюнинга (Ctrl+M, секция «ПОДСКАЗКИ»): открытая
# подсказка перераскладывается сразу (группа "guide_hint" → relayout). Найденные
# значения запекаются сюда же. static var, а не const — панель правит их вживую.
# Арт @2x — 0.5 = половина натурального размера (1536×1024 → 768×512).
static var ART_SCALE: float = 0.5
# Насколько арт уходит за правый край экрана (книга обрезана, как в макете).
static var ART_OVERFLOW_X: float = 140.0
# Ширина рамки.
static var FRAME_W: float = 620.0
# Правый край рамки относительно кончика пальца (+ — правее: рука ложится на угол).
static var FRAME_X: float = 40.0
# Верх рамки относительно кончика пальца (+ — ниже, − — выше).
static var FRAME_Y: float = 60.0
const _SLIDE_PX: float = 90.0  # въезд профессора справа
const _FADE_IN: float = 0.35
const _FADE_OUT: float = 0.2

var _lines: Array = []
var _over_modals: bool = false
var _index: int = 0
var _closing: bool = false
var _root: Control
var _art: TextureRect
var _frame: PanelContainer
var _text: Label
var _more: Label


## Показать реплики наставника поверх сцены parent. Возвращает узел подсказки
## (его finished — когда игрок прочитал всё). over_modals — поверх открытых окон
## (подсказка ПРО это окно: встреча, бой, магазин); иначе — под модалками.
static func say(parent: Node, lines: Array, over_modals: bool = false) -> GuideHint:
	var g := GuideHint.new()
	g.name = "GuideHint"
	g._lines = lines.duplicate()
	g._over_modals = over_modals
	parent.add_child(g)
	return g


func _ready() -> void:
	# Над картой и HUD (≤ 50), под модалками (80+); про окно — над ними (до 90:
	# диалоги и пауза выше).
	layer = 89 if _over_modals else 79
	add_to_group("guide_hint")  # TuningPanel пушит сюда relayout
	_build()
	if _lines.is_empty():
		_close()
		return
	_show_line(0)
	_layout()
	get_viewport().size_changed.connect(_layout)
	UIStyle.mark_modal(self, true)
	_play_in()


func _build() -> void:
	# Ловим клики по всему экрану: карта под подсказкой не должна реагировать.
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.gui_input.connect(_on_root_input)
	add_child(_root)

	# Рамка — под профессором: его рука ложится на её правый верхний угол.
	_frame = PanelContainer.new()
	_frame.name = "Frame"
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.style_modal_panel(_frame, 30)
	_root.add_child(_frame)
	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 8)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_child(box)
	_text = UIStyle.label("", UIStyle.MODAL_FS_LEAD)
	_text.name = "Text"
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_text)
	_more = UIStyle.label("GUIDE_CONTINUE", UIStyle.MODAL_FS_HINT, UIColors.MUTED)
	_more.name = "Continue"
	_more.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_more.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_more)

	_art = TextureRect.new()
	_art.name = "Armitage"
	_art.texture = _ART
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_SCALE
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_art)


## Перераскладка по текущим static var (зовёт TuningPanel).
func relayout() -> void:
	_layout()


# Раскладка от правого нижнего угла: профессор на верхнем крае HUD, рамка — слева
# от него на уровне пальца. Ширина экрана при aspect=expand разная — считаем от края.
func _layout() -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var art_size: Vector2 = _ART.get_size() * ART_SCALE
	var art_pos := Vector2(vp.x + ART_OVERFLOW_X - art_size.x, vp.y - _HUD_H - art_size.y)
	_art.size = art_size
	_art.position = art_pos
	var finger: Vector2 = art_pos + _FINGER * ART_SCALE
	_frame.custom_minimum_size = Vector2(FRAME_W, _FRAME_MIN_H)
	_frame.position = Vector2(finger.x + FRAME_X - FRAME_W, finger.y + FRAME_Y)
	_fit_frame.call_deferred()


# Высота рамки — по тексту. Отложенно: перенос строк в Label считается, когда ширина
# уже известна, а до этого минимальная высота «по слову в строке» раздувала рамку до
# низа экрана, и PanelContainer сам обратно не сжимается.
func _fit_frame() -> void:
	if is_instance_valid(_frame):
		_frame.size = Vector2(FRAME_W, 0.0)  # 0 → ужмётся до минимума содержимого


func _show_line(i: int) -> void:
	_index = i
	_text.text = String(_lines[i])
	var last: bool = i >= _lines.size() - 1
	_more.text = "GUIDE_CLOSE" if last else "GUIDE_CONTINUE"
	_fit_frame.call_deferred()  # другая реплика — другая высота


func _play_in() -> void:
	var rest_x: float = _art.position.x
	_art.position.x = rest_x + _SLIDE_PX
	_art.modulate.a = 0.0
	_frame.modulate.a = 0.0
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(
		Tween.EASE_OUT
	)
	tw.tween_property(_art, "position:x", rest_x, _FADE_IN)
	tw.tween_property(_art, "modulate:a", 1.0, _FADE_IN)
	tw.tween_property(_frame, "modulate:a", 1.0, _FADE_IN).set_delay(_FADE_IN * 0.5)


func _on_root_input(event: InputEvent) -> void:
	if (
		event is InputEventMouseButton
		and (event as InputEventMouseButton).pressed
		and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
	):
		_advance()
		get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and (event as InputEventKey).pressed):
		return
	match (event as InputEventKey).keycode:
		KEY_ESCAPE:
			_close()
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			_advance()
		_:
			return
	get_viewport().set_input_as_handled()


## Следующая реплика; после последней — закрыть.
func _advance() -> void:
	if _closing:
		return
	if _index + 1 < _lines.size():
		_show_line(_index + 1)
	else:
		_close()


func _close() -> void:
	if _closing:
		return
	_closing = true
	UIStyle.mark_modal(self, false)
	var tw := create_tween().set_parallel(true)
	if is_instance_valid(_root):
		tw.tween_property(_root, "modulate:a", 0.0, _FADE_OUT)
	tw.chain().tween_callback(
		func() -> void:
			finished.emit()
			queue_free()
	)
