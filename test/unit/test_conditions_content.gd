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
		assert_eq((def.get("backs", []) as Array).size(), int(SEASON0[cid]), "%s: обороты EH" % cid)


func test_every_back_resolves_and_is_translated() -> void:
	for cid: String in SEASON0:
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
