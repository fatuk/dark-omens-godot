class_name InvestigatorPanel
extends CanvasLayer

## Всегда-видимая нижняя HUD-панель сыщика на карте: круглый аватар во фрейме +
## compact InfoBar (HP/рассудок + атрибуты) в ornate-рамке на фоне-паттерне.
##
## Разметка строится в коде — геометрия в константах ниже (подбирается визуально
## под ассеты). Данные сыщика: _load_data (GameState → NetworkManager → prefs).

const _PREFS_SECTION := "player"
const _DATA_PATH := "res://data/investigators.json"

# ── Геометрия (display-px). Тюнить под ассеты. ────────────────────────────────
const BAR_H := 248.0  # высота полосы
const _FRAME_PATCH_H := 300  # 9-slice торцы рамки (лево/право — не растягиваются)
const _FRAME_PATCH_V := 110  # 9-slice верх/низ рамки
const _FRAME_SCALE := 0.5  # ассет @2× → рисуем в 1× (рамка/борта вдвое мельче)
const _CONTENT_PAD_X := 48.0  # инсет контента от левого края
const _CONTENT_PAD_Y := 26.0  # инсет контента сверху
const _AVATAR_D := 168.0  # диаметр аватара (кольцо avatar-round-frame)
const _GAP := 18.0  # отступ между аватаром и InfoBar
const _CAPTION_OVERLAP := 7  # на сколько px подпись имени налезает на низ аватарки

# Мягкая тень кольца-рамки аватара: размытый силуэт КОЛЬЦА, сдвинутый вниз. Лежит
# НАД портретом, но ПОД самим кольцом — поэтому тень падает и на портрет (внутри),
# и на подложку панели (снаружи). Box-blur по альфе текстуры — как у билетов.
const _AVATAR_SHADOW_OFFSET := Vector2(0.0, 6.0)  # сдвиг тени вниз
const _AVATAR_SHADOW_BLUR := 7.0  # радиус размытия (в TEXTURE_PIXEL_SIZE)
const _AVATAR_SHADOW_ALPHA := 0.55  # непрозрачность тени

const _FRAME_TEX: Texture2D = preload(
	"res://assets/investigator-panel/investigator-panel-frame.png"
)
const _AVATAR_FRAME: Texture2D = preload("res://assets/investigator-panel/avatar-round-frame.png")

## Ореол «твой ход» вокруг аватарки: мягкое зелёное свечение с дыханием ПОД
## портретом и кольцом (наружу от кольца). Показывается только на экране того,
## кто ходит, — остальным «кого ждут» подсказывает ореол пина на карте.
## static var, а не const: тюнинг-панель (Ctrl+M) крутит их вживую через GROUP /
## refresh_turn_glow; найденное значение запекается сюда в default.
const GROUP := "investigator_panel"
static var GLOW_ALPHA: float = 0.66  # яркость у самого кольца
static var GLOW_SPREAD: float = 1.2  # во сколько раз ореол крупнее аватарки
static var GLOW_FALLOFF: float = 3.15  # крутизна затухания наружу (1 — линейно)
static var GLOW_PULSE_SPEED: float = 2.2  # скорость дыхания, рад/с
static var GLOW_PULSE_AMOUNT: float = 0.72  # глубина дыхания (0 — ровное свечение)
const GLOW_FADE: float = 0.45  # сек на плавное появление/угасание ореола хода


## Тюнинг-панель: положить значение в static-поле по имени (GLOW_ALPHA … GLOW_PULSE_AMOUNT).
## Цвет ореола — общий UIColors.ACTIVE, здесь не крутится.
static func set_glow_param(field: String, v: float) -> void:
	match field:
		"GLOW_ALPHA":
			GLOW_ALPHA = v
		"GLOW_SPREAD":
			GLOW_SPREAD = v
		"GLOW_FALLOFF":
			GLOW_FALLOFF = v
		"GLOW_PULSE_SPEED":
			GLOW_PULSE_SPEED = v
		"GLOW_PULSE_AMOUNT":
			GLOW_PULSE_AMOUNT = v
		_:
			push_warning("[InvestigatorPanel] неизвестный параметр ореола «%s»" % field)


