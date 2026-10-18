extends CanvasLayer

## Окно «бросок в Расплате»: монстр или карта Мифов бросает кубик в своей Расплате
## («Дитя Козла: 1–2 — Рок +1»). Раньше dieRoll шёл молча — Рок просто прыгал.
## Теперь видно, КТО бросил (портрет + имя), что выпало (лоток со спином) и что
## из этого вышло (строка исхода проявляется, когда кубы осели).
##
## Источник — синкаемое GameState.reckoning_roll (ReckoningFlow._show_roll): хост
## держит его ROLL_SHOW секунд и сам гасит, кнопок нет. Строится кодом, монтируется
## из world_map.

const _MIN_W: float = 460.0
const _ART_H: float = 230.0  # высота портрета в окне
const _MYTHOS_ART_DIR := "res://assets/mythos/"

var _root: ColorRect
var _panel: PanelContainer
var _box: VBoxContainer
var _nonce: int = -1  # какой бросок уже показан — не пересобираем на каждом синке


func _ready() -> void:
	layer = 84  # поверх карты и панелей, под окнами проверки/приобретений
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


func _build() -> void:
	_root = ColorRect.new()
	_root.name = "Root"
	_root.color = Color(0, 0, 0, 0.45)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = false
	add_child(_root)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.custom_minimum_size.x = _MIN_W
	UIStyle.style_modal_panel(_panel)
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	_panel.add_child(margin)

	_box = VBoxContainer.new()
	_box.name = "Box"
	_box.add_theme_constant_override("separation", 14)
	margin.add_child(_box)


func _refresh() -> void:
	var ev: Dictionary = GameState.reckoning_roll
	if ev.is_empty():
		_nonce = -1
		UIStyle.modal_set_visible(_root, _panel, false)
		return
	var n: int = int(ev.get("nonce", 0))
	if n != _nonce:
		_nonce = n
		_fill(ev)
	UIStyle.modal_set_visible(_root, _panel, true)


func _fill(ev: Dictionary) -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()

	var title := UIStyle.modal_title("RECKONING_ROLL_TITLE", UIColors.DANGER)
	title.name = "Title"
	_box.add_child(title)
	UIStyle.separator(_box)

	var is_monster: bool = String(ev.get("source", "")) == "monster"
	var art: Texture2D = _monster_art(ev) if is_monster else _mythos_art(ev)
	if art != null:
		var pic := TextureRect.new()
		pic.name = "Portrait"
		pic.texture = art
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		pic.custom_minimum_size = Vector2(art.get_size().x * (_ART_H / art.get_size().y), _ART_H)
		pic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_box.add_child(pic)

	var who: String = (
		String(ev.get("nameKey", ev.get("id", ""))) if is_monster else String(ev.get("name", ""))
	)
	var name_lbl := UIStyle.label(
		who, UIStyle.MODAL_FS_LEAD, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER
	)
	name_lbl.name = "Who"
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_box.add_child(name_lbl)

	var tray := DiceTray.new()
	tray.name = "Rolls"
	tray.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_box.add_child(tray)

	# Исход — описание эффектов, что сейчас применит хост (на своём языке), или «ничего».
	var effects: Array = ev.get("effects", [])
	var text: String = EffectManifest.describe_list(effects)
	if not text.is_empty():  # метки эффектов — со строчной («рок +1»): строка — с заглавной
		text = text.left(1).to_upper() + text.substr(1)
	var outcome := UIStyle.label(
		text if not text.is_empty() else "RECKONING_ROLL_NONE",
		UIStyle.MODAL_FS_BODY,
		UIColors.DANGER if not effects.is_empty() else UIColors.MUTED,
		HORIZONTAL_ALIGNMENT_CENTER
	)
	outcome.name = "Outcome"
	outcome.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outcome.modulate.a = 0.0  # проявится, когда кубы осядут — не раньше броска
	_box.add_child(outcome)
	tray.roll_settled.connect(
		func() -> void:
			if is_instance_valid(outcome):
				outcome.create_tween().tween_property(outcome, "modulate:a", 1.0, 0.25)
	)
	tray.play_roll(ev.get("dice", []), false, false)


func _monster_art(ev: Dictionary) -> Texture2D:
	return MonsterCatalog.card_art(String(ev.get("id", "")))


# Арт карты Мифов по её id в CMS (как в mythos_modal); нет файла — без картинки.
func _mythos_art(ev: Dictionary) -> Texture2D:
	var sid: String = String(ev.get("sourceId", ""))
	if sid.is_empty():
		return null
	var path: String = _MYTHOS_ART_DIR + sid + ".png"
	return load(path) as Texture2D if ResourceLoader.exists(path) else null
