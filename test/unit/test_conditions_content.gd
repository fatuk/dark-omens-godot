## Состояния из data/conditions.json, сверенные с EH: сезоны, обороты сезона 0
## (core + Forsaken Lore) и их исполнимость, «вместо встречи» у Задержан/Затерян.
extends GutTest

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

# Сезон 0 по EH: состояние → число оборотов core + Forsaken Lore.
const SEASON0 := {
	"amnesia": 4,
	"backInjury": 4,
	"blessed": 6,
	"cursed": 6,
	"darkPact": 4,
	"debt": 8,
	"detained": 4,
	"hallucinations": 4,
	"internalInjury": 4,
	"legInjury": 4,
	"lostInTimeAndSpace": 4,
	"paranoia": 4,
	"poisoned": 4,
}

# Все варианты EH (с дополнениями) у состояний, что уже есть в игре.
const EH_TOTAL := {
	"agreement": 4,
	"amnesia": 6,
	"backInjury": 5,
	"blessed": 11,
	"cursed": 11,
	"darkPact": 9,
	"debt": 14,
	"despair": 4,
	"detained": 5,
	"diseased": 4,
	"funding": 4,
	"hallucinations": 5,
	"haunted": 4,
	"headInjury": 4,
	"hunger": 4,
	"hunted": 4,
	"hypothermia": 8,
	"infection": 4,
	"internalInjury": 5,
	"legInjury": 4,
	"lostInTimeAndSpace": 8,
	"paranoia": 4,
	"poisoned": 4,
	"righteous": 4,
}

var _nm: Node
var _was_host: bool


func before_each() -> void:
	_nm = get_node("/root/NetworkManager")
	_was_host = bool(_nm.get("_is_host_flag"))


func after_each() -> void:
	GameState.reset_session()
	_nm.set("_is_host_flag", _was_host)


func test_every_condition_has_season() -> void:
	for id_v: Variant in Conditions.all_ids():
		var def: Dictionary = Conditions.get_def(String(id_v))
		assert_false(String(def.get("season", "")).is_empty(), "%s: сезон" % id_v)


func test_season0_backs_match_eh() -> void:
	for cid: String in SEASON0:
		var def: Dictionary = Conditions.get_def(cid)
		assert_eq(String(def.get("season", "")), "core", "%s — сезон 0" % cid)
		var core: Array = (def.get("backs", []) as Array).filter(
			func(b: Variant) -> bool: return String((b as Dictionary).get("season", "")) == "core"
		)
		assert_eq(core.size(), int(SEASON0[cid]), "%s: обороты сезона 0" % cid)


func test_all_eh_variants_present() -> void:
	for cid: String in EH_TOTAL:
		var backs: Array = Conditions.get_def(cid).get("backs", [])
		assert_eq(backs.size(), int(EH_TOTAL[cid]), "%s: все варианты EH" % cid)
		for b_v: Variant in backs:
			assert_false(String((b_v as Dictionary).get("season", "")).is_empty(), "сезон оборота")


func test_backs_follow_table_seasons() -> void:
	# Стол базового сезона: Долг тянет только 8 базовых оборотов из 14.
	SeasonGate.set_room(["core"])
	var room: Array = ConditionFlow._room_backs(Conditions.get_def("debt").get("backs", []))
	assert_eq(room.size(), 8)
	SeasonGate.set_room(["core", "mom"])
	room = ConditionFlow._room_backs(Conditions.get_def("debt").get("backs", []))
	assert_eq(room.size(), 10, "+ 2 варианта Гор Безумия")
	SeasonGate.set_room(["core"])


func test_every_back_resolves_and_is_translated() -> void:
	for cid: String in EH_TOTAL:
		for b_v: Variant in Conditions.get_def(cid).get("backs", []):
			var b: Dictionary = b_v
			assert_has(["discard", "front"], String(b.get("then", "")), "%s: концовка" % b["id"])
			for key: String in [String(b["name"]), String(b["text"])]:
				assert_ne(tr(key), key, "%s: перевод %s" % [b["id"], key])
			var p: Dictionary = {
				"hp": 5,
				"hp_max": 7,
				"sanity": 5,
				"sanity_max": 7,
				"clues": 2,
				"items": [],
				"conditions": [cid],
				"skill_mods": {}
			}
			_EffectRunner.run(b.get("effect", []), p, {"skills": {}, "loc_type": "city"})
			assert_true(int(p["hp"]) >= 0, "%s: прогон без ошибок" % b["id"])


func test_random_condition_of_kind_only_from_table_seasons() -> void:
	# Стол базового сезона: «получите Безумие» не выдаёт Отчаяние/Голод из дополнений.
	SeasonGate.set_room(["core"])
	for _i in range(40):
		var p: Dictionary = {"conditions": []}
		_EffectRunner.run([{"do": "gainCondition", "kind": "madness"}], p)
		var got: String = String((p["conditions"] as Array)[0])
		assert_eq(String(Conditions.get_def(got).get("season", "")), "core", got)


func _detained(clues: int) -> void:
	_nm.set("_is_host_flag", true)
	GameState.reset_session()
	GameState.players = {"a": GameState._make_player_dict("a", "A", "Frank Dalton", "5", 5, 5)}
	GameState.players["a"]["conditions"] = ["detained"]
	GameState.players["a"]["clues"] = clues
	GameState.turn_order = ["a"]
	GameState.current_idx = 0
	GameState.phase = Phases.ENCOUNTER
	GameState.active = true
	GameState._encounter.begin_turn()
	assert_true(GameState.current_encounter.is_empty(), "встреча не началась — вместо неё оборот")


func test_detained_with_clue_asks_clue_or_test() -> void:
	_detained(1)
	assert_true(
		bool(GameState.mythos_decision.get("active", false)),
		"оборот спрашивает: улика или проверка"
	)


func test_detained_without_clue_goes_to_test() -> void:
	_detained(0)
	assert_true(GameState.players["a"].has("reckoning_check"), "платить нечем — сразу проверка")


func test_rest_roll_shown_to_player() -> void:
	# «При отдыхе бросьте кубик: на 5–6 сбросьте» — бросок виден в окне результата.
	_nm.set("_is_host_flag", true)
	GameState.reset_session()
	GameState.players = {"a": GameState._make_player_dict("a", "A", "Frank Dalton", "5", 5, 5)}
	GameState.players["a"]["conditions"] = ["legInjury"]
	GameState.players["a"]["actions_left"] = 2
	GameState.turn_order = ["a"]
	GameState.current_idx = 0
	GameState.phase = Phases.ACTION
	GameState.active = true
	assert_true(GameState._phase.host_apply_action("a", GameActions.REST, {}))
	var g: Dictionary = GameState.players["a"].get("gains", {})
	assert_eq(String(g.get("card", "")), "legInjury", "окно результата — карта состояния")
	assert_eq((g.get("rolls", []) as Array).size(), 1, "выпавший кубик")
	var cured: bool = not (GameState.players["a"]["conditions"] as Array).has("legInjury")
	assert_eq(cured, int(g["rolls"][0]) >= 5, "сброс — ровно на 5–6")
