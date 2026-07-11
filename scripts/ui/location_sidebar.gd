extends CanvasLayer

## Боковая панель справа с инфой о выбранной локации (орнаментальная рамка).
## Открывается show_location(data), закрывается close_panel() / крестиком.
##
## Раскладка: рамка-арт (sidebar-bg.png) → орнаментальный заголовок с шевронами →
## окно-картинка локации (assets/locations/<id>.png, как арт ассетов) → действия
## (Переместиться / Обмен, плюс контекстные Магазин / Билеты) → описание → список
## объектов на локации (монстры/улики/слухи).
##
## Сигналы:
##   closed          — пользователь закрыл крестиком (карта снимет подсветку)
##   shop_requested  — клик «Магазин» (открыть модалку магазина)
##   trade_requested — клик «Обмен» (открыть модалку обмена)

signal closed
signal shop_requested
signal trade_requested

const PANEL_WIDTH: float = 360.0
const ANIM_TIME: float = 0.22

# Картинка локации: по конвенции имени файла assets/locations/<id>.png (как арт
# ассетов по id). Нет файла → пустое окно-заглушка.
const LOCATION_ART_DIR: String = "res://assets/locations/"
# Орнаментальная рамка окна-картинки (прозрачный центр — рисуем поверх картинки).
const _IMAGE_FRAME := preload("res://assets/location-sidebar/image-frame.png")

# Цвета типов дорог — для кнопок покупки билетов (соответствуют MapLayer.COLOR_*).
const CONN_COLORS: Dictionary = {
	"ship": Color(0.275, 0.510, 0.706),
	"train": Color(0.627, 0.322, 0.176),
}

@onready var _panel: Control = %Panel
@onready var _frame: NinePatchRect = %Frame
@onready var _vbox: VBoxContainer = %VBox

var _is_open: bool = false
var _tween: Tween = null
var _loc_id: String = ""  # id показанной сейчас локации (для GameState.travel)

# Узлы контента (строятся программно в _ready).
var _title_lbl: Label = null
var _caption: Label = null
var _image: TextureRect = null
var _description: Label = null
var _travel_btn: Button = null
var _trade_btn: Button = null
var _shop_btn: Button = null
var _buy_train_btn: Button = null
var _buy_ship_btn: Button = null
var _items_sep: HSeparator = null
var _items_hdr: Label = null
var _items_list: VBoxContainer = null


func _ready() -> void:
	_build_ui()
	GameState.state_changed.connect(_refresh_actions)
	GameState.state_changed.connect(_refresh_items)
	# Рамка-фон нарисована @2× — рендерим её в scale 0.5 (иначе орнамент вдвое
	# крупнее). Узел растянут на 2× панели, поэтому после scale покрывает её ровно.
	_panel.resized.connect(_fit_frame)
	_fit_frame()
	_apply_offsets(true)


# Держим рамку под размер панели с учётом её scale 0.5 (size = 2× панели → рендер 1×).
func _fit_frame() -> void:
	if is_instance_valid(_frame) and is_instance_valid(_panel):
		_frame.size = _panel.size * 2.0


# ── Сборка UI ─────────────────────────────────────────────────────────────────


func _build_ui() -> void:
	_build_header()
	_build_caption()
	_build_image_box()
	_build_actions()
	_build_content()


# Орнаментальный заголовок (шеврон · имя · шеврон) + крестик поверх правого угла.
func _build_header() -> void:
	var header := Control.new()
	header.name = "Header"
	header.custom_minimum_size = Vector2(0, 40)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_child(header)

	var title_row := UIStyle.ornate_title("", 22, UIColors.ACCENT)
	title_row.name = "TitleRow"
	title_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(title_row)
	_title_lbl = title_row.get_node("Title")

	var close := Button.new()
	close.name = "CloseBtn"
	close.custom_minimum_size = Vector2(30, 30)
	close.text = "×"
	close.add_theme_font_size_override("font_size", 18)
	close.anchor_left = 1.0
	close.anchor_right = 1.0
	close.offset_left = -30.0
	close.offset_top = 2.0
	close.offset_right = 0.0
	close.offset_bottom = 32.0
	UIStyle.style_icon_button(close, UIColors.DANGER)
	close.pressed.connect(_on_close_pressed)
	header.add_child(close)


# Подпись под заголовком: тип · реальный прообраз (мелко, приглушённо).
func _build_caption() -> void:
	_caption = Label.new()
	_caption.name = "Caption"
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.add_theme_font_size_override("font_size", 12)
	_caption.add_theme_color_override("font_color", UIColors.MUTED)
	_vbox.add_child(_caption)


