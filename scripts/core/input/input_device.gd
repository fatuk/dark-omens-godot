class_name InputDevice
extends Node

## Чем игрок управляет прямо сейчас: мышью/клавиатурой или геймпадом, и какой у
## геймпада «род» (для иконок кнопок). Узел живёт под CustomCursor (тот монтирует
## его в _ready); статические геттеры — для всех остальных:
##   InputDevice.using_pad()    — последний ввод был с геймпада (прячем курсор,
##                                показываем фокус и иконки кнопок)
##   InputDevice.family()       — xbox | playstation | nintendo (иконки кнопок)
##   InputDevice.get_instance().changed.connect(...)
## Род берётся из vendor id / имени контроллера; «прочие» — как Xbox (так их
## рисует большинство игр). SettingsStore.pad_glyphs ≠ "auto" — принудительный
## род (настройка и отладка без нужного контроллера: консоль `pad xbox`).

signal changed

const XBOX := "xbox"
const PLAYSTATION := "playstation"
const NINTENDO := "nintendo"
const FAMILIES := [XBOX, PLAYSTATION, NINTENDO]

# USB vendor id производителей геймпадов.
const _VENDORS := {1118: XBOX, 1356: PLAYSTATION, 1406: NINTENDO}
const _MOUSE_MOVE_MIN: float = 3.0  # px: дрожание мыши на столе не забирает управление

static var _inst: InputDevice = null

var pad_active: bool = false
var detected: String = XBOX  # род последнего активного геймпада


static func get_instance() -> InputDevice:
	return _inst


## Последний ввод — с геймпада.
static func using_pad() -> bool:
	return _inst != null and _inst.pad_active


## Род геймпада для иконок: принудительный из настроек или определённый.
static func family() -> String:
	var forced: String = SettingsStore.pad_glyphs if _has_settings() else "auto"
	if forced in FAMILIES:
		return forced
	return _inst.detected if _inst != null else XBOX


## Род по описанию контроллера: vendor id (надёжнее) или имя SDL.
static func family_for(joy_name: String, vendor_id: int = 0) -> String:
	if _VENDORS.has(vendor_id):
		return String(_VENDORS[vendor_id])
	var n: String = joy_name.to_lower()
	for tag: String in ["dualsense", "dualshock", "playstation", "ps5", "ps4", "ps3", "sony"]:
		if n.contains(tag):
			return PLAYSTATION
	for tag: String in ["nintendo", "switch", "joy-con", "pro controller"]:
		if n.contains(tag):
			return NINTENDO
	return XBOX  # Xbox, Steam Deck/виртуальный Steam, клоны XInput и прочие


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # и в меню паузы
	_inst = self
	Input.joy_connection_changed.connect(_on_joy_connection)
	var pads: Array[int] = Input.get_connected_joypads()
	if not pads.is_empty():
		detected = _detect(pads[0])


func _exit_tree() -> void:
	if _inst == self:
		_inst = null


func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		if (event as InputEventJoypadButton).pressed:
			_use_pad(event.device)
	elif event is InputEventJoypadMotion:
		if absf((event as InputEventJoypadMotion).axis_value) > GameInput.STICK_DEADZONE:
			_use_pad(event.device)
	elif event is InputEventMouseMotion:
		if (event as InputEventMouseMotion).relative.length() >= _MOUSE_MOVE_MIN:
			_use_pointer()
	elif event is InputEventMouseButton or event is InputEventKey:
		if event.is_pressed():
			_use_pointer()


func _use_pad(device: int) -> void:
	var fam: String = _detect(device)
	if pad_active and fam == detected:
		return
	pad_active = true
	detected = fam
	changed.emit()


func _use_pointer() -> void:
	if not pad_active:
		return
	pad_active = false
	changed.emit()


func _on_joy_connection(device: int, connected: bool) -> void:
	if connected:
		detected = _detect(device)
	elif pad_active and Input.get_connected_joypads().is_empty():
		pad_active = false  # выдернули последний геймпад — вернуть курсор
	changed.emit()


func _detect(device: int) -> String:
	var info: Dictionary = Input.get_joy_info(device)
	return family_for(Input.get_joy_name(device), int(info.get("vendor_id", 0)))


static func _has_settings() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	return tree != null and tree.root.has_node("SettingsStore")
