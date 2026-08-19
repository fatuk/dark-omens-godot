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
const GLOW_COLOR: Color = Color(0.85, 0.71, 0.32, 0.85)
const _GLOW_SPREAD: float = 1.55  # насколько ореол крупнее карточки

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
void fragment() {
	float d = length(v_local / half_size);
	float a = 1.0 - smoothstep(edge, 1.0, d);
	a *= 0.75 + 0.25 * sin(TIME * 2.4);
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


func setup(portrait: Texture2D) -> void:
	# Портрет в окне: Polygon2D по окну (искажённому перспективой), UV =
	# cover-crop портрета (заполняет окно, бока обрезаются формой полигона).
	var poly := Polygon2D.new()
	_portrait_poly = poly
	poly.name = "Portrait"
	poly.texture = portrait
	poly.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
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
	frame.z_index = 1
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
func set_active(active: bool) -> void:
	if not active:
		if is_instance_valid(_turn_glow):
			_turn_glow.queue_free()
			_turn_glow = null
		return
	if is_instance_valid(_turn_glow):
		return
	var hw: float = CARD_W * 0.5 * _GLOW_SPREAD
	var hh: float = CARD_H * 0.5 * _GLOW_SPREAD
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
	_turn_mat.set_shader_parameter(
		"glow", Vector4(GLOW_COLOR.r, GLOW_COLOR.g, GLOW_COLOR.b, GLOW_COLOR.a)
	)
	_turn_mat.set_shader_parameter("edge", 1.0 / _GLOW_SPREAD)
	_turn_mat.set_shader_parameter("half_size", Vector2(hw, hh))
	_turn_glow.material = _turn_mat
	add_child(_turn_glow)


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
