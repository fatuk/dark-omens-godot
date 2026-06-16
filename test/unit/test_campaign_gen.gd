extends GutTest

## Регрессия: CampaignGen._summary должен переносить в синкаемую сводку Тайны не
## только act/title/locations/onEnter, но и ХУКИ ПРОГРЕССА (progress / legacy
## progressHook). Без них tokensOnCard-Тайна в игре не продвигается и не предлагает
## встречу (полная библия с хуками живёт на relay, а в GameState едет сводка).


func test_summary_preserves_progress_and_progress_hook() -> void:
	var cg := CampaignGen.new(autofree(Node.new()))  # _summary не трогает _gs
	var full := {
		"id": "c1",
		"doomClock": 12,
		"ancientOne": {},
		"theme": [],
		"mysteries":
		[
			{
				"act": 1,
				"title": "A",
				"solveCondition": {"kind": "tokensOnCard"},
				"progress": [{"on": "encounterAtEldritchToken", "effect": []}],
			},
			{
				"act": 2,
				"title": "B",
				"solveCondition": {"kind": "tokensOnCard"},
				"progressHook": {"on": "gateClosed", "effect": []},
			},
			{"act": 3, "title": "C", "solveCondition": {"kind": "cluesOnCard"}},
		],
	}
	var s: Dictionary = cg._summary(full)
	var ms: Array = s["mysteries"]
	assert_true((ms[0] as Dictionary).has("progress"), "progress перенесён в сводку")
	assert_eq((ms[0]["progress"] as Array).size(), 1, "хук progress сохранён")
	assert_true((ms[1] as Dictionary).has("progressHook"), "legacy progressHook перенесён")
	# Нет хуков → ключи НЕ добавляются (иначе пустой progress затенил бы progressHook).
	assert_false((ms[2] as Dictionary).has("progress"), "без хуков progress не добавляется")
	assert_false((ms[2] as Dictionary).has("progressHook"))


# Регрессия: relay шлёт ancientOne как {name, epithet, …} БЕЗ id, а ReckoningFlow/
# AncientCatalog адресуются по id — _summary обязан проштамповать сид-id Древнего.
func test_summary_stamps_ancient_id() -> void:
	var cg := CampaignGen.new(autofree(Node.new()))
	var full := {"ancientOne": {"name": "Азатот"}, "mysteries": []}
	var s: Dictionary = cg._summary(full, "azathoth")
	var ao: Dictionary = s["ancientOne"]
	assert_eq(String(ao.get("id", "")), "azathoth", "id Древнего проштампован из сида")
	assert_eq(String(ao.get("name", "")), "Азатот", "прочие поля сохранены")
	# Уже есть id (на будущее, если relay начнёт слать) → не перетираем.
	var s2: Dictionary = cg._summary({"ancientOne": {"id": "dagon"}, "mysteries": []}, "azathoth")
	assert_eq(
		String((s2["ancientOne"] as Dictionary).get("id", "")), "dagon", "существующий id цел"
	)
