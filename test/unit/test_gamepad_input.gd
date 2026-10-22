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


func test_raw_stick_not_bound_to_ui() -> void:
	GameInput.register()
	var ev := InputEventJoypadMotion.new()
	ev.axis = JOY_AXIS_LEFT_X
	ev.axis_value = -0.9
	assert_false(ev.is_action(&"ui_left"), "сырая ось не листает — шаги шлёт InputDevice")


func test_stick_hysteresis() -> void:
	assert_eq(InputDevice.stick_dir(0, -0.9), -1, "толчок влево")
	assert_eq(InputDevice.stick_dir(-1, -0.5), -1, "между порогами — держим")
	assert_eq(InputDevice.stick_dir(0, -0.5), 0, "между порогами — не включаем")
	assert_eq(InputDevice.stick_dir(-1, -0.1), 0, "отпустили")
	assert_eq(InputDevice.stick_dir(-1, 0.8), 1, "перекинули вправо")


func test_stick_push_is_one_step() -> void:
	var dev := InputDevice.new()
	dev.name = "TestDevice"
	add_child_autofree(dev)
	dev.stick(JOY_AXIS_LEFT_X, -0.9)
	Input.flush_buffered_events()  # синтезированное нажатие применяется на флаше
	assert_true(Input.is_action_pressed(&"ui_left"), "толчок — ui_left нажат")
	dev.stick(JOY_AXIS_LEFT_X, -0.95)
	dev.stick(JOY_AXIS_LEFT_X, -0.7)
	assert_eq(dev._held, &"ui_left", "дрожание в наклоне не шлёт новых шагов")
	dev.stick(JOY_AXIS_LEFT_X, 0.0)
	Input.flush_buffered_events()
	assert_false(Input.is_action_pressed(&"ui_left"), "отпустили — отпущен")
	assert_eq(dev._held, &"", "автоповтор снят")


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


# ── Карта: шаг курсора по направлению ─────────────────────────────────────────


func test_pick_direction_prefers_aligned_and_wraps() -> void:
	var c := {"me": Vector2(500, 500), "east": Vector2(700, 520), "ne": Vector2(600, 380)}
	c["far_e"] = Vector2(1500, 500)
	assert_eq(MapLayer.pick_direction(c["me"], Vector2.RIGHT, c, 2000.0, "me"), "east")
	assert_eq(MapLayer.pick_direction(c["me"], Vector2.UP, c, 2000.0, "me"), "ne")
	assert_eq(MapLayer.pick_direction(c["me"], Vector2.DOWN, c, 2000.0, "me"), "", "вниз — пусто")
	# Через шов: от x=1900 вправо ближайшая — x=100 (копия справа).
	var w := {"edge": Vector2(1900, 500), "wrap": Vector2(100, 500), "back": Vector2(1500, 500)}
	assert_eq(MapLayer.pick_direction(w["edge"], Vector2.RIGHT, w, 2000.0, "edge"), "wrap")


# ── ○/B: чем закрыть модалку ──────────────────────────────────────────────────


func test_find_dismiss_close_meta_then_text() -> void:
	var root: Control = autofree(Control.new())
	root.name = "Modal"
	add_child(root)
	var roll := _btn(root, "CAST_ROLL")
	var ok := _btn(root, "GAINS_OK")
	assert_eq(PadFocus.find_dismiss(root), ok, "кнопка «ок» — закрывает")
	var x := _btn(root, "")
	x.set_meta(PadFocus.CLOSE, true)
	assert_eq(PadFocus.find_dismiss(root), x, "крестик — первым")
	x.visible = false
	ok.disabled = true
	assert_null(PadFocus.find_dismiss(root), "решающие кнопки (бросок) «назад» не жмёт")
	assert_not_null(roll)


# ── Правый стик: прокрутка ────────────────────────────────────────────────────


func test_scroll_by_moves_scroll_container_until_edge() -> void:
	var sc := ScrollContainer.new()
	sc.name = "Scroll"
	sc.size = Vector2(200, 100)
	add_child_autofree(sc)
	var tall := Control.new()
	tall.name = "Tall"
	tall.custom_minimum_size = Vector2(180, 400)
	sc.add_child(tall)
	await wait_physics_frames(2)
	assert_true(PadFocus.scroll_by(sc, 50.0), "есть куда крутить")
	assert_eq(sc.scroll_vertical, 50)
	assert_true(PadFocus.scroll_by(sc, -500.0), "назад к верху")
	assert_eq(sc.scroll_vertical, 0)
	assert_false(PadFocus.scroll_by(sc, -10.0), "у верха — стоп")


func test_scroll_targets_priority() -> void:
	var scope: Control = autofree(Control.new())
	scope.name = "Modal"
	add_child(scope)
	var sc := ScrollContainer.new()
	sc.name = "Scroll"
	scope.add_child(sc)
	var foc := Button.new()
	foc.name = "Focused"
	scope.add_child(foc)
	var card: Control = autofree(Control.new())
	card.name = "LinkedCard"
	foc.set_meta(PadFocus.SCROLL_CARD, card)
	var fan: Control = autofree(Control.new())
	fan.name = "FanCard"
	var t: Array = PadFocus.scroll_targets(scope, foc, fan)
	assert_eq(t[0], fan, "веер — первым")
	assert_eq(t[1], card, "затем карта контрола в фокусе")
	assert_true(t.has(sc), "и прокрутки окна")
