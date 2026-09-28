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
	# Пул строится из ВСЕХ локаций карты — подставляем фикстуру A/B/C вместо реальной
	# locations.json. campaign.ancientOne.clues задаёт только КОНТЕНТ (ClueCatalog).
	GameState.map = LocationGraph.new([{"id": "A"}, {"id": "B"}, {"id": "C"}])
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
	GameState._board.reset_clue_deck()


func after_each() -> void:
	GameState._nm = _saved_nm
	GameState.campaign = {}
	GameState.players = {}
	GameState.entities = {}
	GameState.map = LocationGraph.new()  # сброс фикстуры — другие тесты грузят реальную
	GameState._board.reset_clue_deck()


# ── Пул ───────────────────────────────────────────────────────────────────────


func test_pool_builds_from_all_locations() -> void:
	GameState._board.ensure_clue_deck()
	assert_eq(GameState.clue_deck.size(), 3, "пул = все локации карты (фикстура A/B/C)")
	assert_true(GameState.clue_deck.has("A") and GameState.clue_deck.has("C"))


func test_claim_board_clue_takes_own_location() -> void:
	GameState._board.ensure_clue_deck()
	GameState._board.claim_board_clue("A")
	assert_false(GameState.clue_deck.has("A"), "A ушла из пула на поле")
	assert_eq(GameState.clue_board_ids.get("A", []), ["A"], "A на жетоне локации A")


func test_claim_unknown_location_is_noop() -> void:
	GameState._board.ensure_clue_deck()
	GameState._board.claim_board_clue("Z")  # нет улики для Z
	assert_eq(GameState.clue_deck.size(), 3, "пул не тронут")
	assert_false(GameState.clue_board_ids.has("Z"))


# ── Исследование: жетон → на руки ──────────────────────────────────────────────


func test_research_collects_board_clue_to_player() -> void:
	GameState._board.ensure_clue_deck()
	GameState._board.claim_board_clue("A")
	GameState.players = {"p1": {"clues": 1, "clue_ids": []}}
	GameState._board.collect_board_clues("p1", "A", 1)
	assert_eq(GameState.players["p1"]["clue_ids"], ["A"], "улика A на руках у p1")
	assert_false(GameState.clue_board_ids.has("A"), "жетон A больше не на поле")


# ── Сверка: generic gain / потеря ──────────────────────────────────────────────


func test_reconcile_draws_generic_from_pool() -> void:
	GameState._board.ensure_clue_deck()  # пул A,B,C
	GameState.players = {"p1": {"clues": 2, "clue_ids": []}}
	GameState._board.reconcile_clue_identities()
	var ids: Array = GameState.players["p1"]["clue_ids"]
	assert_eq(ids.size(), 2, "добрали 2 идентичности под число улик")
	assert_eq(GameState.clue_deck.size(), 1, "в пуле осталась одна")
	assert_ne(String(ids[0]), String(ids[1]), "уникальны — разные ключи")


func test_reconcile_spent_clue_goes_to_discard() -> void:
	GameState._board.ensure_clue_deck()
	GameState.clue_deck.erase("A")
	GameState.clue_deck.erase("B")  # A,B розданы; в колоде только C
	GameState.players = {"p1": {"clues": 1, "clue_ids": ["A", "B"]}}
	GameState._board.reconcile_clue_identities()
	assert_eq(GameState.players["p1"]["clue_ids"].size(), 1, "осталась одна улика")
	assert_eq(GameState.clue_deck.size(), 1, "колода не пополняется тратой напрямую")
	assert_eq(GameState.clue_discard.size(), 1, "потраченный ключ ушёл в сброс")


func test_reconcile_board_dead_token_goes_to_discard() -> void:
	GameState._board.ensure_clue_deck()
	GameState._board.claim_board_clue("A")  # A на поле, в колоде B,C
	GameState.entities = {}  # жетон сняли не исследованием (напр. discardAllClues)
	GameState._board.reconcile_board_clue_ids()
	assert_true(GameState.clue_discard.has("A"), "A ушла в сброс")
	assert_false(GameState.clue_deck.has("A"), "и не вернулась в колоду напрямую")
	assert_false(GameState.clue_board_ids.has("A"))


