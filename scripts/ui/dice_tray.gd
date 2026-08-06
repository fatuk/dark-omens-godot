class_name DiceTray
extends HBoxContainer

## Единый лоток проверки кубов в стиле «слот-машины»: рамка с окном, в окне
## крутится лента граней-текстур и тормозит на финале (как в прототипе).
## Один компонент на ВСЕ проверки (встречи, бой, магазин) — единый вид и логика.
##
## API:
##   show_roll(values, can_reroll)  — показать результат СРАЗУ (для синка/ре-рендера)
##   play_roll(values, can_reroll)  — показать со СПИНОМ (свежий бросок)
##   show_pending(count)            — пустые кубы до броска (рубашки)
##   reroll_die(index, value, can)  — перекрутить ОДИН куб
## Сигнал die_selected(index) — клик по провальному кубу (переброс за фокус).
##
## Грани и рамка — ассеты (assets/dice). Размытие движения — вертикальный
## Gaussian-шейдер прямо на грани (_BLUR_SHADER), сила драйвится тви́ном спина.
## Успех/провал/переброс показываем свечением за рамкой (_style_glow).

signal die_selected(index: int)

# Ассеты костей.
const FRAME_TEX: Texture2D = preload("res://assets/dice/die-frame.png")
# Иконки навыков (assets/virtues-panel, @2×) — стоят в пустом кубе ДО броска
# вместо безликой рубашки: сразу видно, что именно проверяем.
const SKILL_TEX := {
	"strength": preload("res://assets/virtues-panel/strength.png"),
	"lore": preload("res://assets/virtues-panel/lore.png"),
	"will": preload("res://assets/virtues-panel/will.png"),
	"influence": preload("res://assets/virtues-panel/influence.png"),
	"observation": preload("res://assets/virtues-panel/observation.png"),
}
const SKILL_ICON_SCALE: float = 0.65  # ассеты @2× (0.5) + 30% — иконка крупнее грани

# Зазор между рамками кубов. У die-frame.png нет прозрачных полей по краям, поэтому
# это ровно видимое расстояние между кубами. static — крутится в панели тюнинга
# (Ctrl+M, секция «КУБЫ»); найденное значение запекается сюда же.
static var DIE_GAP: float = 16.0
const GAP_GROUP: StringName = &"dice_tray"

const FACE_TEX := {
	1: preload("res://assets/dice/side1.png"),
	2: preload("res://assets/dice/side2.png"),
	3: preload("res://assets/dice/side3.png"),
	4: preload("res://assets/dice/side4.png"),
	5: preload("res://assets/dice/side5.png"),
	6: preload("res://assets/dice/side6.png"),
}

# Размер куба = аспект рамки (326×364 ≈ 0.896). Грань/свечение/блюр масштабируются
# пропорционально от этих чисел.
const DIE_W: float = 130.0
const DIE_H: float = 145.0

# Грань (квадрат) сидит ПО ЦЕНТРУ рамки, меньше выреза — вокруг неё видно
# свечение-подложку и кант рамки (как в референсе).
const FACE_FRAC: float = 0.56  # сторона грани в долях ширины куба
const _FACE: float = FACE_FRAC * DIE_W
const GLOW_INSET: float = 0.15  # свечение заполняет внутренний вырез рамки

# Тайминги спина.
const SPIN_BASE: float = 0.76  # длительность первого куба (сек)
const SPIN_STAGGER: float = 0.20  # +на каждый следующий куб (оседают по очереди)
const STRIP_MIN: int = 18  # сколько случайных граней прокрутить до финала
const LOCK_FLASH: float = 0.42  # вспышка при остановке
const BLUR_MAX: float = 0.30  # макс. вертикальный смаз (доля высоты грани, UV)
const SHAKE_AMP: float = 5.0  # амплитуда «тряски» куба при броске (px)
const SHAKE_DUR: float = 0.40  # длительность тряски (сек)

