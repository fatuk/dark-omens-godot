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

const _BG_PATTERN: Texture2D = preload("res://assets/bg-pattern.png")
const _FRAME_TEX: Texture2D = preload(
	"res://assets/investigator-panel/investigator-panel-frame.png"
)
const _AVATAR_FRAME: Texture2D = preload("res://assets/investigator-panel/avatar-round-frame.png")

# Круглая маска портрета: отсекаем фрагменты вне вписанного круга.
const _CIRCLE_MASK_SHADER := """
shader_type canvas_item;
void fragment() {
	if (distance(UV, vec2(0.5)) > 0.5) { COLOR.a = 0.0; }
}
"""

var _inv_name: String = ""
var _inv_data: Dictionary = {}
var _info_bar: InfoBar
var _portrait: TextureRect
var _name_label: Label

# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	_load_data()
	_build_ui()
	_populate_data()
	# Идентичность сыщика и живые статы тянем при смене стейта (поздний вход,
	# переподключение). _refresh_identity пересобирает только при смене сыщика.
	GameState.state_changed.connect(_refresh_identity)
	GameState.state_changed.connect(_refresh_live)
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

	# Фон-паттерн на всю полосу (под рамкой и кнопками действий).
	var bg := TextureRect.new()
	bg.name = "BgPattern"
	bg.texture = _BG_PATTERN
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_TILE  # bg-pattern.png — тайлящийся паттерн
	bg.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED  # иначе TILE клампит края
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	col.add_theme_constant_override("separation", 4)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var holder := Control.new()
	holder.name = "Avatar"
	holder.custom_minimum_size = Vector2(_AVATAR_D, _AVATAR_D)
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

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

	_name_label = Label.new()
	_name_label.name = "NameLabel"
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.add_theme_font_size_override("font_size", 16)
	_name_label.add_theme_color_override("font_color", UIColors.TEXT)
	col.add_child(_name_label)

	return col


# ── Заполнение данными ────────────────────────────────────────────────────────


func _populate_data() -> void:
	if is_instance_valid(_portrait):
		_portrait.texture = _load_portrait()
	if is_instance_valid(_name_label):
		# displayName — translation key; Label переводит автоматически.
		_name_label.text = String(_inv_data.get("displayName", _inv_data.get("name", _inv_name)))
	if is_instance_valid(_info_bar):
		_info_bar.update(_inv_data)


func _refresh_identity() -> void:
	var prev: String = _inv_name
	_load_data()
	if _inv_name != prev:
		_populate_data()


## Живые статы из GameState. v1: InfoBar показывает базовые статы сыщика
## (_inv_data); живой HP-fill (cur/max + заливка баров) из GameState.my_player()
## — следующим шагом (нужен live-режим у самого InfoBar). Заглушка-хук на смену
## стейта оставлена, чтобы доводку было куда вешать.
func _refresh_live() -> void:
	pass


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
