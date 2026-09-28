extends GutTest

## Юнит-тесты подсистемы доски (scripts/core/game/board_state.gd): омен/дум,
## врата, монстры, улики/жетоны/слухи, Наплыв, стартовая раскладка.
##
## Случайность (выбор локации/монстра) приручаем раскладкой: явный open_gate(loc,
## color) обходит ГСЧ; мешок ["cultist"] спаунит детерминированно (культист не
## вынимается); одна локация-кандидат → улика/жетон ложатся именно туда. Зависимость
## MonsterCatalog реальна — стойкость не фиксируем, проверяем health >= 1.

var _gs: Mock
var _board: BoardState


class StubCampaign:
	extends RefCounted
	var balance_pc: int = 1

	func balance_player_count() -> int:
		return balance_pc


# Стаб подсистемы Тайн: close_gate триггерит _gs._mystery.try_mystery_hook.
class StubMystery:
	extends RefCounted
	var hooks: Array = []

	func try_mystery_hook(event: String, ctx: Dictionary, pid: String) -> void:
		hooks.append({"event": event, "ctx": ctx, "pid": pid})

	func check_defeat() -> void:
		pass  # проверку/кламп дума тестируем отдельно (test_mystery_flow)


# Мок GameState: BoardState мутирует синкаемый стейт через эти поля/методы.
class Mock:
	extends "res://test/unit/helpers/mock_game_state.gd"
	var gates: Dictionary = {}
	var entities: Dictionary = {}
	var monsters: Dictionary = {}
	var monster_bag: Array = []
	var gate_deck: Array = []  # колода жетонов врат (см. BoardState._reset_gate_deck)
	var gate_discard: Array = []
	var clue_deck: Array = []  # колода ключей улик (см. GameState._clue_draw_ready)
	var clue_discard: Array = []
	var monster_surge: int = 1
	var doom: int = 0
	var omens_step: int = 0
	var shop_filled: int = 0
	var mythos_in_play: Array = []
	var _campaign: StubCampaign
	var _mystery: StubMystery
	var _rumor: RumorFlow

	func _init() -> void:
		_campaign = StubCampaign.new()
		_mystery = StubMystery.new()
		_rumor = RumorFlow.new(self)

	# Колода улик: мок отдаёт «есть что тянуть», пока в ней что-то лежит.
	func _clue_draw_ready() -> bool:
		return not clue_deck.is_empty()

	func _fill_shop_reserve() -> void:
		shop_filled += 1

	func _claim_board_clue(_loc: String) -> void:
		pass  # слой идентичности улик не под тестом board_state


func before_each() -> void:
	_gs = autofree(Mock.new())
	_board = BoardState.new(_gs)


# Поставить активного игрока «p» на локацию loc.
func _at(loc: String) -> void:
	_gs.turn_order = ["p"]
	_gs.current_idx = 0
	_gs.players["p"] = {"location": loc}


# Сколько ячеек entities содержат маркер.
func _count_marker(marker: String) -> int:
	var n: int = 0
	for k_v: Variant in _gs.entities:
		if (_gs.entities[k_v] as Array).has(marker):
			n += 1
	return n


# ── Омен / дум ────────────────────────────────────────────────────────────────


func test_omen_color_cycles() -> void:
	var seq: Array = []
	for step: int in range(5):
		_gs.omens_step = step
		seq.append(_board.current_omen_color())
	assert_eq(seq, ["green", "blue", "red", "blue", "green"], "цикл green→blue→red→blue")


func test_count_gates_of_color() -> void:
	_gs.gates = {"a": "green", "b": "blue", "c": "green"}
	assert_eq(_board.count_gates_of_color("green"), 2)
	assert_eq(_board.count_gates_of_color("blue"), 1)
	assert_eq(_board.count_gates_of_color("red"), 0)


func test_resolve_omen_doom_adds_for_matching_gates() -> void:
	_gs.omens_step = 0  # green
	_gs.gates = {"a": "green", "b": "green", "c": "red"}
	var added: int = _board.resolve_omen_doom()
	assert_eq(added, 2, "две зелёных врат")
	assert_eq(_gs.doom, 2, "doom += 2")