# Звук броска (SfxManager.SFX_DICE = dice-roll.wav): клаттер 0..settle (под спин),
# затем «активация» — хвостовой сегмент после тихого участка, в момент оседания
# последнего куба. Таймкоды подобраны по огибающей файла (тишина ~1.7–1.88 c).
const _SFX_ACT_START: float = 1.85  # начало «активации» в файле (после тишины), сек
const _SFX_ACT_END: float = 2.137  # конец файла, сек
const _SFX_ACT_PITCH: float = 0.05  # ± случайный питч щелчка-активации (живее каскад)
const _SFX_ACT_LEAD: float = 0.10  # на сколько раньше всполоха бить щелчок (сек)

# Свечение-подложка (за гранью, во внутреннем вырезе рамки).
const C_GLOW_SUCCESS := UIColors.SUCCESS  # успех (≥5) — зелёное свечение
const C_GLOW_REROLL := UIColors.ACCENT  # провал + есть фокус → янтарь (кликабельно)

# Вертикальный motion-blur грани: несколько тапов по Y с треугольным весом.
const _BLUR_SHADER := """
shader_type canvas_item;
uniform float blur = 0.0; // доля высоты текстуры
void fragment() {
	vec4 acc = vec4(0.0);
	float total = 0.0;
	const int N = 8;
	for (int i = -N; i <= N; i++) {
		float t = float(i) / float(N);   // -1..1
		float wgt = 1.0 - abs(t);         // треугольный вес ≈ Gaussian
		vec2 uv = vec2(UV.x, clamp(UV.y + t * blur, 0.0, 1.0));
		acc += texture(TEXTURE, uv) * wgt;
		total += wgt;
	}
	COLOR = acc / total;
}
"""

var _dice: Array = []  # [{root, glow, reel, blur_mat, value, index, clickable, pending}]
var _pending_skill: String = ""  # какой навык показывать в пустых кубах (см. show_pending)


func _init() -> void:
	name = "DiceTray"
	add_to_group(GAP_GROUP)  # чтобы панель тюнинга дотянулась до живых лотков
	refresh_gap()
	alignment = BoxContainer.ALIGNMENT_CENTER


# ── API ───────────────────────────────────────────────────────────────────────


## Показать результат сразу (без анимации) — для ре-рендера на синке.
func show_roll(values: Array, can_reroll: bool = false, can_add: bool = false) -> void:
	_build(values, can_reroll, 0, can_add)
	for d in _dice:
		_settle(d, false)


## Куб кликабелен: под переброс (провал по порогу + есть чем) ИЛИ под +1 addToDie
## (любой куб < 6, если заряд свободен). Не «рубашка».
static func _clickable(value: int, is_pending: bool, can_reroll: bool, can_add: bool) -> bool:
	if is_pending:
		return false
	if can_reroll and not Dice.is_success(value):
		return true
	return can_add and value < Dice.SIDES


## Показать бросок со спином (свежий бросок). Кубы оседают по очереди.
func play_roll(values: Array, can_reroll: bool = false, can_add: bool = false) -> void:
	_build(values, can_reroll, 0, can_add)
	_shake()
	for i in range(_dice.size()):
		_spin(_dice[i], SPIN_BASE + i * SPIN_STAGGER)
		_jitter(_dice[i])
	if not _dice.is_empty():
		_play_clatter(_dice.size())  # щелчки-активации бьёт _settle по всполохам


## Перечитать DIE_GAP в отступ контейнера (панель тюнинга дёргает у живых лотков).
func refresh_gap() -> void:
	add_theme_constant_override("separation", int(roundf(DIE_GAP)))


## Пустые кубы до броска. skill (strength/lore/will/influence/observation) рисует
## в них иконку навыка; пустая строка — прежняя безликая рубашка.
func show_pending(count: int, skill: String = "") -> void:
	_pending_skill = skill
	_build([], false, maxi(0, count))


# Иконка навыка для пустого куба; null — рисуем рубашку.
func _pending_icon() -> Texture2D:
	return SKILL_TEX.get(_pending_skill, null) as Texture2D


