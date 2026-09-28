extends GutTest

## Юнит-тесты прогона программ актива (scripts/core/game/asset_action_flow.gd).
## Покрытие:
##   • выдача карты с onGain: обычный актив в руку, услуга срабатывает и сбрасывается;
##   • интерактивный выбор МОНСТРА (target chosenMonster) — пауза, модалка, ref;
##   • интерактивный выбор ЛОКАЦИИ (target chosenSpace) — урон всем монстрам там;
##   • очередь выдач: вторая карта ждёт, пока игрок ответит по первой;
##   • действие актива: удержание хода, оплата (истощение) и гварды can_play.
##
## Монстры на поле подменяются заглушкой _board: движку важны только варианты
## выбора, а сам урон наносит BoardState (см. test_board_state.gd).

const _DERRINGER: String = "18_derringer"  # обычный актив (без onGain)
const _QUARANTINE: String = "agency_quarantine"  # услуга: onGain → damageMonster chosenSpace
const _ASSASSINATION: String = "assassination"  # услуга: onGain → damageMonster chosenMonster
const _MONSTER_HUNTER: String = "monster_hunter"  # действие: damageMonster chosenMonster
const _CHARTER: String = "charter_flight"  # услуга: onGain → move на 2 локации

var _gs: MockGameState
var _flow: AssetActionFlow


# Заглушка BoardState: варианты выбора монстра и локации.
class StubBoard:
	extends RefCounted
	var monsters: Array = []
	var spaces: Array = []

	func monster_choices() -> Array:
		return monsters

	func space_choices() -> Array:
		return spaces


# Заглушка TargetResolver: «прочие сыщики» для chosenInvestigator.
class StubTarget:
	extends RefCounted

	func other_pids(_exclude: String) -> Array:
		return []


# Заглушка CheckFlow: программа с test поднимает видимую проверку.
class StubCheck:
	extends RefCounted
	var started: Dictionary = {}

	func start(owner: String, pid: String, skill: String, _mod: int, _ctx: String) -> void:
		started = {"owner": owner, "pid": pid, "skill": skill}

	func clear() -> void:
		started = {}


# Заглушка PhaseController: завершение действия освобождает ход.
class StubPhase:
	extends RefCounted
	var released: Array = []

	func release_asset_turn(pid: String) -> void:
		released.append(pid)


class MockGameState:
	extends Node
	var players: Dictionary = {}
	var board_effects: Array = []
	var host: bool = true
	var pending_check: Dictionary = {}
	var mythos_decision: Dictionary = {}
	var asset_deck: Array = []  # запасы: выданная карта обязана уйти отсюда
	var shop_reserve: Array = []
	var locations: Array = []  # граф для move (Чартерный рейс)
	var _board := StubBoard.new()
	var _target := StubTarget.new()
	var _check := StubCheck.new()
	var _phase := StubPhase.new()

	func is_host() -> bool:
		return host

	# Граф локаций из тестового списка — пересобирается на каждое чтение, чтобы
	# `_gs.locations = [...]` в тесте подхватывалось без setup-хуков.
	var map: LocationGraph:
		get:
			return LocationGraph.new(locations)

	func name_of(pid: String) -> String:
		return pid

	func apply_board_effect(node: Dictionary) -> void:
		board_effects.append(node)

	# Лента исходов (die_roll / дельты сыщика) — копим, чтобы проверять видимость броска.
	var feed: Array = []

	func announce_action(pid: String, action_id: String, params: Dictionary = {}) -> void:
		feed.append({"pid": pid, "id": action_id, "params": params})

	func _refill_shop_reserve(bought: Array) -> void:
		for b_v: Variant in bought:
			shop_reserve.erase(String(b_v))

	func broadcast_sync() -> void:
		pass

	func emit_changed() -> void:
		pass


func before_each() -> void:
	_gs = autofree(MockGameState.new())
	_flow = AssetActionFlow.new(_gs)


