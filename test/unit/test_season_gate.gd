extends GutTest

## Гейт сезонов: что попадает в пулы выдачи. Фильтруются ТОЛЬКО пулы — поиск
## by_id обязан находить контент чужого сезона, иначе у игрока пропадёт карта,
## пришедшая синком от хоста, который сезоном владеет.
##
## Состояние гейта статическое, поэтому каждый тест возвращает его к базе —
## иначе протечёт в соседние наборы.


func after_each() -> void:
	SeasonGate.set_room(["core"])
	SeasonGate.set_own(["core"])


func test_base_allows_only_core() -> void:
	assert_true(SeasonGate.room_allows({"season": "core"}), "база доступна")
	assert_false(SeasonGate.room_allows({"season": "td"}), "чужой сезон закрыт")


func test_entry_without_season_is_closed() -> void:
	# Правило то же, что в CMS: забыли разметить — контент не утечёт молча.
	assert_false(SeasonGate.room_allows({}), "без поля season — недоступно")
	assert_false(SeasonGate.own_allows({"id": "x"}), "без поля season — недоступно")


func test_room_and_own_independent() -> void:
	# Купил сезон — играешь его сыщиком даже в чужой базовой комнате.
	SeasonGate.set_own(["td"])
	assert_true(SeasonGate.own_allows({"season": "td"}), "свой сезон открыт лично")
	assert_false(SeasonGate.room_allows({"season": "td"}), "но стол остался базовым")


func test_core_always_present() -> void:
	# Базу купили вместе с игрой — её нельзя потерять, выдав сезон.
	SeasonGate.set_room(["td"])
	assert_true(SeasonGate.room_allows({"season": "core"}), "база на месте")
	assert_true(SeasonGate.room_allows({"season": "td"}), "и выданный сезон тоже")


func test_empty_falls_back_to_base() -> void:
	# Партия без контента неиграбельна — лучше база, чем пустые пулы.
	SeasonGate.set_room([])
	assert_true(SeasonGate.room_allows({"season": "core"}), "пустой список → база")


func test_filter_room_keeps_only_allowed() -> void:
	var src: Array = [{"season": "core"}, {"season": "td"}, {"season": "core"}, {}]
	assert_eq(SeasonGate.filter_room(src).size(), 2, "оставлены только базовые")


# ── Реальные каталоги ─────────────────────────────────────────────────────────


func test_available_assets_are_subset_of_supported() -> void:
	# available_ids = поддержано движком И куплено. Пересечение, а не замена:
	# путать их нельзя, иначе неподдержанная карта уедет в колоду.
	var avail: Array = AssetCatalog.available_ids()
	var supported: Array = AssetCatalog.supported_ids()
	assert_gt(avail.size(), 0, "база не пуста")
	assert_lt(avail.size(), supported.size(), "сезонные активы отсечены")
	for i in range(avail.size()):
		assert_has(supported, String(avail[i]), "доступное обязано быть поддержанным")


func test_available_assets_are_core_only() -> void:
	var avail: Array = AssetCatalog.available_ids()
	for i in range(avail.size()):
		var a: Dictionary = AssetCatalog.by_id(String(avail[i]))
		assert_eq(String(a.get("season", "")), "core", "в базе только core-активы")


func test_by_id_ignores_season() -> void:
	# Ключевое: карта чужого сезона обязана находиться. Она может лежать на столе
	# у хоста, который сезоном владеет, и прийти к нам синком.
	var a: Dictionary = AssetCatalog.by_id("camera")  # season td
	assert_false(a.is_empty(), "актив чужого сезона всё равно ищется по id")
	assert_eq(String(a.get("season", "")), "td", "и это действительно чужой сезон")


func test_monster_cup_shrinks_but_keeps_top_tier() -> void:
	# Резали ради связности, а не чтобы облегчить игру: верхний ярус стойкости
	# обязан остаться, иначе база станет безопаснее.
	var cup: Array = SeasonGate.filter_room(MonsterCatalog.non_epic())
	assert_lt(cup.size(), MonsterCatalog.non_epic().size(), "чаша урезана")
	var tough: int = 0
	for i in range(cup.size()):
		tough = maxi(tough, int((cup[i] as Dictionary).get("toughness", 0)))
	assert_gte(tough, 5, "самые крепкие монстры остались в базе")