# Радиальный ореол: сплошной внутри края аватарки (edge = 1/spread по радиусу, его
# всё равно закрывает портрет с кольцом), затухание к краю квадрата, дыхание по TIME.
const _TURN_GLOW_SHADER := """
shader_type canvas_item;
uniform vec4 glow;
uniform float edge;
uniform float falloff;
uniform float pulse_speed;
uniform float pulse_amount;
void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float a = 1.0 - smoothstep(edge, 1.0, d);
	a = pow(a, falloff);
	a *= (1.0 - pulse_amount) + pulse_amount * (0.5 + 0.5 * sin(TIME * pulse_speed));
	COLOR = vec4(glow.rgb, glow.a * a);
}
"""

# Круглая маска портрета: отсекаем фрагменты вне вписанного круга.
const _CIRCLE_MASK_SHADER := """
shader_type canvas_item;
uniform float dead = 0.0;  // Тень: 1.0 → портрет ч/б
void fragment() {
	if (distance(UV, vec2(0.5)) > 0.5) { COLOR.a = 0.0; }
	if (dead > 0.5) {
		float g = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
		COLOR.rgb = vec3(g);
	}
}
"""

# Тень кольца: 5×5 box-blur альфы текстуры → мягкий чёрный силуэт кольца.
const _AVATAR_SHADOW_SHADER := """
shader_type canvas_item;
uniform float blur : hint_range(0.0, 32.0) = 7.0;
uniform float shadow_alpha : hint_range(0.0, 1.0) = 0.55;
void fragment() {
	vec2 stp = TEXTURE_PIXEL_SIZE * blur;
	float a = 0.0;
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			a += texture(TEXTURE, UV + vec2(float(x), float(y)) * stp).a;
		}
	}
	COLOR = vec4(0.0, 0.0, 0.0, (a / 25.0) * shadow_alpha);
}
"""

var _inv_name: String = ""
var _inv_data: Dictionary = {}
var _info_bar: InfoBar
var _portrait: TextureRect
var _turn_glow: ColorRect  # ореол «твой ход» под аватаркой (см. GROUP)
var _turn_glow_mat: ShaderMaterial
var _turn_on: bool = false  # ореол включён (цель фейда)
var _turn_level: float = 0.0  # текущая яркость ореола 0..1 (ведёт твин)
var _turn_tw: Tween
var _name_label: Label
var _occ_label: Label

# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	_load_data()
	_build_ui()
	_populate_data()
	# Идентичность сыщика и живые статы тянем при смене стейта (поздний вход,
	# переподключение). _refresh_identity пересобирает только при смене сыщика.
	GameState.state_changed.connect(_refresh_identity)
	GameState.state_changed.connect(_refresh_live)
	add_to_group(GROUP)
	_refresh_live()


# ── Построение разметки ───────────────────────────────────────────────────────


