extends GutTest

## Токены шрифтов и «Размер текста» (UIFonts): текст растёт по настройке, заголовки —
## не больше DISPLAY_CAP, повторное применение не копит масштаб, смена настройки
## пересчитывает открытые узлы, вписывание не выпускает строку за рамку.

var _saved: float = 1.0


func before_each() -> void:
	_saved = SettingsStore.text_scale


func after_each() -> void:
	SettingsStore.text_scale = _saved


func test_text_scales_display_capped() -> void:
	SettingsStore.text_scale = 1.3
	assert_eq(UIFonts.px(UIFonts.BODY), 29, "текст — на 30 %")
	assert_eq(UIFonts.px(UIFonts.TITLE), 33, "заголовок — не больше 10 %")
	SettingsStore.text_scale = 1.0
	assert_eq(UIFonts.px(UIFonts.BODY), 22)
	assert_eq(UIFonts.px(UIFonts.TITLE), 30)


func test_art_scales_at_half_gain() -> void:
	SettingsStore.text_scale = 1.3
	assert_eq(UIFonts.px(UIFonts.art(20)), 23, "подпись на арте — вполсилы (+15 %)")
	assert_eq(UIFonts.px(UIFonts.art(14, 1.0)), 18, "своя доля прироста — как текст")
	SettingsStore.text_scale = 1.0
	assert_eq(UIFonts.px(UIFonts.art(20)), 20)


func test_number_is_fixed_and_token_is_live() -> void:
	SettingsStore.text_scale = 1.0
	var fixed := Label.new()
	fixed.name = "Hud"
	var live := Label.new()
	live.name = "Body"
	add_child_autofree(fixed)
	add_child_autofree(live)
	UIFonts.apply(fixed, 14)
	UIFonts.apply(live, UIFonts.BODY)
	UIFonts.apply(live, UIFonts.BODY)  # повтор — не копит
	SettingsStore.set_text_scale(1.3)
	assert_eq(fixed.get_theme_font_size("font_size"), 14, "число — не масштабируется")
	assert_eq(live.get_theme_font_size("font_size"), 29, "токен пересчитан на месте")
	SettingsStore.set_text_scale(1.0)
	assert_eq(live.get_theme_font_size("font_size"), 22, "и обратно — без накопления")


func test_fit_px_shrinks_to_width() -> void:
	var font: Font = ThemeDB.fallback_font
	var text := "Очень длинный заголовок окна"
	var wide: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 30).x
	assert_eq(UIFonts.fit_px(font, text, 30, wide + 5.0), 30, "влезает — не трогаем")
	var n: int = UIFonts.fit_px(font, text, 30, wide * 0.7)
	assert_lt(n, 30, "не влезает — меньше")
	assert_true(
		font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, n).x <= wide * 0.7,
		"и вписан в рамку"
	)
	assert_eq(UIFonts.fit_px(font, text, 30, 1.0), UIFonts.FIT_MIN_PX, "не меньше минимума")
