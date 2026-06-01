class_name DiceTray
extends HBoxContainer

## Единый компонент отрисовки броска кубиков — ВСЕ проверки выглядят одинаково.
## Логика броска — в Dice; здесь только показ результата и выбор куба к перебросу.
##
## API:
##   tray.show_roll(values, can_reroll)  — показать результат (кликабельны провалы)
##   tray.show_pending(count)            — кубы «рубашкой вверх» до броска
##   signal die_selected(index)          — клик по перебрасываемому кубу
##
## ЕДИНАЯ точка отрисовки одного куба — _make_die(). Когда появятся ассеты граней
## кубов, менять нужно только её, и все проверки обновятся разом.

signal die_selected(index: int)

const DIE_SIZE: Vector2 = Vector2(44, 44)
const _BG_NORMAL  := Color(0.10, 0.10, 0.13, 0.92)
const _BG_HOVER   := Color(0.20, 0.17, 0.10, 0.96)


func _init() -> void:
	name = "DiceTray"
	add_theme_constant_override("separation", 8)
	alignment = BoxContainer.ALIGNMENT_CENTER


## Показать результат броска. can_reroll → провальные кубы (d<5) кликабельны
## (янтарная рамка) для переброса за концентрацию; успешные — зелёные, не жмутся.
func show_roll(values: Array, can_reroll: bool = false) -> void:
	_clear()
	for i in range(values.size()):
		add_child(_make_die(int(values[i]), can_reroll, i))


## Показать `count` кубов до броска («рубашкой вверх»).
func show_pending(count: int) -> void:
	_clear()
	for i in range(maxi(0, count)):
		add_child(_make_die(0, false, i))


func _clear() -> void:
	for c in get_children():
		c.queue_free()


# value <= 0 → ещё не брошен (рубашка). ЕДИНАЯ точка отрисовки куба.
func _make_die(value: int, can_reroll: bool, index: int) -> Control:
	var pending: bool   = value <= 0
	var success: bool   = (not pending) and Dice.is_success(value)
	var clickable: bool = can_reroll and not pending and not success

	var edge: Color
	if pending:      edge = UIColors.MUTED
	elif success:    edge = UIColors.SUCCESS
	elif clickable:  edge = UIColors.ACCENT
	else:            edge = UIColors.MUTED

	var chip := Button.new()
	chip.name = "Die"
	chip.text = "" if pending else str(value)
	chip.custom_minimum_size = DIE_SIZE
	chip.focus_mode = Control.FOCUS_NONE
	chip.add_theme_font_size_override("font_size", 20)
	var fcol: Color = UIColors.SUCCESS if success else UIColors.TEXT
	chip.add_theme_color_override("font_color", fcol)
	chip.add_theme_color_override("font_disabled_color", fcol)   # не сереть в disabled
	chip.add_theme_color_override("font_hover_color", fcol)

	var sb := StyleBoxFlat.new()
	sb.bg_color = _BG_NORMAL
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(2)
	sb.border_color = edge
	chip.add_theme_stylebox_override("normal", sb)
	chip.add_theme_stylebox_override("disabled", sb)
	var sb_hi := sb.duplicate() as StyleBoxFlat
	sb_hi.bg_color = _BG_HOVER
	chip.add_theme_stylebox_override("hover", sb_hi)
	chip.add_theme_stylebox_override("pressed", sb_hi)

	if clickable:
		var idx: int = index
		chip.pressed.connect(func() -> void: die_selected.emit(idx))
	else:
		chip.disabled = true
	return chip
