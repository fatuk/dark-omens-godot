## gainAsset в выборе встречи («Обвал лесов»): подписи веток говорят, ОТКУДА и КАКОЙ
## актив (витрина / случайная из колоды + трейт), выбор с витрины фильтрует карты по
## трейту, а без подходящих — откатывается к случайной из колоды.
extends GutTest

const EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

const ITEM := "38_revolver"
const ITEM_2 := "45_automatic"
const ALLY := "arcane_scholar"


func _player() -> Dictionary:
	return {"user_id": "p", "hp": 5, "sanity": 5, "clues": 0, "conditions": [], "items": []}


func _t(key: String) -> String:
	return TranslationServer.translate(key)


func test_labels_name_source_and_trait() -> void:
	var reserve: String = EffectManifest.describe(
		{"do": "gainAsset", "from": "reserve", "trait": "item"}
	)
	var deck: String = EffectManifest.describe({"do": "gainAsset", "trait": "item"})
	assert_eq(reserve, _t("VERB_GAIN_ASSET_RESERVE").replace("{trait}", _t("TRAIT_ITEM")))
	assert_eq(deck, _t("VERB_GAIN_ASSET_DECK").replace("{trait}", _t("TRAIT_ITEM")))
	assert_ne(reserve, deck, "две ветки выбора больше не читаются одинаково")
	assert_eq(
		EffectManifest.describe({"do": "gainAsset"}),
		_t("VERB_GAIN_ASSET_DECK").replace("{trait}", _t("ASSET_ANY")),
		"без трейта — «Актив»"
	)


func test_with_trait_is_strict() -> void:
	assert_eq(AssetCatalog.with_trait([ALLY, ITEM, ITEM_2], "item"), [ITEM, ITEM_2])
	assert_eq(AssetCatalog.with_trait([ALLY], "item"), [], "без отката ко всему списку")
	assert_eq(AssetCatalog.with_trait([ALLY, ITEM], ""), [ALLY, ITEM], "пустой трейт — все")


func test_reserve_pick_offers_only_matching_trait() -> void:
	var flow: Dictionary = {"interactive": true, "decisions": {}, "rolls": {}, "pending": {}}
	var res: Dictionary = EffectRunner.run(
		[{"do": "gainAsset", "from": "reserve", "trait": "item"}],
		_player(),
		{"reserve": [ALLY, ITEM, ITEM_2]},
		flow
	)
	var pending: Dictionary = res.get("pending", {})
	assert_eq(String(pending.get("kind", "")), "asset", "выбор карты с витрины")
	var refs: Array = []
	for o_v: Variant in pending.get("options", []):
		refs.append(String((o_v as Dictionary).get("ref", "")))
	assert_eq(refs, [ITEM, ITEM_2], "союзник с витрины не предлагается")


func test_reserve_pick_takes_card_and_marks_reserve() -> void:
	var p: Dictionary = _player()
	var flow: Dictionary = {"interactive": true, "decisions": {"0": ITEM_2}, "rolls": {}}
	var res: Dictionary = EffectRunner.run(
		[{"do": "gainAsset", "from": "reserve", "trait": "item"}],
		p,
		{"reserve": [ITEM, ITEM_2]},
		flow
	)
	assert_eq((p["items"] as Array).size(), 1)
	assert_eq(String((p["items"][0] as Dictionary).get("id", "")), ITEM_2, "взята выбранная")
	assert_has(res.get("board", []), {"do": "takeFromReserve", "id": ITEM_2}, "снять с витрины")


func test_no_matching_reserve_card_falls_back_to_deck() -> void:
	var p: Dictionary = _player()
	var flow: Dictionary = {"interactive": true, "decisions": {}, "rolls": {}, "pending": {}}
	var res: Dictionary = EffectRunner.run(
		[{"do": "gainAsset", "from": "reserve", "trait": "item"}], p, {"reserve": [ALLY]}, flow
	)
	assert_true((res.get("pending", {}) as Dictionary).is_empty(), "выбирать нечего")
	assert_eq((p["items"] as Array).size(), 1, "выдана случайная карта из колоды")
	assert_ne(String((p["items"][0] as Dictionary).get("id", "")), ALLY, "не союзник с витрины")


func test_card_name_key_resolves_assets() -> void:
	assert_eq(
		AssetCatalog.card_name_key({"id": ITEM}),
		String(AssetCatalog.by_id(ITEM).get("nameKey", "")),
		"имя актива по nameKey"
	)
	assert_eq(AssetCatalog.card_name_key("nope"), "nope", "неизвестная — id")


