extends CanvasLayer

## Боковая панель справа с инфой о выбранной локации.
## Открывается через show_location(data), закрывается close_panel() или
## кнопкой ✕. При смене локации с открытым сайдбаром просто обновляет контент
## без re-анимации.
##
## Сигналы:
##   closed              — пользователь закрыл крестиком (карта снимет подсветку)
##   neighbor_selected   — клик по соседу в списке (карта переключится туда)

signal closed
signal neighbor_selected(loc_name: String)

const PANEL_WIDTH: float = 360.0
const ANIM_TIME:   float = 0.22

# Цвета и подписи типов связей (соответствуют MapLayer.COLOR_*).
const CONN_COLORS: Dictionary = {
	"ship":      Color(0.275, 0.510, 0.706),
	"train":     Color(0.627, 0.322, 0.176),
	"uncharted": Color(1.000, 0.843, 0.000),
}
# Ключи переводов для типов связей — резолвятся через tr() при отрисовке.
const CONN_TR_KEYS: Dictionary = {
	"ship":      "CONN_SHIP",
	"train":     "CONN_TRAIN",
	"uncharted": "CONN_UNCHARTED",
}

@onready var _panel:         PanelContainer = %Panel
@onready var _title:         Label          = %Title
@onready var _subtitle:      Label          = %Subtitle
@onready var _type_label:    Label          = %TypeLabel
@onready var _description:   Label          = %Description
@onready var _close_btn:     Button         = %CloseBtn
@onready var _neighbors_hdr: Label          = %NeighborsHeader
@onready var _neighbors:     VBoxContainer  = %NeighborsList
@onready var _travel_btn:    Button         = %TravelBtn

var _is_open: bool   = false
var _tween:   Tween  = null
var _loc_id:  String = ""   # id показанной сейчас локации (для GameState.travel)

# Блок «айтемы на локации» — создаётся программно (динамический контент).
var _items_sep:  HSeparator    = null
var _items_hdr:  Label         = null
var _items_list: VBoxContainer = null


func _ready() -> void:
	UIStyle.style_panel(_panel, 18)
	_style_close_button()
	_title.add_theme_color_override("font_color",         UIColors.ACCENT)
	_subtitle.add_theme_color_override("font_color",      UIColors.MUTED)
	_type_label.add_theme_color_override("font_color",    UIColors.WARNING)
	_description.add_theme_color_override("font_color",   UIColors.TEXT)
	_neighbors_hdr.add_theme_color_override("font_color", UIColors.MUTED)
	_close_btn.pressed.connect(_on_close_pressed)
	UIStyle.style_button(_travel_btn)
	_travel_btn.pressed.connect(_on_travel_pressed)
	GameState.state_changed.connect(_refresh_travel)
	GameState.state_changed.connect(_refresh_items)
	_build_items_section()
	_apply_offsets(true)
	_neighbors_hdr.text = "SIDEBAR_NEIGHBORS"  # Godot auto-translate при рендере


# Создаёт секцию «айтемы на локации» в VBox сразу после кнопки перемещения.
func _build_items_section() -> void:
	var vbox: Node = _neighbors.get_parent()   # Panel/Margin/VBox
	_items_sep = HSeparator.new()
	_items_hdr = Label.new()
	_items_hdr.text = "SIDEBAR_ITEMS"
	_items_hdr.add_theme_font_size_override("font_size", 11)
	_items_hdr.add_theme_color_override("font_color", UIColors.MUTED)
	_items_list = VBoxContainer.new()
	_items_list.add_theme_constant_override("separation", 6)
	vbox.add_child(_items_sep)
	vbox.add_child(_items_hdr)
	vbox.add_child(_items_list)
	var at: int = _travel_btn.get_index() + 1
	vbox.move_child(_items_sep, at)
	vbox.move_child(_items_hdr, at + 1)
	vbox.move_child(_items_list, at + 2)


# ── Public ────────────────────────────────────────────────────────────────────

func show_location(data: Dictionary) -> void:
	# name/realWorldLocation/description/type — translation keys.
	# Присваивание в Label.text оставляет ключ; Godot вызывает tr() при рендере
	# и сам обновит при смене локали.
	_title.text       = String(data.get("name", ""))              # игровое имя (LOC_*_NAME)
	_subtitle.text    = String(data.get("realWorldLocation", "")) # реальный прообраз
	_type_label.text  = _type_label_for(String(data.get("type", "city")))
	_description.text = String(data.get("description", ""))
	_populate_neighbors(data.get("connections", []))
	_loc_id = String(data.get("id", ""))
	_populate_items(_loc_id)
	_refresh_travel()
	if not _is_open:
		_is_open = true
		_animate(false)


