extends GutTest

## Модалка карты Мифов: при тексте правил машинный список «Эффекты» не дублирует
## его; список — только запасной вариант для карт без текста (шаблонные заглушки).

const _SCENE := preload("res://scenes/ui/mythos_modal.tscn")

var _modal: CanvasLayer


func before_each() -> void:
	_modal = _SCENE.instantiate()
	add_child_autofree(_modal)


func _card(text: String) -> Dictionary:
	return {
		"name": "Круг %d" % randi(),  # уникальный ключ — модалка пересобирается на смене карты
		"text": text,
		"onDraw": [{"do": "openGate", "monster": "cultist"}, {"do": "advanceOmen"}],
	}


func test_rules_text_hides_effects_list() -> void:
	_modal._show_card(_card("Откройте врата, из них выходит культист. Сдвиньте омен."))
	assert_true(_modal._text_lbl.visible, "текст правил виден")
	assert_false(_modal._eff_box.visible, "список эффектов скрыт")
	assert_false(_modal._eff_header.visible, "заголовок «Эффекты» скрыт")
	assert_false(_modal._eff_sep.visible, "и разделитель над ним")


func test_no_text_falls_back_to_effects_list() -> void:
	_modal._show_card(_card(""))
	assert_false(_modal._text_lbl.visible, "текста нет")
	assert_true(_modal._eff_box.visible, "список эффектов показан")
	assert_true(_modal._eff_header.visible, "с заголовком")
	assert_eq(_modal._eff_box.get_child_count(), 2, "по строке на эффект")
