extends GutTest

## Юнит-тесты сопротивления монстров (MonsterCatalog). Данные — реальный
## data/monsters.json: ghost = physical-резист, colour_out_of_space = magical,
## ghoul = без резиста.


func test_resists_physical() -> void:
	var m: Dictionary = MonsterCatalog.by_id("ghost")
	assert_true(MonsterCatalog.resists(m, "physical"), "ghost сопротивляется физ-урону")
	assert_false(MonsterCatalog.resists(m, "magical"), "но не магическому")


func test_resists_magical() -> void:
	assert_true(MonsterCatalog.resists(MonsterCatalog.by_id("colour_out_of_space"), "magical"))


func test_no_resist() -> void:
	var m: Dictionary = MonsterCatalog.by_id("ghoul")
	assert_false(MonsterCatalog.resists(m, "physical"))
	assert_false(MonsterCatalog.resists(m, "magical"))


func test_apply_resistance_halves_matching_floor() -> void:
	var ghost: Dictionary = MonsterCatalog.by_id("ghost")  # physical
	assert_eq(MonsterCatalog.apply_resistance(ghost, 4, "physical"), 2, "физ-резист: 4 → 2")
	assert_eq(MonsterCatalog.apply_resistance(ghost, 3, "physical"), 1, "округление вниз: 3 → 1")
	assert_eq(MonsterCatalog.apply_resistance(ghost, 4, "magical"), 4, "магия обходит физ-резист")


func test_apply_resistance_no_resist_unchanged() -> void:
	var ghoul: Dictionary = MonsterCatalog.by_id("ghoul")
	assert_eq(MonsterCatalog.apply_resistance(ghoul, 3, "physical"), 3)
	assert_eq(MonsterCatalog.apply_resistance(ghoul, 3, "magical"), 3)


func test_apply_resistance_zero_unchanged() -> void:
	assert_eq(MonsterCatalog.apply_resistance(MonsterCatalog.by_id("ghost"), 0, "physical"), 0)


# ── Стойкость эпиков: +ceil(per × N), per дробный ────────────────────────────


func test_toughness_per_investigator_rounds_up() -> void:
	var elder := {"toughness": 3, "toughnessPerInvestigator": 0.5}
	assert_eq(MonsterCatalog.toughness_for(elder, 1), 4, "0.5×1 → +1")
	assert_eq(MonsterCatalog.toughness_for(elder, 2), 4, "0.5×2 → +1")
	assert_eq(MonsterCatalog.toughness_for(elder, 3), 5, "0.5×3 = 1.5 → +2")
	assert_eq(
		MonsterCatalog.toughness_for({"toughness": 2, "toughnessPerInvestigator": 1}, 4),
		6,
		"целый per — как раньше"
	)
	assert_eq(MonsterCatalog.toughness_for({"toughness": 2}, 4), 2, "без per — база")


# ── Культист: статы и Расплата с листа Древнего (useAncientOne) ───────────────


func test_cultist_resolves_from_ancient_sheet() -> void:
	var sheet := {
		"cultist":
		{
			"toughness": 2,
			"horror": {"skill": "will", "modifier": -1, "damage": 2},
			"combat": {"skill": "strength", "modifier": 0, "damage": 1},
			"onReckoning": [{"do": "advanceDoom", "amount": 1}],
		}
	}
	var m: Dictionary = MonsterCatalog.resolve(MonsterCatalog.by_id("cultist"), sheet)
	assert_eq(int(m["toughness"]), 2)
	assert_eq(int((m["horror"] as Dictionary)["damage"]), 2)
	assert_eq(String(((m["onReckoning"] as Array)[0] as Dictionary)["do"]), "advanceDoom")
	assert_eq(String(m["nameKey"]), "MON_CULTIST_NAME", "имя и прочее — из каталога")


func test_cultist_without_sheet_gets_safe_defaults() -> void:
	var m: Dictionary = MonsterCatalog.resolve(MonsterCatalog.by_id("cultist"), {})
	assert_eq(int(m["toughness"]), 1)
	assert_eq(String((m["horror"] as Dictionary)["skill"]), "will")
	assert_eq(int((m["combat"] as Dictionary)["damage"]), 1)
	assert_true((m.get("onReckoning", []) as Array).is_empty(), "Расплаты без листа нет")


func test_resolve_leaves_ordinary_monsters_alone() -> void:
	var ghoul: Dictionary = MonsterCatalog.by_id("ghoul")
	var m: Dictionary = MonsterCatalog.resolve(ghoul, {"cultist": {"toughness": 9}})
	assert_eq(m, ghoul, "лист Древнего касается только useAncientOne")
