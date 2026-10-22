class_name PadFocus
extends Node

## Фокус для геймпада: пока игрок на геймпаде (InputDevice.using_pad), держит фокус
## внутри верхней открытой модалки (UIStyle.top_modal) — крестовина ходит по её
## кнопкам, ✕/A жмёт. Модалки пересобирают кнопки на каждом синке, и фокус
## теряется; тогда возвращаем его на кнопку с тем же текстом, иначе — на кнопку по
## умолчанию (мета DEFAULT) или первую доступную, не «×». Фокус в окне ВЫШЕ модалки
## (меню паузы, консоль) не трогаем. Без модалки — то же в открытой «зоне фокуса»
## (группа ZONE, напр. сайдбар локации; открыта — is_open()), иначе не трогаем.
## ○/B закрывает верхнюю модалку её же кнопкой: крестиком (CLOSE) или кнопкой
## «закрыть / ок / отмена / продолжить» (DISMISS_KEYS). Окна со своим «назад»
## (ModalDialog, просмотр карты, галерея) ловят его раньше, в _input.
## Живёт под CustomCursor рядом с InputDevice.

const DEFAULT := &"pad_default"  # мета кнопки: фокус сюда при открытии окна
const ZONE := &"pad_zone"  # группа панелей не-модалок, где тоже держим фокус
const SKIP := &"pad_skip_default"  # мета: не брать по умолчанию (крестик «закрыть»)
const CLOSE := &"pad_close"  # мета крестика окна (UIStyle.style_modal_close_button)
# Кнопки, которые закрывают окно без решения — их жмёт ○/B. «Завершить» бой и пр.
# действия сюда не входят: «назад» не должен ничего решать за игрока.
const DISMISS_KEYS := [
	"BTN_BACK",
	"BTN_CANCEL",
	"BTN_CANCEL_BIG",
	"BTN_OK",
	"GAINS_OK",
	"MYTHOS_BTN_CLOSE",
	"SIDEBAR_BTN_CLOSE",
	"TRADE_OFFER_CANCEL",
	"ENCOUNTER_CONTINUE",
]

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
		top = _open_zone()
	if top == null:
		return
	var foc: Control = get_viewport().gui_get_focus_owner()
	if foc != null and foc.is_visible_in_tree() and not foc.is_queued_for_deletion():
		if top.is_ancestor_of(foc):
			if foc is Button:
				_last_text = (foc as Button).text
			return
		if UIStyle.canvas_layer_of(foc) > UIStyle.canvas_layer_of(top):
			return  # фокус в окне поверх модалки (пауза, консоль)
	var target: Control = pick(top, _last_text)
	if target != null:
		target.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventJoypadButton and event.is_action_pressed(GameInput.BACK)):
		return
	var top: Node = UIStyle.top_modal()
	if top == null:
		return
	var btn: BaseButton = find_dismiss(top)
	if btn != null:
		btn.pressed.emit()
		get_viewport().set_input_as_handled()


## Кнопка, закрывающая окно root: видимый доступный крестик (CLOSE), иначе кнопка
## с текстом из DISMISS_KEYS (ключ или его перевод). null — закрыть нечем.
static func find_dismiss(root: Node) -> BaseButton:
	var labelled: BaseButton = null
	for n: Node in root.find_children("*", "BaseButton", true, false):
		var b := n as BaseButton
		if not b.is_visible_in_tree() or b.disabled:
			continue
		if b.has_meta(CLOSE):
			return b
		if labelled == null and b is Button and _is_dismiss_text((b as Button).text):
			labelled = b
	return labelled


static func _is_dismiss_text(text: String) -> bool:
	for k: String in DISMISS_KEYS:
		if text == k or text == TranslationServer.translate(k):
			return true
	return false


# Открытая зона фокуса (без модалок): видима и, если умеет, is_open().
func _open_zone() -> Node:
	for n: Node in get_tree().get_nodes_in_group(ZONE):
		if n is CanvasItem and not (n as CanvasItem).is_visible_in_tree():
			continue
		if n.has_method("is_open") and not bool(n.call("is_open")):
			continue
		return n
	return null


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
