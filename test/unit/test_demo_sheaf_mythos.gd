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


func _tokens_at(loc: String) -> int:
	return (GameState.entities.get(loc, []) as Array).count("eldritch_token")


func test_first_sheaf_tokens_and_special_encounters() -> void:
	_start()
	# Стартовые улики раскладываются случайно и могут лечь и на «5» — сверяем, что
	# ТАЙНА добавляет жетоны, а не улики (раньше тест падал от неудачной раскладки).
	var clues_before: int = (GameState.entities.get("5", []) as Array).count("clue")
	GameState._mystery.apply_mystery_on_enter()
	assert_eq(_tokens_at("5"), 3, "три жетона Знамения на поле, улик нет")
	assert_eq(
		(GameState.entities.get("5", []) as Array).count("clue"),
		clues_before,
		"Тайна улик не кладёт"
	)
	GameState.players["a"]["location"] = "5"
	assert_true(GameState._encounter._compute_choices("a").has("eldritch"), "у знака — встреча")
	var hook: Dictionary = GameState._mystery.mystery_encounter_hook("5", "a")
	assert_eq(String(hook.get("encounterTag", "")), "demo-sheaf-field")
	# Карты особых встреч — только по тегу, в общую выборку не попадают.
	var cid: String = String(GameState.campaign.get("id", ""))
	var req := {
		"kind": "general",
		"realLocation": {"id": "5", "name": "5", "locationType": "city"},
		"language": "Russian",
		"campaignId": cid,
	}
	for i: int in range(20):
		var sid: String = String(OfflineContent.draw(req)["encounters"][0].get("sourceId", ""))
		assert_false(sid.begins_with("demo-sheaf-field"), "особая карта в общей выборке")
	req["tag"] = "demo-sheaf-field"
	var tagged: String = String(OfflineContent.draw(req)["encounters"][0].get("sourceId", ""))
	assert_true(tagged.begins_with("demo-sheaf-field"), "по тегу — карта поля")
	# Провал: жетон остаётся; успех: жетон уходит на карту Тайны.
	GameState._encounter._apply_eldritch_outcome("a", hook, "5", false)
	assert_eq(_tokens_at("5"), 3)
	assert_eq(GameState.mystery_tokens_on_card, 0)
	GameState._encounter._apply_eldritch_outcome("a", hook, "5", true)
	assert_eq(_tokens_at("5"), 2, "жетон снят с поля")
	assert_eq(GameState.mystery_tokens_on_card, 1, "и лёг на карту Тайны")


func test_offline_general_deck_mixes_ancient_and_any() -> void:
	# Как на реле: общие встречи (ancient:any) тянутся наравне со своими картами
	# Древнего, а не только когда свои кончились.
	_start()
	var cid: String = String(GameState.campaign.get("id", ""))
	var seen_any: bool = false
	for _i in range(60):
		var req := {
			"kind": "general",
			"campaignId": cid,
			"realLocation": {"id": "1", "locationType": "city"},
			"count": 1,
		}
		var sid: String = String(OfflineContent.draw(req)["encounters"][0].get("sourceId", ""))
		if sid.begins_with("gen-"):
			seen_any = true
			break
	assert_true(seen_any, "общая встреча по типу клетки выпадает и в демо")


func test_demo_clues_only_at_six_spots_each_with_research() -> void:
	# Улики в демо выкладываются только в шести местах Америк (data.clues Древнего),
	# и у каждого места свои встречи-исследования — без механических заглушек.
	_start()
	var spots: Array = ["5", "6", "Arkham", "San Francisco", "4", "The Amazon"]
	GameState._board.reset_clue_deck()
	GameState._board.ensure_clue_deck()
	var deck: Array = GameState.clue_deck.duplicate()
	deck.sort()
	var want: Array = spots.duplicate()
	want.sort()
	assert_eq(deck, want, "пул улик — только шесть мест")
	for _i in range(10):
		GameState._board.place_clue()
	for loc_v: Variant in GameState.entities:
		if (GameState.entities[loc_v] as Array).has("clue"):
			assert_has(spots, String(loc_v), "улика легла в одно из шести мест")
	var cid: String = String(GameState.campaign.get("id", ""))
	for loc: String in spots:
		var types: Dictionary = {"4": "wilderness", "The Amazon": "wilderness"}
		var req := {
			"kind": "research",
			"campaignId": cid,
			"realLocation": {"id": loc, "locationType": String(types.get(loc, "city"))},
			"count": 1,
		}
		var card: Dictionary = OfflineContent.draw(req)["encounters"][0]
		assert_false(bool(card.get("mechanical", true)), "%s: настоящая карта, не заглушка" % loc)
		assert_false(String(card.get("name", "")).is_empty(), "%s: у встречи есть название" % loc)