# Окно-картинка локации: тёмная подложка + картинка (cover) + орнаментальная рамка
# поверх (image-frame.png, прозрачный центр). Пусто, если файла нет — заглушка.
func _build_image_box() -> void:
	var box := Control.new()
	box.name = "ImageBox"
	box.custom_minimum_size = Vector2(0, 200)

	var bg := ColorRect.new()
	bg.name = "Bg"
	bg.color = Color(0.06, 0.06, 0.05, 0.85)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(bg)

	_image = TextureRect.new()
	_image.name = "Image"
	_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_image.clip_contents = true
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_image)

	# Рамка окна тоже @2× → scale 0.5. Растягиваем на 2× бокса при его ресайзе.
	var frame := NinePatchRect.new()
	frame.name = "Frame"
	frame.texture = _IMAGE_FRAME
	frame.draw_center = false
	frame.patch_margin_left = 40
	frame.patch_margin_top = 40
	frame.patch_margin_right = 40
	frame.patch_margin_bottom = 40
	frame.scale = Vector2(0.5, 0.5)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(frame)
	box.resized.connect(func() -> void: frame.size = box.size * 2.0)

	_vbox.add_child(box)


# Ряд действий: Переместиться | Обмен, плюс контекстные Магазин и Билеты (стопкой).
func _build_actions() -> void:
	var row := HBoxContainer.new()
	row.name = "Actions"
	row.add_theme_constant_override("separation", 8)
	_vbox.add_child(row)

	_travel_btn = UIStyle.button("SIDEBAR_TRAVEL")
	_travel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_travel_btn.visible = false
	_travel_btn.pressed.connect(_on_travel_pressed)
	row.add_child(_travel_btn)

	_trade_btn = UIStyle.button("SIDEBAR_TRADE")
	_trade_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trade_btn.visible = false
	_trade_btn.pressed.connect(func() -> void: trade_requested.emit())
	row.add_child(_trade_btn)

	_shop_btn = UIStyle.button("SIDEBAR_BTN_SHOP", UIColors.ACCENT)
	_shop_btn.visible = false
	_shop_btn.pressed.connect(func() -> void: shop_requested.emit())
	_vbox.add_child(_shop_btn)

	_buy_train_btn = _make_buy_ticket_btn("SIDEBAR_BTN_TICKET_TRAIN", "train")
	_buy_ship_btn = _make_buy_ticket_btn("SIDEBAR_BTN_TICKET_SHIP", "ship")
	_vbox.add_child(_buy_train_btn)
	_vbox.add_child(_buy_ship_btn)


func _make_buy_ticket_btn(label_key: String, ticket_type: String) -> Button:
	var btn := UIStyle.button(label_key, CONN_COLORS[ticket_type])
	btn.name = "BuyTicket_" + ticket_type
	btn.visible = false
	btn.pressed.connect(func() -> void: GameState.buy_ticket(ticket_type))
	return btn


# Описание + список объектов на локации в прокручиваемой области (тянется вниз).
func _build_content() -> void:
	var sep := HSeparator.new()
	sep.name = "Sep"
	_vbox.add_child(sep)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_vbox.add_child(scroll)

	var content := VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	_description = Label.new()
	_description.name = "Description"
	_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_description.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_description.add_theme_font_size_override("font_size", 14)
	_description.add_theme_color_override("font_color", UIColors.TEXT)
	content.add_child(_description)

	_items_sep = HSeparator.new()
	_items_sep.name = "ItemsSeparator"
	_items_hdr = Label.new()
	_items_hdr.name = "ItemsHeader"
	_items_hdr.text = "SIDEBAR_ITEMS"
	_items_hdr.add_theme_font_size_override("font_size", 11)
	_items_hdr.add_theme_color_override("font_color", UIColors.MUTED)
	_items_list = VBoxContainer.new()
	_items_list.name = "ItemsList"
	_items_list.add_theme_constant_override("separation", 6)
	content.add_child(_items_sep)
	content.add_child(_items_hdr)
	content.add_child(_items_list)


# ── Public ────────────────────────────────────────────────────────────────────


func show_location(data: Dictionary) -> void:
	# name/realWorldLocation/description/type — translation keys (Label.tr при рендере).
	_loc_id = String(data.get("id", ""))
	_title_lbl.text = String(data.get("name", ""))
	_caption.text = _caption_text(data)
	_image.texture = _location_art(_loc_id)
	_description.text = String(data.get("description", ""))
	_populate_items(_loc_id)
	_refresh_actions()
	if not _is_open:
		_is_open = true
		_animate(false)


func close_panel() -> void:
	if not _is_open:
		return
	_is_open = false
	_loc_id = ""
	_animate(true)
	closed.emit()