func test_uniqueness_across_deck_board_hand_discard() -> void:
	GameState._board.ensure_clue_deck()
	GameState._board.claim_board_clue("A")  # A на поле
	GameState.players = {"p1": {"clues": 1, "clue_ids": []}}
	GameState._board.reconcile_clue_identities()  # p1 добирает из остатка (B или C)
	var seen: Array = []
	seen.append_array(GameState.clue_deck)
	for loc: Variant in GameState.clue_board_ids:
		seen.append_array(GameState.clue_board_ids[loc])
	seen.append_array(GameState.players["p1"]["clue_ids"])
	seen.append_array(GameState.clue_discard)
	assert_eq(seen.size(), 3, "все 3 ключа учтены (колода+поле+руки+сброс)")
	seen.sort()
	assert_eq(seen, ["A", "B", "C"], "ни одного дубля — ключ ровно в одном месте")


func test_not_host_is_noop() -> void:
	GameState._nm = null  # is_instance_valid(null)==false → is_host()==false
	GameState._board.ensure_clue_deck()
	GameState.players = {"p1": {"clues": 2, "clue_ids": []}}
	GameState._board.reconcile_clue_identities()
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


func test_catalog_payload_desc_falls_back_to_location() -> void:
	# Улики для "Z" нет → описание = имя локации (loc_name_key → "Z" вне locations.json).
	var p: Dictionary = ClueCatalog.card_payload("Z")
	assert_eq(String(p.get("desc", "")), "Z", "нет описания → имя локации")


func test_catalog_deck_for_ids() -> void:
	var deck: Array = ClueCatalog.deck_for_clue_ids(["A", "C"])
	assert_eq(deck.size(), 2)
	assert_eq(String((deck[0] as Dictionary).get("id", "")), "A")
	assert_eq(int((deck[0] as Dictionary).get("clue_index", -1)), 0)
	assert_eq(int((deck[1] as Dictionary).get("clue_index", -1)), 1)


# ── Переживание перезахода хоста ──────────────────────────────────────────────


# Состояние колоды приходит хосту снапшотом (_SYNC_FIELDS). Раньше «колода собрана»
# и привязка ключей к жетонам были host-only: перезашедший хост считал колоду
# несобранной и на ближайшей же сверке пересобирал её из ВСЕХ локаций поверх живой
# партии — счётчик прыгал обратно на максимум, а потраченные улики переставали
# попадать в сброс (_clue_to_discard молчит, если ключ «лежит в колоде»).
func _snapshot_roundtrip() -> void:
	var snap: Dictionary = {}
	for f: String in GameState._SYNC_FIELDS:
		snap[f] = GameState.get(f)
	# Host-only поля перезаход НЕ переживают — их и проверяем.
	GameState.clue_deck = []
	GameState.clue_board_ids = {}
	GameState.clue_deck_built = false
	for f: String in GameState._SYNC_FIELDS:
		GameState.set(f, snap.get(f, GameState.get(f)))


func test_deck_survives_host_rejoin() -> void:
	GameState._board.ensure_clue_deck()
	GameState.entities["A"] = ["clue"]  # жетон лежит на поле…
	GameState._board.claim_board_clue("A")  # …и несёт ключ улики этой локации
	GameState.players["p"] = {"clues": 1, "clue_ids": []}
	GameState._board.reconcile_clue_identities()  # игроку выдали ключ из колоды
	var deck_before: int = GameState.clue_deck.size()
	assert_eq(deck_before, 1, "3 ключа: один на поле, один на руках, один в колоде")

	_snapshot_roundtrip()
	GameState._board.reconcile_clue_identities()  # ближайшая сверка после перезахода
	assert_eq(GameState.clue_deck.size(), deck_before, "колода не пересобирается заново")
	assert_eq(GameState.clue_board_ids.get("A", []), ["A"], "привязка жетона к ключу цела")


func test_spent_clue_reaches_discard_after_rejoin() -> void:
	GameState._board.ensure_clue_deck()
	GameState.players["p"] = {"clues": 1, "clue_ids": []}
	GameState._board.reconcile_clue_identities()
	_snapshot_roundtrip()

	GameState.players["p"]["clues"] = 0  # потратил на переброс
	GameState._board.reconcile_clue_identities()
	assert_eq(GameState.clue_discard.size(), 1, "потраченная улика видна в сбросе")