func test_take_from_reserve_board_effect_removes_and_refills() -> void:
	var nm: Node = get_node("/root/NetworkManager")
	var was_host: bool = bool(nm.get("_is_host_flag"))
	nm.set("_is_host_flag", true)
	GameState.reset_session()
	# Как в игре: к моменту board-эффекта карта уже в руке сыщика (не «сброс»).
	GameState.players = {"p": {"user_id": "p", "items": [{"id": ITEM, "exhausted": false}]}}
	GameState.shop_reserve = [ITEM, ITEM_2]
	GameState.asset_deck = [ITEM, ITEM_2, ALLY]
	GameState.apply_board_effect({"do": "takeFromReserve", "id": ITEM})
	assert_does_not_have(GameState.shop_reserve, ITEM, "взятая карта ушла с витрины")
	assert_does_not_have(GameState.asset_deck, ITEM, "и из колоды")
	assert_has(GameState.shop_reserve, ITEM_2, "остальные на месте")
	GameState.reset_session()
	nm.set("_is_host_flag", was_host)


# ── Без дублей: «случайная из колоды» не выдаёт то, что уже в игре ───────────


func test_random_draw_skips_own_cards() -> void:
	var saved: Callable = EffectRunner.asset_pool
	EffectRunner.asset_pool = func() -> Array: return [ITEM, ITEM_2]
	for _i in range(20):
		var p: Dictionary = _player()
		p["items"] = [{"id": ITEM, "exhausted": false}]
		EffectRunner.run([{"do": "gainAsset", "trait": "item"}], p)
		assert_eq(String((p["items"][1] as Dictionary).get("id", "")), ITEM_2, "второй копии нет")
	EffectRunner.asset_pool = saved


func test_free_ids_exclude_reserve_and_all_hands() -> void:
	GameState.reset_session()
	GameState.players = {
		"a": {"user_id": "a", "items": [{"id": ITEM, "exhausted": false}]},
		"b": {"user_id": "b", "items": [{"id": ALLY, "exhausted": false}]},
	}
	GameState.shop_reserve = [ITEM_2]
	GameState.asset_deck = [ITEM, ITEM_2, ALLY, "kerosene"]
	assert_eq(
		GameState._shop.free_ids(), ["kerosene"], "только то, что не на руках и не на витрине"
	)
	var p: Dictionary = GameState.players["a"]
	EffectRunner.run([{"do": "gainAsset"}], p)
	assert_eq(
		String((p["items"][1] as Dictionary).get("id", "")), "kerosene", "GameState — пул колоды"
	)
	GameState.reset_session()


# ── Услуги (onGain) из эффектов: не в руку, а через выдачу ───────────────────


func test_effect_granted_service_is_routed_through_on_gain() -> void:
	var saved: Callable = EffectRunner.asset_pool
	EffectRunner.asset_pool = func() -> Array: return ["charter_flight"]
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run([{"do": "gainAsset", "trait": "service"}], p)
	EffectRunner.asset_pool = saved
	assert_has(
		res.get("board", []),
		{"do": "grantOnGain", "id": "charter_flight", "_pid": "p"},
		"услуга уходит на выдачу с onGain"
	)


func test_plain_asset_has_no_on_gain_node() -> void:
	var saved: Callable = EffectRunner.asset_pool
	EffectRunner.asset_pool = func() -> Array: return [ITEM]
	var res: Dictionary = EffectRunner.run([{"do": "gainAsset", "trait": "item"}], _player())
	EffectRunner.asset_pool = saved
	var on_gain: Array = (res.get("board", []) as Array).filter(
		func(n: Variant) -> bool: return String((n as Dictionary).get("do", "")) == "grantOnGain"
	)
	assert_eq(on_gain, [], "обычная карта — просто в руку")


func test_game_state_runs_on_gain_and_service_leaves_hand() -> void:
	var nm: Node = get_node("/root/NetworkManager")
	var was_host: bool = bool(nm.get("_is_host_flag"))
	nm.set("_is_host_flag", true)
	GameState.reset_session()
	GameState.players = {
		"p":
		{"user_id": "p", "location": "5", "items": [{"id": "charter_flight", "exhausted": false}]}
	}
	GameState.apply_board_effect({"do": "grantOnGain", "id": "charter_flight", "_pid": "p"})
	var ids: Array = []
	for it_v: Variant in GameState.players["p"]["items"]:
		ids.append(AssetCatalog.entry_id(it_v))
	assert_does_not_have(ids, "charter_flight", "услуга не лежит в руке")
	assert_eq(
		String(GameState.mythos_decision.get("kind", "")),
		"destination",
		"рейс спрашивает, куда лететь"
	)
	GameState.reset_session()
	nm.set("_is_host_flag", was_host)
