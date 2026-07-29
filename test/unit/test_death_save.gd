extends GutTest

## Юнит-тесты движка спас-броска на Пороге (scripts/core/game/death_save_flow.gd).
##
## DeathSaveFlow работает поверх per-player слота players[pid].death_save_check и
## настоящего CheckFlow (fixed_pool=1), поэтому исход резолвим детерминированно,
## задавая кубы слота напрямую (сам бросок Dice.roll рандомен — для open проверяем
## лишь размер пула и факт броска, для apply — заранее заданный passed).

var _gs: MockGameState
var _ds: DeathSaveFlow


# Мок GameState: DeathSaveFlow/CheckFlow обращаются к players, _check, _sync, _name_of.
class MockGameState:
	extends Node
	var players: Dictionary = {}
	var active_check: Dictionary = {}
	var _check: CheckFlow
	var sync_count: int = 0

	func _init() -> void:
		_check = CheckFlow.new(self)

	func _name_of(pid: String) -> String:
		return pid

	func _broadcast_sync() -> void:
		sync_count += 1

	func _emit_changed() -> void:
		pass


func before_each() -> void:
	_gs = autofree(MockGameState.new())
	_ds = DeathSaveFlow.new(_gs)


func _player(extra: Dictionary = {}) -> void:
	var base: Dictionary = {
		"investigator": "", "skill_mods": {}, "resources": 0, "hp": 0, "sanity": 0
	}
	for k_v: Variant in extra:
		base[k_v] = extra[k_v]
	_gs.players["p"] = base


# Готовый «брошенный» слот спас-броска с заданным исходом (для apply / reroll).
func _save_slot(stat: String, passed: bool) -> void:
	var skill: String = "strength" if stat == "hp" else "will"
	var val: int = 6 if passed else 2  # порог по умолчанию 5
	var c: Dictionary = _gs._check.make_check("deathSave", "p", skill, 0, "deathSave")
	c["fixed_pool"] = 1
	c["death_stat"] = stat
	c["rolled"] = true
	c["base"] = [val]
	c["dice"] = [val]
	c["successes"] = 1 if passed else 0
	c["passed"] = passed
	_gs.players["p"][PlayerKeys.DEATH_SAVE_CHECK] = c


# ── open: создание слота, 1 кубик, порог шрама ────────────────────────────────


func test_open_creates_death_save_with_one_die() -> void:
	_player({"hp": 0})
	assert_eq(_ds.open("p", "hp"), "save")
	var c: Dictionary = _ds.slot("p")
	assert_false(c.is_empty(), "слот спас-броска создан")
	assert_true(bool(c["rolled"]), "кубик брошен")
	assert_eq((c["base"] as Array).size(), 1, "ровно 1 кубик (fixed_pool)")
	assert_eq(String(c["death_stat"]), "hp")
	assert_eq(String(c["skill"]), "strength", "по здоровью страдает Сила")
	assert_gt(_gs.sync_count, 0, "результат разослан")


func test_open_sanity_targets_will() -> void:
	_player({"sanity": 0})
	assert_eq(_ds.open("p", "sanity"), "save")
	assert_eq(String(_ds.slot("p")["skill"]), "will", "по рассудку страдает Воля")
	assert_eq(String(_ds.slot("p")["death_stat"]), "sanity")


func test_open_is_idempotent_while_save_pending() -> void:
	_player({"hp": 0})
	_ds.open("p", "hp")
	assert_eq(_ds.open("p", "hp"), "", "второй open при живом слоте — no-op")


func test_open_on_dead_player_noop() -> void:
	_player({"hp": 0, "dead": true})
	assert_eq(_ds.open("p", "hp"), "")
	assert_true(_ds.slot("p").is_empty(), "слот не создаётся мёртвому")


func test_open_at_scar_cap_is_immediate_death() -> void:
	_player({"hp": 0, "skill_mods": {"strength": -2}})
	assert_eq(_ds.open("p", "hp"), "death", "на −2 цепляться нельзя")
	assert_true(bool(_gs.players["p"]["dead"]))
	assert_true(_ds.slot("p").is_empty(), "слот не создаётся")


# ── apply: успех (выжил + шрам) / провал (смерть) ─────────────────────────────


func test_apply_survive_hp_sets_one_and_scars_strength() -> void:
	_player({"hp": 0})
	_save_slot("hp", true)
	assert_eq(_ds.apply("p"), "survive")
	var p: Dictionary = _gs.players["p"]
	assert_eq(int(p["hp"]), 1, "вырван с Порога на 1")
	assert_eq(int((p["skill_mods"] as Dictionary).get("strength", 0)), -1, "шрам −1 к Силе")
	assert_true(_ds.slot("p").is_empty(), "слот снят")
	assert_false(bool(p.get("dead", false)), "жив")


func test_apply_survive_sanity_scars_will() -> void:
	_player({"sanity": 0})
	_save_slot("sanity", true)
	assert_eq(_ds.apply("p"), "survive")
	assert_eq(int(_gs.players["p"]["sanity"]), 1)
	assert_eq(
		int((_gs.players["p"]["skill_mods"] as Dictionary).get("will", 0)), -1, "шрам −1 к Воле"
	)


func test_scar_accumulates_to_cap() -> void:
	_player({"hp": 0, "skill_mods": {"strength": -1}})
	_save_slot("hp", true)
	_ds.apply("p")
	assert_eq(
		int((_gs.players["p"]["skill_mods"] as Dictionary).get("strength", 0)), -2, "−1 → −2 (пол)"
	)


func test_apply_fail_is_death() -> void:
	_player({"hp": 0})
	_save_slot("hp", false)
	assert_eq(_ds.apply("p"), "death")
	assert_true(bool(_gs.players["p"]["dead"]))
	assert_true(_ds.slot("p").is_empty(), "слот снят")


func test_apply_without_slot_noop() -> void:
	_player()
	assert_eq(_ds.apply("p"), "", "нет слота — нечего применять")


# ── reroll_by_resource: сосед платит ресурсом ────────────────────────────────


func test_reroll_by_resource_spends_ally_resource() -> void:
	_player({"hp": 0})
	_save_slot("hp", false)  # провальный куб [2]
	_gs.players["ally"] = {"investigator": "", "resources": 1}
	assert_true(_ds.reroll_by_resource("ally", "p", 0))
	assert_eq(int(_gs.players["ally"]["resources"]), 0, "ресурс соседа списан")
	assert_eq(int(_ds.slot("p").get("reroll_nonce", 0)), 1, "куб переброшен (nonce)")


func test_reroll_by_resource_rejected_without_resource() -> void:
	_player({"hp": 0})
	_save_slot("hp", false)
	_gs.players["ally"] = {"investigator": "", "resources": 0}
	assert_false(_ds.reroll_by_resource("ally", "p", 0), "у соседа нет ресурса")


func test_reroll_by_resource_rejected_on_success_die() -> void:
	_player({"hp": 0})
	_save_slot("hp", true)  # куб [6] — успех
	_gs.players["ally"] = {"investigator": "", "resources": 1}
	assert_false(_ds.reroll_by_resource("ally", "p", 0), "успешный куб не перебрасывается")
	assert_eq(int(_gs.players["ally"]["resources"]), 1, "ресурс не тронут")