func close_panel() -> void:
	if not _is_open:
		return
	_is_open = false
	_loc_id = ""
	_refresh_travel()
	_animate(true)
	closed.emit()


func is_open() -> bool:
	return _is_open


# ── Перемещение ──────────────────────────────────────────────────────────────

## Показывает кнопку «Переместиться сюда», если игрок может туда пойти сейчас.
func _refresh_travel() -> void:
	_travel_btn.visible = not _loc_id.is_empty() and GameState.can_travel_to(_loc_id)


func _on_travel_pressed() -> void:
	if not _loc_id.is_empty():
		GameState.travel(_loc_id)


# ── Айтемы на локации ──────────────────────────────────────────────────────────

## При смене стейта (спаун монстров/улик) — перерисовать список, если открыт.
func _refresh_items() -> void:
	if _is_open and not _loc_id.is_empty():
		_populate_items(_loc_id)


## Список айтемов локации, сгруппированный: Монстры (со статами) → Улики → Слухи.
func _populate_items(loc_id: String) -> void:
	if not is_instance_valid(_items_list):
		return
	for child in _items_list.get_children():
		child.queue_free()

	var ents:  Array = GameState.entities.get(loc_id, [])
	var mons:  Array = GameState.monsters.get(loc_id, [])
	var clues: int   = (ents as Array).count("clue")
	var rumors: int  = (ents as Array).count("rumor")

	var empty: bool = mons.is_empty() and clues == 0 and rumors == 0
	_items_sep.visible  = not empty
	_items_hdr.visible  = not empty
	_items_list.visible = not empty
	if empty:
		return

	if not mons.is_empty():
		_items_list.add_child(_make_category_header("SIDEBAR_CAT_MONSTERS", mons.size()))
		for i: int in range(mons.size()):
			var inst_v: Variant = mons[i]   # {id, health} или легаси id-строка
			var mid: String = String(inst_v.get("id", "")) if inst_v is Dictionary else String(inst_v)
			var hp: int = int((inst_v as Dictionary).get("health", -1)) if inst_v is Dictionary else -1
			var m: Dictionary = MonsterCatalog.by_id(mid)
			if not m.is_empty():
				_items_list.add_child(_make_monster_card(m, hp))
	if clues > 0:
		_items_list.add_child(_make_category_header("SIDEBAR_CAT_CLUES", clues))
	if rumors > 0:
		_items_list.add_child(_make_category_header("SIDEBAR_CAT_RUMORS", rumors))


func _make_category_header(key: String, count: int) -> Label:
	var l := Label.new()
	l.text = "%s — %d" % [tr(key), count]
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", UIColors.WARNING)
	return l


func _make_monster_card(m: Dictionary, cur_health: int = -1) -> PanelContainer:
	var pc := PanelContainer.new()
	UIStyle.style_panel(pc, 10)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	pc.add_child(vb)

	var nm := Label.new()
	nm.text = String(m.get("nameKey", ""))   # MON_*_NAME — Godot переведёт
	nm.add_theme_font_size_override("font_size", 14)
	nm.add_theme_color_override("font_color", UIColors.ACCENT)
	vb.add_child(nm)

	if m.has("horror"):
		var inv: int = maxi(1, GameState.players.size())
		var tough: int = MonsterCatalog.toughness_for(m, inv)
		var st := Label.new()
		# Текущее здоровье экземпляра / макс (если ранен — видно в бою).
		st.text = ("%s: %d / %d" % [tr("SIDEBAR_TOUGHNESS"), cur_health, tough]) if cur_health >= 0 \
			else ("%s: %d" % [tr("SIDEBAR_TOUGHNESS"), tough])
		st.add_theme_font_size_override("font_size", 12)
		st.add_theme_color_override("font_color", UIColors.TEXT)
		vb.add_child(st)
		vb.add_child(_stat_line("SIDEBAR_HORROR", m.get("horror", {})))
		vb.add_child(_stat_line("SIDEBAR_COMBAT", m.get("combat", {})))
	elif bool(m.get("useAncientOne", false)):
		var ao := Label.new()
		ao.text = "SIDEBAR_USE_ANCIENT_ONE"
		ao.add_theme_font_size_override("font_size", 12)
		ao.add_theme_color_override("font_color", UIColors.MUTED)
		vb.add_child(ao)

	var ab := Label.new()
	ab.text = String(m.get("ability", {}).get("textKey", ""))
	ab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ab.add_theme_font_size_override("font_size", 11)
	ab.add_theme_color_override("font_color", UIColors.MUTED)
	vb.add_child(ab)
	return pc


