extends CanvasLayer

## Кастомный курсор. Autoload /root/CustomCursor.
##
## Скрывает системный курсор и рисует свой PNG поверх всего. Над кнопками и прочими
## активными элементами курсор не меняется — всегда одна и та же стрелка.
##
## Хотспот — верхний-левый угол текстуры (там кончик стрелки на PNG).
##
## Здесь же поднимается поддержка геймпада (курсор — тот, кто первым узнаёт, чем
## управляют): действия InputMap (GameInput.register), трекер устройства
## (InputDevice) и фокус модалок (PadFocus). На геймпаде курсор прячется.

# Ассеты под 2x — на экране рисуем в половину от исходных 195×263.
const CURSOR_SIZE: Vector2 = Vector2(97.5, 131.5)

# Подсказки (tooltip) — правее нашего курсора, а не под ним: стандартное смещение
# Godot (10, 10) кладёт текст прямо под рисунок стрелки. У правого края экрана Godot
# сам переносит подсказку влево от точки мыши — там курсора нет.
const TOOLTIP_OFFSET: Vector2 = Vector2(CURSOR_SIZE.x + 8.0, 24.0)

@onready var _icon_default: TextureRect = %IconDefault


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Только в памяти (project.godot не трогаем) — движок читает настройку при показе.
	ProjectSettings.set_setting("display/mouse_cursor/tooltip_position_offset", TOOLTIP_OFFSET)
	_hide_system_cursor()
	_icon_default.size = CURSOR_SIZE
	GameInput.register()
	var dev := InputDevice.new()
	dev.name = "InputDevice"
	add_child(dev)
	dev.changed.connect(_on_device_changed)
	var pf := PadFocus.new()
	pf.name = "PadFocus"
	add_child(pf)


# Геймпад — курсор прячем (фокус и так показывает, где мы); мышь — возвращаем.
func _on_device_changed() -> void:
	_icon_default.visible = not InputDevice.using_pad()


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
	_icon_default.position = vp.get_mouse_position()
