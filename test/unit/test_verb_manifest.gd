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


# Регрессия: у forEach `do` — Array (под-программа), не verb. Раньше String(do) падал
# («Nonexistent 'String' constructor») при показе social-карты Мифов.
func test_describe_foreach_lists_subeffects() -> void:
	var s: String = EffectManifest.describe(
		{"forEach": "each", "do": [{"text": "X"}, {"text": "Y"}]}
	)
	assert_true("X" in s and "Y" in s, "под-эффекты forEach перечислены, без краша")


func test_describe_dieroll_lists_faces() -> void:
	var node := {
		"dieRoll": [{"on": "6", "then": [{"text": "A"}]}, {"on": "1", "then": [{"text": "B"}]}]
	}
	assert_eq(EffectManifest.describe(node), "A / B")


func test_describe_non_string_do_is_safe() -> void:
	# Гард на структурный узел с нестроковым do → "" вместо краша String(Array).
	assert_eq(EffectManifest.describe({"do": ["x"]}), "")