func _build_ui() -> void:
	# Полоса снизу на всю ширину экрана (всегда видна, не скрывается).
	var bar := Control.new()
	bar.name = "Bar"
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -BAR_H
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)

	# Фон-паттерн — тем же тайлингом/масштабом, что в карусели выбора сыщиков
	# (UIStyle: BG_TEX @ BG_SCALE=0.5 через шейдер-тайлинг). На всю ширину полосы.
	var bg := UIStyle.make_tiled_texture_rect()
	bg.name = "BgPattern"
	bar.add_child(bg)

	# Ornate-рамка на ВСЮ ширину (9-slice: торцы крепкие, середина тянется).
	# Ассет @2× — рисуем через scale (борта вдвое тоньше); размер рамки делаем
	# в 1/scale раз больше полосы, чтобы после масштаба она ровно её покрыла.
	var frame := NinePatchRect.new()
	frame.name = "Frame"
	frame.texture = _FRAME_TEX
	frame.patch_margin_left = _FRAME_PATCH_H
	frame.patch_margin_right = _FRAME_PATCH_H
	frame.patch_margin_top = _FRAME_PATCH_V
	frame.patch_margin_bottom = _FRAME_PATCH_V
	frame.scale = Vector2(_FRAME_SCALE, _FRAME_SCALE)
	frame.position = Vector2.ZERO
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(frame)
	var fit_frame := func() -> void: frame.size = bar.size / _FRAME_SCALE
	bar.resized.connect(fit_frame)
	fit_frame.call()

	# Контент слева: [аватар] [compact InfoBar]. Справа в полосе — место под
	# кнопки действий (ActionPanel — отдельный компонент). HBox по содержимому,
	# кладём поверх рамки на левый край.
	var content := HBoxContainer.new()
	content.name = "Content"
	content.add_theme_constant_override("separation", int(_GAP))
	content.alignment = BoxContainer.ALIGNMENT_BEGIN
	content.position = Vector2(_CONTENT_PAD_X, _CONTENT_PAD_Y)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(content)

	content.add_child(_build_avatar())

	_info_bar = InfoBar.new()
	_info_bar.name = "InfoBar"
	_info_bar.compact = true
	_info_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	content.add_child(_info_bar)


