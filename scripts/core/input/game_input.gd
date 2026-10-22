class_name GameInput
extends RefCounted

## Действия ввода игры: клавиатура и геймпад в одном InputMap. Кнопки геймпада —
## по ПОЛОЖЕНИЮ (SDL): JOY_BUTTON_A — нижняя (✕ на PlayStation, A на Xbox, B на
## Switch), JOY_BUTTON_B — правая и т.д., поэтому раскладка одна на все контроллеры.
## project.godot не трогаем: действия регистрируются в памяти на старте
## (CustomCursor._ready → register()). Код проверяет действия, а не клавиши:
##   if event.is_action_pressed(GameInput.BACK): close()

const BACK := &"back"  # закрыть окно / шаг назад: Esc, ○/B
const PAUSE := &"pause"  # меню паузы: Esc, Options/Menu
const HAND := &"hand"  # веер руки: Tab, △/Y
const CHAT := &"chat"  # чат: C, Share/View
const PAGE_PREV := &"page_prev"  # листать влево (секции веера и т.п.): ←, L1/LB
const PAGE_NEXT := &"page_next"  # листать вправо: →, R1/RB

const STICK_DEADZONE: float = 0.5

# action → [клавиши, кнопки геймпада]. Порядок — порядок показа подсказок.
const _ACTIONS := {
	BACK: [[KEY_ESCAPE], [JOY_BUTTON_B]],
	PAUSE: [[KEY_ESCAPE], [JOY_BUTTON_START]],
	HAND: [[KEY_TAB], [JOY_BUTTON_Y]],
	CHAT: [[KEY_C], [JOY_BUTTON_BACK]],
	PAGE_PREV: [[KEY_LEFT], [JOY_BUTTON_LEFT_SHOULDER]],
	PAGE_NEXT: [[KEY_RIGHT], [JOY_BUTTON_RIGHT_SHOULDER]],
}

# Встроенные ui_* (навигация фокусом): кнопки. Левый стик к ui_* НЕ привязан —
# его в шаги переводит InputDevice (сырая ось листала бы на каждое микродвижение).
const _UI_BUTTONS := {
	&"ui_accept": JOY_BUTTON_A,
	&"ui_cancel": JOY_BUTTON_B,
	&"ui_up": JOY_BUTTON_DPAD_UP,
	&"ui_down": JOY_BUTTON_DPAD_DOWN,
	&"ui_left": JOY_BUTTON_DPAD_LEFT,
	&"ui_right": JOY_BUTTON_DPAD_RIGHT,
}


## Зарегистрировать действия игры и догрузить геймпад во встроенные ui_*.
## Идемпотентно: повторный вызов не плодит события.
static func register() -> void:
	for action: StringName in _ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, STICK_DEADZONE)
		var keys: Array = _ACTIONS[action][0]
		var buttons: Array = _ACTIONS[action][1]
		for k: int in keys:
			_add(action, _key(k))
		for b: int in buttons:
			_add(action, _button(b))
	for action: StringName in _UI_BUTTONS:
		_add(action, _button(int(_UI_BUTTONS[action])))
	# Оси левого стика из встроенных ui_* (в Godot они там по умолчанию) снимаем.
	for action: StringName in _UI_BUTTONS:
		for ev: InputEvent in InputMap.action_get_events(action):
			if ev is InputEventJoypadMotion:
				InputMap.action_erase_event(action, ev)


## Кнопка геймпада, назначенная действию (первая), или -1.
static func pad_button(action: StringName) -> int:
	if not InputMap.has_action(action):
		return -1
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton:
			return (ev as InputEventJoypadButton).button_index
	return -1


## Клавиша, назначенная действию (первая), или KEY_NONE.
static func key(action: StringName) -> Key:
	if not InputMap.has_action(action):
		return KEY_NONE
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventKey:
			return (ev as InputEventKey).keycode
	return KEY_NONE


static func _add(action: StringName, ev: InputEvent) -> void:
	if InputMap.has_action(action) and not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)


static func _key(k: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = k as Key
	return ev


static func _button(b: int) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.device = -1  # любой геймпад
	ev.button_index = b as JoyButton
	return ev
