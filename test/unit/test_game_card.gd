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


# Высота текста как в проде: строки × (высота строки + межстрочный интервал).
func _content_h(lbl: Label) -> float:
	var spacing: float = float(lbl.get_theme_constant("line_spacing"))
	return float(lbl.get_line_count()) * (float(lbl.get_line_height()) + spacing)


func test_long_desc_overflows_zone() -> void:
	var card: GameCard = _make_card("word ".repeat(140))
	await get_tree().process_frame
	await get_tree().process_frame
	var lbl: Label = card.find_child("DescLabel", true, false)
	assert_not_null(lbl, "лейбл описания существует")
	var zone: Control = lbl.get_parent()
	assert_gt(lbl.get_line_count(), 3, "длинный текст переносится на много строк")
	assert_gt(_content_h(lbl), zone.size.y, "контент выше зоны — есть что скроллить")


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
	assert_lt(_content_h(lbl), zone.size.y, "короткий текст влезает — скроллить нечего")


func _wheel(card: GameCard, down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_DOWN if down else MOUSE_BUTTON_WHEEL_UP
	ev.pressed = true
	card._gui_input(ev)


func test_wheel_scrolls_desc_of_large_card() -> void:
	var card: GameCard = _make_card("word ".repeat(140))
	card.size = Vector2(300.0, 300.0 / GameCard.ASPECT)  # крупная: выше порога
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(card.is_desc_scrollable(), "крупная карта крутится")
	_wheel(card, true)
	assert_gt(card._desc_offset, 0.0, "колесо вниз сдвинуло описание")
	_wheel(card, false)
	assert_almost_eq(card._desc_offset, 0.0, 0.01, "колесо вверх вернуло к началу")


func test_wheel_ignores_small_card() -> void:
	var card: GameCard = _make_card("word ".repeat(140))
	card.size = Vector2(150.0, 150.0 / GameCard.ASPECT)  # миниатюра: ниже порога
	await get_tree().process_frame
	await get_tree().process_frame
	assert_false(card.is_desc_scrollable(), "мелкую карту не крутим")
	_wheel(card, true)
	assert_almost_eq(card._desc_offset, 0.0, 0.01, "колесо мелкую карту не сдвинуло")
