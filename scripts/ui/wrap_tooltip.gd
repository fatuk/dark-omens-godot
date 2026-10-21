class_name WrapTooltip
extends Control

## Контрол со всплывающей подсказкой, которая переносит длинный текст: ширина —
## по тексту, но не больше MAX_W, дальше строки переносятся по словам. Стандартная
## подсказка Godot тянется в одну строку на весь экран (монстр со способностью).
##
##   var tile := WrapTooltip.new()
##   tile.tooltip_text = "…"

const MAX_W: float = 460.0


func _make_custom_tooltip(for_text: String) -> Object:
	return make_label(for_text)


## Метка подсказки с переносом: короткий текст — в свою ширину, длинный — в MAX_W.
## Общая и для контролов, которые не наследуют этот класс.
static func make_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.name = "TooltipText"
	lbl.theme_type_variation = &"TooltipLabel"
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var font: Font = lbl.get_theme_font("font", &"TooltipLabel")
	var fs: int = lbl.get_theme_font_size("font_size", &"TooltipLabel")
	var natural: float = font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	lbl.custom_minimum_size.x = minf(ceilf(natural) + 2.0, MAX_W)
	return lbl
