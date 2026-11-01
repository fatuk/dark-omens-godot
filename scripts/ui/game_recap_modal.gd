extends CanvasLayer

## Экран «Итоги партии» — открывается из финальной модалки (OutcomeModal) кнопкой
## «Итоги партии». Данные — GameState.recap.summary().
##
## Фон (assets/game-stats/bg.png) нарисован целиком: плитки с иконками, три
## пергамента под сыщиков и две нижние панели уже на нём. Поэтому раскладка — не
## контейнерами, а прямоугольниками в координатах сцены 1920×1080 (STAGE), которые
## совпадают с нарисованными зонами; сцена центрируется на экране.
##   • плитки: Рок · раунды · Тайны · время;
##   • пергаменты: карточка сыщика (тёмная плашка с портретом, титул, счётчики);
##     пустой пергамент — «Свободное место»; больше трёх сыщиков — свой ряд карточек
##     поверх всех трёх пергаментов (фон рассчитан на трёх);
##   • слева внизу — ключевые моменты; справа — промо полной версии (демо) или
##     концовка Древнего.
## Строится кодом (без .tscn); содержимое пересобирается на каждый open().

signal menu_requested

const SITE_URL := "https://dark-omens.world"
const STAGE := Vector2(1920, 1080)

const _BG: Texture2D = preload("res://assets/game-stats/bg.png")
const _BORDER: Texture2D = preload("res://assets/game-stats/investigator-border.png")
const _DIVIDER: Texture2D = preload("res://assets/virtues-panel/divider.png")

# Зоны фона в координатах STAGE (замерены по bg.png, рисуемому в 1920×1080).
const _TILES := [
	Rect2(257, 208, 336, 116),
	Rect2(612, 208, 338, 116),
	Rect2(970, 208, 338, 116),
	Rect2(1327, 208, 337, 116),
]
const _TILE_ICON_W := 140.0  # левая часть плитки занята нарисованной иконкой
const _CARDS := [
	Rect2(266, 344, 450, 374),
	Rect2(739, 344, 449, 374),
	Rect2(1206, 344, 450, 374),
]
const _MOMENTS := Rect2(233, 735, 778, 201)
const _MOMENTS_TEXT_W := 520.0  # правее — нарисованная сцена с культистами
const _PROMO := Rect2(1028, 735, 660, 201)
const _PROMO_TEXT_W := 420.0  # правее — нарисованный замок под луной
const _BUTTON := Rect2(730, 958, 460, 52)
const _MAX_MOMENTS := 4

const _PLATE := Color(0.06, 0.05, 0.04, 0.88)  # тёмная плашка шапки карточки
const _INK := Color(0.07, 0.05, 0.03)  # строки статистики — чёрные чернила на пергаменте
const _PORTRAIT := Vector2(117, 113)  # рамка портрета @2× — в половину натурального

var _backdrop: ColorRect
var _stage: Control


func _ready() -> void:
	layer = 91  # над финальной модалкой
	_build()


func _build() -> void:
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.color = Color(0, 0, 0, 1)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)

	_stage = Control.new()
	_stage.name = "Stage"
	_stage.set_anchors_preset(Control.PRESET_CENTER)
	_stage.offset_left = -STAGE.x / 2
	_stage.offset_top = -STAGE.y / 2
	_stage.offset_right = STAGE.x / 2
	_stage.offset_bottom = STAGE.y / 2
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.add_child(_stage)

	_backdrop.visible = false


## Показать итоги текущей партии.
func open() -> void:
	_rebuild(GameState.recap.summary(GameState))
	UIStyle.modal_set_visible(_backdrop, _stage, true)


func _rebuild(s: Dictionary) -> void:
	for c: Node in _stage.get_children():
		c.queue_free()
	var bg := TextureRect.new()
	bg.name = "Background"
	bg.texture = _BG
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.size = STAGE
	_stage.add_child(bg)

	_header()
	_tiles(s)
	_cards(s["players"])
	_moments(s["moments"])
	if Demo.active():
		_promo()
	else:
		_ending()
	var btn: Button = UIStyle.button("OUTCOME_TO_MENU", UIColors.ACCENT)
	btn.name = "MenuBtn"
	_place(btn, _BUTTON)
	btn.pressed.connect(func() -> void: menu_requested.emit())


