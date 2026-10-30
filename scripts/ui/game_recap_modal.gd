extends CanvasLayer

## Экран «Итоги партии» — открывается из финальной модалки (OutcomeModal) кнопкой
## «Итоги партии». Данные — GameState.recap.summary(): плитки (раунды, Рок, Тайны,
## время), карточка на каждого сыщика (судьба, счётчики, титул), ключевые моменты.
## В демо-сборке внизу — промо полной версии со ссылкой на сайт игры.
## Строится кодом (без .tscn); содержимое пересобирается на каждый open().

signal menu_requested

const SITE_URL := "https://dark-omens.world"
const _PORTRAIT := Vector2(84, 108)  # портреты @2× — рисуем в половину натурального

var _backdrop: ColorRect
var _panel: PanelContainer
var _body: VBoxContainer


func _ready() -> void:
	layer = 91  # над финальной модалкой
	_build()


func _build() -> void:
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.color = Color(0, 0, 0, 0.82)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.custom_minimum_size = Vector2(1180, 0)
	UIStyle.style_modal_panel(_panel)
	center.add_child(_panel)

	_body = VBoxContainer.new()
	_body.name = "Body"
	_body.add_theme_constant_override("separation", 16)
	_panel.add_child(_body)

	_backdrop.visible = false


## Показать итоги текущей партии.
func open() -> void:
	_rebuild(GameState.recap.summary(GameState))
	UIStyle.modal_set_visible(_backdrop, _panel, true)


func _rebuild(s: Dictionary) -> void:
	for c: Node in _body.get_children():
		c.queue_free()
	_body.add_child(UIStyle.modal_title("RECAP_HEADER"))
	_body.add_child(_subtitle())
	UIStyle.separator(_body)
	_body.add_child(_tiles(s))
	_body.add_child(_cards(s["players"]))
	var moments: Array = s["moments"]
	if not moments.is_empty():
		_body.add_child(_moments(moments))
	if Demo.active():
		_body.add_child(_promo())
	UIStyle.separator(_body)
	var btn: Button = UIStyle.button("OUTCOME_TO_MENU", UIColors.ACCENT)
	btn.name = "MenuBtn"
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func() -> void: menu_requested.emit())
	_body.add_child(btn)


# «Азатот · Древний пробуждается» — Древний и исход в цвет результата.
func _subtitle() -> Label:
	var ao: Dictionary = GameState.campaign.get("ancientOne", {})
	var won: bool = GameState.outcome == GameOutcome.VICTORY
	var title: String = tr(GameOutcome.title_key(GameState.outcome, GameState.outcome_reason))
	var text: String = title
	var ancient: String = String(ao.get("name", ""))
	if not ancient.is_empty():
		text = "%s · %s" % [ancient, title]
	var lbl: Label = UIStyle.label(
		text, UIFonts.LEAD, UIColors.SUCCESS if won else UIColors.ERROR, HORIZONTAL_ALIGNMENT_CENTER
	)
	lbl.name = "Subtitle"
	return lbl


