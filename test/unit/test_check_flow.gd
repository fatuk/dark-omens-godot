extends GutTest

## Юнит-тесты единой активной проверки (scripts/core/game/check_flow.gd) —
## хост-авторитетного механизма броска/перебросов/активации карт.
##
## CheckFlow работает поверх _gs.active_check (обычный словарь) и _gs.players, что
## позволяет задавать ТОЧНЫЕ кубы напрямую и проверять детерминированные побочные
## эффекты (списание валюты, счётчики перебросов, гварды), не завися от случайного
## значения нового куба. Сам бросок (Dice.roll) рандомен — проверяем размер пула и
## факт броска, а не конкретные грани.

var _gs: MockGameState
var _cf: CheckFlow


# Мок GameState: CheckFlow обращается к active_check, players, _name_of и _sync.
class MockGameState:
	extends Node
	var players: Dictionary = {}
	var active_check: Dictionary = {}
	var _check_stack: Array = []
	var sync_count: int = 0

	func _name_of(pid: String) -> String:
		return pid

	func _broadcast_sync() -> void:
		sync_count += 1

	func _emit_changed() -> void:
		pass


func before_each() -> void:
	_gs = autofree(MockGameState.new())
	_cf = CheckFlow.new(_gs)


func _player(extra: Dictionary = {}) -> void:
	var base: Dictionary = {"investigator": "", "skill_mods": {}, "concentration": 0, "clues": 0}
	for k_v: Variant in extra:
		base[k_v] = extra[k_v]
	_gs.players["p"] = base


# Готовая «брошенная» проверка с заданными кубами (для reroll / reroll_all).
func _rolled(extra: Dictionary = {}) -> void:
	var c: Dictionary = {
		"owner": "shop",
		"pid": "p",
		"skill": "will",
		"modifier": 0,
		"context": "",
		"rolled": true,
		"base": [2, 6],
		"dice": [2, 6],
		"successes": 1,
		"passed": true,
		"active_mods": [],
		"reroll_allowance": 0,
		"rerolls_used": 0,
		"reroll_all_allowance": 0,
		"reroll_all_used": 0,
		"exhausted_cards": [],
	}
	for k_v: Variant in extra:
		c[k_v] = extra[k_v]
	_gs.active_check = c


# ── Жизненный цикл ────────────────────────────────────────────────────────────


func test_start_initializes_active_check() -> void:
	_cf.start("shop", "p", "influence", 2, "acquireAssets")
	var c: Dictionary = _gs.active_check
	assert_eq(String(c["owner"]), "shop")
	assert_eq(String(c["pid"]), "p")
	assert_eq(String(c["skill"]), "influence")
	assert_eq(int(c["modifier"]), 2)
	assert_eq(String(c["context"]), "acquireAssets")
	assert_false(bool(c["rolled"]), "до броска rolled=false")
	assert_eq((c["base"] as Array).size(), 0, "кубов ещё нет")
	assert_eq((c["exhausted_cards"] as Array).size(), 0)


func test_clear_empties_active_check() -> void:
	_cf.start("shop", "p", "will", 0, "")
	_cf.clear()
	assert_eq(_gs.active_check.size(), 0, "active_check очищен")


# ── push/pop: вложенные проверки (incantation поверх боя) ─────────────────────


func test_push_then_start_then_pop_restores_outer_check() -> void:
	# Внешняя (боевая) проверка → push → новая spell-проверка перетирает active_check.
	_cf.start("combat", "p", "will", 0, "combatEncounter")
	var combat_snapshot: Dictionary = _gs.active_check.duplicate(true)
	_cf.push()
	_cf.start("spell", "p", "lore", 0, "castSpell")
	assert_eq(String(_gs.active_check["owner"]), "spell", "поверх — spell-проверка")
	# pop → боевая проверка возвращается БЕЗ изменений (round-trip).
	_cf.pop()
	assert_eq(String(_gs.active_check["owner"]), "combat", "после pop — снова бой")
	assert_eq(_gs.active_check, combat_snapshot, "боевая проверка восстановлена как была")
	assert_eq((_gs._check_stack as Array).size(), 0, "стек пуст")


func test_pop_on_empty_stack_clears_active_check() -> void:
	_cf.start("spell", "p", "lore", 0, "castSpell")
	_cf.pop()  # стек пуст → active_check очищается
	assert_eq(_gs.active_check.size(), 0, "pop без сохранённой → active_check пуст")


