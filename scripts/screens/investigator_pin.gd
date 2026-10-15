class_name InvestigatorPin
extends Node2D

## Пин сыщика на карте — фото-карточка: портрет в окне рамки avatar-pin.
## Чистый 2D (без SubViewport/3D). Портрет натянут на Polygon2D точно по окну
## рамки (cover-crop), рамка-ассет рисуется поверх. Перспективу (трапецию)
## можно включить позже, заменив прямоугольный polygon на трапециевидный.
##
## Координаты — в нативных пикселях ассета (325×465, origin в центре карточки).
## MapLayer масштабирует/позиционирует весь Node2D как раньше плоские маркеры.

const FRAME_TEX: Texture2D = preload("res://assets/map/avatar-pin.png")

# Ореол хода: золото под цвет рамки, заметно ярче фона карты и НЕ лаймовый —
# лайм уже занят подсветкой выделения (SelectionIndicator), путать нельзя.
# static var, а не const: тюнинг-панель крутит их вживую (см. GROUP/refresh_glow).
const GLOW_RGB: Color = UIColors.ACTIVE  # единый цвет активного выделения
static var GLOW_ALPHA: float = 0.85  # яркость в самой плотной части
static var GLOW_SPREAD: float = 1.55  # насколько ореол крупнее карточки
static var GLOW_PULSE_SPEED: float = 2.4  # скорость дыхания, рад/с
static var GLOW_PULSE_AMOUNT: float = 0.25  # глубина дыхания (0 — ровное свечение)
const GLOW_FADE: float = 0.45  # сек на плавное появление/угасание ореола хода

## Группа всех пинов на карте — тюнинг-панель через неё переприменяет параметры.
const GROUP := "investigator_pins"

## Прозрачность карточки вышедшего игрока.
static var AWAY_ALPHA: float = 0.4

# Ореол вокруг карточки: сплошная заливка ВНУТРИ силуэта (её всё равно закрывает
# портрет с рамкой) и затухание наружу. Расстояние считаем от ПОЗИЦИИ ВЕРШИНЫ, а
# не от UV: у Polygon2D без текстуры массив uv в шейдер не попадает, UV там нулевой,
# и на нём альфа выходила нулевой всюду — ореола не было видно вообще.
# edge — где по этой мере проходит край карточки (обратная _GLOW_SPREAD).
const _GLOW_SHADER := """
shader_type canvas_item;
uniform vec4 glow;
uniform vec2 half_size;
uniform float edge;
varying vec2 v_local;
void vertex() {
	v_local = VERTEX;
}
uniform float pulse_speed;
uniform float pulse_amount;
void fragment() {
	float d = length(v_local / half_size);
	float a = 1.0 - smoothstep(edge, 1.0, d);
	a *= (1.0 - pulse_amount) + pulse_amount * sin(TIME * pulse_speed);
	COLOR = vec4(glow.rgb, glow.a * a);
}
"""

# Ч/б портрет мёртвого сыщика (Тень). Обесцвечиваем УЖЕ сэмплированный COLOR —
# без texture()/UV, поэтому корректно и на Polygon2D (пиксельные UV), и с мипмапами.
const _DEAD_SHADER := """
shader_type canvas_item;
void fragment() {
	float g = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	COLOR.rgb = vec3(g);
}
"""

var _portrait_poly: Polygon2D
var _turn_glow: Polygon2D  # ореол «сейчас ходит» ПОД карточкой (см. set_active)
var _turn_mat: ShaderMaterial
var _turn_on: bool = false  # ореол включён (цель фейда)
var _turn_level: float = 0.0  # текущая яркость ореола 0..1 (ведёт твин)
var _turn_tw: Tween

# Размер карточки (нативный, ассет @2×) и геометрия прозрачного окна под портрет.
const CARD_W: float = 325.0
const CARD_H: float = 465.0
# Окно под портрет (центр относительно центра карточки + размер). С небольшим
# overscan по высоте — портрет перекрывает окно до самой рамки, без зазора
# сверху. Лишнее обрезается рамкой-ассетом поверх.
const WIN_CENTER := Vector2(-9.5, 10.0)
const WIN_SIZE := Vector2(264.0, 372.0)

