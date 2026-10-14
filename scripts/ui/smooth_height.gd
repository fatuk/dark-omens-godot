class_name SmoothHeight
extends Container

## Плавная смена высоты окна: контейнер между панелью модалки и её содержимым.
## Содержимое раскладывается в полный рост, а видимая высота (и минимальный размер
## для панели) догоняет её твином — окно растёт/сжимается плавно, а не скачком.
## Лишнее на время анимации обрезается (clip_contents).
##
##   SmoothHeight.wrap(_panel)  # вставить между панелью и её единственным ребёнком
##
## Первая раскладка — без анимации (окно открывается сразу нужного размера).

const DURATION: float = 0.3

var _shown_h: float = -1.0  # видимая высота; -1 — ещё не раскладывались
var _target_h: float = 0.0
var _tween: Tween


## Вставить SmoothHeight между panel и её содержимым (первый ребёнок). Возвращает
## контейнер (или существующий, если уже обёрнута).
static func wrap(panel: Container) -> SmoothHeight:
	for c: Node in panel.get_children():
		if c is SmoothHeight:
			return c
	var content: Control = null
	for c: Node in panel.get_children():
		if c is Control:
			content = c
			break
	var sh := SmoothHeight.new()
	sh.name = "SmoothHeight"
	panel.add_child(sh)
	if content != null:
		panel.move_child(sh, content.get_index())
		content.reparent(sh, false)
	return sh


func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		_sort()


func _get_minimum_size() -> Vector2:
	var w: float = 0.0
	for c: Control in _content():
		w = maxf(w, c.get_combined_minimum_size().x)
	return Vector2(w, maxf(_shown_h, 0.0))


func _content() -> Array:
	var out: Array = []
	for c: Node in get_children():
		if c is Control and (c as Control).visible:
			out.append(c)
	return out


# Ребёнок — в полный (натуральный) рост; высоту окна подтягиваем к нему.
func _sort() -> void:
	var target: float = 0.0
	for c: Control in _content():
		target = maxf(target, c.get_combined_minimum_size().y)
	for c: Control in _content():
		fit_child_in_rect(c, Rect2(0, 0, size.x, target))
	if is_equal_approx(target, _target_h) and _shown_h >= 0.0:
		return
	_target_h = target
	if _shown_h < 0.0 or not is_visible_in_tree():
		_set_shown(target)  # первая раскладка / скрыто — без анимации
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_set_shown, _shown_h, target, DURATION)


func _set_shown(h: float) -> void:
	_shown_h = h
	update_minimum_size()


## Видимая высота сейчас (для тестов).
func shown_height() -> float:
	return _shown_h
