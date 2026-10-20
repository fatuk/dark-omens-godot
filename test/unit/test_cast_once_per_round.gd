## Каст заклинания — действие этой карты: разные заклинания за ход можно, одно и то же —
## раз в раунд (раньше «Пищу для разума» читали дважды за раунд).
extends GutTest

var _nm: Node
var _was_host: bool


func before_each() -> void:
	_nm = get_node("/root/NetworkManager")
	_was_host = bool(_nm.get("_is_host_flag"))
	_nm.set("_is_host_flag", true)
	GameState.reset_session()
	GameState.players = {"a": GameState._make_player_dict("a", "A", "Frank Dalton", "5", 5, 5)}
	GameState.players["a"]["items"] = [
		{"id": "feed_the_mind", "kind": "spell"},
		{"id": "shriveling", "kind": "spell"},
	]
	GameState.players["a"]["actions_left"] = 3
	GameState.turn_order = ["a"]
	GameState.current_idx = 0
	GameState.phase = Phases.ACTION
	GameState.active = true


func after_each() -> void:
	GameState.reset_session()
	_nm.set("_is_host_flag", _was_host)


# Каст завершён (как после «Применить»): снять каст и проверку, вернуть ход.
func _finish_cast() -> void:
	GameState.players["a"]["casting"] = false
	GameState.casting_spell = {}
	GameState.active_check = {}


func test_same_spell_only_once_per_round() -> void:
	var cast := {"item": 0}
	assert_true(
		GameState._phase.host_apply_action("a", GameActions.CAST_SPELL, cast), "первый каст"
	)
	assert_true(
		(GameState.players["a"]["actions_used"] as Array).has("cast_spell:feed_the_mind"),
		"каст отмечен по id заклинания"
	)
	_finish_cast()
	var left: int = int(GameState.players["a"]["actions_left"])
	assert_false(
		GameState._phase.host_apply_action("a", GameActions.CAST_SPELL, cast),
		"то же заклинание второй раз за раунд — нельзя"
	)
	assert_eq(int(GameState.players["a"]["actions_left"]), left, "действие не потрачено")


func test_other_spell_same_round_allowed() -> void:
	assert_true(GameState._phase.host_apply_action("a", GameActions.CAST_SPELL, {"item": 0}))
	_finish_cast()
	assert_true(
		GameState._phase.host_apply_action("a", GameActions.CAST_SPELL, {"item": 1}),
		"другое заклинание в том же раунде — можно"
	)
