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
	assert_gt(card._desc_target, 0.0, "колесо вниз задало цель прокрутки")
	card._process(0.016)
	assert_gt(card._desc_offset, 0.0, "описание поехало к цели")
	assert_lt(card._desc_offset, card._desc_target, "плавно, а не прыжком")
	card._process(2.0)
	assert_almost_eq(card._desc_offset, card._desc_target, 0.01, "доехало до цели")
	_wheel(card, false)
	card._process(2.0)
	assert_almost_eq(card._desc_offset, 0.0, 0.01, "колесо вверх вернуло к началу")


func test_wheel_ignores_small_card() -> void:
	var card: GameCard = _make_card("word ".repeat(140))
	card.size = Vector2(150.0, 150.0 / GameCard.ASPECT)  # миниатюра: ниже порога
	await get_tree().process_frame
	await get_tree().process_frame
	assert_false(card.is_desc_scrollable(), "мелкую карту не крутим")
	_wheel(card, true)
	assert_almost_eq(card._desc_offset, 0.0, 0.01, "колесо мелкую карту не сдвинуло")


# Смена «Размера текста» в настройках пересчитывает описание уже построенной карты.
func test_text_scale_setting_resizes_built_card() -> void:
	var card: GameCard = _make_card("word ".repeat(40))
	var lbl: Label = card.find_child("DescLabel", true, false)
	var store: Node = get_tree().root.get_node("SettingsStore")
	var was: float = float(store.get("text_scale"))
	store.set("text_scale", 1.0)
	UIFonts.refresh_all(get_tree())
	var base_px: int = lbl.get_theme_font_size("font_size")
	store.set("text_scale", 1.3)
	UIFonts.refresh_all(get_tree())
	var big_px: int = lbl.get_theme_font_size("font_size")
	store.set("text_scale", was)
	UIFonts.refresh_all(get_tree())
	assert_gt(big_px, base_px, "крупнее в настройках — крупнее описание на карте")