## Перспектива «карточка наклонена к зрителю, основание уходит в карту».
## Нижний край сужается (BOT_SCALE), верхний — полная ширина; ряды у низа
## слегка сжаты по высоте (BOT_SQUASH). Применяется к рамке и портрету
## одинаково — оба Polygon2D, поэтому окно и портрет искажаются согласованно.
## Билинейный маппинг Polygon2D даёт лёгкий шир на трапеции — для умеренного
## наклона незаметно.
const PERSP_BOT_SCALE: float = 0.8  # ширина нижнего края (доля от верхнего)
const PERSP_BOT_SQUASH: float = 0.20  # сжатие по высоте у нижнего края


# Кейстоун карточки: точку card-space (origin в центре) проецирует в трапецию.
# t∈[0,1]: 0 — верх карточки, 1 — низ. Нижние ряды сужаются по X и слегка
# подтягиваются вверх по Y (перспективное укорочение основания).
func _persp(p: Vector2) -> Vector2:
	var t: float = (p.y + CARD_H * 0.5) / CARD_H
	var sx: float = lerpf(1.0, PERSP_BOT_SCALE, t)
	var y_squash: float = lerpf(0.0, PERSP_BOT_SQUASH, t) * CARD_H * 0.5
	return Vector2(p.x * sx, p.y - y_squash)


func _ready() -> void:
	add_to_group(GROUP)


func setup(portrait: Texture2D) -> void:
	# Портрет в окне: Polygon2D по окну (искажённому перспективой), UV =
	# cover-crop портрета (заполняет окно, бока обрезаются формой полигона).
	var poly := Polygon2D.new()
	_portrait_poly = poly
	poly.name = "Portrait"
	poly.texture = portrait
	poly.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Портрет и рамка — на ОДНОМ слое z (порядок — по дереву): разные z сквозят между
	# пинами — рамка соседнего пина рисовалась бы поверх этого портрета.
	poly.z_index = 0
	var hw: float = WIN_SIZE.x * 0.5
	var hh: float = WIN_SIZE.y * 0.5
	poly.polygon = PackedVector2Array(
		[
			_persp(WIN_CENTER + Vector2(-hw, -hh)),
			_persp(WIN_CENTER + Vector2(hw, -hh)),
			_persp(WIN_CENTER + Vector2(hw, hh)),
			_persp(WIN_CENTER + Vector2(-hw, hh)),
		]
	)
	if portrait != null:
		var pw: float = float(portrait.get_width())
		var ph: float = float(portrait.get_height())
		# cover по высоте: UV занимает всю высоту портрета, ширина — по аспекту
		# окна, центрированно (обрезаются бока квадратного портрета).
		var uvw: float = ph * (WIN_SIZE.x / WIN_SIZE.y)
		var ux0: float = (pw - uvw) * 0.5
		poly.uv = PackedVector2Array(
			[
				Vector2(ux0, 0.0),
				Vector2(ux0 + uvw, 0.0),
				Vector2(ux0 + uvw, ph),
				Vector2(ux0, ph),
			]
		)
	add_child(poly)

	# Рамка-ассет поверх портрета — тоже Polygon2D, чтобы искажалась той же
	# перспективой, что и портрет. UV — полная текстура (origin в её центре).
	var fhw: float = CARD_W * 0.5
	var fhh: float = CARD_H * 0.5
	var frame := Polygon2D.new()
	frame.name = "Frame"
	frame.texture = FRAME_TEX
	frame.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	frame.z_index = 0  # над портретом — порядком в дереве (добавлена позже)
	frame.polygon = PackedVector2Array(
		[
			_persp(Vector2(-fhw, -fhh)),
			_persp(Vector2(fhw, -fhh)),
			_persp(Vector2(fhw, fhh)),
			_persp(Vector2(-fhw, fhh)),
		]
	)
	frame.uv = PackedVector2Array(
		[
			Vector2(0.0, 0.0),
			Vector2(CARD_W, 0.0),
			Vector2(CARD_W, CARD_H),
			Vector2(0.0, CARD_H),
		]
	)
	add_child(frame)


