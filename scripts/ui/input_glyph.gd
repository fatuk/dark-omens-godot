class_name InputGlyph
extends Control

## Иконка кнопки действия под текущее устройство ввода: на геймпаде — кнопка его
## рода (✕ ○ □ △ на PlayStation, A B X Y на Xbox, B A Y X на Nintendo — по
## положению кнопки; L1 / LB / L и т.п.), на клавиатуре — «кейкап» клавиши.
## Рисуется кодом, без ассетов, и перерисовывается, когда игрок меняет устройство
## (InputDevice.changed). Привязки под текущее устройство нет — иконка скрыта.
##
##   row.add_child(InputGlyph.make(GameInput.HAND))
##
## Справочник управления рисует и вне текущего устройства: InputGlyph.key_text("ЛКМ")
## — кейкап с надписью, InputGlyph.pad(JOY_BUTTON_A, h, "xbox") — кнопка геймпада
## заданного рода (STICK_L/STICK_R/DPAD_ANY — стики и крестовина целиком).

const STICK_L: int = 1002  # левый стик (движение), не нажатие L3
const STICK_R: int = 1003
const DPAD_ANY: int = 1004  # крестовина целиком

const _BG := Color(0.075, 0.07, 0.06, 0.96)
const _RING := Color(0.78, 0.66, 0.42, 0.85)
const _INK := Color(0.93, 0.88, 0.78)

# Цвета символов PlayStation и букв Xbox (как на самих контроллерах, приглушённо).
const _PS_COLORS := {
	JOY_BUTTON_A: Color(0.52, 0.66, 0.95),  # ✕ синий
	JOY_BUTTON_B: Color(0.93, 0.42, 0.42),  # ○ красный
	JOY_BUTTON_X: Color(0.88, 0.55, 0.78),  # □ розовый
	JOY_BUTTON_Y: Color(0.38, 0.82, 0.68),  # △ бирюзовый
}
const _XBOX_COLORS := {
	JOY_BUTTON_A: Color(0.45, 0.78, 0.32),
	JOY_BUTTON_B: Color(0.88, 0.32, 0.28),
	JOY_BUTTON_X: Color(0.32, 0.55, 0.92),
	JOY_BUTTON_Y: Color(0.95, 0.78, 0.25),
}
const _FACE := [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_Y]
const _DPAD := [
	JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT
]
const _KEY_NAMES := {
	KEY_ESCAPE: "Esc",
	KEY_LEFT: "←",
	KEY_RIGHT: "→",
	KEY_UP: "↑",
	KEY_DOWN: "↓",
	KEY_ENTER: "Enter",
}

@export var action: StringName = &""
@export var glyph_height: float = 30.0
@export var keyboard_too: bool = true  # вне геймпада показывать клавишу
## Фиксированная иконка (справочник): текст кейкапа / кнопка геймпада и её род.
var fixed_text: String = ""
var fixed_button: int = -1
var family_override: String = ""


## Кейкап с произвольной надписью («ЛКМ», «Колесо»), всегда виден.
static func key_text(text: String, h: float = 30.0) -> InputGlyph:
	var g := InputGlyph.new()
	g.name = "Key"
	g.fixed_text = text
	g.glyph_height = h
	g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return g


## Кнопка геймпада button (или STICK_L / STICK_R / DPAD_ANY) рода fam ("" —
## текущего), всегда видна.
static func pad(button: int, h: float = 30.0, fam: String = "") -> InputGlyph:
	var g := InputGlyph.new()
	g.name = "Pad_%d" % button
	g.fixed_button = button
	g.family_override = fam
	g.glyph_height = h
	g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return g


static func make(act: StringName, h: float = 30.0, kb: bool = true) -> InputGlyph:
	var g := InputGlyph.new()
	g.name = "Glyph_%s" % act
	g.action = act
	g.glyph_height = h
	g.keyboard_too = kb
	g.size_flags_vertical = Control.SIZE_SHRINK_CENTER  # в ряду с кнопкой — по центру
	return g