# ── pool: навык + skill_mods + modifier + доп.кубы карт ───────────────────────


func test_pool_sums_skill_mods_modifier_and_card_bonus() -> void:
	_player({"skill_mods": {"will": 2}})
	var c: Dictionary = {
		"pid": "p",
		"skill": "will",
		"modifier": 3,
		"active_mods": [{"do": "rollAdditionalDice", "count": 1}],
	}
	# база 1 (инвестигатор "") + skill_mods 2 + modifier 3 + доп.куб 1 = 7
	assert_eq(_cf.pool(c), 7)


func test_pool_never_below_one() -> void:
	_player()
	assert_eq(_cf.pool({"pid": "p", "skill": "will", "modifier": -5, "active_mods": []}), 1)


# ── roll: гварды и размер пула ────────────────────────────────────────────────


func test_roll_sets_dice_of_pool_size() -> void:
	_player()  # инвестигатор "" → база навыка 1 → пул 1
	_cf.start("shop", "p", "will", 0, "")
	var ok: bool = _cf.roll("p")
	assert_true(ok, "бросок выполнен")
	assert_true(bool(_gs.active_check["rolled"]))
	assert_eq((_gs.active_check["base"] as Array).size(), 1, "кубов = размеру пула")
	assert_gt(_gs.sync_count, 0, "результат разослан")


func test_roll_twice_is_rejected() -> void:
	_player()
	_cf.start("shop", "p", "will", 0, "")
	_cf.roll("p")
	assert_false(_cf.roll("p"), "повторный бросок той же проверки запрещён")


func test_roll_wrong_pid_rejected() -> void:
	_player()
	_cf.start("shop", "p", "will", 0, "")
	assert_false(_cf.roll("other"), "бросок не своей проверки запрещён")


func test_roll_without_active_check_rejected() -> void:
	assert_false(_cf.roll("p"), "нет активной проверки")


# ── reroll: выбор валюты и гварды ─────────────────────────────────────────────


func test_reroll_with_concentration_spends_one() -> void:
	_player({"concentration": 2})
	_rolled()  # base [2, 6] — индекс 0 провальный
	var ok: bool = _cf.reroll("p", 0, "concentration")
	assert_true(ok)
	assert_eq(int(_gs.players["p"]["concentration"]), 1, "списана 1 концентрация")


func test_reroll_with_clue_spends_one() -> void:
	_player({"clues": 2})
	_rolled()
	assert_true(_cf.reroll("p", 0, "clue"))
	assert_eq(int(_gs.players["p"]["clues"]), 1, "списана 1 улика")


func test_reroll_free_uses_card_allowance() -> void:
	_player()
	_rolled({"reroll_allowance": 1, "rerolls_used": 0})
	assert_true(_cf.reroll("p", 0, "free"))
	assert_eq(int(_gs.active_check["rerolls_used"]), 1, "израсходован карточный переброс")


func test_reroll_auto_priority_free_then_concentration_then_clue() -> void:
	# Авто-приоритет (currency ""): карта → концентрация → улика.
	_player({"concentration": 1, "clues": 1})
	_rolled({"reroll_allowance": 0})  # карт нет
	_cf.reroll("p", 0, "")
	assert_eq(int(_gs.players["p"]["concentration"]), 0, "при отсутствии карт берётся концентрация")
	assert_eq(int(_gs.players["p"]["clues"]), 1, "улика не тронута, пока есть концентрация")


func test_reroll_auto_falls_back_to_clue() -> void:
	_player({"concentration": 0, "clues": 1})
	_rolled({"reroll_allowance": 0})
	_cf.reroll("p", 0, "")
	assert_eq(int(_gs.players["p"]["clues"]), 0, "без карт и концентрации — улика")


func test_reroll_rejected_without_currency() -> void:
	_player({"concentration": 0, "clues": 0})
	_rolled({"reroll_allowance": 0})
	assert_false(_cf.reroll("p", 0, ""), "нечем перебрасывать")


func test_reroll_rejected_on_success_die() -> void:
	_player({"concentration": 5})
	_rolled()  # индекс 1 = 6 (успех)
	assert_false(_cf.reroll("p", 1, "concentration"), "успешный куб не перебрасывается")
	assert_eq(int(_gs.players["p"]["concentration"]), 5, "валюта не списана")