# Заголовок и «Древний · исход» в цвет результата — в тёмном проёме вверху фона.
func _header() -> void:
	var title: Label = UIStyle.label(
		"RECAP_HEADER", UIFonts.art(64, 0.3), UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER
	)
	title.name = "Title"
	_place(title, Rect2(560, 62, 800, 90))
	var ao: Dictionary = GameState.campaign.get("ancientOne", {})
	var won: bool = GameState.outcome == GameOutcome.VICTORY
	var text: String = tr(GameOutcome.title_key(GameState.outcome, GameState.outcome_reason))
	var ancient: String = String(ao.get("name", ""))
	if not ancient.is_empty():
		text = "%s · %s" % [ancient, text]
	var sub: Label = UIStyle.label(
		text, UIFonts.LEAD, UIColors.SUCCESS if won else UIColors.ERROR, HORIZONTAL_ALIGNMENT_CENTER
	)
	sub.name = "Subtitle"
	_place(sub, Rect2(460, 150, 1000, 40))


func _tiles(s: Dictionary) -> void:
	var doom: String = str(s["doom"])
	if int(s["doom_clock"]) > 0:
		doom = "%d / %d" % [s["doom"], s["doom_clock"]]
	var items := [
		["Doom", doom, "RECAP_TILE_DOOM"],
		["Rounds", str(s["rounds"]), "RECAP_TILE_ROUNDS"],
		[
			"Mysteries",
			"%d / %d" % [s["mysteries_solved"], s["mysteries_total"]],
			"RECAP_TILE_MYSTERIES"
		],
		["Time", tr("RECAP_MINUTES_FMT") % s["minutes"], "RECAP_TILE_TIME"],
	]
	for i: int in items.size():
		var t: Array = items[i]
		var r: Rect2 = _TILES[i]
		var box := VBoxContainer.new()
		box.name = "Tile" + String(t[0])
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		box.add_theme_constant_override("separation", 0)
		var w: float = r.size.x - _TILE_ICON_W - 12.0
		_place(box, Rect2(r.position.x + _TILE_ICON_W, r.position.y, w, r.size.y))
		var big: Label = UIStyle.label(
			String(t[1]), UIFonts.art(36), UIColors.TEXT_BRIGHT, HORIZONTAL_ALIGNMENT_CENTER
		)
		big.name = "Value"
		UIFonts.apply(big, UIFonts.art(36), w)
		box.add_child(big)
		var cap: Label = UIStyle.label(
			String(t[2]), UIFonts.art(16), UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER
		)
		cap.name = "Caption"
		cap.uppercase = true
		UIFonts.apply(cap, UIFonts.art(16), w)
		box.add_child(cap)


func _cards(players: Array) -> void:
	if players.size() <= _CARDS.size():
		for i: int in _CARDS.size():
			var r: Rect2 = _CARDS[i]
			if i < players.size():
				_card(players[i], r, "Card%d" % (i + 1))
			else:
				_empty_seat(r, "Card%d" % (i + 1))
		return
	# Больше трёх сыщиков: один пергаментный лист поверх всех нарисованных и свой
	# ряд узких карточек.
	var area := Rect2(_CARDS[0].position, _CARDS[-1].end - _CARDS[0].position)
	var sheet := Panel.new()
	sheet.name = "WideSheet"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.62, 0.48, 0.30)
	sb.border_color = Color(0.25, 0.17, 0.08)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(3)
	sheet.add_theme_stylebox_override("panel", sb)
	_place(sheet, area)
	var gap := 12.0
	var n: int = players.size()
	var w: float = (area.size.x - gap * (n + 1)) / n
	for i: int in n:
		var r := Rect2(area.position.x + gap + i * (w + gap), area.position.y, w, area.size.y)
		_card(players[i], r, "Card%d" % (i + 1))