## Пометка «сейчас ходит»: мягкий золотой ореол ПОД карточкой. Живёт на самом
## пине, поэтому едет вместе с ним при панорамировании, зуме и веере на клетке —
## отдельной ноде пришлось бы синхронить позицию каждый кадр.
## Включение/выключение — плавным фейдом яркости (не скачком).
func set_active(active: bool) -> void:
	if active == _turn_on:
		return
	_turn_on = active
	if active and not is_instance_valid(_turn_glow):
		_build_turn_glow()
	if not is_instance_valid(_turn_glow):
		return
	if _turn_tw != null and _turn_tw.is_valid():
		_turn_tw.kill()
	_turn_tw = create_tween()
	_turn_tw.tween_method(_set_turn_level, _turn_level, 1.0 if active else 0.0, GLOW_FADE)
	if not active:
		_turn_tw.tween_callback(_drop_turn_glow)


# Яркость ореола (0..1) — множитель альфы glow в шейдере (modulate шейдер не видит:
# он целиком задаёт COLOR).
func _set_turn_level(v: float) -> void:
	_turn_level = v
	if _turn_mat != null:
		_turn_mat.set_shader_parameter(
			"glow", Vector4(GLOW_RGB.r, GLOW_RGB.g, GLOW_RGB.b, GLOW_ALPHA * v)
		)


func _drop_turn_glow() -> void:
	if is_instance_valid(_turn_glow):
		_turn_glow.queue_free()
	_turn_glow = null


func _build_turn_glow() -> void:
	var hw: float = CARD_W * 0.5 * GLOW_SPREAD
	var hh: float = CARD_H * 0.5 * GLOW_SPREAD
	_turn_glow = Polygon2D.new()
	_turn_glow.name = "TurnGlow"
	_turn_glow.z_index = -1  # под портретом и рамкой
	_turn_glow.polygon = PackedVector2Array(
		[
			_persp(Vector2(-hw, -hh)),
			_persp(Vector2(hw, -hh)),
			_persp(Vector2(hw, hh)),
			_persp(Vector2(-hw, hh)),
		]
	)
	_turn_glow.uv = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	_turn_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = _GLOW_SHADER
	_turn_mat.shader = sh
	_turn_glow.material = _turn_mat
	_apply_glow_params(hw, hh)
	add_child(_turn_glow)


# Параметры ореола в материал. Отдельно от сборки — их же переприменяет
# refresh_glow, когда тюнинг-панель подвинула ползунок.
func _apply_glow_params(hw: float, hh: float) -> void:
	_set_turn_level(_turn_level)  # glow: цвет × текущая яркость фейда
	_turn_mat.set_shader_parameter("edge", 1.0 / GLOW_SPREAD)
	_turn_mat.set_shader_parameter("half_size", Vector2(hw, hh))
	_turn_mat.set_shader_parameter("pulse_speed", GLOW_PULSE_SPEED)
	_turn_mat.set_shader_parameter("pulse_amount", GLOW_PULSE_AMOUNT)


## Тюнинг-панель подвинула ползунок — пересобираем ореол (размах меняет геометрию
## полигона, поэтому проще собрать заново, чем править точки).
func refresh_glow() -> void:
	if not is_instance_valid(_turn_glow):
		return
	_turn_glow.free()  # сразу, без фейда: яркость (_turn_level) сохраняется
	_turn_glow = null
	_build_turn_glow()


## Игрок вышел из комнаты: карточка полупрозрачная — «его тут нет». Намеренно НЕ
## ч/б: серый уже значит Тень (set_dead), а это состояние временное — слот держат
## до возвращения, и по возврату карточка просто снова наливается цветом.
func set_away(away: bool) -> void:
	modulate.a = AWAY_ALPHA if away else 1.0


## Мёртвый сыщик (Тень) — портрет ч/б. Рамка остаётся цветной.
func set_dead(dead: bool) -> void:
	if not is_instance_valid(_portrait_poly):
		return
	if not dead:
		_portrait_poly.material = null
		return
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = _DEAD_SHADER
	mat.shader = sh
	_portrait_poly.material = mat


# Высота карточки в нативных пикселях — MapLayer завязывает на неё экранный
# размер пина и якорит основание к локации.
static func card_height() -> float:
	return CARD_H