func test_reroll_rejected_out_of_range() -> void:
	_player({"concentration": 5})
	_rolled()
	assert_false(_cf.reroll("p", 9, "concentration"), "индекс вне диапазона")


# Гард для UI (GameState.reroll_die): тапнули по неперебрасываемому кубу → НЕ тратим
# заряженный жетон. die_is_rerollable зеркалит гард reroll() без мутаций.
func test_die_is_rerollable_mirrors_reroll_guard() -> void:
	_player({"concentration": 1})
	_rolled()  # base/dice [2, 6], порог по умолчанию 5
	assert_true(_cf.die_is_rerollable("p", 0), "куб 0 = 2 (провал) — перебрасываемый")
	assert_false(_cf.die_is_rerollable("p", 1), "куб 1 = 6 (успех) — не перебрасываемый")
	assert_false(_cf.die_is_rerollable("p", 5), "индекс вне диапазона")
	assert_false(_cf.die_is_rerollable("p", -1), "отрицательный индекс")
	assert_false(_cf.die_is_rerollable("other", 0), "не своя проверка (чужой pid)")
	assert_eq(int(_gs.players["p"]["concentration"]), 1, "валидация без мутаций — фокус цел")


func test_die_is_rerollable_false_before_roll() -> void:
	_player({"concentration": 1})
	_rolled({"rolled": false})
	assert_false(_cf.die_is_rerollable("p", 0), "до броска перебрасывать нечего")


# Метка переброса: UI крутит куб даже при перебросе в ТО ЖЕ значение (иначе клик
# выглядит «съеденным»). Каждый успешный reroll инкрементит nonce и пишет индекс.
func test_reroll_stamps_nonce_and_index() -> void:
	_player({"concentration": 2})
	_rolled()  # base/dice [2, 6], куб 0 = провал
	assert_true(_cf.reroll("p", 0, "concentration"), "провальный куб переброшен")
	assert_eq(int(_gs.active_check.get("reroll_nonce", 0)), 1, "nonce инкрементнулся")
	assert_eq(int(_gs.active_check.get("reroll_index", -1)), 0, "индекс переброшенного куба")


func test_reroll_rejected_before_roll() -> void:
	_player({"concentration": 5})
	_rolled({"rolled": false})
	assert_false(_cf.reroll("p", 0, "concentration"), "до броска перебрасывать нечего")


func test_reroll_explicit_concentration_rejected_when_empty() -> void:
	_player({"concentration": 0, "clues": 3})
	_rolled()
	assert_false(_cf.reroll("p", 0, "concentration"), "явная валюта без запаса → отказ")
	assert_eq(int(_gs.players["p"]["clues"]), 3, "к улике не падаем при явной валюте")


# ── reroll_all: «перебросить всё разом» ───────────────────────────────────────


func test_reroll_all_consumes_one_allowance() -> void:
	_player()
	_rolled({"base": [1, 2, 3], "dice": [1, 2, 3], "reroll_all_allowance": 1})
	assert_true(_cf.reroll_all("p"))
	assert_eq(int(_gs.active_check["reroll_all_used"]), 1)
	assert_eq((_gs.active_check["base"] as Array).size(), 3, "размер пула сохраняется")


func test_reroll_all_rejected_without_allowance() -> void:
	_player()
	_rolled({"base": [1, 2], "dice": [1, 2], "reroll_all_allowance": 0})
	assert_false(_cf.reroll_all("p"), "нет доступного полного переброса")


func test_reroll_all_rejected_before_roll() -> void:
	_player()
	_rolled({"rolled": false, "reroll_all_allowance": 1})
	assert_false(_cf.reroll_all("p"))


func test_reroll_all_rejected_wrong_pid() -> void:
	_player()
	_rolled({"reroll_all_allowance": 1})
	assert_false(_cf.reroll_all("other"))


# ── activate: гварды (детерминированные, без данных активов) ───────────────────


func test_activate_rejected_without_active_check() -> void:
	_player({"items": [{"id": "18_derringer", "exhausted": false}]})
	assert_false(_cf.activate("p", 0), "нет активной проверки")


