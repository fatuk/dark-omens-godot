extends GutTest

## Фаза C улик Древнего: пул идентичности (host-only) + ClueCatalog. Числовой
## player.clues и раскладку не трогаем — проверяем аддитивный слой clue_ids:
## пул ⇄ поле ⇄ руки, уникальность на партию, возврат в пул при потере.

var _saved_nm: Variant


class HostStub:
	extends Node

	func is_host() -> bool:
		return true


func before_each() -> void:
	_saved_nm = GameState._nm
	GameState._nm = autofree(HostStub.new())
	GameState.campaign = {
		"ancientOne":
		{
			"clues":
			[
				{"location": "A", "title": "TA", "description": "DA"},
				{"location": "B", "title": "TB", "description": "DB"},
				{"location": "C", "title": "TC", "description": "DC"},
			]
		}
	}
	GameState.players = {}
	GameState.entities = {}
	GameState._reset_clue_pool()


func after_each() -> void:
	GameState._nm = _saved_nm
	GameState.campaign = {}
	GameState.players = {}
	GameState.entities = {}
	GameState._reset_clue_pool()


# ── Пул ───────────────────────────────────────────────────────────────────────


func test_pool_builds_from_campaign() -> void:
	GameState._ensure_clue_pool()
	assert_eq(GameState._clue_pool.size(), 3, "три улики в пуле")
	assert_true(GameState._clue_pool.has("A") and GameState._clue_pool.has("C"))


func test_claim_board_clue_takes_own_location() -> void:
	GameState._ensure_clue_pool()
	GameState._claim_board_clue("A")
	assert_false(GameState._clue_pool.has("A"), "A ушла из пула на поле")
	assert_eq(GameState._board_clue_ids.get("A", []), ["A"], "A на жетоне локации A")


func test_claim_unknown_location_is_noop() -> void:
	GameState._ensure_clue_pool()
	GameState._claim_board_clue("Z")  # нет улики для Z
	assert_eq(GameState._clue_pool.size(), 3, "пул не тронут")
	assert_false(GameState._board_clue_ids.has("Z"))


# ── Исследование: жетон → на руки ──────────────────────────────────────────────


func test_research_collects_board_clue_to_player() -> void:
	GameState._ensure_clue_pool()
	GameState._claim_board_clue("A")
	GameState.players = {"p1": {"clues": 1, "clue_ids": []}}
	GameState._collect_board_clues("p1", "A", 1)
	assert_eq(GameState.players["p1"]["clue_ids"], ["A"], "улика A на руках у p1")
	assert_false(GameState._board_clue_ids.has("A"), "жетон A больше не на поле")


# ── Сверка: generic gain / потеря ──────────────────────────────────────────────


func test_reconcile_draws_generic_from_pool() -> void:
	GameState._ensure_clue_pool()  # пул A,B,C
	GameState.players = {"p1": {"clues": 2, "clue_ids": []}}
	GameState._reconcile_clue_identities()
	var ids: Array = GameState.players["p1"]["clue_ids"]
	assert_eq(ids.size(), 2, "добрали 2 идентичности под число улик")
	assert_eq(GameState._clue_pool.size(), 1, "в пуле осталась одна")
	assert_ne(String(ids[0]), String(ids[1]), "уникальны — разные ключи")


func test_reconcile_returns_to_pool_on_loss() -> void:
	GameState._ensure_clue_pool()
	GameState._clue_pool.erase("A")
	GameState._clue_pool.erase("B")  # A,B считаем розданными; в пуле только C
	GameState.players = {"p1": {"clues": 1, "clue_ids": ["A", "B"]}}
	GameState._reconcile_clue_identities()
	assert_eq(GameState.players["p1"]["clue_ids"].size(), 1, "осталась одна улика")
	assert_eq(GameState._clue_pool.size(), 2, "излишек вернулся в пул")


func test_reconcile_board_returns_dead_token_to_pool() -> void:
	GameState._ensure_clue_pool()
	GameState._claim_board_clue("A")  # A на поле, пул B,C
	GameState.entities = {}  # жетон сняли не исследованием (напр. discardAllClues)
	GameState._reconcile_board_clue_ids()
	assert_true(GameState._clue_pool.has("A"), "A вернулась в пул")
	assert_false(GameState._board_clue_ids.has("A"))


func test_uniqueness_across_pool_board_hand() -> void:
	GameState._ensure_clue_pool()
	GameState._claim_board_clue("A")  # A на поле
	GameState.players = {"p1": {"clues": 1, "clue_ids": []}}
	GameState._reconcile_clue_identities()  # p1 добирает из остатка (B или C)
	var seen: Array = []
	seen.append_array(GameState._clue_pool)
	for loc: Variant in GameState._board_clue_ids:
		seen.append_array(GameState._board_clue_ids[loc])
	seen.append_array(GameState.players["p1"]["clue_ids"])
	assert_eq(seen.size(), 3, "все 3 ключа учтены (пул+поле+руки)")
	seen.sort()
	assert_eq(seen, ["A", "B", "C"], "ни одного дубля — ключ ровно в одном месте")


func test_not_host_is_noop() -> void:
	GameState._nm = null  # is_instance_valid(null)==false → _is_host()==false
	GameState._ensure_clue_pool()
	GameState.players = {"p1": {"clues": 2, "clue_ids": []}}
	GameState._reconcile_clue_identities()
	assert_eq(GameState.players["p1"]["clue_ids"].size(), 0, "не хост — идентичности не трогаем")


# ── ClueCatalog ────────────────────────────────────────────────────────────────


func test_catalog_by_location() -> void:
	assert_eq(String(ClueCatalog.by_location("B").get("title", "")), "TB")
	assert_true(ClueCatalog.by_location("Z").is_empty(), "нет улики Z")


func test_catalog_card_payload() -> void:
	var p: Dictionary = ClueCatalog.card_payload("B")
	assert_eq(String(p.get("id", "")), "B")
	assert_eq(String(p.get("title", "")), "TB")
	assert_eq(String(p.get("desc", "")), "DB")
	assert_false(p.has("art"), "файла арта нет → без art")


func test_catalog_deck_for_ids() -> void:
	var deck: Array = ClueCatalog.deck_for_clue_ids(["A", "C"])
	assert_eq(deck.size(), 2)
	assert_eq(String((deck[0] as Dictionary).get("id", "")), "A")
	assert_eq(int((deck[0] as Dictionary).get("clue_index", -1)), 0)
	assert_eq(int((deck[1] as Dictionary).get("clue_index", -1)), 1)