# Строка проверки: «Ужас: Воля −1 · урон 2».
func _stat_line(label_key: String, stat: Dictionary) -> Label:
	var l := Label.new()
	var skill: String = String(stat.get("skill", "none"))
	var skill_tr: String = tr("SKILL_" + skill.to_upper())
	var mod: int = int(stat.get("modificator", 0))
	var mod_s: String = ("%+d" % mod) if mod != 0 else "0"
	l.text = "%s: %s %s · %s %d" % [tr(label_key), skill_tr, mod_s, tr("SIDEBAR_DAMAGE"), int(stat.get("damage", 0))]
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", UIColors.TEXT)
	return l


# ── Соседи ───────────────────────────────────────────────────────────────────

func _populate_neighbors(conns: Array) -> void:
	for child in _neighbors.get_children():
		child.queue_free()

	if conns.is_empty():
		var none := Label.new()
		none.text = "SIDEBAR_NO_NEIGHBORS"
		none.add_theme_color_override("font_color", UIColors.MUTED)
		none.add_theme_font_size_override("font_size", 13)
		_neighbors.add_child(none)
		return

	for i: int in range(conns.size()):
		var c: Dictionary = conns[i]
		var to_id:   String = String(c.get("to", ""))
		var to_name: String = String(c.get("name", to_id))   # translation key, fallback на id
		var ctype:   String = String(c.get("type", "ship"))
		_neighbors.add_child(_make_neighbor_row(to_id, to_name, ctype))


func _make_neighbor_row(to_id: String, to_name: String, ctype: String) -> Button:
	var btn := Button.new()
	# to_name — translation key (LOC_*_NAME), Godot переводит автоматически.
	btn.text = to_name
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# List item, не «обычная» кнопка — оставляем компактный stylebox-стиль.
	UIStyle.style_icon_button(btn, CONN_COLORS.get(ctype, UIColors.BORDER))
	btn.add_theme_font_size_override("font_size", 13)
	# Подпись «морем/поездом/путь» в правом углу — храним ключ, Godot переведёт.
	var hint := Label.new()
	hint.text = String(CONN_TR_KEYS.get(ctype, ctype))
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", CONN_COLORS.get(ctype, UIColors.MUTED))
	hint.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	hint.offset_left   = -90.0
	hint.offset_right  = -10.0
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(hint)
	btn.pressed.connect(func() -> void: neighbor_selected.emit(to_id))
	return btn


# ── Внутренние ───────────────────────────────────────────────────────────────

func _on_close_pressed() -> void:
	close_panel()


func _animate(hide_panel: bool) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	# Звук слайда синхронен с tween'ом — один и тот же эффект в обе стороны.
	SfxManager.play(SfxManager.SFX_SIDEBAR_SLIDE)
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var off_left: float  = 0.0         if hide_panel else -PANEL_WIDTH
	var off_right: float = PANEL_WIDTH if hide_panel else 0.0
	_tween.tween_property(_panel, "offset_left",  off_left,  ANIM_TIME)
	_tween.tween_property(_panel, "offset_right", off_right, ANIM_TIME)


func _apply_offsets(hide_panel: bool) -> void:
	if hide_panel:
		_panel.offset_left  = 0.0
		_panel.offset_right = PANEL_WIDTH
	else:
		_panel.offset_left  = -PANEL_WIDTH
		_panel.offset_right = 0.0


func _style_close_button() -> void:
	UIStyle.style_icon_button(_close_btn, UIColors.DANGER)
	_close_btn.add_theme_font_size_override("font_size", 18)


func _type_label_for(t: String) -> String:
	# Возвращаем translation key — Godot переводит автоматически.
	match t:
		"city":       return "LOC_TYPE_CITY"
		"sea":        return "LOC_TYPE_SEA"
		"wilderness": return "LOC_TYPE_WILDERNESS"
	return t.to_upper()