## Перебросить ОДИН куб (по индексу): крутится только он. Остальные лишь
## обновляют доступность — фокус мог иссякнуть (can_reroll = есть ли ещё фокус).
func reroll_die(index: int, new_value: int, can_reroll: bool, can_add: bool = false) -> void:
	if index < 0 or index >= _dice.size():
		return
	_dice[index]["value"] = new_value
	for d in _dice:
		d["clickable"] = _clickable(int(d["value"]), bool(d["pending"]), can_reroll, can_add)
		_apply_click(d)
	for i in range(_dice.size()):
		if i != index:
			_settle(_dice[i], false)  # обновить свечение без кручения
	_spin(_dice[index], SPIN_BASE)
	_jitter(_dice[index])
	_play_clatter(1)  # клаттер; щелчок — из _settle когда куб сядет


# ── Сборка ──────────────────────────────────────────────────────────────────


func _build(values: Array, can_reroll: bool, pending: int = 0, can_add: bool = false) -> void:
	for c in get_children():
		c.queue_free()
	_dice.clear()
	var n: int = values.size() if not values.is_empty() else pending
	for i in range(n):
		var val: int = int(values[i]) if i < values.size() else 0
		_dice.append(_make_die(val, can_reroll, i, values.is_empty(), can_add))


func _make_die(
	value: int, can_reroll: bool, index: int, is_pending: bool, can_add: bool = false
) -> Dictionary:
	var root := Control.new()
	root.name = "Die%d" % index
	root.custom_minimum_size = Vector2(DIE_W, DIE_H)
	root.size = Vector2(DIE_W, DIE_H)

	# Внутренняя обёртка визуала: HBox задаёт позицию root'а, поэтому translate-тряску
	# вешаем на content (его позицию контейнер не трогает). Клик ловит root.
	var content := Control.new()
	content.name = "Content"
	content.position = Vector2.ZERO
	content.size = Vector2(DIE_W, DIE_H)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(content)

	# Рамка (текстура) — кант + тёмный центр. Свечение и грань идут ПОВЕРХ.
	var frame := TextureRect.new()
	frame.name = "Frame"
	frame.texture = FRAME_TEX
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_SCALE
	frame.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(frame)

	# Свечение-подложка — радиальная заливка во внутреннем вырезе (за гранью).
	var glow := TextureRect.new()
	glow.name = "Glow"
	glow.texture = _glow_texture()
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.position = Vector2(GLOW_INSET * DIE_W, GLOW_INSET * DIE_H)
	glow.size = Vector2((1.0 - 2.0 * GLOW_INSET) * DIE_W, (1.0 - 2.0 * GLOW_INSET) * DIE_H)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.visible = false
	content.add_child(glow)

	# Окно с гранью — квадрат ПО ЦЕНТРУ; в нём ездит лента.
	var window := Control.new()
	window.name = "Window"
	window.position = Vector2((DIE_W - _FACE) * 0.5, (DIE_H - _FACE) * 0.5)
	window.size = Vector2(_FACE, _FACE)
	window.clip_contents = true
	window.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(window)

	var reel := Control.new()
	reel.name = "Reel"
	reel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	window.add_child(reel)

	# Иконка навыка (пустой куб до броска) — ПОВЕРХ рамки, а не в окне грани:
	# окно клипает по стороне грани, а иконка крупнее её. Центрируем по рамке.
	if is_pending:
		var icon: Texture2D = _pending_icon()
		if icon != null:
			var sz: Vector2 = icon.get_size() * SKILL_ICON_SCALE
			var skill_icon := TextureRect.new()
			skill_icon.name = "SkillIcon"
			skill_icon.texture = icon
			skill_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			skill_icon.stretch_mode = TextureRect.STRETCH_SCALE
			skill_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			skill_icon.position = (Vector2(DIE_W, DIE_H) - sz) * 0.5
			skill_icon.size = sz
			skill_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			content.add_child(skill_icon)

	# Материал блюра — один на куб (общий для всех граней ленты).
	var blur_mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = _BLUR_SHADER
	blur_mat.shader = sh
	blur_mat.set_shader_parameter("blur", 0.0)

	var clickable: bool = _clickable(value, is_pending, can_reroll, can_add)
	var die := {
		"root": root,
		"content": content,
		"glow": glow,
		"reel": reel,
		"blur_mat": blur_mat,
		"value": value,
		"index": index,
		"clickable": clickable,
		"pending": is_pending,
	}

	# Клик по кубу → переброс (только если провал и есть право).
	root.mouse_filter = Control.MOUSE_FILTER_STOP if clickable else Control.MOUSE_FILTER_IGNORE
	if clickable:
		root.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var idx: int = index
		root.gui_input.connect(
			func(ev: InputEvent) -> void:
				if (
					ev is InputEventMouseButton
					and (ev as InputEventMouseButton).pressed
					and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
				):
					die_selected.emit(idx)
		)

	add_child(root)
	# Стартово — одна финальная грань (статика); спин перезаполнит ленту сам.
	_set_reel(die, [value])
	return die