func is_open() -> bool:
	return _is_open


# ── Картинка локации ──────────────────────────────────────────────────────────


# Арт локации по конвенции имени файла: assets/locations/<id>.png (как арт ассетов
# по id). Нет файла → null (окно-заглушка).
func _location_art(loc_id: String) -> Texture2D:
	if loc_id.is_empty():
		return null
	var path: String = "%s%s.png" % [LOCATION_ART_DIR, loc_id]
	return load(path) if ResourceLoader.exists(path) else null


func _caption_text(data: Dictionary) -> String:
	var t: String = tr(_type_label_for(String(data.get("type", "city"))))
	var real: String = String(data.get("realWorldLocation", ""))
	return "%s · %s" % [t, tr(real)] if not real.is_empty() else t


# ── Действия (перемещение / обмен / магазин / билеты) ─────────────────────────


func _refresh_actions() -> void:
	if not is_instance_valid(_travel_btn):
		return
	_travel_btn.visible = not _loc_id.is_empty() and GameState.can_travel_to(_loc_id)
	_trade_btn.visible = _can_trade()
	_shop_btn.visible = GameState.can_shop(_loc_id)
	var can_ticket: bool = GameState.can_buy_ticket(_loc_id)
	var avail: Array = GameState.available_ticket_types(_loc_id)
	_buy_train_btn.visible = can_ticket and avail.has("train")
	_buy_ship_btn.visible = can_ticket and avail.has("ship")


func _on_travel_pressed() -> void:
	if not _loc_id.is_empty():
		GameState.travel(_loc_id)


# Можно ли обменяться здесь: мой ход, моя локация, есть действие, обмен ещё не делал
# в раунде и есть со-локационный подключённый напарник (иначе меняться не с кем).
func _can_trade() -> bool:
	if _loc_id.is_empty() or not GameState.is_my_turn():
		return false
	var me: Dictionary = GameState.my_player()
	if int(me.get("actions_left", 0)) <= 0:
		return false
	if (me.get("actions_used", []) as Array).has(GameActions.TRADE):
		return false
	if String(me.get("location", "")) != _loc_id:
		return false
	var my_id: String = String(me.get("user_id", ""))
	for pid_v: Variant in GameState.players:
		var pid: String = String(pid_v)
		var p: Dictionary = GameState.players[pid]
		if (
			pid != my_id
			and bool(p.get("connected", true))
			and String(p.get("location", "")) == _loc_id
		):
			return true
	return false


# ── Объекты на локации (монстры/улики/слухи) ──────────────────────────────────


## При смене стейта (спаун монстров/улик) — перерисовать список, если открыт.
func _refresh_items() -> void:
	if _is_open and not _loc_id.is_empty():
		_populate_items(_loc_id)


## Список объектов локации: Монстры (со статами) → Улики → Слухи.
func _populate_items(loc_id: String) -> void:
	if not is_instance_valid(_items_list):
		return
	for child in _items_list.get_children():
		child.queue_free()

	var ents: Array = GameState.entities.get(loc_id, [])
	var mons: Array = GameState.monsters.get(loc_id, [])
	var clues: int = (ents as Array).count("clue")
	var rumors: int = (ents as Array).count("rumor")

	var empty: bool = mons.is_empty() and clues == 0 and rumors == 0
	_items_sep.visible = not empty
	_items_hdr.visible = not empty
	_items_list.visible = not empty
	if empty:
		return

	if not mons.is_empty():
		_items_list.add_child(_make_category_header("SIDEBAR_CAT_MONSTERS", mons.size()))
		for i: int in range(mons.size()):
			var inst_v: Variant = mons[i]  # {id, health} или легаси id-строка
			var mid: String = (
				String(inst_v.get("id", "")) if inst_v is Dictionary else String(inst_v)
			)
			var hp: int = (
				int((inst_v as Dictionary).get("health", -1)) if inst_v is Dictionary else -1
			)
			var m: Dictionary = MonsterCatalog.by_id(mid)
			if not m.is_empty():
				_items_list.add_child(_make_monster_card(m, hp))
	if clues > 0:
		_items_list.add_child(_make_category_header("SIDEBAR_CAT_CLUES", clues))
	if rumors > 0:
		_items_list.add_child(_make_category_header("SIDEBAR_CAT_RUMORS", rumors))


func _make_category_header(key: String, count: int) -> Label:
	var l := Label.new()
	l.name = "Label"
	l.text = "%s — %d" % [tr(key), count]
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", UIColors.WARNING)
	return l