func _card(p: Dictionary, r: Rect2, node_name: String) -> void:
	var root := MarginContainer.new()
	root.name = node_name
	root.add_theme_constant_override("margin_left", 18)
	root.add_theme_constant_override("margin_right", 30)  # справа рваный край пергамента
	root.add_theme_constant_override("margin_top", 16)
	root.add_theme_constant_override("margin_bottom", 14)
	_place(root, r)
	var v := VBoxContainer.new()
	v.name = "VBox"
	v.add_theme_constant_override("separation", 6)
	root.add_child(v)
	v.add_child(_card_plate(p))

	var grid := GridContainer.new()
	grid.name = "Stats"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 5)
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(grid)
	var stats: Dictionary = p["stats"]
	for c: String in GameRecap.COUNTERS:
		var k: Label = UIStyle.label("RECAP_STAT_" + c.to_upper(), UIFonts.art(22), _INK)
		k.name = "Key_" + c
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		k.clip_text = true
		grid.add_child(k)
		var n: Label = UIStyle.label(
			str(int(stats.get(c, 0))), UIFonts.art(22), _INK, HORIZONTAL_ALIGNMENT_RIGHT
		)
		n.name = "Val_" + c
		grid.add_child(n)


# Тёмная плашка шапки: портрет в рамке, сыщик, игрок, судьба; снизу титул.
func _card_plate(p: Dictionary) -> PanelContainer:
	var plate := PanelContainer.new()
	plate.name = "Plate"
	var sb := StyleBoxFlat.new()
	sb.bg_color = _PLATE
	sb.set_corner_radius_all(2)
	sb.set_content_margin_all(8)
	plate.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.name = "VBox"
	v.add_theme_constant_override("separation", 4)
	plate.add_child(v)

	var head := HBoxContainer.new()
	head.name = "Row"
	head.add_theme_constant_override("separation", 14)
	v.add_child(head)
	head.add_child(_portrait_frame(String(p["investigator"])))
	var who := VBoxContainer.new()
	who.name = "Who"
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.alignment = BoxContainer.ALIGNMENT_CENTER
	who.add_theme_constant_override("separation", 0)
	head.add_child(who)
	var inv: Label = UIStyle.label(
		tr(Investigators.display_name(String(p["investigator"]))), UIFonts.art(22), UIColors.ACCENT
	)
	inv.name = "Investigator"
	inv.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	who.add_child(inv)
	var player: Label = UIStyle.label(String(p["name"]), UIFonts.art(18), UIColors.TEXT)
	player.name = "Player"
	player.clip_text = true
	who.add_child(player)
	var dead: bool = bool(p["dead"])
	var fate_txt: String = tr("RECAP_SURVIVED")
	if dead:
		fate_txt = tr("RECAP_FELL") % maxi(1, int(p["fell_round"]))
	var fate: Label = UIStyle.label(
		fate_txt, UIFonts.art(18), UIColors.ERROR if dead else UIColors.SUCCESS
	)
	fate.name = "Fate"
	who.add_child(fate)

	# Строка титула есть всегда (без титула — одни разделители): шапки карточек
	# одной высоты, строки статистики на одном уровне.
	var row := HBoxContainer.new()
	row.name = "TitleRow"
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	row.add_child(_divider("DividerL"))
	var badge: Label = UIStyle.label(String(p["title"]), UIFonts.art(15), UIColors.ACCENT)
	badge.name = "Title"
	badge.uppercase = true
	row.add_child(badge)
	row.add_child(_divider("DividerR"))
	return plate


func _portrait_frame(inv_name: String) -> Control:
	var frame := Control.new()
	frame.name = "Portrait"
	frame.custom_minimum_size = _PORTRAIT
	var face := TextureRect.new()
	face.name = "Face"
	face.texture = _portrait(inv_name)
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	face.position = Vector2(5, 5)
	face.size = _PORTRAIT - Vector2(10, 10)
	face.clip_contents = true
	frame.add_child(face)
	var border := TextureRect.new()
	border.name = "Border"
	border.texture = _BORDER
	border.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	border.stretch_mode = TextureRect.STRETCH_SCALE
	border.size = _PORTRAIT
	frame.add_child(border)
	return frame


func _divider(node_name: String) -> TextureRect:
	var d := TextureRect.new()
	d.name = node_name
	d.texture = _DIVIDER
	d.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	d.stretch_mode = TextureRect.STRETCH_SCALE
	d.custom_minimum_size = Vector2(0, 3)
	d.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return d


func _empty_seat(r: Rect2, node_name: String) -> void:
	var lbl: Label = UIStyle.label(
		"RECAP_EMPTY_SEAT", UIFonts.LABEL, Color(UIColors.INK, 0.55), HORIZONTAL_ALIGNMENT_CENTER
	)
	lbl.name = node_name
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_place(lbl, r)


