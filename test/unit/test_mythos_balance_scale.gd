## Символы карт Мифов «врата» и «улики на поле» со scale:"balance" масштабируются
## числом сыщиков по карточке баланса (BoardState.REFERENCE), как в оригинале:
## врат 1 (1–4) / 2 (5–8), улик 1/2/2/3/3/3/4/4. Настоящий GameState (хост) —
## сторожит, что scale доходит от карты Мифа до поля, а не теряется в EffectRunner.
extends GutTest

var _nm: Node
var _was_host: bool


func before_each() -> void:
	_nm = get_node("/root/NetworkManager")
	_was_host = bool(_nm.get("_is_host_flag"))
	_nm.set("_is_host_flag", true)  # мутации поля — только хост
	GameState.reset_session()


func after_each() -> void:
	GameState._campaign._room_player_count = 0
	GameState.reset_session()
	_nm.set("_is_host_flag", _was_host)


func _setup(players: int) -> void:
	GameState._campaign._room_player_count = players
	GameState._board.setup_board(players)


func _clues_on_board() -> int:
	var n: int = 0
	for loc_v: Variant in GameState.entities:
		n += (GameState.entities[loc_v] as Array).count("clue")
	return n


func test_gates_scale_with_player_count() -> void:
	_setup(5)
	var before: int = GameState.gates.size()
	await GameState._mythos._apply_effects([{"do": "openGate", "scale": "balance"}])
	assert_eq(GameState.gates.size() - before, 2, "5 сыщиков — двое врат")


func test_gates_one_for_small_table() -> void:
	_setup(2)
	var before: int = GameState.gates.size()
	await GameState._mythos._apply_effects([{"do": "openGate", "scale": "balance"}])
	assert_eq(GameState.gates.size() - before, 1, "2 сыщика — одни врата")


func test_clues_scale_with_player_count() -> void:
	_setup(5)
	var before: int = _clues_on_board()
	await GameState._mythos._apply_effects([{"do": "placeClue", "scale": "balance"}])
	assert_eq(_clues_on_board() - before, 3, "5 сыщиков — три улики")
