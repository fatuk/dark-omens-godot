extends CanvasLayer

## HUD-панель сыщика.
## Иконка-портрет всегда видна в левом нижнем углу.
## Клик открывает/закрывает горизонтальную полосу снизу с анимацией.
##
## Разметка статичной части в scenes/ui/investigator_panel.tscn.
## Тут — загрузка данных, заполнение текста + динамика (роли, веер карт),
## анимация выезда панели.

const _PREFS_PATH    := "user://dark_omens_prefs.cfg"
const _PREFS_SECTION := "player"
const _DATA_PATH     := "res://data/investigators.json"

const BAR_H     := 280.0   # высота выезжающей панели
const ANIM_DUR  :=   0.28
const CARD_W    :=  68.0
const CARD_H    := 100.0
const MAX_CARDS :=   20

# ── Узлы ──────────────────────────────────────────────────────────────────────
@onready var _info_panel:    Control = %InfoPanel
@onready var _portrait_btn:  Button  = %PortraitBtn
@onready var _balloon:       Control = %Balloon

@onready var _portrait_tex:  TextureRect = %Texture
@onready var _name_label:    Label = %NameLabel
@onready var _occ_label:     Label = %OccLabel
@onready var _quote_label:   Label = %QuoteLabel

@onready var _hp_value:      Label         = $InfoPanel/InfoCol/StatsRow/HpPill/Value
@onready var _san_value:     Label         = $InfoPanel/InfoCol/StatsRow/SanPill/Value
@onready var _skills_label:  Label         = %SkillsLabel
@onready var _roles_row:     HBoxContainer = %RolesRow
@onready var _card_fan:      Control       = %CardFan

# ── Состояние ──────────────────────────────────────────────────────────────────
var _inv_name: String     = ""
var _inv_data: Dictionary = {}
var _shown:    bool       = false
var _tween:    Tween      = null


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_load_data()
	_apply_styles()
	_populate_data()
	_build_card_fan()
	_wire_handlers()


# ── Применение Dark Omens-цветов к статичным лейблам ──────────────────────────

func _apply_styles() -> void:
	# HP / Рассудок: иконка цветная, число — TEXT, подпись — MUTED
	($InfoPanel/InfoCol/StatsRow/HpPill/Icon as Label).add_theme_color_override(
		"font_color", Color(0.85, 0.22, 0.22))
	_hp_value.add_theme_color_override("font_color", UIColors.TEXT)
	($InfoPanel/InfoCol/StatsRow/HpPill/Sub as Label).add_theme_color_override(
		"font_color", UIColors.MUTED)

	($InfoPanel/InfoCol/StatsRow/SanPill/Icon as Label).add_theme_color_override(
		"font_color", Color(0.28, 0.55, 0.90))
	_san_value.add_theme_color_override("font_color", UIColors.TEXT)
	($InfoPanel/InfoCol/StatsRow/SanPill/Sub as Label).add_theme_color_override(
		"font_color", UIColors.MUTED)

	_skills_label.add_theme_color_override("font_color", UIColors.MUTED)
	_name_label.add_theme_color_override("font_color", UIColors.TEXT)
	_occ_label.add_theme_color_override("font_color", UIColors.MUTED)
	_quote_label.add_theme_color_override("font_color", UIColors.MUTED)


# ── Заполнение текста / портрета / ролей ──────────────────────────────────────

func _populate_data() -> void:
	# Портрет
	_portrait_tex.texture = _load_portrait()
	# displayName/occupation/quote — translation keys; Godot переводит автоматически.
	# (Кавычки «...» теперь внутри переведённой строки в CSV.)
	_name_label.text  = _inv_data.get("displayName",
		_inv_data.get("name", _inv_name if not _inv_name.is_empty() else "???"))
	_occ_label.text   = _inv_data.get("occupation", "")
	_quote_label.text = _inv_data.get("quote", "")

	# HP / Рассудок
	_hp_value.text  = "%.1f" % float(_inv_data.get("health", 0))
	_san_value.text = "%.1f" % float(_inv_data.get("sanity", 0))

	# Навыки
	var sk: Dictionary = _inv_data.get("skills", {})
	_skills_label.text = "Lore %d  ·  Infl %d  ·  Obs %d\nStr %d  ·  Will %d" % [
		int(sk.get("lore", 0)), int(sk.get("influence", 0)),
		int(sk.get("observation", 0)), int(sk.get("strength", 0)),
		int(sk.get("will", 0))
	]

	# Роли — динамическое количество бейджей
	for child in _roles_row.get_children():
		child.queue_free()
	var roles: Array = _inv_data.get("role", [])
	for role: String in roles:
		_roles_row.add_child(_make_role_badge(role))


