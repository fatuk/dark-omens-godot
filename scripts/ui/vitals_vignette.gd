class_name VitalsVignette
extends CanvasLayer

## Виньетка «на грани»: пульсирующая подсветка краёв экрана, когда у МОЕГО сыщика
## просела витальность. Красная — здоровье ниже половины, голубая — рассудок.
##
## ЛОКАЛЬНАЯ: читает GameState.my_player(), поэтому её видит только тот игрок,
## которому плохо. Соседям по столу экран не красит.
##
## Оба показателя ниже половины — берём ТОТ, которому хуже (меньшая доля): два
## цвета разом дали бы грязный фиолетовый, а сигнал должен читаться однозначно.
## Погибший сыщик подсветки не получает: ему уже не о чем предупреждать.

const _SHADER := preload("res://assets/shaders/screen_vignette.gdshader")
const GROUP: StringName = &"vitals_vignette"

const _THRESHOLD: float = 0.5  # с какой доли начинаем предупреждать
const _FADE: float = 0.5  # за сколько секунд наводим/снимаем подсветку

## Настройки (крутятся в панели тюнинга, секция «ВИНЬЕТКА ЖИЗНИ»).
static var C_HEALTH: Color = Color(0.62, 0.06, 0.06, 1.0)  # здоровье на исходе
static var C_SANITY: Color = Color(0.10, 0.42, 0.72, 1.0)  # рассудок на исходе
static var MAX_STRENGTH: float = 0.62  # сила при нулевой витальности
static var PULSE_SPEED: float = 2.4
static var PULSE_DEPTH: float = 0.55

var _rect: ColorRect
var _fade: Tween = null
var _shown: float = -1.0  # текущая сила подсветки (−1 — ещё не считали)


func _ready() -> void:
	layer = 202  # поверх рун Рока: это предупреждение, его нельзя терять под ними
	add_to_group(GROUP)
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


func _build() -> void:
	_rect = ColorRect.new()
	_rect.name = "Vitals"
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = _SHADER
	mat.set_shader_parameter("vig_strength", 0.0)
	mat.set_shader_parameter("vig_start", 0.35)
	mat.set_shader_parameter("vig_softness", 0.75)
	mat.set_shader_parameter("vig_pulse_speed", PULSE_SPEED)
	mat.set_shader_parameter("vig_pulse_depth", PULSE_DEPTH)
	_rect.material = mat
	add_child(_rect)


## Чтение/запись uniform'а — для панели тюнинга.
func get_param(param: String) -> Variant:
	if not is_instance_valid(_rect):
		return null
	return (_rect.material as ShaderMaterial).get_shader_parameter(param)


func set_param(param: String, value: Variant) -> void:
	if is_instance_valid(_rect):
		(_rect.material as ShaderMaterial).set_shader_parameter(param, value)


# Доля запаса: 1.0 — полный, 0.0 — на нуле. Нет максимума в стейте → считаем полным.
static func _ratio(p: Dictionary, cur: String, max_key: String) -> float:
	var m: int = int(p.get(max_key, 0))
	if m <= 0:
		return 1.0
	return clampf(float(p.get(cur, 0)) / float(m), 0.0, 1.0)


func _refresh() -> void:
	if not is_instance_valid(_rect):
		return
	var me: Dictionary = GameState.my_player()
	var hp: float = _ratio(me, "hp", "hp_max")
	var san: float = _ratio(me, "sanity", "sanity_max")
	var worst: float = minf(hp, san)

	# Мёртвому не предупреждаем; выше порога — подсветки нет.
	if me.is_empty() or bool(me.get("dead", false)) or worst >= _THRESHOLD:
		_fade_to(0.0)
		return

	# Цвет — по тому показателю, которому хуже. Сила растёт от порога к нулю.
	set_param("vig_color", C_HEALTH if hp <= san else C_SANITY)
	_fade_to(MAX_STRENGTH * clampf((_THRESHOLD - worst) / _THRESHOLD, 0.0, 1.0))


# Плавно ведём силу к целевой: витальность меняется рывками (урон/лечение), без
# этого подсветка вспыхивала бы скачком.
func _fade_to(target: float) -> void:
	if is_equal_approx(target, _shown):
		return  # ничего не изменилось — синки приходят часто
	var from: float = maxf(_shown, 0.0)
	_shown = target
	if _fade != null and _fade.is_valid():
		_fade.kill()
	_fade = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_fade.tween_method(func(v: float) -> void: set_param("vig_strength", v), from, target, _FADE)