func _make_monster_card(m: Dictionary, cur_health: int = -1) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.name = "Panel"
	UIStyle.style_panel(pc, 10)
	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 2)
	pc.add_child(vb)

	var nm := Label.new()
	nm.name = "Name"
	nm.text = String(m.get("nameKey", ""))  # MON_*_NAME — Godot переведёт
	nm.add_theme_font_size_override("font_size", 14)
	nm.add_theme_color_override("font_color", UIColors.ACCENT)
	vb.add_child(nm)

	if m.has("horror"):
		var inv: int = maxi(1, GameState.players.size())
		var tough: int = MonsterCatalog.toughness_for(m, inv)
		var st := Label.new()
		st.name = "Stat"
		# Текущее здоровье экземпляра / макс (если ранен — видно в бою).
		st.text = (
			("%s: %d / %d" % [tr("SIDEBAR_TOUGHNESS"), cur_health, tough])
			if cur_health >= 0
			else ("%s: %d" % [tr("SIDEBAR_TOUGHNESS"), tough])
		)
		st.add_theme_font_size_override("font_size", 12)
		st.add_theme_color_override("font_color", UIColors.TEXT)
		vb.add_child(st)
		vb.add_child(_stat_line("SIDEBAR_HORROR", m.get("horror", {})))
		vb.add_child(_stat_line("SIDEBAR_COMBAT", m.get("combat", {})))
		if m.has("resist"):
			var rl := Label.new()
			rl.name = "Resist"
			rl.text = "%s: %s" % [tr("SIDEBAR_RESIST"), _resist_text(m.get("resist"))]
			rl.add_theme_font_size_override("font_size", 12)
			rl.add_theme_color_override("font_color", UIColors.ACCENT)
			vb.add_child(rl)
	elif bool(m.get("useAncientOne", false)):
		var ao := Label.new()
		ao.name = "Ability"
		ao.text = "SIDEBAR_USE_ANCIENT_ONE"
		ao.add_theme_font_size_override("font_size", 12)
		ao.add_theme_color_override("font_color", UIColors.MUTED)
		vb.add_child(ao)

	var ab := Label.new()
	ab.name = "Ability"
	ab.text = String(m.get("ability", {}).get("textKey", ""))
	ab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ab.add_theme_font_size_override("font_size", 11)
	ab.add_theme_color_override("font_color", UIColors.MUTED)
	vb.add_child(ab)
	return pc


# Строка проверки: «Ужас: Воля −1 · урон 2».
func _stat_line(label_key: String, stat: Dictionary) -> Label:
	var l := Label.new()
	l.name = "Label"
	var skill: String = String(stat.get("skill", "none"))
	var skill_tr: String = tr("SKILL_" + skill.to_upper())
	var mod: int = int(stat.get("modifier", 0))
	var mod_s: String = ("%+d" % mod) if mod != 0 else "0"
	l.text = (
		"%s: %s %s · %s %d"
		% [tr(label_key), skill_tr, mod_s, tr("SIDEBAR_DAMAGE"), int(stat.get("damage", 0))]
	)
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", UIColors.TEXT)
	return l


# Текст сопротивления монстра: «физическое»/«магическое» (resist — строка/массив).
func _resist_text(r: Variant) -> String:
	var types: Array = r if r is Array else [r]
	var parts: PackedStringArray = []
	for t: Variant in types:
		parts.append(tr("RESIST_PHYSICAL" if String(t) == "physical" else "RESIST_MAGICAL"))
	return ", ".join(parts)


# ── Внутренние ───────────────────────────────────────────────────────────────


func _on_close_pressed() -> void:
	close_panel()


func _animate(hide_panel: bool) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	# Звук слайда синхронен с tween'ом — один и тот же эффект в обе стороны.
	SfxManager.play(SfxManager.SFX_SIDEBAR_SLIDE)
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var off_left: float = 0.0 if hide_panel else -PANEL_WIDTH
	var off_right: float = PANEL_WIDTH if hide_panel else 0.0
	_tween.tween_property(_panel, "offset_left", off_left, ANIM_TIME)
	_tween.tween_property(_panel, "offset_right", off_right, ANIM_TIME)


func _apply_offsets(hide_panel: bool) -> void:
	if hide_panel:
		_panel.offset_left = 0.0
		_panel.offset_right = PANEL_WIDTH
	else:
		_panel.offset_left = -PANEL_WIDTH
		_panel.offset_right = 0.0


func _type_label_for(t: String) -> String:
	# Возвращаем translation key — Godot переводит автоматически.
	match t:
		"city":
			return "LOC_TYPE_CITY"
		"sea":
			return "LOC_TYPE_SEA"
		"wilderness":
			return "LOC_TYPE_WILDERNESS"
	return t.to_upper()