func test_resolve_omen_doom_zero_when_no_match() -> void:
	_gs.omens_step = 2  # red
	_gs.gates = {"a": "green"}
	assert_eq(_board.resolve_omen_doom(), 0)
	assert_eq(_gs.doom, 0, "doom не меняется")


# ── Врата ─────────────────────────────────────────────────────────────────────


func test_open_gate_explicit_places_gate_and_spawns_monster() -> void:
	_gs.monster_bag = ["cultist"]
	_board.open_gate("gA", "red")
	assert_eq(String(_gs.gates["gA"]), "red", "врата с заданным цветом")
	assert_eq((_gs.monsters["gA"] as Array).size(), 1, "новые врата → 1 монстр")


func test_open_gate_explicit_non_gatespace_uses_green_fallback() -> void:
	# «Открыть Врата в этой локации» (openGate where:self/<id>) кладёт врата на ЛЮБУЮ
	# клетку, даже не гейт-спейс (напр. Точка Немо) — цвет из gateColor, иначе green.
	_gs.monster_bag = ["cultist"]
	_gs.locations = [{"id": "nemo"}]  # без gateColor
	_board.open_gate("nemo")
	assert_eq(String(_gs.gates.get("nemo", "")), "green", "врата на не-гейт-спейсе, фолбэк green")
	assert_eq((_gs.monsters["nemo"] as Array).size(), 1, "новые врата → 1 монстр")


func test_spawn_monster_at_places_at_location() -> void:
	# spawnMonster {where:self/<id>} → монстр в конкретной локации (без врат).
	_gs.monster_bag = ["cultist"]
	_board.spawn_monster_at("loc")
	assert_eq((_gs.monsters["loc"] as Array).size(), 1, "монстр появился в указанной локации")


func test_open_gate_non_host_is_noop() -> void:
	_gs.host = false
	_board.open_gate("gA", "red")
	assert_false(_gs.gates.has("gA"))


func test_open_gate_random_uses_location_gate_color() -> void:
	_gs.monster_bag = ["cultist"]
	_gs.locations = [{"id": "gA", "gateColor": "red"}, {"id": "plain"}]
	_gs.gate_deck = ["gA"]  # жетон врат тянется из колоды (см. BoardState._draw_gate)
	_board.open_gate()  # без loc → единственный жетон в колоде
	assert_eq(String(_gs.gates.get("gA", "")), "red", "цвет взят из gateColor локации")
	assert_false(_gs.gates.has("plain"), "не-гейт-спейс пропущен")


func test_close_gate_at_active_player_fires_mystery_hook() -> void:
	_at("gA")
	_gs.gates = {"gA": "green"}
	_board.close_gate_at_active_player()
	assert_false(_gs.gates.has("gA"), "врата закрыты")
	assert_eq(_gs._mystery.hooks.size(), 1, "триггер gateClosed")
	assert_eq(String((_gs._mystery.hooks[0] as Dictionary)["event"]), "gateClosed")


func test_close_gate_noop_when_no_gate_here() -> void:
	_at("plain")
	_gs.gates = {"gA": "green"}
	_board.close_gate_at_active_player()
	assert_true(_gs.gates.has("gA"), "чужие врата не трогаем")
	assert_eq(_gs._mystery.hooks.size(), 0)


func test_discard_gate_at_active_location() -> void:
	_at("gA")
	_gs.gates = {"gA": "green"}
	_board.discard_gate()
	assert_false(_gs.gates.has("gA"))


# ── Монстры ───────────────────────────────────────────────────────────────────


func test_spawn_keeps_cultist_in_bag() -> void:
	_gs.monster_bag = ["cultist"]
	_board.open_gate("gA", "green")
	assert_true(_gs.monster_bag.has("cultist"), "культист не вынимается из мешка")
	var inst: Dictionary = _gs.monsters["gA"][0]
	assert_eq(String(inst["id"]), "cultist")
	assert_gt(int(inst["health"]), 0, "стойкость >= 1")


func test_spawn_removes_non_cultist_from_bag() -> void:
	_gs.monster_bag = ["ghoul"]
	_board.open_gate("gA", "green")
	assert_false(_gs.monster_bag.has("ghoul"), "уникальный монстр вынут из мешка")


