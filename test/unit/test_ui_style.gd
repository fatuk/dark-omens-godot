extends GutTest

## Регрессия рунного «скрэмбла» (UIStyle.rune_scramble): значение должно ПРОЯВИТЬСЯ
## даже когда предыдущий скрэмбл прерван новым (частые update() в пикере). Баг был:
## новый скрэмбл захватывал стоящий на лейбле РУННЫЙ шрифт как «базовый» и в финале
## восстанавливал руны — значение так и не появлялось.


func test_rune_scramble_settles_value_after_interruption() -> void:
	var lbl := Label.new()
	add_child_autofree(lbl)
	UIStyle.rune_scramble(lbl, "3")
	await get_tree().process_frame
	await get_tree().process_frame  # первый скрэмбл уже поставил рунный шрифт
	UIStyle.rune_scramble(lbl, "5")  # прерываем первый
	await get_tree().create_timer(1.2).timeout  # ждём завершения (8 кадров с джиттером + запас)
	assert_eq(lbl.text, "5", "значение проявилось, а не залипло на рунах")
	assert_false(lbl.has_theme_font_override("font"), "рунный шрифт снят (base был null)")


func test_rune_scramble_settles_value_clean_run() -> void:
	var lbl := Label.new()
	add_child_autofree(lbl)
	UIStyle.rune_scramble(lbl, "7")
	await get_tree().create_timer(1.2).timeout
	assert_eq(lbl.text, "7", "обычный скрэмбл проявляет значение")
