extends GutTest

## Каталог артефактов (scripts/core/data/artifact_catalog.gd) и его шов с активами.
##
## Главное, что здесь проверяется, — ГРАНИЦА двух каталогов: артефакт обязан быть
## виден там, где речь про владение (by_id, веер), и НЕ виден там, где речь про
## колоду и витрину (all, available_ids, случайная выдача gainAsset).

const EffectRunner = preload("res://scripts/core/game/effect_runner.gd")


func test_catalog_is_not_empty() -> void:
	assert_gt(ArtifactCatalog.all().size(), 0, "artifacts.json выгружен из CMS")


func test_known_artifact_has_expected_shape() -> void:
	var a: Dictionary = ArtifactCatalog.by_id("necronomicon")
	assert_false(a.is_empty(), "«Некрономикон» есть в каталоге")
	assert_true(String(a.get("nameKey", "")).begins_with("ARTIFACT_"), "ключ имени артефактный")
	assert_has(a.get("traits", []), "tome", "трейт Книга на месте")


func test_unknown_id_is_empty() -> void:
	assert_true(ArtifactCatalog.by_id("нет-такого").is_empty(), "неизвестный id — пусто")
	assert_false(ArtifactCatalog.has("нет-такого"), "has для неизвестного — false")


# ── Шов с каталогом активов ───────────────────────────────────────────────────


func test_asset_by_id_falls_back_to_artifacts() -> void:
	# Ради этого шва всё и сделано: пассивы, слот action и веер ходят через by_id,
	# и артефакт обязан находиться там же, где актив.
	var a: Dictionary = AssetCatalog.by_id("necronomicon")
	assert_false(a.is_empty(), "артефакт находится через AssetCatalog.by_id")


func test_artifacts_stay_out_of_the_asset_deck() -> void:
	# Обратная половина шва: колода и витрина ходят через all()/available_ids(),
	# и артефакт туда попасть не должен — иначе он утечёт в магазин.
	var deck: Array = AssetCatalog.available_ids()
	assert_false(deck.has("necronomicon"), "артефакта нет в колоде активов")
	for a_v: Variant in AssetCatalog.all():
		assert_false(
			ArtifactCatalog.has(String((a_v as Dictionary).get("id", ""))),
			"в assets.json не просочился артефакт"
		)


func test_shop_offer_has_no_artifacts() -> void:
	for a_v: Variant in AssetCatalog.shop_offer(8):
		assert_false(
			ArtifactCatalog.has(String((a_v as Dictionary).get("id", ""))),
			"витрина торгует только активами"
		)


func test_random_gain_asset_never_yields_artifact() -> void:
	var p: Dictionary = {"items": []}
	for _i in range(30):
		EffectRunner.run([{"do": "gainAsset"}], p)
	for it_v: Variant in p["items"]:
		assert_false(
			ArtifactCatalog.has(AssetCatalog.entry_id(it_v)), "gainAsset выдаёт только активы"
		)


# ── Карта для веера ───────────────────────────────────────────────────────────


func test_artifact_card_payload_has_no_cost() -> void:
	# GameCard рисует плашку стоимости по НАЛИЧИЮ ключа, а артефакт не продаётся.
	var payload: Dictionary = ArtifactCatalog.card_payload(ArtifactCatalog.by_id("necronomicon"))
	assert_false(payload.has("cost"), "у артефакта нет цены")
	assert_eq(String(payload.get("subtitle", "")), "TRAIT_ARTIFACT", "подзаголовок помечает класс")


func test_artifact_renders_in_the_hand_fan() -> void:
	# Раньше веер молча выбрасывал артефакт: by_id его не знал, карта была невидима.
	var deck: Array = AssetCatalog.deck_for_items(
		[{"id": "necronomicon", "kind": "artifact", "exhausted": false}]
	)
	assert_eq(deck.size(), 1, "артефакт попал в веер")
	assert_eq(String((deck[0] as Dictionary).get("id", "")), "necronomicon")
	assert_true(bool((deck[0] as Dictionary).get("is_artifact", false)), "помечен как артефакт")


func test_available_ids_trait_filter() -> void:
	var tomes: Array = ArtifactCatalog.available_ids("tome")
	assert_gt(tomes.size(), 0, "книги-артефакты есть")
	for id_v: Variant in tomes:
		assert_has(
			ArtifactCatalog.by_id(String(id_v)).get("traits", []), "tome", "фильтр по трейту точен"
		)


func test_available_ids_unmatched_trait_falls_back() -> void:
	# То же правило, что у gainAsset: пустая награда за успех хуже слегка неточной.
	var any: Array = ArtifactCatalog.available_ids("нет-такого-трейта")
	assert_eq(any.size(), ArtifactCatalog.available_ids().size(), "откат на полный список")


# ── Уникальность выдачи ───────────────────────────────────────────────────────


func test_pick_free_excludes_taken() -> void:
	# Артефакт уникален: занятая карта не выдаётся повторно.
	var taken: Dictionary = {}
	for id_v: Variant in ArtifactCatalog.available_ids():
		taken[String(id_v)] = true
	taken.erase("necronomicon")
	assert_eq(ArtifactCatalog.pick_free(taken), "necronomicon", "остался ровно один свободный")


func test_pick_free_returns_empty_when_all_taken() -> void:
	var taken: Dictionary = {}
	for id_v: Variant in ArtifactCatalog.available_ids():
		taken[String(id_v)] = true
	assert_eq(ArtifactCatalog.pick_free(taken), "", "свободных нет — пусто, а не случайный")


func test_pick_free_respects_trait() -> void:
	for _i in range(20):
		var id: String = ArtifactCatalog.pick_free({}, "tome")
		assert_has(ArtifactCatalog.by_id(id).get("traits", []), "tome", "выдаётся книга")


# ── Эффекты артефакта видит слой активов ──────────────────────────────────────


func test_artifact_passive_reaches_check_pipeline() -> void:
	# «Серебряный ключ»: whileOwned rerollDice в контексте Иного мира. Проверяем не
	# сам бросок, а то, что механизм АКТИВОВ видит эффект артефакта — ради этого и
	# сделан шов by_id.
	var key: Dictionary = ArtifactCatalog.by_id("silver_key")
	assert_false(key.is_empty(), "карточка на месте")
	var mods: Array = AssetCatalog.passive_check_mods(key, "otherWorldEncounter")
	assert_gt(mods.size(), 0, "пассив артефакта прочитан механизмом активов")
	assert_eq(String((mods[0] as Dictionary).get("do", "")), "rerollDice")


func test_artifact_reckoning_is_read_like_asset() -> void:
	# onReckoning артефакта («Проклятая сфера») обязан читаться тем же путём, что
	# у актива, — иначе Расплата молча пропустит карту.
	var reck: Array = AssetCatalog.reckoning_of("cursed_sphere")
	assert_gt(reck.size(), 0, "Расплата артефакта видна через AssetCatalog")