func _tiles(s: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Tiles"
	row.add_theme_constant_override("separation", 12)
	var doom: String = str(s["doom"])
	if int(s["doom_clock"]) > 0:
		doom = "%d / %d" % [s["doom"], s["doom_clock"]]
	for t_v: Variant in [
		["Rounds", str(s["rounds"]), "RECAP_TILE_ROUNDS"],
		["Doom", doom, "RECAP_TILE_DOOM"],
		[
			"Mysteries",
			"%d / %d" % [s["mysteries_solved"], s["mysteries_total"]],
			"RECAP_TILE_MYSTERIES"
		],
		["Time", tr("RECAP_MINUTES_FMT") % s["minutes"], "RECAP_TILE_TIME"],
	]:
		var t: Array = t_v
		var tile: PanelContainer = UIStyle.panel(14)
		tile.name = "Tile" + String(t[0])
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var v := VBoxContainer.new()
		v.name = "VBox"
		v.add_theme_constant_override("separation", 2)
		tile.add_child(v)
		var big: Label = UIStyle.label(
			t[1], UIFonts.TITLE, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER
		)
		big.name = "Value"
		v.add_child(big)
		var cap: Label = UIStyle.label(
			String(t[2]), UIFonts.CAPTION, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER
		)
		cap.name = "Caption"
		cap.uppercase = true
		v.add_child(cap)
		row.add_child(tile)
	return row


func _cards(players: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Investigators"
	row.add_theme_constant_override("separation", 12)
	for p_v: Variant in players:
		row.add_child(_card(p_v))
	return row


func _card(p: Dictionary) -> PanelContainer:
	var card: PanelContainer = UIStyle.panel(14)
	card.name = "Card_" + String(p["pid"]).validate_node_name()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.name = "VBox"
	v.add_theme_constant_override("separation", 8)
	card.add_child(v)

	var head := HBoxContainer.new()
	head.name = "Head"
	head.add_theme_constant_override("separation", 12)
	v.add_child(head)
	var face := TextureRect.new()
	face.name = "Portrait"
	face.texture = _portrait(String(p["investigator"]))
	face.custom_minimum_size = _PORTRAIT
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	head.add_child(face)

	var who := VBoxContainer.new()
	who.name = "Who"
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_child(who)
	var inv: Label = UIStyle.label(
		tr(Investigators.display_name(String(p["investigator"]))), UIFonts.LABEL, UIColors.ACCENT
	)
	inv.name = "Investigator"
	inv.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	who.add_child(inv)
	var player: Label = UIStyle.label(String(p["name"]), UIFonts.SMALL, UIColors.MUTED)
	player.name = "Player"
	who.add_child(player)
	var fate_txt: String = tr("RECAP_SURVIVED")
	if bool(p["dead"]):
		fate_txt = tr("RECAP_FELL") % maxi(1, int(p["fell_round"]))
	var fate: Label = UIStyle.label(
		fate_txt, UIFonts.SMALL, UIColors.ERROR if bool(p["dead"]) else UIColors.SUCCESS
	)
	fate.name = "Fate"
	who.add_child(fate)

	var title: String = String(p["title"])
	if not title.is_empty():
		var badge: Label = UIStyle.label(
			title, UIFonts.CAPTION, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER
		)
		badge.name = "Title"
		badge.uppercase = true
		v.add_child(badge)

	var grid := GridContainer.new()
	grid.name = "Stats"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 2)
	v.add_child(grid)
	var stats: Dictionary = p["stats"]
	for c: String in GameRecap.COUNTERS:
		var k: Label = UIStyle.label("RECAP_STAT_" + c.to_upper(), UIFonts.SMALL, UIColors.MUTED)
		k.name = "Key_" + c
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(k)
		var n: Label = UIStyle.label(
			str(int(stats.get(c, 0))), UIFonts.SMALL, UIColors.VALUE, HORIZONTAL_ALIGNMENT_RIGHT
		)
		n.name = "Val_" + c
		grid.add_child(n)
	return card


func _moments(moments: Array) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "Moments"
	box.add_theme_constant_override("separation", 4)
	var head: Label = UIStyle.label("RECAP_MOMENTS", UIFonts.LABEL, UIColors.ACCENT)
	head.name = "Header"
	box.add_child(head)
	var mysteries: Array = GameState.campaign.get("mysteries", [])
	for m_v: Variant in moments:
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
		var lbl: Label = UIStyle.label(text, UIFonts.BODY, UIColors.TEXT)
		lbl.name = "Moment"
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(lbl)
	return box


# Демо: полная версия в работе — ссылка на сайт игры.
func _promo() -> PanelContainer:
	var promo: PanelContainer = UIStyle.panel(18)
	promo.name = "Promo"
	var sb: StyleBoxFlat = promo.get_theme_stylebox("panel").duplicate()
	sb.border_color = UIColors.ACCENT
	promo.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 20)
	promo.add_child(row)
	var text := VBoxContainer.new()
	text.name = "Text"
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)
	var head: Label = UIStyle.label("RECAP_DEMO_TITLE", UIFonts.LABEL, UIColors.ACCENT)
	head.name = "PromoTitle"
	text.add_child(head)
	var body: Label = UIStyle.label("RECAP_DEMO_BODY", UIFonts.BODY, UIColors.TEXT)
	body.name = "PromoBody"
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(body)
	var site: Button = UIStyle.button("RECAP_DEMO_SITE", UIColors.ACCENT)
	site.name = "SiteBtn"
	site.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	site.pressed.connect(func() -> void: OS.shell_open(SITE_URL))
	row.add_child(site)
	return promo


static func _portrait(inv_name: String) -> Texture2D:
	var path := "res://assets/investigators/%s.png" % inv_name
	if not inv_name.is_empty() and ResourceLoader.exists(path):
		return load(path)
	return null