func test_activate_rejected_wrong_pid() -> void:
	_player({"items": [{"id": "18_derringer", "exhausted": false}]})
	_rolled()
	assert_false(_cf.activate("other", 0))


func test_activate_rejected_index_out_of_range() -> void:
	_player({"items": []})
	_rolled()
	assert_false(_cf.activate("p", 0), "пустой инвентарь")


func test_activate_rejected_exhausted_card() -> void:
	_player({"items": [{"id": "18_derringer", "exhausted": true}]})
	_rolled()
	assert_false(_cf.activate("p", 0), "истощённая карта (oncePerRound)")


func test_activate_rejected_already_applied_this_check() -> void:
	_player({"items": [{"id": "18_derringer", "exhausted": false}]})
	_rolled({"exhausted_cards": [0]})
	assert_false(_cf.activate("p", 0), "карта уже применена в этой проверке")


func test_activate_rejected_unknown_asset() -> void:
	_player({"items": [{"id": "no_such_asset", "exhausted": false}]})
	_rolled()
	assert_false(_cf.activate("p", 0), "id отсутствует в каталоге")


# ── activate: применение модов (реальные активы из data/assets.json) ──────────


func test_activate_post_roll_card_applies_and_exhausts_once_per_round() -> void:
	# lucky_cigarette_case: addToDie (пост-бросковый), anyTest, oncePerRound.
	_player({"items": [{"id": "lucky_cigarette_case", "exhausted": false}]})
	_rolled()  # rolled=true → пост-бросковый мод применим
	assert_true(_cf.activate("p", 0))
	assert_true(bool(_gs.players["p"]["items"][0]["exhausted"]), "oncePerRound → карта истощена")
	assert_gt(_gs.sync_count, 0, "результат разослан")
	var verbs: Array = []
	for m_v: Variant in _gs.active_check["active_mods"]:
		verbs.append(String((m_v as Dictionary).get("do", "")))
	assert_has(verbs, "addToDie", "мод добавлен в active_mods")


func test_activate_discard_self_removes_card() -> void:
	# kerosene: improveSkill strength (до броска), combatEncounter, cost discardSelf.
	_player({"items": [{"id": "kerosene", "exhausted": false}]})
	_rolled(
		{"context": "combatEncounter", "skill": "strength", "rolled": false, "base": [], "dice": []}
	)
	assert_true(_cf.activate("p", 0))
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "discardSelf → карта сброшена")


func test_activate_this_check_only_marks_exhausted_cards() -> void:
	# holy_water: вторая action-нода improveSkill strength без cost/limit → действует
	# только на ЭТУ проверку (exhausted_cards); карта не истощается и не сбрасывается.
	_player({"items": [{"id": "holy_water", "exhausted": false}]})
	_rolled(
		{"context": "combatEncounter", "skill": "strength", "rolled": false, "base": [], "dice": []}
	)
	assert_true(_cf.activate("p", 0))
	assert_eq(_gs.active_check["exhausted_cards"] as Array, [0], "помечена в exhausted_cards")
	assert_false(bool(_gs.players["p"]["items"][0]["exhausted"]), "сама карта не истощена")


func test_activate_cost_spend_rejected_without_resource() -> void:
	# magnifying_glass: rerollDice (пост-бросковый), cost spend clue 1.
	_player({"items": [{"id": "magnifying_glass", "exhausted": false}], "clues": 0})
	_rolled()
	assert_false(_cf.activate("p", 0), "нечем оплатить улику")


func test_activate_cost_spend_pays_resource() -> void:
	_player({"items": [{"id": "magnifying_glass", "exhausted": false}], "clues": 1})
	_rolled()
	assert_true(_cf.activate("p", 0))
	assert_eq(int(_gs.players["p"]["clues"]), 0, "улика списана")


func test_activate_wrong_context_rejected() -> void:
	# kerosene нужен combatEncounter — в shop-проверке нет применимых модов.
	_player({"items": [{"id": "kerosene", "exhausted": false}]})
	_rolled(
		{"context": "acquireAssets", "skill": "strength", "rolled": false, "base": [], "dice": []}
	)
	assert_false(_cf.activate("p", 0), "контекст не совпал")


