class_name MapGrain
extends RefCounted

## Процедурное зерно поверх карты — замена «Add Noise», запечённому в ассет.
##
## Запечённое зерно давало две беды: ползло при панорамировании (дробная позиция
## камеры → билинейная выборка каждый кадр усредняла соседние тексели по-новому)
## и раздувало PNG вчетверо, потому что шум не жмётся. Здесь то же зерно считается
## в экранных координатах на лету: неподвижное, одинакового размера на любом зуме.
##
## Настройки крутятся в панели тюнинга (Ctrl+M, секция «ЗЕРНО КАРТЫ»); найденное
## значение запекается сюда. AMOUNT читается как Amount в фотошопе: 0.03 = 3%.

const GROUP: StringName = &"map_grain"  # живые карты — для панели тюнинга
const SHADER: Shader = preload("res://assets/shaders/map_grain.gdshader")

static var AMOUNT: float = 0.03  # сила зерна (доля полного диапазона яркости)
static var SIZE: float = 1.0  # сторона зерна в пикселях экрана


## Материал для тайлов карты. Один на все три копии — зерно экранное, шва не будет.
static func make_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	apply_to(mat)
	return mat


## Перелить текущие настройки в материал (панель тюнинга — на живой карте).
static func apply_to(mat: ShaderMaterial) -> void:
	if mat == null:
		return
	mat.set_shader_parameter("amount", AMOUNT)
	mat.set_shader_parameter("grain_size", SIZE)
