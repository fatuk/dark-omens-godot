extends GutTest

## Рефлексивный синк (_SYNC_FIELDS): _apply_snapshot полагается на то, что Object.set()
## коэрсит значение под ТИП поля. По сети JSON-числа приходят как float — int-поля
## должны остаться int. Тест защищает это допущение (иначе синк молча испортит типы).

var _saved: Dictionary = {}


func before_each() -> void:
	_saved = {"round_num": GameState.round_num, "doom": GameState.doom, "phase": GameState.phase}


func after_each() -> void:
	GameState.round_num = int(_saved["round_num"])
	GameState.doom = int(_saved["doom"])
	GameState.phase = String(_saved["phase"])


func test_set_coerces_json_float_to_int_field() -> void:
	GameState.set("round_num", 7.0)  # как приходит из распарсенного JSON по сети
	assert_eq(typeof(GameState.round_num), TYPE_INT, "int-поле остаётся int после set(float)")
	assert_eq(GameState.round_num, 7, "значение коэрснуто корректно")
	GameState.set("doom", 3.0)
	assert_eq(GameState.doom, 3)


func test_set_string_field() -> void:
	GameState.set("phase", "mythos")
	assert_eq(GameState.phase, "mythos")


# reset_session (выход из комнаты) чистит рудимент прошлой партии — иначе сыщик
# из неё светится «занято» в новом лобби (см. lobby._mark_ingame_taken).
func test_reset_session_clears_leftover_game_state() -> void:
	var saved_players: Dictionary = GameState.players.duplicate(true)
	var saved_campaign: Dictionary = GameState.campaign.duplicate(true)
	var saved_order: Array = GameState.turn_order.duplicate(true)
	GameState.players = {"u1": {"investigator": "Ezra Gilman", "name": "Эзра"}}
	GameState.turn_order = ["u1"]
	GameState.campaign = {"id": "c1", "mysteries": [{}]}
	GameState.doom = 5
	GameState.reset_session()
	assert_true(GameState.players.is_empty(), "players очищены")
	assert_true(GameState.turn_order.is_empty(), "turn_order очищен")
	assert_true(GameState.campaign.is_empty(), "campaign очищен")
	assert_eq(GameState.doom, 0, "doom сброшен")
	GameState.players = saved_players
	GameState.turn_order = saved_order
	GameState.campaign = saved_campaign