func _add_player(pid: String) -> void:
	_gs.players[pid] = {
		"user_id": pid,
		"investigator": "Charlie Kane",
		"hp": 5,
		"hp_max": 7,
		"sanity": 5,
		"sanity_max": 6,
		"clues": 0,
		"items": [],
		"conditions": [],
		"location": "arkham",
	}


func _monster(ref: String, loc: String) -> Dictionary:
	return {"ref": ref, "name": "MON", "toughness": 2, "health": 2, "loc": loc, "loc_name": loc}


# Первый board-эффект с указанным глаголом ({} — нет такого).
func _board_node(verb: String) -> Dictionary:
	for i in range(_gs.board_effects.size()):
		var n: Dictionary = _gs.board_effects[i]
		if String(n.get("do", "")) == verb:
			return n
	return {}


# ── Выдача карты (onGain) ─────────────────────────────────────────────────────


func test_grant_normal_asset_added_to_items() -> void:
	_add_player("p")
	_flow.grant("p", _DERRINGER)
	var items: Array = _gs.players["p"]["items"]
	assert_eq(items.size(), 1, "обычный актив попадает в инвентарь")
	assert_eq(String((items[0] as Dictionary)["id"]), _DERRINGER)
	assert_false(bool((items[0] as Dictionary)["exhausted"]), "выдан неистощённым")
	assert_true(_gs.mythos_decision.is_empty(), "без интерактива модалку не поднимаем")


func test_grant_asset_non_host_is_noop() -> void:
	_gs.host = false
	_add_player("p")
	_flow.grant("p", _DERRINGER)
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "не-хост ничего не выдаёт")


func test_grant_unknown_asset_is_noop() -> void:
	_add_player("p")
	_flow.grant("p", "no_such_asset")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "неизвестный id игнорируется")


func test_grant_takes_card_out_of_supply() -> void:
	# Сброс активов ВЫВОДИТСЯ (поддержанные минус колода, витрина и руки). Если
	# выданная карта осталась бы в колоде, в сбросе она никогда бы не появилась.
	_add_player("p")
	_gs.asset_deck = [_DERRINGER, _QUARANTINE]
	_gs.shop_reserve = [_QUARANTINE]
	_gs._board.spaces = [{"ref": "arkham", "name": "arkham", "count": 1}]
	_flow.grant("p", _QUARANTINE)
	assert_false(_gs.asset_deck.has(_QUARANTINE), "услуга ушла из колоды")
	assert_false(_gs.shop_reserve.has(_QUARANTINE), "и с витрины")
	assert_true(_gs.asset_deck.has(_DERRINGER), "остальную колоду не трогаем")


func test_grant_without_ongain_also_leaves_deck() -> void:
	_add_player("p")
	_gs.asset_deck = [_DERRINGER]
	_flow.grant("p", _DERRINGER)
	assert_false(_gs.asset_deck.has(_DERRINGER), "карта в руке не может лежать и в колоде")


# ── Выбор монстра (chosenMonster) ─────────────────────────────────────────────


func test_grant_service_asks_for_monster() -> void:
	_add_player("p")
	_gs._board.monsters = [_monster("arkham#0", "arkham"), _monster("rome#1", "rome")]
	_flow.grant("p", _ASSASSINATION)
	var d: Dictionary = _gs.mythos_decision
	assert_true(bool(d.get("active", false)), "прогон встал на выборе монстра")
	assert_eq(String(d.get("kind", "")), "monster")
	assert_eq(String(d.get("driver", "")), "asset", "будить надо прогон актива, не мифы")
	assert_eq((d.get("options", []) as Array).size(), 2, "оба монстра предложены")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "карта ещё не отработала")


func test_chosen_monster_reaches_board_by_ref() -> void:
	_add_player("p")
	_gs._board.monsters = [_monster("arkham#0", "arkham"), _monster("rome#1", "rome")]
	_flow.grant("p", _ASSASSINATION)
	_flow.resolve_decision("p", 1)  # второй монстр
	var node: Dictionary = _board_node("damageMonster")
	assert_eq(String(node.get("_target_monster", "")), "rome#1", "урон уходит выбранному монстру")
	assert_eq(int(node.get("amount", 0)), 2, "урон карты сохранён")
	assert_true(_gs.mythos_decision.is_empty(), "модалка закрыта после ответа")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "услуга сброшена, в руку не идёт")


