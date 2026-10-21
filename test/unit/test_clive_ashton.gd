## Клайв Эштон (Астроном): действие «потратьте 2 улики — сбросьте монстра с клетки с
## вратами» и пассив «раз в раунд 1 рассудок вместо 1 улики».
extends GutTest

var _nm: Node
var _was_host: bool


func before_each() -> void:
	_nm = get_node("/root/NetworkManager")
	_was_host = bool(_nm.get("_is_host_flag"))
	_nm.set("_is_host_flag", true)
	GameState.reset_session()
	GameState.players = {"a": GameState._make_player_dict("a", "A", "Clive Ashton", "5", 5, 7)}
	GameState.players["a"]["actions_left"] = 2
	GameState.players["a"]["clues"] = 2
	GameState.turn_order = ["a"]
	GameState.current_idx = 0
	GameState.phase = Phases.ACTION
	GameState.active = true
	GameState.gates = {"Rome": {}}
	GameState.monsters = {"Rome": [{"id": "cultist", "health": 1}], "Tokyo": [{"id": "cultist"}]}


func after_each() -> void:
	GameState.reset_session()
	_nm.set("_is_host_flag", _was_host)


func _ability(payload: Dictionary) -> bool:
	return GameState._phase.host_apply_action("a", GameActions.INVESTIGATOR_ABILITY, payload)


func test_only_monsters_at_gates_offered() -> void:
	var refs: Array = []
	for o_v: Variant in GameState.monsters_at_gates():
		refs.append(String((o_v as Dictionary).get("ref", "")))
	assert_eq(refs, ["Rome#0"], "Токио без врат — не цель")


func test_discard_monster_at_gate_for_two_clues() -> void:
	assert_true(_ability({"monster": "Rome#0"}))
	assert_false(GameState.monsters.has("Rome"), "монстр у врат сброшен")
	assert_eq(int(GameState.players["a"]["clues"]), 0, "2 улики потрачены")


func test_monster_without_gate_rejected() -> void:
	assert_false(_ability({"monster": "Tokyo#0"}))
	assert_eq(int(GameState.players["a"]["clues"]), 2, "ничего не потрачено")
	assert_eq(int(GameState.players["a"]["actions_left"]), 2, "действие не потрачено")


func test_one_clue_plus_sanity() -> void:
	GameState.players["a"]["clues"] = 1
	assert_true(_ability({"monster": "Rome#0"}), "1 улика + 1 рассудок")
	assert_eq(int(GameState.players["a"]["clues"]), 0)
	assert_eq(int(GameState.players["a"]["sanity"]), 6, "рассудок вместо улики")
	assert_true(bool(GameState.players["a"].get(PlayerKeys.RESOURCE_SWAP_USED, false)))


func test_pay_sanity_by_choice() -> void:
	assert_true(
		_ability({"monster": "Rome#0", "sanity": true}), "улик хватает, но платим рассудком"
	)
	assert_eq(int(GameState.players["a"]["clues"]), 1, "сэкономлена улика")
	assert_eq(int(GameState.players["a"]["sanity"]), 6)


func test_swap_once_per_round() -> void:
	var p: Dictionary = GameState.players["a"]
	p["clues"] = 0
	assert_true(ResourceLedger.can_pay(p, "clue", 1), "рассудок вместо улики")
	ResourceLedger.spend(p, "clue", 1)
	assert_eq(int(p["sanity"]), 6)
	assert_false(ResourceLedger.can_pay(p, "clue", 1), "второй раз за раунд — нет")
	GameState._phase.start_new_round()
	assert_true(ResourceLedger.can_pay(p, "clue", 1), "новый раунд — снова можно")


func test_swap_never_lethal() -> void:
	var p: Dictionary = GameState.players["a"]
	p["clues"] = 0
	p["sanity"] = 1
	assert_false(ResourceLedger.can_pay(p, "clue", 1), "последний рассудок не отдаём")


func test_others_cannot_swap() -> void:
	var p: Dictionary = GameState._make_player_dict("b", "B", "Frank Dalton", "5", 5, 5)
	assert_false(ResourceLedger.can_pay(p, "clue", 1), "пассив только у Клайва")


# Брошенная проверка Клайва с двумя провальными кубами, улик нет.
func _failed_check() -> void:
	GameState.players["a"]["clues"] = 0
	GameState._check.start("encounter", "a", "lore", 0, "generalEncounter")
	GameState._check.roll("a")
	var c: Dictionary = GameState.active_check
	c["base"] = [1, 1]
	c["dice"] = [1, 1]


func test_reroll_paid_with_sanity() -> void:
	_failed_check()
	assert_true(GameState._check.reroll("a", 0, "sanityForClue"), "жетон «рассудок вместо улики»")
	assert_eq(int(GameState.players["a"]["sanity"]), 6, "−1 рассудок")
	assert_false(GameState._check.reroll("a", 1, "sanityForClue"), "второй раз за раунд — нельзя")


func test_auto_reroll_never_spends_sanity() -> void:
	_failed_check()
	assert_false(GameState._check.reroll("a", 0, ""), "без жетона рассудок не трогаем")
	assert_eq(int(GameState.players["a"]["sanity"]), 7)