# Круглый аватар: портрет с круговой маской + кольцо-фрейм поверх + подпись имени.
func _build_avatar() -> Control:
	var col := VBoxContainer.new()
	col.name = "AvatarCol"
	# Отрицательный отступ: подпись подтягивается вверх и слегка налезает на низ
	# аватарки (имя идёт после холдера → рисуется поверх кольца).
	col.add_theme_constant_override("separation", -_CAPTION_OVERLAP)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var holder := Control.new()
	holder.name = "Avatar"
	holder.custom_minimum_size = Vector2(_AVATAR_D, _AVATAR_D)
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# Аватар кликабелен — открывает карточку способностей (спец-действие + пассив).
	holder.mouse_filter = Control.MOUSE_FILTER_STOP
	holder.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	holder.gui_input.connect(_on_avatar_input)

	# Ореол хода — самым нижним слоем холдера: под портретом, тенью и кольцом.
	_turn_glow = ColorRect.new()
	_turn_glow.name = "TurnGlow"
	_turn_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_turn_glow.visible = false
	_turn_glow_mat = ShaderMaterial.new()
	var glow_sh := Shader.new()
	glow_sh.code = _TURN_GLOW_SHADER
	_turn_glow_mat.shader = glow_sh
	_turn_glow.material = _turn_glow_mat
	holder.add_child(_turn_glow)
	refresh_turn_glow()

	# Портрет заполняет весь холдер с круговой маской; кольцо-фрейм сверху прячет
	# края портрета — т.е. портрет лежит ПОД фреймом аватарки.
	_portrait = TextureRect.new()
	_portrait.name = "Portrait"
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = _CIRCLE_MASK_SHADER
	mat.shader = sh
	_portrait.material = mat
	holder.add_child(_portrait)

	# Тень кольца: размытый силуэт рамки, сдвинут вниз. ПОД кольцом, но НАД портретом —
	# падает и на портрет (внутренняя дуга), и наружу на подложку панели (внешняя).
	var shadow := TextureRect.new()
	shadow.name = "RingShadow"
	shadow.texture = _AVATAR_FRAME
	shadow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shadow.stretch_mode = TextureRect.STRETCH_SCALE
	shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shadow.offset_left = _AVATAR_SHADOW_OFFSET.x
	shadow.offset_right = _AVATAR_SHADOW_OFFSET.x
	shadow.offset_top = _AVATAR_SHADOW_OFFSET.y
	shadow.offset_bottom = _AVATAR_SHADOW_OFFSET.y
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh_mat := ShaderMaterial.new()
	var sh_sh := Shader.new()
	sh_sh.code = _AVATAR_SHADOW_SHADER
	sh_mat.shader = sh_sh
	sh_mat.set_shader_parameter("blur", _AVATAR_SHADOW_BLUR)
	sh_mat.set_shader_parameter("shadow_alpha", _AVATAR_SHADOW_ALPHA)
	shadow.material = sh_mat
	holder.add_child(shadow)

	# Кольцо-фрейм поверх портрета.
	var ring := TextureRect.new()
	ring.name = "Ring"
	ring.texture = _AVATAR_FRAME
	ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ring.stretch_mode = TextureRect.STRETCH_SCALE
	ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(ring)
	col.add_child(holder)

	# Подпись как на карточке сыщика: имя золотом (ACCENT) + род занятий ниже
	# (MUTED), по центру, с лёгкой тенью; две строки вплотную.
	var caption := VBoxContainer.new()
	caption.name = "Caption"
	caption.alignment = BoxContainer.ALIGNMENT_CENTER
	caption.add_theme_constant_override("separation", 0)
	caption.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_name_label = UIStyle.label("", 20, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_name_label.name = "NameLabel"
	_caption_shadow(_name_label)
	caption.add_child(_name_label)

	_occ_label = UIStyle.label("", 14, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_occ_label.name = "OccLabel"
	_caption_shadow(_occ_label)
	caption.add_child(_occ_label)

	col.add_child(caption)
	return col


# Лёгкая чёрная тень под текстом подписи (читаемость поверх фона/рамки) — как на
# карточке сыщика (_apply_card_text_shadow).
func _caption_shadow(lbl: Label) -> void:
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.add_theme_constant_override("shadow_outline_size", 2)


# ── Заполнение данными ────────────────────────────────────────────────────────


func _populate_data() -> void:
	if is_instance_valid(_portrait):
		_portrait.texture = _load_portrait()
	if is_instance_valid(_name_label):
		# displayName / occupation — translation keys; Label переводит автоматически
		# (реактивно к смене локали). Обычный регистр, без caps.
		_name_label.text = String(_inv_data.get("displayName", _inv_data.get("name", _inv_name)))
		_occ_label.text = String(_inv_data.get("occupation", ""))
	if is_instance_valid(_info_bar):
		_info_bar.update(_inv_data)


# Клик по аватару — карточка способностей сыщика.
func _on_avatar_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if _inv_name.is_empty():
		return
	AbilityInfo.open(self, _inv_name)


func _refresh_identity() -> void:
	var prev: String = _inv_name
	_load_data()
	if _inv_name != prev:
		_populate_data()


## Живые HP/рассудок из GameState (cur/max + заливка баров). Атрибуты остаются
## базовыми (из _inv_data). Пока не в игре — оставляем базовые значения.
func _refresh_live() -> void:
	var p: Dictionary = GameState.my_player()
	if p.is_empty() or not is_instance_valid(_info_bar):
		return
	# Тень — не живой сыщик: прячем HP/рассудок/атрибуты, портрет делаем ч/б.
	var ghost: bool = bool(p.get(PlayerKeys.DEAD, false))
	_info_bar.visible = not ghost
	# Ореол хода: только когда ходит САМ игрок (действия И встречи — это всё его
	# ход; GameState.is_my_turn() смотрит лишь фазу действий); Тени ходить нечем.
	if is_instance_valid(_turn_glow):
		var my_phase: bool = GameState.phase == Phases.ACTION or GameState.phase == Phases.ENCOUNTER
		_set_turn_glow(
			(
				GameState.active
				and my_phase
				and GameState.current_pid() == GameState.local_pid()
				and not ghost
			)
		)
	if is_instance_valid(_portrait) and _portrait.material is ShaderMaterial:
		(_portrait.material as ShaderMaterial).set_shader_parameter("dead", 1.0 if ghost else 0.0)
	if ghost:
		return
	_info_bar.set_live_vitals(
		int(p.get("hp", 0)),
		int(p.get("hp_max", 0)),
		int(p.get("sanity", 0)),
		int(p.get("sanity_max", 0))
	)
	_info_bar.set_live_skill_mods(p.get("skill_mods", {}))


## Переприменить геометрию и параметры ореола из static-полей. Зовётся при сборке
## и из тюнинг-панели, когда подвинули ползунок (по группе GROUP).
func refresh_turn_glow() -> void:
	if not is_instance_valid(_turn_glow):
		return
	var m: float = _AVATAR_D * (GLOW_SPREAD - 1.0) * 0.5  # вынос за край аватарки
	_turn_glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	_turn_glow.offset_left = -m
	_turn_glow.offset_top = -m
	_turn_glow.offset_right = m
	_turn_glow.offset_bottom = m
	_set_turn_level(_turn_level)  # glow: цвет × текущая яркость фейда
	_turn_glow_mat.set_shader_parameter("edge", 1.0 / GLOW_SPREAD)
	_turn_glow_mat.set_shader_parameter("falloff", GLOW_FALLOFF)
	_turn_glow_mat.set_shader_parameter("pulse_speed", GLOW_PULSE_SPEED)
	_turn_glow_mat.set_shader_parameter("pulse_amount", GLOW_PULSE_AMOUNT)


# Ореол хода включается/гаснет плавным фейдом яркости, а не скачком видимости.
func _set_turn_glow(on: bool) -> void:
	if on == _turn_on:
		return
	_turn_on = on
	if _turn_tw != null and _turn_tw.is_valid():
		_turn_tw.kill()
	_turn_glow.visible = true
	_turn_tw = create_tween()
	_turn_tw.tween_method(_set_turn_level, _turn_level, 1.0 if on else 0.0, GLOW_FADE)
	if not on:
		_turn_tw.tween_callback(func() -> void: _turn_glow.visible = false)


# Яркость ореола (0..1) — множитель альфы glow в шейдере (modulate шейдер не видит:
# он целиком задаёт COLOR).
func _set_turn_level(v: float) -> void:
	_turn_level = v
	var c: Color = UIColors.ACTIVE  # единый цвет активного выделения
	_turn_glow_mat.set_shader_parameter("glow", Vector4(c.r, c.g, c.b, GLOW_ALPHA * v))


# ── Загрузка данных сыщика ────────────────────────────────────────────────────


func _load_data() -> void:
	_inv_name = ""
	# Приоритет 1: GameState (стабильный user_id) — истина во время игры.
	var me: Dictionary = GameState.my_player()
	if not me.is_empty():
		_inv_name = String(me.get("investigator", ""))
	# Приоритет 2: NetworkManager.players (лобби-стейт) — пока игра не началась.
	if _inv_name.is_empty():
		var nm: Node = get_node_or_null("/root/NetworkManager")
		if nm:
			var my_id: String = (nm as Node).get("my_id")
			var players: Dictionary = (nm as Node).get("players")
			if players.has(my_id):
				_inv_name = String(players[my_id].get("investigator", ""))
	# Приоритет 3: prefs.cfg last_investigator — самый ранний просмотр.
	if _inv_name.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(Profile.path("dark_omens_prefs.cfg")) == OK:
			_inv_name = cfg.get_value(_PREFS_SECTION, "last_investigator", "")
	_inv_data = {}
	if _inv_name.is_empty():
		return
	var arr: Array = DataLoader.load_array(_DATA_PATH)
	for inv: Dictionary in arr:
		if inv.get("name", "") == _inv_name:
			_inv_data = inv
			break


func _load_portrait() -> Texture2D:
	if not _inv_name.is_empty():
		var path := "res://assets/investigators/%s.png" % _inv_name
		if ResourceLoader.exists(path):
			return load(path) as Texture2D
	var img := Image.create(80, 100, false, Image.FORMAT_RGB8)
	img.fill(Color(0.13, 0.12, 0.20))
	return ImageTexture.create_from_image(img)