func _moments(moments: Array) -> void:
	var box := VBoxContainer.new()
	box.name = "Moments"
	box.add_theme_constant_override("separation", 6)
	_place(box, Rect2(_MOMENTS.position + Vector2(28, 18), Vector2(_MOMENTS_TEXT_W, 170)))
	var head: Label = UIStyle.label("RECAP_MOMENTS", UIFonts.art(26), UIColors.TEXT_BRIGHT)
	head.name = "Header"
	box.add_child(head)
	var mysteries: Array = GameState.campaign.get("mysteries", [])
	for m_v: Variant in moments.slice(0, _MAX_MOMENTS):
		var m: Dictionary = m_v
		var text: String
		if m["kind"] == "mystery":
			var idx: int = int(m["index"])
			var mt: String = ""
			if idx >= 0 and idx < mysteries.size():
				mt = String((mysteries[idx] as Dictionary).get("title", ""))
			text = tr("RECAP_MOMENT_MYSTERY") % [int(m["round"]), mt]
		else:
			var p: Dictionary = GameState.players.get(m["pid"], {})
			var inv: String = tr(Investigators.display_name(String(p.get("investigator", ""))))
			text = tr("RECAP_MOMENT_FALLEN") % [int(m["round"]), inv]
		var lbl: Label = UIStyle.label(text, UIFonts.art(20), UIColors.TEXT)
		lbl.name = "Moment"
		lbl.clip_text = true
		lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		box.add_child(lbl)
	if moments.is_empty():
		var none: Label = UIStyle.label("—", UIFonts.BODY, UIColors.MUTED)
		none.name = "None"
		box.add_child(none)


# Демо: полная версия в работе — ссылка на сайт игры.
func _promo() -> void:
	var box := VBoxContainer.new()
	box.name = "Promo"
	box.add_theme_constant_override("separation", 4)
	_place(box, Rect2(_PROMO.position + Vector2(26, 14), Vector2(_PROMO_TEXT_W, 176)))
	var head: Label = UIStyle.label("RECAP_DEMO_TITLE", UIFonts.art(20), UIColors.ACCENT)
	head.name = "PromoTitle"
	box.add_child(head)
	var body: Label = UIStyle.label("RECAP_DEMO_BODY", UIFonts.art(18), UIColors.TEXT)
	body.name = "PromoBody"
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(body)
	var site := LinkButton.new()
	site.name = "SiteLink"
	site.text = "RECAP_DEMO_SITE"
	site.underline = LinkButton.UNDERLINE_MODE_ALWAYS
	site.add_theme_color_override("font_color", UIColors.ACCENT)
	site.add_theme_color_override("font_hover_color", UIColors.TEXT_BRIGHT)
	UIFonts.apply(site, UIFonts.art(18))
	site.pressed.connect(func() -> void: OS.shell_open(SITE_URL))
	box.add_child(site)


# Вне демо: на месте промо — концовка Древнего (тот же текст, что в финальной модалке).
func _ending() -> void:
	var box := VBoxContainer.new()
	box.name = "Ending"
	box.add_theme_constant_override("separation", 4)
	_place(box, Rect2(_PROMO.position + Vector2(26, 14), Vector2(_PROMO_TEXT_W, 176)))
	var head: Label = UIStyle.label("RECAP_ENDING", UIFonts.art(20), UIColors.ACCENT)
	head.name = "EndingTitle"
	box.add_child(head)
	var ao: Dictionary = GameState.campaign.get("ancientOne", {})
	var body: Label = UIStyle.label(
		tr(GameOutcome.body_text(ao, GameState.outcome, GameState.outcome_reason)),
		UIFonts.art(18),
		UIColors.TEXT
	)
	body.name = "EndingBody"
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.clip_text = true
	body.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(body)


# Положить контрол в прямоугольник сцены (координаты STAGE).
func _place(c: Control, r: Rect2) -> void:
	c.position = r.position
	c.size = r.size
	_stage.add_child(c)


static func _portrait(inv_name: String) -> Texture2D:
	var path := "res://assets/investigators/%s.png" % inv_name
	if not inv_name.is_empty() and ResourceLoader.exists(path):
		return load(path)
	return null
