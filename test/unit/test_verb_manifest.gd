extends GutTest

## EffectManifest: загрузка verb-манифеста (data/effect-manifest.json, генерится из
## relay) + структурный describe. Подстановка по шаблону зависит от загруженных
## переводов (tr/TranslationServer), поэтому здесь проверяем то, что от них НЕ зависит:
## загрузку дескрипторов и комбинаторы (художественный text, choice/group).


func test_verb_def_loads_kind_and_params() -> void:
	var d: Dictionary = EffectManifest.verb_def("loseHealth")
	assert_eq(String(d.get("kind", "")), "player", "loseHealth — player-verb")
	var names := PackedStringArray()
	for p_v: Variant in d.get("params", []) as Array:
		names.append(String((p_v as Dictionary).get("name", "")))
	assert_true("amount" in names, "у loseHealth есть param amount")


func test_verb_def_target_group_and_scales() -> void:
	var d: Dictionary = EffectManifest.verb_def("loseHealth")
	assert_eq(String(d.get("targets", "")), "players", "цель — группа players")
	assert_eq(String(d.get("scales", "")), "amount", "масштабируется amount")
	assert_eq(String(EffectManifest.verb_def("discardMonster").get("targets", "")), "oneMonster")


func test_verb_def_unknown_is_empty() -> void:
	assert_eq(EffectManifest.verb_def("nope"), {})


func test_describe_artistic_text_overrides() -> void:
	assert_eq(EffectManifest.describe({"text": "Кровь течёт"}), "Кровь течёт")
	assert_eq(
		EffectManifest.describe({"do": "text", "text": "foo"}), "foo", "verb text → его текст"
	)


func test_describe_choice_joins_with_slash() -> void:
	assert_eq(EffectManifest.describe({"choice": [{"text": "A"}, {"text": "B"}]}), "A / B")


func test_describe_group_joins_with_comma() -> void:
	assert_eq(EffectManifest.describe({"group": [{"text": "A"}, {"text": "B"}]}), "A, B")


func test_describe_list_empty_is_blank() -> void:
	assert_eq(EffectManifest.describe_list([]), "")
	assert_eq(EffectManifest.describe_list("nope"), "")