# Заполнить ленту гранями vals (сверху вниз) текстурами. reel.y = 0.
func _set_reel(die: Dictionary, vals: Array) -> void:
	if not is_instance_valid(die.get("reel")):
		return  # куб уже освобождён пересборкой лотка — рисовать нечего
	var reel: Control = die["reel"]
	for c in reel.get_children():
		c.queue_free()
	for i in range(vals.size()):
		var face := TextureRect.new()
		face.name = "Face%d" % i
		face.texture = FACE_TEX.get(int(vals[i]), null)  # 0 → пусто (рубашка)
		face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		face.stretch_mode = TextureRect.STRETCH_SCALE
		face.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		face.material = die["blur_mat"]
		face.position = Vector2(0, i * _FACE)
		face.size = Vector2(_FACE, _FACE)
		face.mouse_filter = Control.MOUSE_FILTER_IGNORE
		reel.add_child(face)
	reel.position.y = 0.0


# ── Анимация ──────────────────────────────────────────────────────────────────


# Спин: лента случайных граней едет вверх и тормозит на финале (cubic-out).
func _spin(die: Dictionary, dur: float) -> void:
	if die["pending"]:
		return
	var strip: Array = []
	var extra: int = randi() % 6
	for _i in range(STRIP_MIN + extra):
		strip.append(randi() % 6 + 1)
	strip.append(int(die["value"]))
	_set_reel(die, strip)

	var last: int = strip.size() - 1
	# Привязываем к самому кубу: лоток может пересобраться прямо во время спина
	# (_build освобождает детей), и отложенный callback _settle дёрнул бы уже
	# освобождённый reel. Привязка убивает твин вместе с нодой.
	var tw := create_tween().bind_node(die["reel"])
	tw.set_parallel(true)
	(
		tw
		. tween_property(die["reel"], "position:y", -last * _FACE, dur)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_OUT)
	)
	# Размытие движения: смаз держится почти весь спин и спадает к остановке.
	(
		tw
		. tween_method(func(b: float) -> void: _set_die_blur(die, b), BLUR_MAX, 0.0, dur)
		. set_trans(Tween.TRANS_QUAD)
		. set_ease(Tween.EASE_IN)
	)
	# Щелчок-активация чуть РАНЬШЕ всполоха: в ТОМ ЖЕ твине (упреждение точное
	# относительно подсветки, без дрейфа отдельных таймеров) — параллельный callback
	# с задержкой dur − LEAD; всполох (_settle) по-прежнему на dur.
	tw.tween_callback(_activation_chime).set_delay(maxf(0.0, dur - _SFX_ACT_LEAD))
	tw.set_parallel(false)
	tw.tween_callback(func() -> void: _settle(die, true))


# Сила вертикального блюра грани (один uniform на куб).
func _set_die_blur(die: Dictionary, b: float) -> void:
	die["blur_mat"].set_shader_parameter("blur", b)


# Финал: одна грань, свечение по состоянию, опц. вспышка.
func _settle(die: Dictionary, flash: bool) -> void:
	if not is_instance_valid(die.get("root")):
		return  # лоток пересобрался, пока крутился куб
	var val: int = int(die["value"])
	_set_reel(die, [val])
	_set_die_blur(die, 0.0)

	if die["pending"]:
		_style_glow(die["glow"], Color.BLACK, false)
	elif Dice.is_success(val):
		_style_glow(die["glow"], C_GLOW_SUCCESS, true)
	elif die["clickable"]:
		_style_glow(die["glow"], C_GLOW_REROLL, true)
	else:
		_style_glow(die["glow"], Color.BLACK, false)  # провал без переброса — без ореола

	if flash:
		var root: Control = die["root"]
		root.modulate = Color(1.45, 1.4, 1.2)
		var tw := create_tween().bind_node(root)  # см. _spin: куб может исчезнуть по ходу
		tw.tween_property(root, "modulate", Color(1, 1, 1), LOCK_FLASH)


