extends CanvasLayer

## HUD-панель сыщика.
## Иконка-портрет всегда видна в левом нижнем углу.
## Клик открывает/закрывает горизонтальную полосу снизу с анимацией.
##
## Разметка статичной части в scenes/ui/investigator_panel.tscn.
## Тут — загрузка данных, заполнение текста + динамика (роли, веер карт),
## анимация выезда панели.

const _PREFS_SECTION := "player"
const _DATA_PATH     := "res://data/investigators.json"

const BAR_H     := 280.0   # высота выезжающей панели
const ANIM_DUR  :=   0.28

# Маркеры типов имущества (GameState items) → ключи перевода.
const _ITEM_WORDS := {
	"gainAsset":       "ITEM_ASSET",
	"gainSpell":       "ITEM_SPELL",
	"gainArtifact":    "ITEM_ARTIFACT",
	"gainImprovement": "ITEM_IMPROVEMENT",
}

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
var _live_label: Label    = null   # строка живых статусов/состояний/имущества


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_load_data()
	_apply_styles()
	_populate_data()
	_build_live_area()
	_wire_handlers()
	# При смене стейта подтягиваем и идентичность сыщика, и живые статусы.
	# Идентичность пересобирается только если поменялась — _populate_data зря
	# не дёргается. Нужно, потому что на первой загрузке мира GameState.players
	# может быть ещё пустым (картинка показалась раньше старта игры) — тогда
	# _load_data возьмёт фолбэк из NM/prefs, а после start_game синк её исправит.
	GameState.state_changed.connect(_refresh_identity)
	GameState.state_changed.connect(_refresh_live)
	_refresh_live()


# Перезагружает идентичность сыщика после смены состояния игры.
func _refresh_identity() -> void:
	var prev: String = _inv_name
	_load_data()
	if _inv_name != prev:
		_populate_data()


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


# ── Живые данные игрока (статусы, состояния, имущество) ───────────────────────

func _build_live_area() -> void:
	# Декоративные слоты предметов больше не нужны — живые данные показываем
	# текстом в области бывшего веера карт.
	for slot_name: String in ["Slot1", "Slot2"]:
		var slot: CanvasItem = get_node_or_null("InfoPanel/" + slot_name) as CanvasItem
		if slot:
			slot.visible = false

	_live_label = Label.new()
	_live_label.name = "LiveInfo"
	_live_label.position = Vector2(480.0, 30.0)
	_live_label.custom_minimum_size = Vector2(900.0, 0.0)
	_live_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_live_label.add_theme_font_size_override("font_size", 18)
	_live_label.add_theme_color_override("font_color", UIColors.TEXT)
	_card_fan.add_child(_live_label)


## Обновляет живые статусы / состояния / имущество из GameState.
func _refresh_live() -> void:
	var p: Dictionary = GameState.my_player()
	if p.is_empty():
		return   # не в игре — оставляем статичные значения
	_hp_value.text  = "%d / %d" % [int(p.get("hp", 0)), int(p.get("hp_max", 0))]
	_san_value.text = "%d / %d" % [int(p.get("sanity", 0)), int(p.get("sanity_max", 0))]
	if is_instance_valid(_live_label):
		_live_label.text = _live_text(p)


func _live_text(p: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("%s: %d   ·   %s: %d   ·   %s: %d" % [
		tr("INV_PANEL_CLUES"),   int(p.get("clues", 0)),
		tr("INV_PANEL_TICKETS"), int(p.get("tickets", 0)),
		tr("INV_PANEL_FOCUS"),   int(p.get("concentration", 0)),
	])

	var conds: Array = p.get("conditions", [])
	var cond_names := PackedStringArray()
	for i: int in range(conds.size()):
		cond_names.append(tr(Conditions.name_key(String(conds[i]))))
	lines.append("%s: %s" % [
		tr("INV_PANEL_CONDITIONS"),
		", ".join(cond_names) if cond_names.size() > 0 else tr("INV_PANEL_NONE"),
	])

	var items: Array = p.get("items", [])
	lines.append("%s: %s" % [
		tr("INV_PANEL_ITEMS"),
		_items_text(items) if items.size() > 0 else tr("INV_PANEL_NONE"),
	])
	return "\n".join(lines)


## Группирует маркеры имущества по типу: «Артефакт ×2, Заклинание».
func _items_text(items: Array) -> String:
	var counts: Dictionary = {}
	for i: int in range(items.size()):
		var key: String = String(_ITEM_WORDS.get(String(items[i]), "ITEM_OTHER"))
		counts[key] = int(counts.get(key, 0)) + 1
	var parts := PackedStringArray()
	for key: String in counts:
		var n: int = int(counts[key])
		parts.append("%s ×%d" % [tr(key), n] if n > 1 else tr(key))
	return ", ".join(parts)


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
	_inv_name = ""
	# Приоритет 1: GameState (ключ по стабильному user_id) — истина во время
	# игры; устойчив к переподключению и позднему входу.
	var me: Dictionary = GameState.my_player()
	if not me.is_empty():
		_inv_name = String(me.get("investigator", ""))
	# Приоритет 2: NetworkManager.players (лобби-стейт) — пока игра не началась.
	if _inv_name.is_empty():
		var nm: Node = get_node_or_null("/root/NetworkManager")
		if nm:
			var my_id: String       = (nm as Node).get("my_id")
			var players: Dictionary = (nm as Node).get("players")
			if players.has(my_id):
				_inv_name = String(players[my_id].get("investigator", ""))
	# Приоритет 3: prefs.cfg last_investigator — самый ранний просмотр (picker
	# в лобби до set_ready, или соло-проверка панели вне игры).
	if _inv_name.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(Profile.path("dark_omens_prefs.cfg")) == OK:
			_inv_name = cfg.get_value(_PREFS_SECTION, "last_investigator", "")
	_inv_data = {}
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