func test_service_without_monsters_still_consumed() -> void:
	_add_player("p")
	_flow.grant("p", _ASSASSINATION)  # монстров на поле нет
	assert_true(_gs.mythos_decision.is_empty(), "выбирать не из кого — вопрос не задаём")
	assert_eq(_board_node("damageMonster"), {}, "урон никуда не уходит")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "карта всё равно сброшена")


# ── Выбор локации (chosenSpace) ───────────────────────────────────────────────


func test_quarantine_asks_for_space() -> void:
	_add_player("p")
	_gs._board.spaces = [{"ref": "arkham", "name": "arkham", "count": 2}]
	_flow.grant("p", _QUARANTINE)
	assert_eq(String(_gs.mythos_decision.get("kind", "")), "space", "карантин выбирает локацию")
	_flow.resolve_decision("p", 0)
	var node: Dictionary = _board_node("damageMonster")
	assert_eq(String(node.get("_target_space", "")), "arkham", "локация уехала на доску")
	assert_eq(int(node.get("amount", 0)), 4, "урон карантина — 4")


# ── Выбор точки назначения (move) ─────────────────────────────────────────────


# Цепочка arkham — b — c — d: с 2 шагами достижимы b и c, но не d.
func _chain_locations() -> Array:
	return [
		{"id": "arkham", "name": "L_ARKHAM", "connections": [{"to": "b", "type": "train"}]},
		{
			"id": "b",
			"name": "L_B",
			"connections": [{"to": "arkham", "type": "train"}, {"to": "c", "type": "ship"}],
		},
		{
			"id": "c",
			"name": "L_C",
			"connections": [{"to": "b", "type": "ship"}, {"to": "d", "type": "train"}]
		},
		{"id": "d", "name": "L_D", "connections": [{"to": "c", "type": "train"}]},
	]


func test_charter_flight_offers_destinations_and_moves() -> void:
	_add_player("p")
	_gs.locations = _chain_locations()
	_flow.grant("p", _CHARTER)
	var d: Dictionary = _gs.mythos_decision
	assert_eq(String(d.get("kind", "")), "destination", "рейс спрашивает, куда лететь")
	var refs: Array = []
	for o_v: Variant in d.get("options", []):
		refs.append(String((o_v as Dictionary)["ref"]))
	assert_eq(refs, ["b", "c"], "2 шага: соседняя и следующая за ней, но не дальше")
	_flow.resolve_decision("p", 1)
	assert_eq(String(_gs.players["p"]["location"]), "c", "сыщик переехал в выбранную локацию")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "услуга сброшена")


func test_move_without_graph_is_still_noop() -> void:
	# Мифы и встречи зовут прогон без графа локаций — там move остаётся заглушкой,
	# а не молча роняет сыщика в пустоту.
	_add_player("p")
	_flow.grant("p", _CHARTER)
	assert_true(_gs.mythos_decision.is_empty(), "идти некуда — вопроса нет")
	assert_eq(String(_gs.players["p"]["location"]), "arkham", "сыщик остался на месте")


# ── Очередь выдач ─────────────────────────────────────────────────────────────


func test_second_grant_waits_for_first_decision() -> void:
	_add_player("p")
	_gs._board.monsters = [_monster("arkham#0", "arkham")]
	_gs._board.spaces = [{"ref": "arkham", "name": "arkham", "count": 1}]
	_flow.grant("p", _ASSASSINATION)
	_flow.grant("p", _QUARANTINE)
	assert_eq(String(_gs.mythos_decision.get("kind", "")), "monster", "первой спрашиваем убийство")
	_flow.resolve_decision("p", 0)
	assert_eq(String(_gs.mythos_decision.get("kind", "")), "space", "очередь дошла до карантина")
	_flow.resolve_decision("p", 0)
	assert_true(_gs.mythos_decision.is_empty(), "очередь пуста — модалки нет")
	assert_eq(_gs.board_effects.size(), 2, "обе услуги применились")


