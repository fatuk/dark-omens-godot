## MapPickPrompt: выбор «куда переместиться» (Чартерный рейс) — кликом по карте.
## Включается только для МОЕГО решения kind:destination и только пока карту не
## заслоняют другие окна (иначе по ней не кликнуть — остаётся список в модалке).
extends GutTest

var _saved_uid: String
var _prompt: MapPickPrompt


func before_each() -> void:
	_saved_uid = NetworkManager.my_user_id
	NetworkManager.my_user_id = "me"
	GameState.reset_session()
	GameState.players = {"me": {"user_id": "me"}, "other": {"user_id": "other"}}
	_prompt = MapPickPrompt.new()
	_prompt.name = "MapPickPrompt"
	add_child_autofree(_prompt)


func after_each() -> void:
	GameState.reset_session()
	NetworkManager.my_user_id = _saved_uid


func _decision(pid: String, kind: String = "destination") -> Dictionary:
	return {
		"active": true,
		"pid": pid,
		"driver": "asset",
		"kind": kind,
		"path": "0",
		"title_key": "ASSET_CHARTER_FLIGHT_NAME",
		"options": [{"ref": "5", "name": "L5"}, {"ref": "7", "name": "L7"}],
	}


func test_my_destination_is_picked_on_map() -> void:
	GameState.mythos_decision = _decision("me")
	await wait_process_frames(2)
	var d: Dictionary = MapPickPrompt.decision()
	assert_false(d.is_empty(), "выбор на карте активен")
	assert_true(_prompt.is_shown(), "плашка-подсказка видна")
	assert_eq(MapPickPrompt.option_index(d, "7"), 1, "клик по «7» — второй вариант")
	assert_eq(MapPickPrompt.option_index(d, "9"), -1, "не цель")


func test_not_for_others_or_other_kinds() -> void:
	GameState.mythos_decision = _decision("other")
	await wait_process_frames(2)
	assert_true(MapPickPrompt.decision().is_empty(), "чужое решение — не моё")
	GameState.mythos_decision = _decision("me", "monster")
	await wait_process_frames(2)
	assert_true(MapPickPrompt.decision().is_empty(), "выбор монстра — список, не карта")
	assert_false(_prompt.is_shown())


func test_blocked_map_falls_back_to_list() -> void:
	# Другое окно заслоняет карту — по ней не кликнуть, выбор остаётся в модалке.
	var other := Control.new()
	other.name = "OtherModal"
	add_child_autofree(other)
	UIStyle.mark_modal(other, true)
	GameState.mythos_decision = _decision("me")
	await wait_process_frames(2)
	assert_true(MapPickPrompt.decision().is_empty(), "карта занята — не активен")
	UIStyle.mark_modal(other, false)
	await wait_process_frames(2)
	assert_false(MapPickPrompt.decision().is_empty(), "окно ушло — выбор на карте")
