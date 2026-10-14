class_name SmoothSize
extends Container

## Плавная смена размера окна: контейнер между панелью модалки и её содержимым.
## Содержимое раскладывается в полный (натуральный) размер, а видимый размер — и
## минимальный размер для панели — догоняет его твином: окно растёт/сжимается
## плавно, а не скачком. И по высоте (появился исход боя), и по ширине (пул кубов
## шире арта монстра). Лишнее на время анимации обрезается (clip_contents);
## по ширине содержимое центрировано — обрезка симметрична, как и рост окна.
##
##   SmoothSize.wrap(_panel)  # вставить между панелью и её единственным ребёнком
##
## Первая раскладка — без анимации (окно открывается сразу нужного размера).

const DURATION: float = 0.3

var _shown := Vector2(-1.0, -1.0)  # видимый размер; < 0 — ещё не раскладывались
var _target := Vector2.ZERO
var _tween: Tween


## Вставить SmoothSize между panel и её содержимым (первый ребёнок-Control).
## Возвращает контейнер (или существующий, если панель уже обёрнута).
static func wrap(panel: Container) -> SmoothSize:
	for c: Node in panel.get_children():
		if c is SmoothSize:
			return c
	var content: Control = null
	for c: Node in panel.get_children():
		if c is Control:
			content = c
			break
	var ss := SmoothSize.new()
	ss.name = "SmoothSize"
	panel.add_child(ss)
	if content != null:
		panel.move_child(ss, content.get_index())
		content.reparent(ss, false)
	return ss


func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_PASS


func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		_sort()


func _get_minimum_size() -> Vector2:
	return Vector2(maxf(_shown.x, 0.0), maxf(_shown.y, 0.0))


func _content() -> Array:
	var out: Array = []
	for c: Node in get_children():
		if c is Control and (c as Control).visible:
			out.append(c)
	return out


# Содержимое — в натуральный размер (по центру по ширине); видимый размер окна
# подтягиваем к нему.
func _sort() -> void:
	var target := Vector2.ZERO
	for c: Control in _content():
		target = target.max(c.get_combined_minimum_size())
	# Панель может быть шире содержимого (custom_minimum_size) — тогда содержимое
	# занимает всю её ширину, как без обёртки.
	var w: float = maxf(target.x, size.x)
	for c: Control in _content():
		fit_child_in_rect(c, Rect2((size.x - w) * 0.5, 0.0, w, target.y))
	if target.is_equal_approx(_target) and _shown.x >= 0.0:
		return
	_target = target
	if _shown.x < 0.0 or not is_visible_in_tree():
		_set_shown(target)  # первая раскладка / скрыто — без анимации
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_set_shown, _shown, target, DURATION)


func _set_shown(v: Vector2) -> void:
	_shown = v
	update_minimum_size()


## Видимый размер сейчас (для тестов и отладки).
func shown_size() -> Vector2:
	return _shown
