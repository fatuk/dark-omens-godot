extends GutTest

const EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

## Пассивы предмета (whileOwned) уровня правил: cannotGainClues и undiscardable (Сноп).
## Каталоги реальные; предмет-носитель подменяем через фиктивный id артефакта нельзя,
## поэтому берём первый артефакт каталога и проверяем через runner с подменой
## whileOwned в самом тесте: EffectRunner читает карточку по id — без флага эффекты
## обычные, с флагом (у тестового актива) — запреты. Для детерминизма используем
## карточки из data: ищем актив с нужным пассивом, если его нет — тест помечает pending.


func _asset_with(verb: String) -> String:
	for a_v: Variant in AssetCatalog.all():
		for n_v: Variant in ((a_v as Dictionary).get("effect", {}) as Dictionary).get(
			"whileOwned", []
		):
			if String((n_v as Dictionary).get("do", "")) == verb:
				return String((a_v as Dictionary)["id"])
	for a_v: Variant in ArtifactCatalog.all():
		for n_v: Variant in ((a_v as Dictionary).get("effect", {}) as Dictionary).get(
			"whileOwned", []
		):
			if String((n_v as Dictionary).get("do", "")) == verb:
				return String((a_v as Dictionary)["id"])
	return ""


func test_gain_clue_without_passive_works() -> void:
	var p := {"clues": 0, "items": []}
	EffectRunner.run([{"do": "gainClue", "count": 2}], p)
	assert_eq(int(p["clues"]), 2)


func test_cannot_gain_clues_blocks_gain() -> void:
	var aid: String = _asset_with("cannotGainClues")
	if aid.is_empty():
		pending("в каталогах пока нет предмета с cannotGainClues (Сноп появится с контентом демки)")
		return
	var p := {"clues": 0, "items": [{"id": aid}]}
	EffectRunner.run([{"do": "gainClue", "count": 2}], p)
	assert_eq(int(p["clues"]), 0, "предмет запрещает улики")


func test_undiscardable_survives_lose_all() -> void:
	var aid: String = _asset_with("undiscardable")
	if aid.is_empty():
		pending("в каталогах пока нет предмета с undiscardable (Сноп появится с контентом демки)")
		return
	var p := {"clues": 0, "items": [{"id": aid}, {"id": "lantern"}]}
	EffectRunner.run([{"do": "loseAllPossessions"}], p)
	assert_eq((p["items"] as Array).size(), 1, "несбрасываемый предмет остался")
	assert_eq(String((p["items"][0] as Dictionary)["id"]), aid)