func test_return_monster_to_bag() -> void:
	_board.return_monster_to_bag("ghoul")
	assert_true(_gs.monster_bag.has("ghoul"))
	_board.return_monster_to_bag("cultist")
	assert_false(_gs.monster_bag.has("cultist"), "культист не дублируется")


func test_remove_monster_at_active_returns_to_bag() -> void:
	_at("loc")
	_gs.monsters = {"loc": [{"id": "ghoul", "health": 2}]}
	_board.remove_monster_at_active(true, 1)
	assert_false(_gs.monsters.has("loc"), "клетка очищена")
	assert_true(_gs.monster_bag.has("ghoul"), "id вернулся в мешок")


func test_remove_monster_at_active_multiple() -> void:
	_at("loc")
	_gs.monsters = {
		"loc": [{"id": "a", "health": 1}, {"id": "b", "health": 1}, {"id": "c", "health": 1}]
	}
	_board.remove_monster_at_active(false, 2)
	assert_eq((_gs.monsters["loc"] as Array).size(), 1, "снято 2 из 3")


func test_damage_monster_reduces_health() -> void:
	_at("loc")
	_gs.monsters = {"loc": [{"id": "ghoul", "health": 3}]}
	_board.damage_monster_at_active(1)
	assert_eq(int(_gs.monsters["loc"][0]["health"]), 2)


func test_damage_monster_magical_resist_halves() -> void:
	# Урон damageMonster — магический. colour_out_of_space = magical-резист → вдвое.
	_at("loc")
	_gs.monsters = {"loc": [{"id": "colour_out_of_space", "health": 5}]}
	_board.damage_monster_at_active(4)
	assert_eq(int(_gs.monsters["loc"][0]["health"]), 3, "magical-резист: 4 → 2, 5 − 2 = 3")


func test_damage_monster_physical_resist_ignored_by_magic() -> void:
	# ghost = physical-резист, но урон заклинаний МАГИЧЕСКИЙ → проходит полностью.
	_at("loc")
	_gs.monsters = {"loc": [{"id": "ghost", "health": 5}]}
	_board.damage_monster_at_active(4)
	assert_eq(int(_gs.monsters["loc"][0]["health"]), 1, "магия обходит phys-резист: 5 − 4 = 1")


func test_damage_monster_lethal_removes() -> void:
	_at("loc")
	_gs.monsters = {"loc": [{"id": "ghoul", "health": 2}]}
	_board.damage_monster_at_active(5)
	assert_false(_gs.monsters.has("loc"), "смертельный урон снимает монстра")


func test_damage_monster_ref_hits_exact_instance() -> void:
	# chosenMonster: ref "loc#idx" — бьём именно выбранного, а не первого попавшегося.
	_gs.monsters = {
		"a": [{"id": "ghoul", "health": 3}],
		"b": [{"id": "ghoul", "health": 3}, {"id": "ghoul", "health": 3}],
	}
	_board.damage_monster_ref("b#1", 2)
	assert_eq(int(_gs.monsters["a"][0]["health"]), 3, "чужая локация не задета")
	assert_eq(int(_gs.monsters["b"][0]["health"]), 3, "сосед по локации не задет")
	assert_eq(int(_gs.monsters["b"][1]["health"]), 1, "урон ушёл выбранному")


func test_damage_monster_ref_lethal_returns_to_bag() -> void:
	_gs.monsters = {"b": [{"id": "ghoul", "health": 1}]}
	_board.damage_monster_ref("b#0", 3)
	assert_false(_gs.monsters.has("b"), "локация очищена")
	assert_true(_gs.monster_bag.has("ghoul"), "id вернулся в мешок")


func test_damage_monster_ref_bad_ref_is_noop() -> void:
	_gs.monsters = {"b": [{"id": "ghoul", "health": 3}]}
	_board.damage_monster_ref("b#7", 3)
	_board.damage_monster_ref("мусор", 3)
	assert_eq(int(_gs.monsters["b"][0]["health"]), 3, "битый ref ничего не ломает")


