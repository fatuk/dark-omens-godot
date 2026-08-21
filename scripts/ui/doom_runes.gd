class_name DoomRunes
extends CanvasLayer

## Руны Ктулху поверх КАРТЫ МИРА — визуальный «градусник» безысходности.
## Чем дальше уехал трек Рока, тем больше знаков проступает.
##
## Проявленность рун и сила виньетки растут ЛИНЕЙНО с треком Рока: 0 в начале
## партии, MAX_* при полном треке (то есть прямо перед поражением). Остальные
## параметры — постоянный «облик», их трек не трогает.
##
## Панель тюнинга (Ctrl+M, секции «РУНЫ РОКА» и «ВИНЬЕТКА») крутит всё живьём;
## слайдеры проявленности и силы виньетки переводят слой в ручной режим (MANUAL),
## иначе следующий синк тут же вернул бы значение с трека.
##
## Отдельный слой, а не второй ColorRect в PostFx: тот выключается настройкой
## «постобработка», а руны — часть игрового состояния, их гасить нельзя.

const _SHADER := preload("res://assets/shaders/doom_runes.gdshader")
const _VIGNETTE_SHADER := preload("res://assets/shaders/screen_vignette.gdshader")
const GROUP: StringName = &"doom_runes"
const _ATLAS_N: int = 4  # глифов в ряду атласа (всего N×N разных рун)
const _ATLAS_PX: int = 512  # сторона атласа в пикселях
const _GLYPH_FILL: float = 0.8  # доля клетки под сам знак (поля не режут глиф)

const _RAMP: float = 1.2  # за сколько секунд доезжаем до нового уровня Рока

## Значения при ПОЛНОМ треке Рока (подобраны в панели). От них ведём линейно.
static var MAX_AMOUNT: float = 0.99  # проявленность рун
static var MAX_VIGNETTE: float = 0.56  # сила виньетки

## Ручной режим: значения задаёт панель тюнинга, а не трек. Включается сама, когда
## трогают соответствующий слайдер.
static var MANUAL: bool = false
static var MANUAL_AMOUNT: float = 0.99
static var MANUAL_VIGNETTE: float = 0.56

var _rect: ColorRect
var _vig: ColorRect
var _ramp: Tween = null  # плавный переезд к новому уровню
var _level: float = -1.0  # доля трека, на которую сейчас настроены слои


func _ready() -> void:
	# Между картой (слой 0) и нижней панелью сыщика (10): руны ложатся на мир, но не
	# на интерфейс. Раньше слой был 201 — поверх вообще всего, и знаки с виньеткой
	# заползали на панели, сайдбары и модалки, мешая их читать.
	# PostFx (200) теперь выше рун и накрывает их своей плёнкой — это не «гашение»
	# настройкой: руны рисуются всегда, просто получают ту же обработку, что и мир.
	layer = 5
	add_to_group(GROUP)  # чтобы панель тюнинга дотянулась до живого слоя
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


func _build() -> void:
	# Виньетка — ОТДЕЛЬНЫМ проходом ПОД рунами: она затемняет (blend_mix), а руны
	# рисуются аддитивно и затемнять не умеют — в одном шейдере не совместить.
	_vig = ColorRect.new()
	_vig.name = "Vignette"
	_vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vmat := ShaderMaterial.new()
	vmat.shader = _VIGNETTE_SHADER
	_vig.material = vmat
	add_child(_vig)

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
	var target: ColorRect = _vig if param.begins_with("vig_") else _rect
	if not is_instance_valid(target):
		return null
	return (target.material as ShaderMaterial).get_shader_parameter(param)


## Записать uniform (панель тюнинга).
## Параметры с префиксом vig_ уходят в слой виньетки, остальные — в руны.
func set_param(param: String, value: Variant) -> void:
	var target: ColorRect = _vig if param.begins_with("vig_") else _rect
	if is_instance_valid(target):
		(target.material as ShaderMaterial).set_shader_parameter(param, value)


# Доля пройденного трека Рока → проявленность рун и сила виньетки (линейно).
# doomClock берём из кампании — у каждого Древнего он свой (та же величина, по
# которой рисуется трек и объявляется поражение), поэтому доля везде честная.
func _refresh() -> void:
	if not is_instance_valid(_rect):
		return
	if MANUAL:
		_kill_ramp()
		_level = -1.0
		_apply_level(MANUAL_AMOUNT, MANUAL_VIGNETTE)
		return
	var clock: int = maxi(1, int(GameState.campaign.get("doomClock", 12)))
	var t: float = clampf(float(GameState.doom) / float(clock), 0.0, 1.0)
	if is_equal_approx(t, _level):
		return  # уровень не менялся — синки приходят часто, дёргать нечего
	# Первая раскладка (вход в партию) — сразу, без переезда: анимировать нечего.
	if _level < 0.0:
		_level = t
		_apply_level(MAX_AMOUNT * t, MAX_VIGNETTE * t)
		return
	_ramp_to(t)


# Плавный переезд от текущего уровня к новому: дум растёт целыми делениями, и без
# этого руны с виньеткой скачком меняли яркость на каждый тик Рока.
func _ramp_to(target: float) -> void:
	_kill_ramp()
	var from: float = _level
	_level = target
	_ramp = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_ramp.tween_method(
		func(t: float) -> void: _apply_level(MAX_AMOUNT * t, MAX_VIGNETTE * t), from, target, _RAMP
	)


func _kill_ramp() -> void:
	if _ramp != null and _ramp.is_valid():
		_ramp.kill()


func _apply_level(runes: float, vig: float) -> void:
	set_param("amount", runes)
	set_param("vig_strength", vig)