## Подпись лицевой кнопки по роду: A/B/X/Y (Xbox), по положению у Nintendo (нижняя —
## B, правая — A, левая — Y, верхняя — X); у PlayStation — имя фигуры.
static func face_symbol(fam: String, button: int) -> String:
	match fam:
		InputDevice.PLAYSTATION:
			return String(
				(
					{
						JOY_BUTTON_A: "cross",
						JOY_BUTTON_B: "circle",
						JOY_BUTTON_X: "square",
						JOY_BUTTON_Y: "triangle"
					}
					. get(button, "")
				)
			)
		InputDevice.NINTENDO:
			return String(
				{JOY_BUTTON_A: "B", JOY_BUTTON_B: "A", JOY_BUTTON_X: "Y", JOY_BUTTON_Y: "X"}.get(
					button, ""
				)
			)
	return String(
		{JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y"}.get(button, "")
	)


## Подпись «таблетки» — плечевые кнопки, меню, стики — по роду контроллера.
static func pill_label(fam: String, button: int) -> String:
	var i: int = maxi(0, InputDevice.FAMILIES.find(fam))  # xbox, playstation, nintendo
	var names := {
		JOY_BUTTON_LEFT_SHOULDER: ["LB", "L1", "L"],
		JOY_BUTTON_RIGHT_SHOULDER: ["RB", "R1", "R"],
		JOY_BUTTON_START: ["MENU", "OPTIONS", "+"],
		JOY_BUTTON_BACK: ["VIEW", "CREATE", "−"],
		JOY_BUTTON_LEFT_STICK: ["LS", "L3", "LS"],
		JOY_BUTTON_RIGHT_STICK: ["RS", "R3", "RS"],
		JOY_BUTTON_TOUCHPAD: ["", "TOUCHPAD", ""],
		GameInput.TRIGGER_LEFT: ["LT", "L2", "ZL"],
		GameInput.TRIGGER_RIGHT: ["RT", "R2", "ZR"],
	}
	return String((names.get(button, ["?", "?", "?"]) as Array)[i])


## Подпись клавиши на кейкапе.
static func key_label(k: int) -> String:
	if _KEY_NAMES.has(k):
		return String(_KEY_NAMES[k])
	return OS.get_keycode_string(k as Key)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dev: InputDevice = InputDevice.get_instance()
	if dev != null:
		dev.changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var pad_mode: bool = InputDevice.using_pad()
	if not fixed_text.is_empty() or fixed_button >= 0:
		visible = true
	else:
		visible = (
			GameInput.pad_button(action) >= 0
			if pad_mode
			else keyboard_too and GameInput.key(action) != KEY_NONE
		)
	custom_minimum_size = Vector2(_width(), glyph_height)
	queue_redraw()


# Что рисовать: кейкап (текст) или кнопка геймпада (код + род).
func _is_key() -> bool:
	if not fixed_text.is_empty():
		return true
	return fixed_button < 0 and not InputDevice.using_pad()


func _key_text() -> String:
	return fixed_text if not fixed_text.is_empty() else key_label(GameInput.key(action))


func _button() -> int:
	return fixed_button if fixed_button >= 0 else GameInput.pad_button(action)


func _family() -> String:
	return family_override if not family_override.is_empty() else InputDevice.family()


func _width() -> float:
	var h: float = glyph_height
	if _is_key():
		return _pill_width(_key_text())
	var b: int = _button()
	if b in _FACE or b in _DPAD or b in [STICK_L, STICK_R, DPAD_ANY]:
		return h
	return _pill_width(pill_label(_family(), b))


func _pill_width(text: String) -> float:
	var fs: int = _pill_fs()
	var w: float = (
		get_theme_default_font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	)
	return maxf(glyph_height, w + glyph_height * 0.7)


func _pill_fs() -> int:
	return int(round(glyph_height * 0.42))


func _draw() -> void:
	if _is_key():
		_draw_pill(_key_text(), 0.22)
		return
	var b: int = _button()
	var fam: String = _family()
	if b in _FACE:
		_draw_face(fam, b)
	elif b in _DPAD or b == DPAD_ANY:
		_draw_dpad(b)
	elif b == STICK_L or b == STICK_R:
		_draw_stick("L" if b == STICK_L else "R")
	else:
		_draw_pill(pill_label(fam, b), 0.5)


# Стик: шляпка с кольцом и буквой L / R.
func _draw_stick(letter: String) -> void:
	var h: float = glyph_height
	var c := Vector2(h, h) * 0.5
	var r: float = h * 0.5 - 1.0
	draw_circle(c, r, _BG)
	draw_arc(c, r, 0.0, TAU, 40, _RING, maxf(1.0, h * 0.05), true)
	draw_arc(c, r * 0.62, 0.0, TAU, 32, Color(_INK, 0.45), maxf(1.0, h * 0.04), true)
	_draw_text_centered(letter, c, int(round(h * 0.42)), _INK)


func _draw_face(fam: String, b: int) -> void:
	var h: float = glyph_height
	var c := Vector2(h, h) * 0.5
	var r: float = h * 0.5 - 1.0
	draw_circle(c, r, _BG)
	draw_arc(c, r, 0.0, TAU, 40, _RING, maxf(1.0, h * 0.05), true)
	var sym: String = face_symbol(fam, b)
	var w: float = maxf(1.5, h * 0.085)
	match sym:
		"cross":
			var col: Color = _PS_COLORS[b]
			var d: float = r * 0.42
			draw_line(c + Vector2(-d, -d), c + Vector2(d, d), col, w, true)
			draw_line(c + Vector2(-d, d), c + Vector2(d, -d), col, w, true)
		"circle":
			draw_arc(c, r * 0.44, 0.0, TAU, 32, _PS_COLORS[b], w, true)
		"square":
			var s: float = r * 0.74
			draw_rect(Rect2(c - Vector2(s, s) * 0.5, Vector2(s, s)), _PS_COLORS[b], false, w)
		"triangle":
			var t: float = r * 0.5
			var pts := PackedVector2Array(
				[
					c + Vector2(0, -t),
					c + Vector2(t * 0.95, t * 0.62),
					c + Vector2(-t * 0.95, t * 0.62),
					c + Vector2(0, -t)
				]
			)
			draw_polyline(pts, _PS_COLORS[b], w, true)
		_:
			var col2: Color = _XBOX_COLORS.get(b, _INK) if fam == InputDevice.XBOX else _INK
			_draw_text_centered(sym, c, int(round(h * 0.56)), col2)


func _draw_dpad(b: int) -> void:
	var h: float = glyph_height
	var c := Vector2(h, h) * 0.5
	var arm: float = h * 0.3
	var t: float = h * 0.17
	var dirs := {
		JOY_BUTTON_DPAD_UP: Vector2.UP,
		JOY_BUTTON_DPAD_DOWN: Vector2.DOWN,
		JOY_BUTTON_DPAD_LEFT: Vector2.LEFT,
		JOY_BUTTON_DPAD_RIGHT: Vector2.RIGHT,
	}
	draw_circle(c, h * 0.5 - 1.0, _BG)
	for k: int in dirs:
		var d: Vector2 = dirs[k]
		var tip: Vector2 = c + d * (arm + t * 0.5)
		var rect := Rect2(c, Vector2.ZERO).expand(tip).grow(t * 0.5)
		draw_rect(rect, _RING if k == b else Color(_INK, 0.35))


func _draw_pill(text: String, round_frac: float) -> void:
	var h: float = glyph_height
	var rect := Rect2(Vector2(1, 1), Vector2(_width() - 2.0, h - 2.0))
	var sb := StyleBoxFlat.new()
	sb.bg_color = _BG
	sb.border_color = _RING
	sb.set_border_width_all(maxi(1, int(h * 0.05)))
	sb.set_corner_radius_all(int(h * round_frac))
	sb.anti_aliasing = true
	draw_style_box(sb, rect)
	_draw_text_centered(text, rect.get_center(), _pill_fs(), _INK)


func _draw_text_centered(text: String, center: Vector2, fs: int, col: Color) -> void:
	var font: Font = get_theme_default_font()
	var sz: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var base_y: float = center.y + (font.get_ascent(fs) - font.get_descent(fs)) * 0.5
	draw_string(
		font, Vector2(center.x - sz.x * 0.5, base_y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col
	)
