## Демо «Братство Колоса»: стадия 1 колоды Мифов на настоящих GameState / MythosFlow /
## ReckoningFlow и запечённой офлайн-библии (data/offline/demo). Сторожит сценарий:
## старт без врат → «Круг» (синие врата на поле + культист) → «Скот встал» (Расплата:
## культист у каждых врат, культисты Рок не двигают) → «Письмо» (омен на синий —
## совпали синие врата, Рок +1; улика самому влиятельному).
extends GutTest

const ANCIENT := "brotherhood_of_the_sheaf"

var _nm: Node
var _was_host: bool


func before_each() -> void:
	OfflineContent.reset()
	_nm = get_node("/root/NetworkManager")
	_was_host = bool(_nm.get("_is_host_flag"))
	_nm.set("_is_host_flag", true)  # мутации поля — только хост
	GameState.reset_session()


func after_each() -> void:
	GameState.reset_session()
	_nm.set("_is_host_flag", _was_host)
	OfflineContent.reset()


func _start() -> Array:
	var res: Dictionary = OfflineContent.assemble(
		{"ancientOne": ANCIENT, "playerCount": 2, "language": "Russian"}
	)
	assert_true(res["ok"], "демо-библия запечена")
	var bible: Dictionary = res["campaign"]
	GameState.campaign = GameState._campaign._summary(bible, ANCIENT)
	GameState._mythos.deck = bible["mythosDeck"]
	GameState.players = {
		"a": GameState._make_player_dict("a", "A", "Frank Dalton", "Rome", 5, 5),
		"b": GameState._make_player_dict("b", "B", "Vivienne Marchetti", "Rome", 5, 5),
	}
	GameState.turn_order = ["a", "b"]
	GameState.active = true
	GameState._board.setup_board(2)
	return bible["mythosDeck"]


func _cultists_at(loc: String) -> int:
	var n: int = 0
	for m: Dictionary in GameState.monsters.get(loc, []):
		if String(m.get("id", "")) == "cultist":
			n += 1
	return n


func _influence(inv: String) -> int:
	return int((Investigators.get_data(inv).get("skills", {}) as Dictionary).get("influence", 0))


func test_stage_one_plays_as_scripted() -> void:
	var deck: Array = _start()
	assert_eq(int(GameState.campaign.get("doomClock", 0)), 10, "Рок 10")
	var names: Array = []
	for i: int in range(3):
		names.append(String((deck[i] as Dictionary).get("name", "")))
	assert_eq(names, ["Круг", "Скот встал", "Письмо"], "стадия 1 — в фиксированном порядке")
	assert_true(GameState.gates.is_empty(), "старт без врат: первый круг откроет Миф")

	# 1. «Круг»: врата из закреплённого жетона — Средний Запад, синие; из них культист.
	await GameState._mythos._apply_effects((deck[0] as Dictionary).get("onDraw", []))
	assert_eq(GameState.gates.get("5", ""), "blue", "первые врата — синие, на поле")
	assert_eq(_cultists_at("5"), 1, "из врат вышел культист")
	assert_eq(GameState.doom, 0, "врата сами Рок не двигают")

	# 2. «Скот встал»: Расплата — культист у каждых врат (лист) и на поле (Тайна I);
	# культисты Рок не двигают. Сыщиков на поле нет — проверки Воли не будет.
	await GameState._mythos._apply_effects((deck[1] as Dictionary).get("onDraw", []))
	assert_eq(_cultists_at("5"), 3, "+1 у врат (лист) +1 на поле (Тайна I)")
	assert_eq(GameState.doom, 0, "Расплата культистов Рок не двигает")

	# 3. «Письмо»: омен зелёный → синий, совпали синие врата — Рок +1; улика
	# самому влиятельному сыщику.
	var lead_by_influence: String = (
		"a" if _influence("Frank Dalton") >= _influence("Vivienne Marchetti") else "b"
	)
	var other: String = "b" if lead_by_influence == "a" else "a"
	# Прирост, а не абсолют: у части сыщиков стартовая улика.
	var lead_before: int = int(GameState.players[lead_by_influence].get("clues", 0))
	var other_before: int = int(GameState.players[other].get("clues", 0))
	await GameState._mythos._apply_effects((deck[2] as Dictionary).get("onDraw", []))
	assert_eq(GameState._board.current_omen_color(), "blue")
	assert_eq(GameState.doom, 1, "омен совпал с синими вратами")
	assert_eq(
		int(GameState.players[lead_by_influence].get("clues", 0)) - lead_before,
		1,
		"улика влиятельному"
	)
	assert_eq(int(GameState.players[other].get("clues", 0)), other_before, "второму — нет")
