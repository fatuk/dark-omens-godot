## GuideDirector: подсказки Армитеджа по событиям игры, по одной за раз, каждая —
## один раз; «free» ждёт свободного экрана, «over» — сразу поверх окна. Настоящий
## GameState; persist=false — профиль (user://) тестами не трогаем.
extends GutTest

const ME := "me"
const LOC := "5"

var _saved_uid: String
var _saved_enabled: bool
var _d: GuideDirector


func before_each() -> void:
	_saved_uid = NetworkManager.my_user_id
	_saved_enabled = SettingsStore.guide_hints
	NetworkManager.my_user_id = ME
	SettingsStore.guide_hints = true
	GameState.reset_session()
	GameState.players = {ME: GameState._make_player_dict(ME, "Me", "Frank Dalton", LOC, 8, 4)}
	GameState.turn_order = [ME]
	GameState.current_idx = 0
	GameState.phase = Phases.ACTION
	GameState.active = true
	_d = GuideDirector.new()
	_d.name = "GuideDirector"
	_d.persist = false
	add_child_autofree(_d)


func after_each() -> void:
	GameState.reset_session()
	NetworkManager.my_user_id = _saved_uid
	SettingsStore.guide_hints = _saved_enabled


func _queue() -> Array:
	return _d.get("_queue")


func _hint_shown() -> GuideHint:
	return _d.find_child("GuideHint", false, false) as GuideHint


func test_data_triggers_are_known() -> void:
	# Опечатка в "on" — подсказка молча никогда бы не показалась.
	var known: Array = [
		"actionPhase",
		"monsterHere",
		"lowVitality",
		"encounter",
		"combat",
		"shop",
		"mythos",
		"reckoning",
	]
	for h_v: Variant in DataLoader.load_dict(GuideDirector.DATA_PATH).get("hints", []):
		var h: Dictionary = h_v
		assert_has(known, String(h.get("on", "")), "событие подсказки %s" % h.get("id"))
		assert_false((h.get("lines", []) as Array).is_empty(), "у %s есть реплики" % h.get("id"))


func test_my_action_turn_queues_welcome_first() -> void:
	GameState.monsters = {LOC: [{"id": "deep_one", "health": 2}]}
	_d.call("_refresh")
	assert_eq(_queue(), ["welcome", "monster_here"], "по приоритету: сначала приветствие")


func test_free_hint_waits_then_shows_once() -> void:
	_d.call("_refresh")
	_d._process(0.1)
	assert_null(_hint_shown(), "экран ещё не «устоялся»")
	_d._process(1.0)
	assert_not_null(_hint_shown(), "приветствие показано")
	assert_has(_d.get("_seen"), "welcome")
	_hint_shown().queue_free()
	await wait_process_frames(2)
	_d.call("_refresh")
	assert_does_not_have(_queue(), "welcome", "второй раз не показываем")


func test_lapsed_event_is_dropped() -> void:
	_d.call("_refresh")
	GameState.players[ME]["actions_left"] = 0  # ход кончился, пока подсказка ждала
	_d._process(1.0)
	assert_null(_hint_shown())
	assert_does_not_have(_queue(), "welcome")
	assert_does_not_have(_d.get("_seen"), "welcome", "не показана — не помечаем")


func test_disabled_in_settings_shows_nothing() -> void:
	SettingsStore.guide_hints = false
	_d.call("_refresh")
	_d._process(1.0)
	assert_eq(_queue(), [])
	assert_null(_hint_shown())


func test_encounter_hint_shows_over_modals_at_once() -> void:
	GameState.phase = Phases.ENCOUNTER
	GameState.current_encounter = {"kind": "general", "name": "x"}
	assert_true(_d.trigger_active("encounter"))
	assert_false(_d.trigger_active("actionPhase"), "фаза действий кончилась")
	_d.call("_refresh")
	_d._process(0.0)
	var g: GuideHint = _hint_shown()
	assert_not_null(g, "про открытое окно — сразу, без ожидания")
	assert_eq(g.layer, 89, "поверх модалок")


func test_shadow_gets_no_hints() -> void:
	GameState.players[ME][PlayerKeys.DEAD] = true
	assert_false(_d.trigger_active("actionPhase"))
	assert_false(_d.trigger_active("lowVitality"))