func test_activate_wrong_skill_rejected() -> void:
	# kerosene несёт skill strength — на шаг will не применяется.
	_player({"items": [{"id": "kerosene", "exhausted": false}]})
	_rolled(
		{"context": "combatEncounter", "skill": "will", "rolled": false, "base": [], "dice": []}
	)
	assert_false(_cf.activate("p", 0), "мод чужого навыка отфильтрован")


func test_activate_wrong_timing_rejected() -> void:
	# kerosene improveSkill — усиление пула, применимо ТОЛЬКО до броска.
	_player({"items": [{"id": "kerosene", "exhausted": false}]})
	_rolled({"context": "combatEncounter", "skill": "strength"})  # rolled=true по умолчанию
	assert_false(_cf.activate("p", 0), "усиление пула после броска не применяется")


func test_activate_glamour_aura() -> void:
	# Пассив-аура glamour (Mind's Eye: rerollDice anyTest) применяется к проверке
	# тем же путём, что пассивы актива. rerollDice — пост-бросковый (rolled=true).
	_player({"items": [{"id": "mind_s_eye"}]})
	_rolled()
	assert_true(_cf.activate("p", 0), "glamour-аура применима")
	var verbs: Array = []
	for m_v: Variant in _gs.active_check["active_mods"]:
		verbs.append(String((m_v as Dictionary).get("do", "")))
	assert_has(verbs, "rerollDice", "аура glamour в active_mods")


# ── addToDie: заряд + тап по кубу (add_die / die_can_add) ──────────────────────
func test_add_available_counts_unassigned_charges() -> void:
	_player()
	_rolled({"active_mods": [{"do": "addToDie", "amount": 1, "count": 1}]})
	assert_eq(_cf.add_available(_gs.active_check), 1, "один заряд addToDie свободен")
	assert_true(_cf.add_die("p", 0), "тап кладёт +1 на куб 0")
	assert_eq(_cf.add_available(_gs.active_check), 0, "заряд израсходован")


func test_add_die_pushes_five_to_six() -> void:
	# База [2,5]: куб-5 (успех) можно улучшить до 6 — для карт, которым нужны шестёрки.
	_player()
	_rolled(
		{
			"base": [2, 5],
			"dice": [2, 5],
			"active_mods": [{"do": "addToDie", "amount": 1, "count": 1}],
		}
	)
	assert_true(_cf.die_can_add("p", 1, _gs.active_check), "куб 5 (< 6) можно улучшить")
	assert_true(_cf.add_die("p", 1))
	assert_eq(_gs.active_check["dice"], [2, 6], "5→6 на выбранном кубе")


func test_die_can_add_rejects_six_and_no_charges() -> void:
	_player()
	# Куб уже 6 — улучшать некуда, даже с зарядом.
	_rolled({"base": [6, 2], "dice": [6, 2], "active_mods": [{"do": "addToDie", "count": 1}]})
	assert_false(_cf.die_can_add("p", 0, _gs.active_check), "шестёрку не улучшить")
	assert_true(_cf.die_can_add("p", 1, _gs.active_check), "куб 2 — можно")
	# Без addToDie-мода зарядов нет.
	_rolled({"base": [2, 3], "dice": [2, 3], "active_mods": []})
	assert_false(_cf.die_can_add("p", 0, _gs.active_check), "нет заряда — нельзя")


func test_activate_combined_pre_and_post_roll_mods_both_apply() -> void:
	# double_barreled_shotgun: improveSkill(pre-roll) + convertDie(post-roll) в одном
	# whileOwned. Тап ДО броска должен положить ОБА мода: pre-roll усиливает пул сразу,
	# post-roll (скоринг) ждёт подсчёта. Раньше один из них терялся (не в свою фазу).
	_player({"items": [{"id": "double_barreled_shotgun", "exhausted": false}]})
	_rolled(
		{"context": "combatEncounter", "skill": "strength", "rolled": false, "base": [], "dice": []}
	)
	assert_true(_cf.activate("p", 0), "оружие применимо до броска")
	var verbs: Array = []
	for m_v: Variant in _gs.active_check["active_mods"]:
		verbs.append(String((m_v as Dictionary).get("do", "")))
	assert_has(verbs, "improveSkill", "усиление пула легло")
	assert_has(verbs, "convertDie", "скоринг-мод тоже лёг (post-roll в любой фазе)")
	assert_eq(_cf.pool(_gs.active_check), 5, "пул = навык 1 + improveSkill 4")
