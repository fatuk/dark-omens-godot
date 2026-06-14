extends GutTest

## Скролл описания карты. Регрессия на баг: ScrollContainer не считал высоту
## autowrap-текста, поэтому переполнение не детектилось и скролл был невозможен.
## Теперь высота контента берётся по числу перенесённых строк, а сдвиг двигает
## высокий Label внутри клипующей зоны.


func _make_card(desc: String) -> GameCard:
	var card: GameCard = GameCard.new()
	card.size = Vector2(220.0, 220.0 / GameCard.ASPECT)  # пропорции рамки
	add_child_autofree(card)
	card.set_card({"title": "Test", "desc": desc})
	return card


func test_long_desc_overflows_zone() -> void:
	var card: GameCard = _make_card("word ".repeat(140))
	await get_tree().process_frame
	await get_tree().process_frame
	var lbl: Label = card.find_child("DescLabel", true, false)
	assert_not_null(lbl, "лейбл описания существует")
	var zone: Control = lbl.get_parent()
	assert_gt(lbl.get_line_count(), 3, "длинный текст переносится на много строк")
	var content_h: float = float(lbl.get_line_count()) * float(lbl.get_line_height())
	assert_gt(content_h, zone.size.y, "контент выше зоны — есть что скроллить")


func test_apply_offset_moves_label_up() -> void:
	var card: GameCard = _make_card("word ".repeat(140))
	await get_tree().process_frame
	var lbl: Label = card.find_child("DescLabel", true, false)
	var top0: float = lbl.offset_top
	card._desc_offset = 40.0
	card._apply_desc_offset()
	assert_almost_eq(lbl.offset_top, top0 - 40.0, 0.01, "сдвиг двигает текст вверх")


func test_short_desc_no_overflow() -> void:
	var card: GameCard = _make_card("кратко")
	await get_tree().process_frame
	await get_tree().process_frame
	var lbl: Label = card.find_child("DescLabel", true, false)
	var zone: Control = lbl.get_parent()
	var content_h: float = float(lbl.get_line_count()) * float(lbl.get_line_height())
	assert_lt(content_h, zone.size.y, "короткий текст влезает — скроллить нечего")