# Покубовая «тряска» при броске: content куба дёргается на несколько px и
# возвращается в ноль. Направление случайно на куб — кубы дребезжат вразнобой.
# Прерываема (быстрые перебросы не накладывают тви́ны).
func _jitter(die: Dictionary) -> void:
	if die["pending"]:
		return
	var content: Control = die["content"]
	if not is_instance_valid(content):
		return
	var prev: Variant = die.get("jitter_tw")
	if prev and (prev as Tween).is_valid():
		(prev as Tween).kill()
	var a: float = SHAKE_AMP
	var dir: float = 1.0 if randf() < 0.5 else -1.0
	var steps: Array = [
		Vector2(-a, a * 0.5) * dir,
		Vector2(a * 1.1, -a * 0.45) * dir,
		Vector2(-a * 0.6, -a * 0.3) * dir,
		Vector2(a * 0.5, a * 0.35) * dir,
		Vector2.ZERO,
	]
	var tw := content.create_tween()
	var step_dur: float = SHAKE_DUR / float(steps.size())
	for off: Vector2 in steps:
		tw.tween_property(content, "position", off, step_dur).set_trans(Tween.TRANS_SINE)
	die["jitter_tw"] = tw


# Клаттер броска: сегмент файла 0..settle_last (под весь спин). Щелчки-активации
# НЕ здесь — их бьёт _settle ровно по всполоху каждого куба (идеальная синхронизация
# с подсветкой, без дрейфа отдельных таймеров).
func _play_clatter(n: int) -> void:
	if n <= 0:
		return
	var settle_last: float = SPIN_BASE + float(n - 1) * SPIN_STAGGER
	SfxManager.play_variation(SfxManager.SFX_DICE, 1, 0.0, [[0.0, settle_last]])


# Щелчок-активация на оседание (всполох) куба: хвостовой сегмент файла, лёгкий
# питч-разброс, чтобы каскад одинаковых семплов не звучал механически.
func _activation_chime() -> void:
	SfxManager.play_variation(
		SfxManager.SFX_DICE, 1, _SFX_ACT_PITCH, [[_SFX_ACT_START, _SFX_ACT_END]]
	)


# Лёгкий «толчок» лотка при броске (масштаб не сбрасывается контейнером).
func _shake() -> void:
	pivot_offset = size * 0.5
	scale = Vector2(0.94, 0.94)
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector2.ONE, 0.34).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)


# ── Состояние ───────────────────────────────────────────────────────────────


# Доступность клика по кубу (фокус мог иссякнуть → куб «гаснет», клики не ловит).
func _apply_click(die: Dictionary) -> void:
	var c: bool = die["clickable"]
	var root: Control = die["root"]
	root.mouse_filter = Control.MOUSE_FILTER_STOP if c else Control.MOUSE_FILTER_IGNORE
	root.mouse_default_cursor_shape = (Control.CURSOR_POINTING_HAND if c else Control.CURSOR_ARROW)


# Свечение-подложка по состоянию (модуляция радиальной текстуры). on=false → скрыта.
func _style_glow(glow: TextureRect, color: Color, on: bool) -> void:
	glow.visible = on
	if on:
		glow.modulate = Color(color.r, color.g, color.b, 1.0)


# Радиальная подложка свечения (белая, ядро держится до 65% → к краю прозрачно).
# Кэшируется и переиспользуется всеми кубами (цвет задаётся через modulate).
static var _glow_cache: GradientTexture2D = null


static func _glow_texture() -> GradientTexture2D:
	if _glow_cache == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.65, 1.0])
		g.colors = PackedColorArray(
			[Color(1, 1, 1, 0.85), Color(1, 1, 1, 0.6), Color(1, 1, 1, 0.0)]
		)
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 96
		t.height = 96
		_glow_cache = t
	return _glow_cache
