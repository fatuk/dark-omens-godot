class_name PadFocus
extends Node

## Фокус для геймпада: пока игрок на геймпаде (InputDevice.using_pad), держит фокус
## внутри верхней открытой модалки (UIStyle.top_modal) — крестовина ходит по её
## кнопкам, ✕/A жмёт. Модалки пересобирают кнопки на каждом синке, и фокус
## теряется; тогда возвращаем его на кнопку с тем же текстом, иначе — на кнопку по
## умолчанию (мета DEFAULT) или первую доступную, не «×». Фокус в окне ВЫШЕ модалки
## (меню паузы, консоль) не трогаем. Без модалки фокус не трогаем вовсе.
## Живёт под CustomCursor рядом с InputDevice.

const DEFAULT := &"pad_default"  # мета кнопки: фокус сюда при открытии окна
const SKIP := &"pad_skip_default"  # мета: не брать по умолчанию (крестик «закрыть»)

var _last_text: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var dev: InputDevice = InputDevice.get_instance()
	if dev != null:
		dev.changed.connect(_on_device_changed)


func _process(_dt: float) -> void:
	if not InputDevice.using_pad():
		return
	var top: Node = UIStyle.top_modal()
	if top == null:
		return
	var foc: Control = get_viewport().gui_get_focus_owner()
	if foc != null and foc.is_visible_in_tree():
		if top.is_ancestor_of(foc):
			if foc is Button:
				_last_text = (foc as Button).text
			return
		if UIStyle.canvas_layer_of(foc) > UIStyle.canvas_layer_of(top):
			return  # фокус в окне поверх модалки (пауза, консоль)
	var target: Control = pick(top, _last_text)
	if target != null:
		target.grab_focus()


## Куда поставить фокус в окне root: кнопка с текстом prefer (пересобранная та же),
## иначе помеченная DEFAULT, иначе первая доступная не-SKIP, иначе любая доступная.
static func pick(root: Node, prefer: String = "") -> Control:
	var buttons: Array = []
	for n: Node in root.find_children("*", "BaseButton", true, false):
		var b := n as BaseButton
		if b.is_visible_in_tree() and not b.disabled and b.focus_mode != Control.FOCUS_NONE:
			buttons.append(b)
	if buttons.is_empty():
		return null
	if not prefer.is_empty():
		for b: BaseButton in buttons:
			if b is Button and (b as Button).text == prefer:
				return b
	for b: BaseButton in buttons:
		if b.has_meta(DEFAULT):
			return b
	for b: BaseButton in buttons:
		if not b.has_meta(SKIP):
			return b
	return buttons[0]


# Смена устройства: перерисовать кнопку в фокусе (подсветка фокуса видна только на
# геймпаде), уход на мышь — забыть запомненную кнопку.
func _on_device_changed() -> void:
	var foc: Control = get_viewport().gui_get_focus_owner()
	if foc != null:
		foc.queue_redraw()
	if not InputDevice.using_pad():
		_last_text = ""
