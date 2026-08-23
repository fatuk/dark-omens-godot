extends CanvasLayer

## Кастомный курсор. Autoload /root/CustomCursor.
##
## Скрывает системный курсор и рисует свой PNG поверх всего.
## Над интерактивными контролами (BaseButton без disabled, либо любой Control
## с mouse_default_cursor_shape = CURSOR_POINTING_HAND) показывает «активный»
## вариант — со светящимся зелёным глазом, плавно перетекая.
##
## Хотспот — верхний-левый угол текстуры (там кончик стрелки на PNG).

# Ассеты под 2x — на экране рисуем в половину от исходных 195×263.
const CURSOR_SIZE: Vector2 = Vector2(97.5, 131.5)

# Длительность кросс-фейда между обычным и активным курсором.
const FADE_TIME: float = 0.12

@onready var _icon_default: TextureRect = %IconDefault
@onready var _icon_active: TextureRect = %IconActive

var _is_active_now: bool = false
var _tween: Tween = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_hide_system_cursor()
	_icon_default.size = CURSOR_SIZE
	_icon_active.size = CURSOR_SIZE


## macOS прячет курсор только для окна в фокусе, а autoload зовёт set_mouse_mode
## раньше, чем окно станет активным, — системная стрелка остаётся поверх нашей,
## и игрок видит два курсора. Переспрашиваем на возврат фокуса и на вход мыши.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_WM_MOUSE_ENTER:
		_hide_system_cursor(true)


## force — переставить режим через VISIBLE. Нужно потому, что set_mouse_mode
## выходит раньше времени, если запрошенный режим совпадает с текущим: когда
## движок считает курсор скрытым, а система его всё же рисует, простой повтор
## вызова ничего не даст. Дёшево только по событиям, не каждый кадр.
func _hide_system_cursor(force: bool = false) -> void:
	if Input.get_mouse_mode() == Input.MOUSE_MODE_HIDDEN:
		if not force:
			return
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)


func _process(_dt: float) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	_hide_system_cursor()  # страховка: системный курсор мог вернуться сам
	var pos := vp.get_mouse_position()
	_icon_default.position = pos
	_icon_active.position = pos
	var hovered: Control = vp.gui_get_hovered_control()
	var active := _is_interactive(hovered)
	if active != _is_active_now:
		_is_active_now = active
		_animate_to(active)


func _animate_to(active: bool) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	# Интерполируем альфы в обе стороны: активный 0↔1, обычный 1↔0.
	var target_active: float = 1.0 if active else 0.0
	var target_default: float = 0.0 if active else 1.0
	_tween.tween_property(_icon_active, "modulate:a", target_active, FADE_TIME)
	_tween.tween_property(_icon_default, "modulate:a", target_default, FADE_TIME)


func _is_interactive(c: Control) -> bool:
	if c == null:
		return false
	if c is BaseButton:
		return not (c as BaseButton).disabled
	return c.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND
