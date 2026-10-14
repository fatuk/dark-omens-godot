## Телеграмма наблюдателя (encounter_watch_modal): чужая встреча на бланке. Время
## отправки — «ЧЧ:ММ» читающего, код связи — «7Y-19-KA», после броска несбывшийся
## исход гаснет, крестик прячет до следующей встречи, часы переворачиваются.
extends GutTest

const _Modal := preload("res://scripts/ui/encounter_watch_modal.gd")

var _saved_uid: String
var _m: CanvasLayer


func before_each() -> void:
	_saved_uid = NetworkManager.my_user_id
	NetworkManager.my_user_id = "me"
	GameState.reset_session()
	GameState.players = {
		"me": {"user_id": "me", "investigator": "Ezra Gilman"},
		"other": {"user_id": "other", "investigator": "Frank Dalton"},
	}
	GameState.turn_order = ["other", "me"]
	GameState.current_idx = 0
	GameState.phase = Phases.ENCOUNTER
	GameState.active = true
	GameState.current_encounter = _card("Забытый зал")
	_m = _Modal.new()
	_m.name = "EncounterWatchModal"
	add_child_autofree(_m)


func after_each() -> void:
	GameState.reset_session()
	NetworkManager.my_user_id = _saved_uid


func _card(nm: String) -> Dictionary:
	return {
		"kind": "general",
		"name": nm,
		"mainText": "текст",
		"successText": "хорошо",
		"failureText": "плохо",
		"test": {"skill": "will", "modifier": 0},
	}


func _shown() -> bool:
	return (_m.find_child("WatchAnchor", false, false) as Control).visible


func test_comms_code_format() -> void:
	var re := RegEx.create_from_string("^[1-9][A-Z]-\\d{2}-[A-Z]{2}$")
	for _i in range(50):
		var code: String = _Modal.comms_code()
		assert_not_null(re.search(code), "формат 7Y-19-KA: %s" % code)


func test_dispatch_time_format() -> void:
	var re := RegEx.create_from_string("^\\d{2}:\\d{2}$")
	assert_not_null(re.search(_Modal.dispatch_time()), "ЧЧ:ММ")


func test_shows_other_investigator_under_title() -> void:
	assert_true(_shown(), "чужая встреча — телеграмма видна")
	var nm: Label = _m.find_child("Name", true, false)
	assert_eq(nm.text, tr(Investigators.display_name("Frank Dalton")).to_upper())


func test_not_shown_for_my_own_encounter() -> void:
	GameState.current_idx = 1
	_m.call("_refresh")
	await wait_seconds(0.3)
	assert_false(_shown(), "свою встречу показывает обычная модалка")


func test_outcome_hidden_until_rolled_then_only_the_rolled_one() -> void:
	var block: Control = _m.find_child("Outcome", true, false)
	assert_false(block.visible, "до броска исходы не раскрываем")
	GameState.active_check = {"owner": "encounter", "rolled": true, "passed": false}
	_m.call("_refresh")
	assert_true(block.visible, "бросок сыгран — исход виден")
	var rt: RichTextLabel = block.find_child("Text", true, false)
	assert_string_contains(rt.text, "плохо", "выпал провал — текст провала")
	assert_false(rt.text.contains("хорошо"), "текст успеха не показываем")


func test_time_and_code_are_bold() -> void:
	for n: String in ["DispatchTime", "CommsCode"]:
		var l: Label = _m.find_child(n, true, false)
		var f: FontVariation = l.get_theme_font("font") as FontVariation
		assert_not_null(f, "%s — своё начертание" % n)
		assert_gt(f.variation_embolden, 0.0, "%s — жирным" % n)


func test_close_hides_until_next_encounter() -> void:
	(_m.find_child("Close", true, false) as Button).pressed.emit()
	await wait_seconds(0.3)
	assert_false(_shown(), "закрыли крестиком")
	GameState.active_check = {"owner": "encounter", "rolled": true, "passed": true}
	_m.call("_refresh")
	assert_false(_shown(), "та же встреча — не всплывает снова")
	GameState.current_encounter = _card("Другая встреча")
	_m.call("_refresh")
	assert_true(_shown(), "новая встреча — новая телеграмма")


func test_sand_clock_flips_half_turn() -> void:
	var clock: Control = _m.find_child("SandClock", true, false)
	await wait_seconds(2.0)  # пауза 1.2 + переворот 0.6
	assert_almost_eq(fposmod(clock.rotation, TAU), PI, 0.2, "перевернулись на 180°")


func test_height_follows_content() -> void:
	await wait_process_frames(2)
	var sheet: Control = _m.find_child("Sheet", true, false)
	var before: float = sheet.size.y
	assert_lt(before, 2048.0, "короткая встреча — бланк ниже нарисованного")
	GameState.active_check = {"owner": "encounter", "rolled": true, "passed": true}
	_m.call("_refresh")
	await wait_seconds(1.0)
	assert_gt(sheet.size.y, before, "появился исход — бланк вырос")


func test_outcome_reveal_is_animated() -> void:
	await wait_process_frames(2)
	GameState.active_check = {"owner": "encounter", "rolled": true, "passed": false}
	_m.call("_refresh")
	await wait_process_frames(2)
	var block: Control = _m.find_child("Outcome", true, false)
	assert_true(block.visible)
	assert_lt(block.modulate.a, 1.0, "исход проявляется, а не выскакивает")
	await wait_seconds(1.0)
	assert_eq(block.modulate.a, 1.0, "проявился полностью")


func test_sheet_height_clamps() -> void:
	assert_eq(_Modal.sheet_height(5000.0), 2048.0, "не выше нарисованного")
	assert_eq(_Modal.sheet_height(0.0), float(480 + 588), "не ниже шапки и низа")
