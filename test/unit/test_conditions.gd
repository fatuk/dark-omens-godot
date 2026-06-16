extends GutTest

## Conditions.card_payload — payload карты состояния для веера состояний:
## имя/вид/текст/глиф, флаг локального действия, рубашка → текст исхода.
## Каталог грузит data/conditions.json (реальные состояния).


func test_payload_basic_fields() -> void:
	var p: Dictionary = Conditions.card_payload("detained")
	assert_eq(String(p.get("kind", "")), "condition", "вид карты — condition")
	assert_eq(String(p.get("condition_id", "")), "detained")
	assert_eq(String(p.get("title", "")), Conditions.name_key("detained"), "title — ключ имени")
	assert_false(String(p.get("subtitle", "")).is_empty(), "подпись вида задана")
	assert_false(String(p.get("glyph", "")).is_empty(), "глиф по виду задан")
	assert_true(bool(p.get("has_action", false)), "у detained есть локальное действие")


func test_payload_passive_has_no_action() -> void:
	# blessed — пассив (whileHeld successThreshold), без локального action.
	assert_false(bool(Conditions.card_payload("blessed").get("has_action", true)))


func test_payload_front_desc_is_front_key() -> void:
	var p: Dictionary = Conditions.card_payload("debt")
	assert_eq(
		String(p.get("desc", "")),
		String(Conditions.get_def("debt").get("front", "")),
		"лицо → текст лица (front)"
	)


func test_payload_flipped_desc_is_outcome_text() -> void:
	var back: Dictionary = Conditions.card_payload("debt", "collectorsCall")
	var oc: Dictionary = Conditions.outcome_def("collectorsCall")
	assert_false(oc.is_empty(), "исход collectorsCall существует")
	assert_eq(String(back.get("desc", "")), String(oc.get("text", "")), "рубашка → текст исхода")


func test_payload_unknown_is_empty() -> void:
	assert_eq(Conditions.card_payload("nope"), {})


# Регрессия: состояния, чьё ЛИЦО обещает «Локальное действие», должны иметь action
# (иначе в веере карта серая и действие не запустить). agreement — известное
# исключение (optional «потратить 2 улики», ждёт интерактивного condition-action).
func test_local_action_conditions_are_wired() -> void:
	for cid: String in ["debt", "detained"]:
		assert_true(
			bool(Conditions.card_payload(cid).get("has_action", false)),
			"%s: локальное действие подключено" % cid
		)
