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
const SCROLL_CARD := &"pad_scroll_card"  # мета контрола: его карта (GameCard) — для стика

# Правый стик — прокрутка длинного текста: скорость px/с на полном отклонении,
# мёртвая зона; квадратичная кривая — у центра медленно, читать удобно.
const SCROLL_SPEED: float = 600.0
const SCROLL_DEADZONE: float = 0.2
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

static var _inst: PadFocus = null

var _last_text: String = ""
var _right_y: float = 0.0  # последнее отклонение правого стика по вертикали


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_inst = self
	var dev: InputDevice = InputDevice.get_instance()
	if dev != null:
		dev.changed.connect(_on_device_changed)


func _process(dt: float) -> void:
	if not InputDevice.using_pad():
		return
	var top: Node = UIStyle.top_modal()
	if top == null:
		top = _open_zone()
	_scroll_with_stick(top, dt)
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


# ── Правый стик: прокрутка ────────────────────────────────────────────────────


## Правый стик по вертикали (−1 вверх … 1 вниз), 0 — в мёртвой зоне. Для тех, кто
## крутит им не текст (зум карты).
static func right_stick_y() -> float:
	if _inst == null or absf(_inst._right_y) < SCROLL_DEADZONE:
		return 0.0
	return _inst._right_y


# Правый стик по вертикали — из событий (держим последнее значение).
func _input(event: InputEvent) -> void:
	if (
		event is InputEventJoypadMotion
		and (event as InputEventJoypadMotion).axis == JOY_AXIS_RIGHT_Y
	):
		_right_y = (event as InputEventJoypadMotion).axis_value


func _scroll_with_stick(scope: Node, dt: float) -> void:
	var v: float = _right_y
	if absf(v) < SCROLL_DEADZONE:
		return
	var px: float = signf(v) * v * v * SCROLL_SPEED * dt
	var fan: Control = _open_fan_card()
	if fan != null:
		scope = null  # открытый веер — поверх всего, крутим его активную карту
	for t: Object in scroll_targets(scope, get_viewport().gui_get_focus_owner(), fan):
		if scroll_by(t, px):
			return


## Чем крутить, по приоритету: карта веера; карта/прокрутка того, что в фокусе;
## затем всё в окне scope — карты с длинным описанием и ScrollContainer'ы.
static func scroll_targets(scope: Node, foc: Control, fan: Control = null) -> Array:
	var out: Array = []
	if fan != null:
		out.append(fan)
	if foc != null:
		if foc.has_meta(SCROLL_CARD):
			out.append(foc.get_meta(SCROLL_CARD))
		var p: Node = foc
		while p != null:
			if p is ScrollContainer or p is GameCard:
				out.append(p)
				break
			p = p.get_parent()
	if scope != null:
		for n: Node in scope.find_children("*", "", true, false):
			if (n is GameCard or n is ScrollContainer) and (n as Control).is_visible_in_tree():
				out.append(n)
	return out


## Прокрутить цель на px (+ вниз). false — нечего (влезает / у края).
static func scroll_by(t: Object, px: float) -> bool:
	if t is GameCard:
		return (t as GameCard).scroll_desc_by(px)
	if t is ScrollContainer:
		var sc := t as ScrollContainer
		var before: int = sc.scroll_vertical
		sc.scroll_vertical = (
			before + int(roundf(px)) if absf(px) >= 1.0 else before + int(signf(px))
		)
		return sc.scroll_vertical != before
	return false


func _open_fan_card() -> Control:
	for fan: Node in get_tree().get_nodes_in_group("hand_carousel"):
		if fan.has_method("active_card"):
			var c: Control = fan.call("active_card")
			if c != null:
				return c
	return null


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
## иначе помеченная DEFAULT, иначе первая доступная не-SKIP, иначе любая доступная;
## кнопок нет — любой фокусируемый элемент (карточка лавки, куб).
static func pick(root: Node, prefer: String = "") -> Control:
	var buttons: Array = []
	for n: Node in root.find_children("*", "BaseButton", true, false):
		var b := n as BaseButton
		if b.is_visible_in_tree() and not b.disabled and b.focus_mode != Control.FOCUS_NONE:
			buttons.append(b)
	if buttons.is_empty():
		# Доступных кнопок нет (в лавке после долга: «Купить» ждёт выбора, прочие
		# скрыты) — фокус на любой фокусируемый элемент окна (карточку, куб), иначе
		# крестовине не от чего двигаться.
		for n: Node in root.find_children("*", "Control", true, false):
			var c := n as Control
			if c is BaseButton:
				continue  # кнопки уже перебраны: остались только недоступные
			if c.focus_mode == Control.FOCUS_ALL and c.is_visible_in_tree():
				return c
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
