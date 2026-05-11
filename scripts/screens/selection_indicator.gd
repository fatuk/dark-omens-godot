extends Node2D
class_name SelectionIndicator

## Подсветка выделенного маркера на карте: яркое пульсирующее кольцо +
## размытое halo (оба per-pixel через canvas_item шейдер) + треугольная
## стрелка-указатель сверху с тенью (тоже пульсирует).
##
## Все размеры — в экранных пикселях; MapLayer масштабирует ноду на 1/zoom,
## чтобы экранный размер был константой при любом масштабе карты.
##
## Все индикаторы делят один ShaderMaterial — debug-панель через
## get_shared_material() сразу меняет параметры всем активным выделениям.
## Сдвиг (offset_x/y) применяется внутри шейдера для halo и в _draw для стрелки.
## Пульсация работает синхронно: шейдер использует TIME, _draw — Time.get_ticks_msec.

const GROUP := "selection_indicators"

# #8fbd4d — лаймовый
const COLOR: Color = Color(0.561, 0.741, 0.302, 0.95)

const RING_RADIUS:    float = 52.0
const RING_THICKNESS: float = 1.9

const GLOW_INNER:     float = 120.0
const GLOW_OUTER:     float = 59.0
const GLOW_STRENGTH:  float = 0.17
const GLOW_FALLOFF:   float = 8.1

const ARROW_W:     float = 13.0
const ARROW_H:     float = 13.0
const ARROW_TIP_Y: float = -55.0

const OFFSET_X: float = 0.0
const OFFSET_Y: float = -1.5

const PULSE_SPEED:  float = 3.0    # рад/сек, для пульсации радиуса кольца в шейдере
const PULSE_AMOUNT: float = 0.02   # ±2% радиуса кольца

# Тень под стрелкой.
const SHADOW_COLOR:       Color   = Color(0.0, 0.0, 0.0, 0.45)
const SHADOW_OFFSET:      Vector2 = Vector2(1.5, 2.5)
const SHADOW_SCALE_MULT:  float   = 1.12

const SPRITE_SIZE: float = 200.0

const SHADER_CODE: String = """
shader_type canvas_item;

varying vec2 v_local;

uniform vec4  color         : source_color = vec4(1.0);
uniform float ring_r        = 52.0;
uniform float ring_w        = 1.9;
uniform float glow_inner    = 120.0;
uniform float glow_outer    = 59.0;
uniform float glow_strength = 0.17;
uniform float glow_falloff  = 8.1;
uniform vec2  offset        = vec2(0.0);
uniform float pulse_speed   = 3.0;
uniform float pulse_amount  = 0.06;

void vertex() {
	v_local = VERTEX - offset;
}

void fragment() {
	float d = length(v_local);
	float pulse = 1.0 + sin(TIME * pulse_speed) * pulse_amount;
	float r_eff = ring_r * pulse;

	float ring = smoothstep(ring_w, 0.0, abs(d - r_eff));

	float gd = max(d - glow_inner, 0.0);
	float gn = glow_outer - glow_inner;
	float t  = clamp(gd / max(gn, 0.0001), 0.0, 1.0);
	float glow = exp(-t * t * glow_falloff) * (1.0 - step(glow_outer, d)) * glow_strength;

	float a = max(ring, glow);
	COLOR = vec4(color.rgb, color.a * a);
}
"""

# Один общий материал и текстура на все индикаторы.
static var _shared_mat:   ShaderMaterial = null
static var _shared_tex:   Texture2D      = null
static var _offset:       Vector2        = Vector2(OFFSET_X, OFFSET_Y)
static var _pulse_speed:  float          = PULSE_SPEED
static var _pulse_amount: float          = PULSE_AMOUNT

var _glow: Polygon2D = null


# ── Static API ────────────────────────────────────────────────────────────────

static func get_shared_material() -> ShaderMaterial:
	if _shared_mat == null:
		var sh := Shader.new()
		sh.code = SHADER_CODE
		_shared_mat = ShaderMaterial.new()
		_shared_mat.shader = sh
		_shared_mat.set_shader_parameter("color",         Vector4(COLOR.r, COLOR.g, COLOR.b, COLOR.a))
		_shared_mat.set_shader_parameter("ring_r",        RING_RADIUS)
		_shared_mat.set_shader_parameter("ring_w",        RING_THICKNESS)
		_shared_mat.set_shader_parameter("glow_inner",    GLOW_INNER)
		_shared_mat.set_shader_parameter("glow_outer",    GLOW_OUTER)
		_shared_mat.set_shader_parameter("glow_strength", GLOW_STRENGTH)
		_shared_mat.set_shader_parameter("glow_falloff",  GLOW_FALLOFF)
		_shared_mat.set_shader_parameter("offset",        _offset)
		_shared_mat.set_shader_parameter("pulse_speed",   _pulse_speed)
		_shared_mat.set_shader_parameter("pulse_amount",  _pulse_amount)
	return _shared_mat


static func set_offset(x: float, y: float) -> void:
	_offset = Vector2(x, y)
	get_shared_material().set_shader_parameter("offset", _offset)
	_redraw_all()


static func get_offset() -> Vector2:
	return _offset


static func set_pulse(speed: float, amount: float) -> void:
	_pulse_speed  = speed
	_pulse_amount = amount
	var mat := get_shared_material()
	mat.set_shader_parameter("pulse_speed",  speed)
	mat.set_shader_parameter("pulse_amount", amount)
	# arrow перерисуется сам в _process, но дёрнем сразу — на случай ставшего нулевым размаха.
	_redraw_all()


static func get_pulse_speed() -> float:
	return _pulse_speed


static func get_pulse_amount() -> float:
	return _pulse_amount


static func _get_shared_texture() -> Texture2D:
	if _shared_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.set_pixel(0, 0, Color.WHITE)
		_shared_tex = ImageTexture.create_from_image(img)
	return _shared_tex


static func _redraw_all() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for n: Node in tree.get_nodes_in_group(GROUP):
		if is_instance_valid(n) and n is Node2D:
			(n as Node2D).queue_redraw()


# ── Жизненный цикл ────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group(GROUP)

	var s: float = SPRITE_SIZE * 0.5
	_glow = Polygon2D.new()
	_glow.texture = _get_shared_texture()
	_glow.polygon = PackedVector2Array([
		Vector2(-s, -s), Vector2( s, -s),
		Vector2( s,  s), Vector2(-s,  s),
	])
	_glow.color    = Color.WHITE
	_glow.material = get_shared_material()
	add_child(_glow)


func _draw() -> void:
	var ox: float = _offset.x
	var oy: float = _offset.y

	var aw: float     = ARROW_W * 0.5
	var base_y: float = oy + ARROW_TIP_Y - ARROW_H

	# Тень: чуть больше + сдвинута вниз-вправо. Рисуем ПЕРВОЙ — окажется снизу.
	var sw: float  = aw * SHADOW_SCALE_MULT
	var sh: float  = ARROW_H * SHADOW_SCALE_MULT
	var sox: float = ox + SHADOW_OFFSET.x
	var soy: float = base_y + SHADOW_OFFSET.y
	var shadow := PackedVector2Array([
		Vector2(sox - sw, soy),
		Vector2(sox + sw, soy),
		Vector2(sox,      soy + sh),
	])
	draw_colored_polygon(shadow, SHADOW_COLOR)

	# Основная стрелка
	var arrow := PackedVector2Array([
		Vector2(ox - aw, base_y),
		Vector2(ox + aw, base_y),
		Vector2(ox,      base_y + ARROW_H),
	])
	draw_colored_polygon(arrow, COLOR)
