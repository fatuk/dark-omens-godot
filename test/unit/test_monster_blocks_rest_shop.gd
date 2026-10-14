## Монстр на клетке: отдых (лечение) и магазин недоступны — как в EH. Хост отклоняет
## REST / ACQUIRE_ASSETS, не тратя действие; без монстра отдых лечит как раньше.
## Настоящий GameState (хост), город "5" из data/locations.json.
extends GutTest

const CITY := "5"

var _nm: Node
var _was_host: bool


func before_each() -> void:
	_nm = get_node("/root/NetworkManager")
	_was_host = bool(_nm.get("_is_host_flag"))
	_nm.set("_is_host_flag", true)  # host_apply_action — только хост
	GameState.reset_session()
	GameState.players = {"a": GameState._make_player_dict("a", "A", "Frank Dalton", CITY, 5, 5)}
	GameState.players["a"]["hp"] = 3
	GameState.players["a"]["sanity"] = 3
	GameState.turn_order = ["a"]
	GameState.current_idx = 0
	GameState.phase = Phases.ACTION
	GameState.active = true


func after_each() -> void:
	GameState.reset_session()
	_nm.set("_is_host_flag", _was_host)


func _me() -> Dictionary:
	return GameState.players["a"]


func test_has_monster_at() -> void:
	assert_false(GameState.has_monster_at(CITY), "пусто")
	GameState.monsters = {CITY: [{"id": "cultist", "health": 1}]}
	assert_true(GameState.has_monster_at(CITY), "культист в городе")
	assert_false(GameState.has_monster_at("1"), "соседний город свободен")


func test_rest_rejected_with_monster() -> void:
	GameState.monsters = {CITY: [{"id": "cultist", "health": 1}]}
	var left: int = int(_me()["actions_left"])
	assert_false(GameState._phase.host_apply_action("a", GameActions.REST), "отдых отклонён")
	assert_eq(int(_me()["hp"]), 3, "здоровье не восстановлено")
	assert_eq(int(_me()["sanity"]), 3, "рассудок не восстановлен")
	assert_eq(int(_me()["actions_left"]), left, "действие не потрачено")
	assert_does_not_have(_me()["actions_used"], GameActions.REST, "отдых не засчитан")


func test_rest_heals_without_monster() -> void:
	assert_true(GameState._phase.host_apply_action("a", GameActions.REST), "отдых принят")
	assert_eq(int(_me()["hp"]), 4, "+1 здоровье")
	assert_eq(int(_me()["sanity"]), 4, "+1 рассудок")


func test_shop_rejected_with_monster() -> void:
	GameState.monsters = {CITY: [{"id": "cultist", "health": 1}]}
	var left: int = int(_me()["actions_left"])
	assert_false(
		GameState._phase.host_apply_action("a", GameActions.ACQUIRE_ASSETS), "магазин закрыт"
	)
	assert_eq(int(_me()["actions_left"]), left, "действие не потрачено")
	assert_false(bool(_me().get("shopping", false)), "в магазин не вошёл")
