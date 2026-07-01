class_name OmensCounter
extends Control

## Компасный диск «омен» — слева на главной панели.
## Внутренний Circle вращается через rotation_degrees (показывая разные омены),
## но виден только через круглую маску в шейдере (привязана к canvas-центру
## контейнера, не вращается с диском).
##
## current_step — текущее состояние из игры. При наведении мышью диск
## плавно подкручивается на +0.3 шага, чтобы юзер мог «подсмотреть»
## следующий омен. Уход мыши — возвращает на current_step.

# Настройки арта круга — static, чтобы тюнить на лету в дебаг-панели шейдеров
# (Ctrl+M, секция «КРУГ ЗНАМЕНИЙ») и переживать пересоздание узла.
static var STEP_DEG: float = 45.0  # градусов между оменами на диске
static var START_ANGLE_DEG: float = -82.0  # база поворота диска (выравнивает омен под окно)
static var MASK_RADIUS: float = 46.0  # радиус видимого окошка (canvas-координаты)
static var MASK_OFFSET_X: float = 0.0  # сдвиг ОКНА-маски от центра компонента (под арт рамки)
static var MASK_OFFSET_Y: float = 0.0
static var POS_OFFSET_X: float = 0.0  # сдвиг ВСЕГО виджета на панели (позиция узла)
static var POS_OFFSET_Y: float = 0.0
const PEEK_AMOUNT: float = 0.3
const TWEEN_TIME: float = 0.3  # секунды — короткий peek по наведению
const OMEN_MOVE_TIME: float = 0.3  # фолбэк длительности сдвига (берём длину omen-move.wav)

@export var current_step: float = 0.0:
	set(v):
		# Сеттер дёргается на каждом state_changed-рефреше тем же значением —
		# проворачиваем диск (5с + звук) только при реальной смене ступени.
		# Первичная установка — мгновенно, без звука (синк при входе в игру).
		var changed: bool = not is_equal_approx(v, current_step)
		current_step = v
		if not _initialized:
			_initialized = true
			_animate_to(v, TWEEN_TIME)
			return
		if not changed:
			return
		# Длительность проворота = длина звука сдвига (синхронно, как у peek).
		SfxManager.play(SfxManager.SFX_OMEN_MOVE)
		_animate_to(v, _stream_len(SfxManager.SFX_OMEN_MOVE, OMEN_MOVE_TIME))

@onready var _circle: TextureRect = %Circle

var _tween: Tween = null
var _initialized: bool = false
var _base_pos: Vector2 = Vector2.ZERO  # позиция из раскладки; POS_OFFSET прибавляем к ней
var _base_pos_set: bool = false


func _ready() -> void:
	add_to_group("omens_counter")  # чтобы дебаг-панель шейдеров (Ctrl+M) нашла узел
	mouse_entered.connect(_on_hover)
	mouse_exited.connect(_on_unhover)
	# Первый layout-pass для корректных global_position/size
	await get_tree().process_frame
	_base_pos = position
	_base_pos_set = true
	_update_mask_center()
	_circle.rotation_degrees = _angle_for(current_step)


func _process(_delta: float) -> void:
	# Сдвиг всего виджета (дебаг-панель) — от базовой позиции раскладки. Узел
	# anchor-based (не в контейнере), так что position не перетирается.
	if _base_pos_set:
		position = _base_pos + Vector2(POS_OFFSET_X, POS_OFFSET_Y)
	# Позиция компонента могла смениться (сдвиг/resize) — пересчитать центр маски.
	_update_mask_center()


func _on_hover() -> void:
	# Подсматривание следующего омена: длительность анимации = длина звука,
	# чтобы поворот диска шёл синхронно с эффектом.
	SfxManager.play(SfxManager.SFX_OMEN_PICK_IN)
	_animate_to(current_step + PEEK_AMOUNT, _stream_len(SfxManager.SFX_OMEN_PICK_IN, TWEEN_TIME))


func _on_unhover() -> void:
	SfxManager.play(SfxManager.SFX_OMEN_PICK_OUT)
	_animate_to(current_step, _stream_len(SfxManager.SFX_OMEN_PICK_OUT, TWEEN_TIME))


## Длина аудиопотока в секундах (с фолбэком, если поток пуст/нулевой).
func _stream_len(stream: AudioStream, fallback: float) -> float:
	if stream != null:
		var l: float = stream.get_length()
		if l > 0.0:
			return l
	return fallback


func _animate_to(step_value: float, duration: float) -> void:
	if not is_instance_valid(_circle):
		return
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_circle, "rotation_degrees", _angle_for(step_value), duration)


func _angle_for(step_value: float) -> float:
	return START_ANGLE_DEG + step_value * STEP_DEG


func _update_mask_center() -> void:
	if not is_instance_valid(_circle):
		return
	var mat: ShaderMaterial = _circle.material as ShaderMaterial
	if mat == null:
		return
	# Пишем каждый кадр (дёшево) — так живая подстройка радиуса/сдвига из дебаг-панели
	# сразу видна. Сдвиг MASK_OFFSET — под центр отверстия нового арта рамки.
	mat.set_shader_parameter(
		"mask_center", global_position + size * 0.5 + Vector2(MASK_OFFSET_X, MASK_OFFSET_Y)
	)
	mat.set_shader_parameter("mask_radius", MASK_RADIUS)


## Переприменить поворот диска под текущие STEP_DEG/START_ANGLE_DEG (для дебаг-панели).
## Во время твина (peek/сдвиг) не трогаем — иначе дёрнется.
func debug_reapply_angle() -> void:
	if is_instance_valid(_circle) and not (_tween and _tween.is_valid()):
		_circle.rotation_degrees = _angle_for(current_step)
