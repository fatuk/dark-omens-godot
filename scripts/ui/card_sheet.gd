class_name CardSheet
extends RefCounted

## «Лист» модалки по арту-картинке (окно каста заклинания, проверка состояния): панель
## без своей рамки в пропорциях арта, фон-картинка и зоны контента долями листа, живые
## огни поверх нарисованных свечей/фонарей.

const _FLAME_SHADER := preload("res://assets/shaders/flame_glow.gdshader")
const FLAME_COLOR := Color(1.0, 0.68, 0.34)


## Построить лист в panel: высота height, ширина — по аспекту tex. Возвращает
## {sheet: Control, bg: TextureRect, size: Vector2}. Фон — ребёнок "Background":
## при пересборке контента его не трогать.
static func build(panel: PanelContainer, tex: Texture2D, height: float) -> Dictionary:
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var size := Vector2(height * tex.get_width() / tex.get_height(), height)
	panel.custom_minimum_size = size
	var sheet := Control.new()
	sheet.name = "Sheet"
	sheet.custom_minimum_size = size
	panel.add_child(sheet)
	var bg := TextureRect.new()
	bg.name = "Background"
	bg.texture = tex
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.clip_contents = true
	sheet.add_child(bg)
	return {"sheet": sheet, "bg": bg, "size": size}


## Зона листа по долям (x, y, w, h ∈ 0..1).
static func zone(sheet: Control, zname: String, r: Rect2) -> Control:
	var c := Control.new()
	c.name = zname
	c.anchor_left = r.position.x
	c.anchor_top = r.position.y
	c.anchor_right = r.position.x + r.size.x
	c.anchor_bottom = r.position.y + r.size.y
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheet.add_child(c)
	return c


## Мерцающий глоу над каждым огнём арта — дети фона (живут под контентом и переживают
## его пересборку). flames: [{cx, cy, w, h, intensity, speed, seed}] — доли листа.
static func add_flames(
	bg: Control, size: Vector2, flames: Array, color: Color = FLAME_COLOR
) -> void:
	for f_v: Variant in flames:
		var f: Dictionary = f_v
		var mat := ShaderMaterial.new()
		mat.shader = _FLAME_SHADER
		mat.set_shader_parameter("glow_color", color)
		mat.set_shader_parameter("intensity", f.intensity)
		mat.set_shader_parameter("flicker_speed", f.speed)
		mat.set_shader_parameter("seed", f.seed)
		var glow := ColorRect.new()
		glow.name = "Flame"
		glow.color = Color.WHITE  # цвет считает шейдер
		glow.material = mat
		glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sz := Vector2(float(f.w) * size.x, float(f.h) * size.y)
		glow.size = sz
		glow.position = Vector2(float(f.cx) * size.x, float(f.cy) * size.y) - sz * 0.5
		bg.add_child(glow)
