extends Control

## Зелёный орб справа на главной панели — отображает число (текущий раунд,
## количество омен и т.п.) поверх декоративного фона. Цифра — жирная (embolden
## поверх дефолтного шрифта темы); при СМЕНЕ значения проигрывается рунный
## «скрэмбл» (как при выборе сыщика в лобби).

const _BASE_FONT: Font = preload("res://assets/fonts/Forum-Regular.ttf")
const _EMBOLDEN: float = 0.6  # сила утолщения глифов FontVariation
const _SCRAMBLE_RUNES: int = 2  # сколько рун мелькает в кадре скрэмбла

@export var label_text: String = "":
	set(v):
		if v == label_text:
			return  # то же значение — без анимации (set_info зовётся каждый рефреш)
		label_text = v
		if is_node_ready():
			# Смена значения — рунный скрэмбл к новой цифре (фикс. 2 руны в кадре).
			UIStyle.rune_scramble(_label, v, _SCRAMBLE_RUNES)

@onready var _label: Label = %Label


func _ready() -> void:
	_apply_bold()
	_label.text = label_text  # первый показ — мгновенно, без скрэмбла


# Жирная цифра: FontVariation.variation_embolden поверх шрифта темы. Скрэмбл
# восстанавливает именно этот override в финале, так что жирность не слетает.
func _apply_bold() -> void:
	var bold := FontVariation.new()
	bold.base_font = _BASE_FONT
	bold.variation_embolden = _EMBOLDEN
	_label.add_theme_font_override("font", bold)