func _make_role_badge(badge_text: String) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.name = "RoleBadge_" + badge_text
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = UIColors.ACCENT
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left   = 10
	style.content_margin_right  = 10
	style.content_margin_top    = 4
	style.content_margin_bottom = 4
	pc.add_theme_stylebox_override("panel", style)

	var lbl := Label.new()
	lbl.name = "Text"
	lbl.text = badge_text
	lbl.add_theme_font_size_override("font_size", 24)
	lbl.add_theme_color_override("font_color", UIColors.ACCENT)
	pc.add_child(lbl)
	return pc


# ── Веер карт (динамически 20 штук с поворотом) ──────────────────────────────

func _build_card_fan() -> void:
	# Стартовая позиция: правее слотов предметов
	var start_x: float = 660.0
	var arc_deg: float = 38.0
	var step:    float = arc_deg / maxf(float(MAX_CARDS) - 1.0, 1.0)
	var x_step:  float = CARD_W * 0.52

	for i: int in range(MAX_CARDS):
		var angle_deg: float = -arc_deg / 2.0 + float(i) * step

		var card := Panel.new()
		card.name = "Card_%d" % i
		var style := StyleBoxFlat.new()
		style.bg_color     = Color(0.20, 0.15, 0.36, 0.93)
		style.border_color = Color(0.40, 0.30, 0.60)
		style.set_border_width_all(1)
		style.set_corner_radius_all(6)
		card.add_theme_stylebox_override("panel", style)

		card.anchor_left   = 0.0
		card.anchor_right  = 0.0
		card.anchor_top    = 1.0
		card.anchor_bottom = 1.0
		card.offset_left   = start_x + float(i) * x_step
		card.offset_right  = start_x + float(i) * x_step + CARD_W
		card.offset_top    = -CARD_H - 6.0
		card.offset_bottom = -6.0

		# Поворот вокруг нижнего центра — веер раскрывается вверх
		card.pivot_offset = Vector2(CARD_W / 2.0, CARD_H)
		card.rotation     = deg_to_rad(angle_deg)

		_card_fan.add_child(card)


# ── Обработчики ───────────────────────────────────────────────────────────────

func _wire_handlers() -> void:
	_portrait_btn.mouse_entered.connect(func() -> void: _balloon.visible = true)
	_portrait_btn.mouse_exited.connect(func() -> void:  _balloon.visible = false)
	_portrait_btn.pressed.connect(_toggle)


# ── Анимация выезжающей панели ────────────────────────────────────────────────

func _toggle() -> void:
	_shown = not _shown
	if _tween and _tween.is_valid():
		_tween.kill()

	if _shown:
		_info_panel.offset_top = 0.0
		_info_panel.visible    = true
		_tween = create_tween()
		_tween.set_ease(Tween.EASE_OUT)
		_tween.set_trans(Tween.TRANS_QUART)
		_tween.tween_property(_info_panel, "offset_top", -BAR_H, ANIM_DUR)
	else:
		_tween = create_tween()
		_tween.set_ease(Tween.EASE_IN)
		_tween.set_trans(Tween.TRANS_QUART)
		_tween.tween_property(_info_panel, "offset_top", 0.0, ANIM_DUR * 0.85)
		_tween.tween_callback(func() -> void: _info_panel.visible = false)


# ── Загрузка данных сыщика ────────────────────────────────────────────────────

func _load_data() -> void:
	# Приоритет 1: живое состояние NetworkManager (актуально для текущей сессии,
	# корректно при нескольких инстансах на одной машине)
	var nm: Node = get_node_or_null("/root/NetworkManager")
	if nm:
		var my_id: String       = (nm as Node).get("my_id")
		var players: Dictionary = (nm as Node).get("players")
		if players.has(my_id):
			_inv_name = players[my_id].get("investigator", "")
	# Приоритет 2: последний сохранённый выбор (фолбэк / соло-режим)
	if _inv_name.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(_PREFS_PATH) == OK:
			_inv_name = cfg.get_value(_PREFS_SECTION, "last_investigator", "")
	if _inv_name.is_empty():
		return
	var arr: Array = DataLoader.load_array(_DATA_PATH)
	if arr.is_empty():
		return
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
