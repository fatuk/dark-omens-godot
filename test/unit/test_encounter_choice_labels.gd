## Окно встречи, выбор ветки gainAsset («Обвал лесов»): кнопки подписаны по-разному
## (витрина с перечнем подходящих карт / случайная из колоды), фиксированной ширины
## по центру, а исход после коммита называет полученную карту.
extends GutTest

const _MODAL := preload("res://scenes/ui/encounter_modal.tscn")

var _modal: Node


func before_each() -> void:
	GameState.reset_session()
	GameState.shop_reserve = ["kerosene", "hired_muscle", "lantern"]
	_modal = add_child_autofree(_MODAL.instantiate())


func after_each() -> void:
	GameState.reset_session()


func _choice_card() -> Dictionary:
	return {
		"name": "Обвал лесов",
		"pending_choice":
		{
			"kind": "choice",
			"path": "0",
			"options":
			[
				{"do": "gainAsset", "from": "reserve", "trait": "item"},
				{"do": "gainAsset", "trait": "item"},
			],
		},
	}


func _name(id: String) -> String:
	return tr(String(AssetCatalog.by_id(id).get("nameKey", id)))


func test_choice_buttons_name_source_and_cards() -> void:
	_modal.call("_show_choice", _choice_card())
	var btns: Array = _modal.find_children("ChoiceBtn*", "Button", true, false)
	assert_eq(btns.size(), 2)
	var reserve_txt: String = (btns[0] as Button).text
	var deck_txt: String = (btns[1] as Button).text
	assert_ne(reserve_txt, deck_txt, "ветки различимы")
	assert_string_contains(reserve_txt, _name("kerosene"), "перечислены предметы витрины")
	assert_string_contains(reserve_txt, _name("lantern"))
	assert_false(reserve_txt.contains(_name("hired_muscle")), "союзник не предмет — не в списке")
	for b_v: Variant in btns:
		var b: Button = b_v
		assert_eq(b.size_flags_horizontal, Control.SIZE_SHRINK_CENTER, "не растянута на всю ширину")
		assert_gt(b.custom_minimum_size.x, 0.0, "фиксированная ширина")


func test_outcome_names_gained_card() -> void:
	GameState.current_encounter = {"gained_items": [{"id": "lantern", "exhausted": false}]}
	var out: String = _modal.call(
		"_outcome_text", {"successText": "Балка поддаётся.", "onSuccess": []}, true
	)
	assert_string_contains(out, tr("ENC_GAINED") % _name("lantern"), "исход называет карту")