func test_damage_monsters_at_hits_everyone_on_space() -> void:
	# chosenSpace (Карантин/Рейд): достаётся каждому монстру локации, павшие снимаются.
	_gs.monsters = {
		"a": [{"id": "ghoul", "health": 2}, {"id": "ghoul", "health": 5}],
		"b": [{"id": "ghoul", "health": 2}],
	}
	_board.damage_monsters_at("a", 3)
	assert_eq((_gs.monsters["a"] as Array).size(), 1, "слабый пал, живучий остался")
	assert_eq(int(_gs.monsters["a"][0]["health"]), 2, "живучему 5 − 3 = 2")
	assert_eq(int(_gs.monsters["b"][0]["health"]), 2, "соседняя локация не задета")


func test_space_choices_lists_only_occupied_spaces() -> void:
	_gs.monsters = {"a": [{"id": "ghoul", "health": 2}, {"id": "ghoul", "health": 2}]}
	var spaces: Array = _board.space_choices()
	assert_eq(spaces.size(), 1, "предлагаем только локации с монстрами")
	assert_eq(String((spaces[0] as Dictionary)["ref"]), "a")
	assert_eq(int((spaces[0] as Dictionary)["count"]), 2, "счётчик монстров в опции")


func test_monster_choices_carry_location() -> void:
	_gs.monsters = {"a": [{"id": "ghoul", "health": 1}]}
	var opt: Dictionary = (_board.monster_choices() as Array)[0]
	assert_eq(String(opt["ref"]), "a#0")
	assert_eq(String(opt["loc"]), "a", "в опции есть локация — карты бьют по всему полю")
	assert_eq(int(opt["health"]), 1, "текущее здоровье, а не только стойкость")


func test_remove_monsters_by_toughness_selective() -> void:
	# child_of_the_goat t=1, avian_thrall t=3 (balance_pc=1). Порог ≤2: снять слабого.
	_at("loc")
	_gs.monsters = {
		"loc": [{"id": "child_of_the_goat", "health": 1}, {"id": "avian_thrall", "health": 3}]
	}
	_board.remove_monsters_by_toughness(false, 2)
	var remaining: Array = _gs.monsters.get("loc", [])
	assert_eq(remaining.size(), 1, "слабый (t1) снят, сильный (t3) остался")
	assert_eq(String((remaining[0] as Dictionary)["id"]), "avian_thrall")
	assert_true(_gs.monster_bag.has("child_of_the_goat"), "снятый вернулся в мешок")


func test_remove_monsters_by_toughness_zero_noop() -> void:
	_at("loc")
	_gs.monsters = {"loc": [{"id": "child_of_the_goat"}]}
	_board.remove_monsters_by_toughness(false, 0)
	assert_eq((_gs.monsters["loc"] as Array).size(), 1, "порог < 1 → no-op")


# ── Улики / жетоны / слухи ────────────────────────────────────────────────────


func test_place_clue_single_candidate() -> void:
	_gs.locations = [{"id": "only"}]
	_gs.clue_deck = ["only"]  # жетон улики привязан к ключу-локации (см. place_clue)
	_board.place_clue()
	assert_true((_gs.entities["only"] as Array).has("clue"))


func test_place_clue_skips_location_with_clue() -> void:
	_gs.locations = [{"id": "taken"}, {"id": "free"}]
	_gs.entities = {"taken": ["clue"]}
	_gs.clue_deck = ["taken", "free"]  # ключи обеих локаций ещё в колоде
	_board.place_clue()
	assert_true((_gs.entities["free"] as Array).has("clue"), "улика на свободной локации")
	assert_eq((_gs.entities["taken"] as Array).size(), 1, "вторая улика не кладётся (≤1)")


func test_place_eldritch_token_single_candidate() -> void:
	_gs.locations = [{"id": "only"}]
	_board.place_eldritch_token()
	assert_true((_gs.entities["only"] as Array).has("eldritch_token"))


func test_place_rumor_single_candidate() -> void:
	_gs.locations = [{"id": "only"}]
	_board.place_rumor()
	assert_true((_gs.entities["only"] as Array).has("rumor"))


func test_discard_all_clues() -> void:
	_gs.entities = {"a": ["clue"], "b": ["clue", "eldritch_token"], "c": ["monster"]}
	var removed: int = _board.discard_all_clues()
	assert_eq(removed, 2, "снято 2 улики")
	assert_false(_gs.entities.has("a"), "локация только с уликой — очищена")
	assert_eq(_gs.entities["b"], ["eldritch_token"], "у b остался только жетон")
	assert_eq(_gs.entities["c"], ["monster"], "монстр не тронут")