# ── Действие актива ───────────────────────────────────────────────────────────


func test_action_holds_turn_until_monster_picked() -> void:
	_add_player("p")
	_gs._board.monsters = [_monster("arkham#0", "arkham")]
	(_gs.players["p"]["items"] as Array).append({"id": _MONSTER_HUNTER, "exhausted": false})
	assert_eq(_flow.play("p", 0), AssetActionFlow.PLAY_WAITING, "ход держим до выбора")
	assert_eq(_gs._phase.released.size(), 0, "ход ещё не отпущен")
	_flow.resolve_decision("p", 0)
	assert_eq(String(_board_node("damageMonster").get("_target_monster", "")), "arkham#0")
	assert_eq(_gs._phase.released, ["p"], "после ответа ход отпущен")
	var card: Dictionary = (_gs.players["p"]["items"] as Array)[0]
	assert_true(bool(card.get("exhausted", false)), "действие истощило карту")


func test_cannot_play_monster_action_without_monsters() -> void:
	_add_player("p")
	(_gs.players["p"]["items"] as Array).append({"id": _MONSTER_HUNTER, "exhausted": false})
	assert_false(_flow.can_play("p", 0), "монстров нет — карта не играется")
	assert_eq(_flow.play("p", 0), AssetActionFlow.PLAY_INVALID, "действие не тратится")


func test_cannot_play_exhausted_card() -> void:
	_add_player("p")
	_gs._board.monsters = [_monster("arkham#0", "arkham")]
	(_gs.players["p"]["items"] as Array).append({"id": _MONSTER_HUNTER, "exhausted": true})
	assert_false(_flow.can_play("p", 0), "истощённую карту играть нельзя")


# ── Лента исходов: скрытый бросок виден игроку ────────────────────────────────


func test_die_roll_outcome_announced_to_feed() -> void:
	# dieRoll тихий (без модалки), поэтому выпавшая грань уходит в ленту как die_roll
	# (запись self:true — видна и самому), а прирост улики — как got_clue.
	_add_player("p")
	var found_roll: bool = false
	var found_clue: bool = false
	for _i in range(60):  # d6 случайный — крутим, пока не выпадут 5–6 (+улика)
		_gs.feed = []
		_gs.players["p"]["items"] = [{"id": "research_student", "exhausted": false}]
		_gs.players["p"]["actions_left"] = 2
		_gs.players["p"]["actions_used"] = []
		_flow.play("p", 0)
		for e_v: Variant in _gs.feed:
			var e: Dictionary = e_v
			if String(e["id"]) == "die_roll":
				found_roll = true
				var v: int = int(String(e["params"]["value"]))
				assert_true(v >= 1 and v <= 6, "грань d6 в ленте")
			if String(e["id"]) == "got_clue":
				found_clue = true
		if found_clue:
			break
	assert_true(found_roll, "бросок объявлен в ленту")
	assert_true(found_clue, "прирост улики объявлен в ленту")


# ── Событийные триггеры (effect.triggered, on:<событие>) ─────────────────────


func test_triggered_rest_instant_effect() -> void:
	# Библия короля Якова: on:rest → +1 рассудок; карта не истощается (триггер — не действие).
	_add_player("p")
	_gs.players["p"]["items"] = [{"id": "king_james_bible", "exhausted": false}]
	_gs.players["p"]["sanity"] = 3
	assert_true(_flow.fire_triggered("p", "rest"), "карта поставлена")
	assert_eq(int(_gs.players["p"]["sanity"]), 4, "+1 рассудок")
	assert_false(bool(_gs.players["p"]["items"][0].get("exhausted", false)), "не истощена")
	assert_false(bool(_gs.players["p"].get("asset_acting", false)), "мгновенно — ход не держим")


func test_triggered_ignores_other_events() -> void:
	_add_player("p")
	_gs.players["p"]["items"] = [{"id": "king_james_bible", "exhausted": false}]
	assert_false(_flow.fire_triggered("p", "focus"), "у Библии нет on:focus")


