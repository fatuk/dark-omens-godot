class_name DoomRunes
extends CanvasLayer

## Руны Ктулху поверх всего экрана — визуальный «градусник» безысходности.
## Чем дальше уехал трек Рока, тем больше знаков проступает.
##
## СЕЙЧАС К ТРЕКУ НЕ ПРИВЯЗАНО: `amount` и остальные параметры крутятся вручную в
## панели тюнинга (Ctrl+M, секция «РУНЫ РОКА») — сначала подбираем, как это должно
## выглядеть, и только потом решаем, какой amount какому doom соответствует.
## Привязка = снять ручной режим и считать amount из GameState.doom (см. _refresh).
##
## Отдельный слой, а не второй ColorRect в PostFx: тот выключается настройкой
## «постобработка», а руны — часть игрового состояния, их гасить нельзя.

const _SHADER := preload("res://assets/shaders/doom_runes.gdshader")
const GROUP: StringName = &"doom_runes"
const _ATLAS_N: int = 4  # глифов в ряду атласа (всего N×N разных рун)
const _ATLAS_PX: int = 512  # сторона атласа в пикселях
const _GLYPH_FILL: float = 0.8  # доля клетки под сам знак (поля не режут глиф)

## Ручной режим: amount задаёт панель тюнинга, а не трек Рока. Снять при привязке.
static var MANUAL: bool = true
static var MANUAL_AMOUNT: float = 0.0

var _rect: ColorRect


func _ready() -> void:
	layer = 201  # поверх постобработки (PostFx = 200): руны идут по самому верху
	add_to_group(GROUP)  # чтобы панель тюнинга дотянулась до живого слоя
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


func _build() -> void:
	_rect = ColorRect.new()
	_rect.name = "Runes"
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE  # слой чисто декоративный
	var mat := ShaderMaterial.new()
	mat.shader = _SHADER
	mat.set_shader_parameter("atlas", float(_ATLAS_N))
	_rect.material = mat
	add_child(_rect)
	_bake_atlas(mat)


# Атлас глифов: _ATLAS_N × _ATLAS_N случайных рун шрифта CTHUR, отрисованных в
# SubViewport. Берём НАСТОЯЩИЙ шрифт (тот же, что в рунном скрэмбле), а не рисуем
# знаки процедурно — иначе это были бы не руны, а просто угловатые штрихи.
func _bake_atlas(mat: ShaderMaterial) -> void:
	var vp := SubViewport.new()
	vp.name = "RuneAtlas"
	vp.size = Vector2i(_ATLAS_PX, _ATLAS_PX)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(vp)

	var grid := GridContainer.new()
	grid.name = "Glyphs"
	grid.columns = _ATLAS_N
	grid.add_theme_constant_override("h_separation", 0)
	grid.add_theme_constant_override("v_separation", 0)
	vp.add_child(grid)

	var cell: int = int(float(_ATLAS_PX) / float(_ATLAS_N))
	for i in range(_ATLAS_N * _ATLAS_N):
		var lbl := Label.new()
		lbl.name = "Glyph%d" % i
		lbl.text = char(randi_range(97, 122))  # глифы рун CTHUR — на строчных a–z
		lbl.add_theme_font_override("font", UIStyle.RUNE_FONT)
		lbl.add_theme_font_size_override("font_size", int(float(cell) * _GLYPH_FILL))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.custom_minimum_size = Vector2(cell, cell)
		grid.add_child(lbl)

	# Текстуру отдаём шейдеру после отрисовки кадра — до неё она пустая.
	await RenderingServer.frame_post_draw
	mat.set_shader_parameter("runes_tex", vp.get_texture())


## Текущее значение uniform'а (панель тюнинга читает и пишет через set_param).
func get_param(param: String) -> Variant:
	if not is_instance_valid(_rect):
		return null
	return (_rect.material as ShaderMaterial).get_shader_parameter(param)


## Записать uniform (панель тюнинга).
func set_param(param: String, value: Variant) -> void:
	if is_instance_valid(_rect):
		(_rect.material as ShaderMaterial).set_shader_parameter(param, value)


# Пока MANUAL — amount ведёт панель тюнинга. После привязки здесь будет доля
# трека Рока: doom / doomClock Древнего.
func _refresh() -> void:
	if not is_instance_valid(_rect):
		return
	if MANUAL:
		set_param("amount", MANUAL_AMOUNT)
		return
	var clock: int = maxi(1, int(GameState.campaign.get("doomClock", 12)))
	set_param("amount", clampf(float(GameState.doom) / float(clock), 0.0, 1.0))
