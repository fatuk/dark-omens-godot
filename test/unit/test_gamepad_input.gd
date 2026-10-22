extends GutTest

## Геймпад: действия InputMap (GameInput), род контроллера (InputDevice), подписи
## иконок (InputGlyph), выбор фокуса в модалке (PadFocus) и верхняя модалка (UIStyle).


func test_register_binds_keys_and_pad_buttons() -> void:
	GameInput.register()
	assert_true(InputMap.has_action(GameInput.HAND))
	assert_eq(GameInput.key(GameInput.HAND), KEY_TAB)
	assert_eq(GameInput.pad_button(GameInput.HAND), JOY_BUTTON_Y)
	assert_eq(GameInput.pad_button(GameInput.BACK), JOY_BUTTON_B)
	assert_eq(GameInput.pad_button(GameInput.PAUSE), JOY_BUTTON_START)
	assert_eq(GameInput.pad_button(&"ui_accept"), JOY_BUTTON_A)


func test_register_is_idempotent() -> void:
	GameInput.register()
	var n: int = InputMap.action_get_events(GameInput.BACK).size()
	var m: int = InputMap.action_get_events(&"ui_left").size()
	GameInput.register()
	assert_eq(InputMap.action_get_events(GameInput.BACK).size(), n)
	assert_eq(InputMap.action_get_events(&"ui_left").size(), m)


func test_left_stick_moves_ui_focus() -> void:
	GameInput.register()
	var ev := InputEventJoypadMotion.new()
	ev.axis = JOY_AXIS_LEFT_X
	ev.axis_value = -0.9
	assert_true(ev.is_action(&"ui_left"), "стик влево — ui_left")
	ev.axis_value = 0.2
	assert_false(ev.is_action_pressed(&"ui_left"), "в мёртвой зоне — нет")


func test_family_by_vendor_and_name() -> void:
	assert_eq(InputDevice.family_for("", 1356), InputDevice.PLAYSTATION)
	assert_eq(InputDevice.family_for("", 1118), InputDevice.XBOX)
	assert_eq(InputDevice.family_for("", 1406), InputDevice.NINTENDO)
	assert_eq(InputDevice.family_for("PS5 Controller"), InputDevice.PLAYSTATION)
	assert_eq(InputDevice.family_for("DualSense Wireless Controller"), InputDevice.PLAYSTATION)
	assert_eq(InputDevice.family_for("Nintendo Switch Pro Controller"), InputDevice.NINTENDO)
	assert_eq(InputDevice.family_for("Xbox Series X Controller"), InputDevice.XBOX)
	assert_eq(
		InputDevice.family_for("Steam Virtual Gamepad"), InputDevice.XBOX, "прочие — как Xbox"
	)


func test_face_symbols_follow_button_position() -> void:
	# Нижняя кнопка (JOY_BUTTON_A): ✕ / A / B — по роду.
	assert_eq(InputGlyph.face_symbol(InputDevice.PLAYSTATION, JOY_BUTTON_A), "cross")
	assert_eq(InputGlyph.face_symbol(InputDevice.XBOX, JOY_BUTTON_A), "A")
	assert_eq(InputGlyph.face_symbol(InputDevice.NINTENDO, JOY_BUTTON_A), "B")
	assert_eq(InputGlyph.face_symbol(InputDevice.PLAYSTATION, JOY_BUTTON_Y), "triangle")
	assert_eq(InputGlyph.face_symbol(InputDevice.NINTENDO, JOY_BUTTON_Y), "X")


func test_pill_labels_per_family() -> void:
	assert_eq(InputGlyph.pill_label(InputDevice.PLAYSTATION, JOY_BUTTON_LEFT_SHOULDER), "L1")
	assert_eq(InputGlyph.pill_label(InputDevice.XBOX, JOY_BUTTON_RIGHT_SHOULDER), "RB")
	assert_eq(InputGlyph.pill_label(InputDevice.NINTENDO, JOY_BUTTON_START), "+")
	assert_eq(InputGlyph.key_label(KEY_ESCAPE), "Esc")


func test_pick_prefers_same_text_then_default_then_first_enabled() -> void:
	var root: Control = autofree(Control.new())
	root.name = "Modal"
	add_child(root)
	var close := _btn(root, "×")
	close.set_meta(PadFocus.SKIP, true)
	var off := _btn(root, "Off")
	off.disabled = true
	var roll := _btn(root, "Roll")
	var apply := _btn(root, "Apply")
	assert_eq(PadFocus.pick(root), roll, "первая доступная, не крестик и не disabled")
	apply.set_meta(PadFocus.DEFAULT, true)
	assert_eq(PadFocus.pick(root), apply, "кнопка по умолчанию")
	assert_eq(PadFocus.pick(root, "Roll"), roll, "пересобранная с тем же текстом")
	assert_eq(PadFocus.pick(root, "Off"), apply, "disabled не берём даже по тексту")


func test_top_modal_is_highest_canvas_layer() -> void:
	var low := CanvasLayer.new()
	low.name = "LowLayer"
	low.layer = 80
	var high := CanvasLayer.new()
	high.name = "HighLayer"
	high.layer = 95
	add_child_autofree(low)
	add_child_autofree(high)
	var a := Control.new()
	a.name = "LowModal"
	var b := Control.new()
	b.name = "HighModal"
	high.add_child(b)
	low.add_child(a)
	UIStyle.mark_modal(b, true)
	UIStyle.mark_modal(a, true)  # открыта позже, но слой ниже
	assert_eq(UIStyle.top_modal(), b)
	b.visible = false
	assert_eq(UIStyle.top_modal(), a, "скрытая не считается")
	UIStyle.mark_modal(a, false)
	UIStyle.mark_modal(b, false)


func _btn(parent: Control, text: String) -> Button:
	var b := Button.new()
	b.name = "Btn_%s" % text
	b.text = text
	parent.add_child(b)
	return b