func test_discard_nearest_clue_bfs_from_own_space() -> void:
	# Граф a—b—c—d: сыщик на a; улики на c и d → снимается ближайшая (c), d цела.
	_gs.locations = [
		{"id": "a", "connections": [{"to": "b"}]},
		{"id": "b", "connections": [{"to": "a"}, {"to": "c"}]},
		{"id": "c", "connections": [{"to": "b"}, {"to": "d"}]},
		{"id": "d", "connections": [{"to": "c"}]},
	]
	_gs.entities = {"c": ["clue", "monster"], "d": ["clue"]}
	assert_eq(_board.discard_nearest_clue("a"), "c", "ближайшая по дорогам — c")
	assert_eq(_gs.entities["c"], ["monster"], "с c снята одна улика, монстр остался")
	assert_eq(_gs.entities["d"], ["clue"], "дальняя не тронута")
	# Своя клетка — расстояние 0: улика под ногами уходит первой.
	_gs.entities["a"] = ["clue"]
	assert_eq(_board.discard_nearest_clue("a"), "a")
	assert_false(_gs.entities.has("a"), "локация только с уликой — очищена")


func test_discard_nearest_clue_none_on_board() -> void:
	_gs.locations = [{"id": "a", "connections": []}]
	_gs.entities = {"a": ["monster"]}
	assert_eq(_board.discard_nearest_clue("a"), "", "улик нет — ничего не снято")
	assert_eq(_gs.entities["a"], ["monster"])


func test_discard_all_gates() -> void:
	_gs.gates = {"g1": "green", "g2": "red", "g3": "blue"}
	var removed: int = _board.discard_all_gates()
	assert_eq(removed, 3, "убрано 3 врат")
	assert_eq((_gs.gates as Dictionary).size(), 0, "врат не осталось")


# ── Наплыв ────────────────────────────────────────────────────────────────────


func test_monster_surge_spawns_per_matching_gate() -> void:
	_gs.omens_step = 0  # green
	_gs.gates = {"gA": "green"}
	_gs.monster_surge = 2
	_gs.monster_bag = ["cultist"]
	_board.monster_surge()
	assert_eq((_gs.monsters["gA"] as Array).size(), 2, "из врат цвета омена — surge монстров")


func test_monster_surge_opens_new_gate_when_none_match() -> void:
	_gs.omens_step = 0  # green
	_gs.gates = {"gA": "red"}  # нет зелёных
	_gs.monster_bag = ["cultist"]
	_gs.locations = [{"id": "gB", "gateColor": "blue"}]
	_gs.gate_deck = ["gB"]  # жетон врат тянется из колоды
	_board.monster_surge()
	assert_true(_gs.gates.has("gB"), "при отсутствии врат цвета омена — открываются новые")


# ── Стартовая раскладка ───────────────────────────────────────────────────────


func test_setup_board_lays_out_gates_clues_and_surge() -> void:
	_gs.locations = [{"id": "g1", "gateColor": "green"}, {"id": "l1"}, {"id": "l2"}, {"id": "l3"}]
	_gs.clue_deck = ["l1", "l2", "l3"]  # ключи улик (в бою их сеет GameState)
	_board.setup_board(2)  # ref(2): gates 1, clues 2, surge 1
	assert_eq(_gs.gates.size(), 1, "открыты врата по таблице")
	assert_eq(_gs.monster_surge, 1, "Наплыв из таблицы")
	assert_eq(_count_marker("clue"), 2, "разложены улики по таблице")
	assert_false(_gs.monster_bag.is_empty(), "мешок наполнен не-эпическими монстрами")
	assert_eq(_gs.shop_filled, 1, "витрина магазина наполнена")


func test_setup_board_non_host_is_noop() -> void:
	_gs.host = false
	_gs.locations = [{"id": "g1", "gateColor": "green"}]
	_board.setup_board(2)
	assert_eq(_gs.gates.size(), 0, "не-хост раскладку не делает")