func test_triggered_with_check_holds_turn_until_resolved() -> void:
	# Тайный фолиант: on:rest → проверка Знания → gainSpell. Прогон встаёт на проверке,
	# ход держится (asset_acting); ответ → заклинание (board) и ход отпущен.
	_add_player("p")
	_gs.players["p"]["items"] = [{"id": "arcane_tome", "exhausted": false}]
	_flow.fire_triggered("p", "rest")
	assert_eq(String(_gs._check.started.get("skill", "")), "lore", "проверка Знания стартовала")
	assert_true(bool(_gs.players["p"].get("asset_acting", false)), "ход удержан")
	assert_true(_flow.is_busy("p"))
	_flow.resolve_check("p", String(_gs.pending_check.get("path", "")), true)
	var verbs: Array = []
	for n_v: Variant in _gs.board_effects:
		verbs.append(String((n_v as Dictionary).get("do", "")))
	assert_true(verbs.has("gainSpell"), "успех → заклинание")
	assert_eq(_gs._phase.released, ["p"], "ход отпущен")
	assert_false(_flow.is_busy("p"))


func test_optional_node_becomes_skip_choice_and_discard_self_cost() -> void:
	# Свежие фрукты: «можете сбросить карту, чтобы +1 здоровье» (optional + discardSelf)
	# и всегда +1 рассудок. Модалка: ветка / пропустить.
	_add_player("p")
	_gs.players["p"]["items"] = [{"id": "fresh_fruit", "exhausted": false}]
	_gs.players["p"]["hp"] = 3
	_gs.players["p"]["sanity"] = 3
	_flow.fire_triggered("p", "rest")
	var md: Dictionary = _gs.mythos_decision
	assert_eq(String(md.get("kind", "")), "choice", "выбор: сделать / пропустить")
	assert_eq((md.get("options", []) as Array).size(), 2)
	# Пропустить → здоровье не тронуто, карта на месте, рассудок +1.
	_flow.resolve_decision("p", 1)
	assert_eq(int(_gs.players["p"]["hp"]), 3)
	assert_eq(int(_gs.players["p"]["sanity"]), 4)
	assert_eq((_gs.players["p"]["items"] as Array).size(), 1, "карта не сброшена")
	# Снова отдых: взять ветку → +1 здоровье и карта сброшена как цена.
	_gs.mythos_decision = {}
	_flow.fire_triggered("p", "rest")
	_flow.resolve_decision("p", 0)
	assert_eq(int(_gs.players["p"]["hp"]), 4, "+1 здоровье")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "фрукты съедены (discardSelf)")


func test_gain_asset_from_reserve_lets_player_pick() -> void:
	# Форточник: 5–6 → взять карту с витрины по выбору. Куб случайный — крутим до 5–6.
	_add_player("p")
	_gs.shop_reserve = ["axe", "lantern"]
	_gs.asset_deck = ["axe", "lantern", "dynamite"]
	var picked: bool = false
	for _i in range(80):
		_gs.players["p"]["items"] = [{"id": "cat_burglar", "exhausted": false}]
		_gs.players["p"]["actions_left"] = 2
		_gs.mythos_decision = {}
		_gs.shop_reserve = ["axe", "lantern"]
		_flow.play("p", 0)
		if String(_gs.mythos_decision.get("kind", "")) == "asset":
			var opts: Array = _gs.mythos_decision.get("options", [])
			assert_eq(opts.size(), 2, "варианты — вся витрина")
			_flow.resolve_decision("p", 1)  # lantern
			var ids: Array = []
			for it_v: Variant in _gs.players["p"]["items"]:
				ids.append(AssetCatalog.entry_id(it_v))
			assert_true(ids.has("lantern"), "фонарь в руке")
			assert_false((_gs.shop_reserve as Array).has("lantern"), "с витрины снят")
			assert_false((_gs.asset_deck as Array).has("lantern"), "и из колоды выбыл")
			picked = true
			break
	assert_true(picked, "за 80 бросков 5–6 не выпало — крайне маловероятно")
