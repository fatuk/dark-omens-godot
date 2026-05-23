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

# Размер карточки (нативный, ассет @2×) и геометрия прозрачного окна под портрет.
const CARD_W: float = 325.0
const CARD_H: float = 465.0
# Окно под портрет (центр относительно центра карточки + размер). С небольшим
# overscan по высоте — портрет перекрывает окно до самой рамки, без зазора
# сверху. Лишнее обрезается рамкой-ассетом поверх.
const WIN_CENTER := Vector2(-9.5, 10.0)
const WIN_SIZE   := Vector2(264.0, 372.0)

## Перспектива «карточка наклонена к зрителю, основание уходит в карту».
## Нижний край сужается (BOT_SCALE), верхний — полная ширина; ряды у низа
## слегка сжаты по высоте (BOT_SQUASH). Применяется к рамке и портрету
## одинаково — оба Polygon2D, поэтому окно и портрет искажаются согласованно.
## Билинейный маппинг Polygon2D даёт лёгкий шир на трапеции — для умеренного
## наклона незаметно.
const PERSP_BOT_SCALE:  float = 0.8   # ширина нижнего края (доля от верхнего)
const PERSP_BOT_SQUASH: float = 0.20   # сжатие по высоте у нижнего края


# Кейстоун карточки: точку card-space (origin в центре) проецирует в трапецию.
# t∈[0,1]: 0 — верх карточки, 1 — низ. Нижние ряды сужаются по X и слегка
# подтягиваются вверх по Y (перспективное укорочение основания).
func _persp(p: Vector2) -> Vector2:
	var t: float  = (p.y + CARD_H * 0.5) / CARD_H
	var sx: float = lerpf(1.0, PERSP_BOT_SCALE, t)
	var y_squash: float = lerpf(0.0, PERSP_BOT_SQUASH, t) * CARD_H * 0.5
	return Vector2(p.x * sx, p.y - y_squash)


func setup(portrait: Texture2D) -> void:
	# Портрет в окне: Polygon2D по окну (искажённому перспективой), UV =
	# cover-crop портрета (заполняет окно, бока обрезаются формой полигона).
	var poly := Polygon2D.new()
	poly.name = "Portrait"
	poly.texture = portrait
	poly.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	poly.z_index = 0
	var hw: float = WIN_SIZE.x * 0.5
	var hh: float = WIN_SIZE.y * 0.5
	poly.polygon = PackedVector2Array([
		_persp(WIN_CENTER + Vector2(-hw, -hh)),
		_persp(WIN_CENTER + Vector2( hw, -hh)),
		_persp(WIN_CENTER + Vector2( hw,  hh)),
		_persp(WIN_CENTER + Vector2(-hw,  hh)),
	])
	if portrait != null:
		var pw: float = float(portrait.get_width())
		var ph: float = float(portrait.get_height())
		# cover по высоте: UV занимает всю высоту портрета, ширина — по аспекту
		# окна, центрированно (обрезаются бока квадратного портрета).
		var uvw: float = ph * (WIN_SIZE.x / WIN_SIZE.y)
		var ux0: float = (pw - uvw) * 0.5
		poly.uv = PackedVector2Array([
			Vector2(ux0,       0.0),
			Vector2(ux0 + uvw, 0.0),
			Vector2(ux0 + uvw, ph),
			Vector2(ux0,       ph),
		])
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
	frame.polygon = PackedVector2Array([
		_persp(Vector2(-fhw, -fhh)),
		_persp(Vector2( fhw, -fhh)),
		_persp(Vector2( fhw,  fhh)),
		_persp(Vector2(-fhw,  fhh)),
	])
	frame.uv = PackedVector2Array([
		Vector2(0.0,    0.0),
		Vector2(CARD_W, 0.0),
		Vector2(CARD_W, CARD_H),
		Vector2(0.0,    CARD_H),
	])
	add_child(frame)


# Высота карточки в нативных пикселях — MapLayer завязывает на неё экранный
# размер пина и якорит основание к локации.
static func card_height() -> float:
	return CARD_H