func test_monster_choices_lists_ref_name_toughness() -> void:
	_gs._campaign.balance_pc = 1
	_gs.monsters = {"loc": [{"id": "avian_thrall", "health": 3}]}  # toughness 3
	var ch: Array = _board.monster_choices()
	assert_eq(ch.size(), 1)
	assert_eq(String((ch[0] as Dictionary).get("ref", "")), "loc#0", "ref = локация#индекс")
	assert_eq(int((ch[0] as Dictionary).get("toughness", 0)), 3, "стойкость с учётом партии")


func test_discard_monster_ref_removes_instance_and_bags_id() -> void:
	_gs.monsters = {"loc": [{"id": "avian_thrall"}, {"id": "byakhee"}]}
	_board.discard_monster_ref("loc#0")
	assert_eq((_gs.monsters["loc"] as Array).size(), 1, "снят один экземпляр")
	assert_eq(
		String((_gs.monsters["loc"][0] as Dictionary).get("id", "")), "byakhee", "остался второй"
	)
	assert_true((_gs.monster_bag as Array).has("avian_thrall"), "id вернулся в мешок")


func test_discard_monster_ref_bad_ref_noop() -> void:
	_gs.monsters = {"loc": [{"id": "avian_thrall"}]}
	_board.discard_monster_ref("loc#9")  # индекс вне диапазона
	assert_eq((_gs.monsters["loc"] as Array).size(), 1, "плохой ref — ничего не снято")


func test_reference_amount_scales_with_party_size() -> void:
	_gs._campaign.balance_pc = 4  # ref(4): gates 1, clues 3, surge 2
	assert_eq(_board.reference_amount("clues"), 3, "улик по карте баланса на 4")
	assert_eq(_board.reference_amount("gates"), 1, "врат по карте баланса на 4")
	_gs._campaign.balance_pc = 7  # ref(7): clues 4
	assert_eq(_board.reference_amount("clues"), 4, "улик по карте баланса на 7")
	assert_eq(_board.reference_amount("missing"), 1, "неизвестное поле → 1")


# ── eachMonster: снятие по стойкости ПО ВСЕМУ ПОЛЮ ────────────────────────────


func test_remove_by_toughness_everywhere_clears_all_locations() -> void:
	# «Сбросьте всех монстров со стойкостью 1 с игрового поля» — цель eachMonster.
	# Отличие от версии «на моей клетке»: активный игрок не при чём, чистится всё.
	_at("loc")
	_gs.monsters = {
		"a": [{"id": "ghoul", "health": 1}, {"id": "shoggoth", "health": 4}],
		"b": [{"id": "maniac", "health": 1}],
		"c": [{"id": "zombie", "health": 2}],
	}
	_board.remove_monsters_by_toughness_everywhere(false, 1)
	assert_eq((_gs.monsters["a"] as Array).size(), 1, "на a остался только живучий")
	assert_eq(String(_gs.monsters["a"][0]["id"]), "shoggoth", "выжил именно шоггот")
	assert_false(_gs.monsters.has("b"), "клетка со слабым монстром очищена")
	assert_eq((_gs.monsters["c"] as Array).size(), 1, "стойкость 2 > порога — не тронут")
	assert_true(_gs.monster_bag.has("ghoul"), "снятые id вернулись в мешок")
	assert_true(_gs.monster_bag.has("maniac"), "снятые id вернулись в мешок")


func test_remove_by_toughness_everywhere_ignores_active_location() -> void:
	# Активный игрок стоит на пустой клетке — область всё равно всё поле.
	_at("empty")
	_gs.monsters = {"far": [{"id": "ghoul", "health": 1}]}
	_board.remove_monsters_by_toughness_everywhere(true, 1)
	assert_false(_gs.monsters.has("far"), "снято на чужой клетке")


func test_remove_by_toughness_everywhere_zero_threshold_is_noop() -> void:
	# max_t < 1 — защита от узла без maxToughness, распарсенного в 0: не сносим поле.
	_gs.monsters = {"a": [{"id": "ghoul", "health": 1}]}
	_board.remove_monsters_by_toughness_everywhere(false, 0)
	assert_eq((_gs.monsters["a"] as Array).size(), 1, "порог 0 ничего не снимает")
