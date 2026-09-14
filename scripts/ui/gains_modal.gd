extends CanvasLayer

## Окно «вы получили»: сводка ПРИОБРЕТЕНИЙ сыщика после мифа или Расплаты — там
## выдача проходит молча, и понять, что именно пришло, было неоткуда.
## Потери и полученные состояния сюда НЕ попадают: они остаются лентой над фишкой.
##
## Второй режим — РЕЗУЛЬТАТ РОЗЫГРЫША карты (gains.card): заголовок — имя карты,
## сама карта, лоток с выпавшими кубами (тихий dieRoll иначе невидим), строки
## событий (урон, потеря улики на поле…) и «ничего не произошло», если пусто.
##
## Источник — синкаемое players[me].gains (копит ActionFeed.collect_gains). Кнопка
## стирает запись через act(DISMISS_GAINS), поэтому окно не всплывает
## повторно на следующем синке. Строится кодом, монтируется из world_map.

# Ширина окна. Без неё панель ужималась по содержимому — на паре жетонов выходило
# 248 px, заголовок переносился на две строки, и окно смотрелось узкой полоской.
const _MIN_W: float = 496.0
const _CARD_H: float = 210.0  # высота миниатюры карты в окне
const _CARD_FULL_H: float = 520.0  # карту строим в полный рост и ужимаем (как в info_bar)
const _TOKEN_H: float = 52.0  # высота жетона-иконки в ряду

# Жетоны показываем ИКОНКОЙ с «×N», как в панели игрока, а не строкой текста.
const _TOKEN_TEX := {
	"clues": preload("res://assets/map/clue-icon.png"),
	"resources": preload("res://assets/map/resource-icon.png"),
	"focus": preload("res://assets/action-panel/concentration-icon.png"),
	"hp": preload("res://assets/player-hud/health-icon.png"),
	"sanity": preload("res://assets/player-hud/sanity-icon.png"),
	"train": preload("res://assets/tickets/train-ticket.png"),
	"ship": preload("res://assets/tickets/ocean-ticket.png"),
}
# Порядок жетонов в ряду.
const _TOKEN_ORDER: Array = ["clues", "resources", "focus", "hp", "sanity", "train", "ship"]

var _root: ColorRect
var _panel: PanelContainer
var _box: VBoxContainer
var _sig: String = ""  # что уже показано — не пересобираем на каждом синке


func _ready() -> void:
	layer = 88  # поверх карты и панелей, под модалкой проверки (86 — та интерактивна)
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


func _build() -> void:
	_root = ColorRect.new()
	_root.name = "Root"
	_root.color = Color(0, 0, 0, 0.55)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP  # ловим клики мимо окна
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
	_box.add_theme_constant_override("separation", 16)
	margin.add_child(_box)


func _refresh() -> void:
	var gains: Dictionary = GameState.my_player().get("gains", {})
	if gains.is_empty():
		_sig = ""
		UIStyle.modal_set_visible(_root, _panel, false)
		return
	var sig: String = JSON.stringify(gains)
	if sig != _sig:
		_sig = sig
		_fill(gains)
	UIStyle.modal_set_visible(_root, _panel, true)


func _fill(gains: Dictionary) -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()

	var src: String = String(gains.get("card", ""))  # режим «результат розыгрыша»
	var title := UIStyle.modal_title(
		String(AssetCatalog.by_id(src).get("nameKey", src)) if not src.is_empty() else "GAINS_TITLE"
	)
	title.name = "Title"
	_box.add_child(title)
	UIStyle.separator(_box)

	if not src.is_empty():
		var src_row := HBoxContainer.new()
		src_row.name = "Source"
		src_row.alignment = BoxContainer.ALIGNMENT_CENTER
		src_row.add_child(_card_node(src))
		_box.add_child(src_row)
	var rolls: Array = gains.get("rolls", [])
	if not rolls.is_empty():
		var tray := DiceTray.new()
		tray.name = "Rolls"
		tray.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_box.add_child(tray)
		tray.play_roll(rolls, false, false)  # спин — игрок видит, что выпало

	var cards: Array = gains.get("items", [])
	if not cards.is_empty():
		var row := HBoxContainer.new()
		row.name = "Cards"
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 14)
		_box.add_child(row)
		for it_v: Variant in cards:
			row.add_child(_card_node(it_v))

	# Жетоны — одним рядом иконок с «×N» (перенос, если не влезли).
	var tokens := HFlowContainer.new()
	tokens.name = "Tokens"
	tokens.alignment = FlowContainer.ALIGNMENT_CENTER
	tokens.add_theme_constant_override("h_separation", 18)
	tokens.add_theme_constant_override("v_separation", 8)
	for f_v: Variant in _TOKEN_ORDER:
		var f: String = f_v
		var n: int = int(gains.get(f, 0))
		if n > 0:
			tokens.add_child(_token(f, n))
	if tokens.get_child_count() > 0:
		_box.add_child(tokens)

	# События (урон, состояние, улика с поля…) — строками из словаря ленты.
	var events: Array = gains.get("events", [])
	for e_v: Variant in events:
		var e: Dictionary = e_v
		var text: String = ActionLog.render(
			String(e.get("id", "")), e.get("params", {}), I18n.get_locale()
		)
		if text.is_empty():
			continue
		var line := UIStyle.label(
			text, UIStyle.MODAL_FS_BODY, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER
		)
		line.name = "Event"
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_box.add_child(line)
	# Розыгрыш без последствий — сказать явно, а не показывать пустое окно.
	if (
		not src.is_empty()
		and cards.is_empty()
		and tokens.get_child_count() == 0
		and events.is_empty()
	):
		var none := UIStyle.label(
			"GAINS_NOTHING", UIStyle.MODAL_FS_BODY, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER
		)
		none.name = "Nothing"
		_box.add_child(none)

	var btn := UIStyle.button("GAINS_OK" if src.is_empty() else "BTN_OK", UIColors.ACCENT)
	btn.name = "OkBtn"
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func() -> void: GameState.act(RelayActions.DISMISS_GAINS))
	_box.add_child(btn)


# Миниатюра полученной карты: GameCard в полный рост, ужатый через scale — те же
# пропорции шрифта и рамки, что у настоящей карты (приём из info_bar).
func _card_node(entry: Variant) -> Control:
	var payload: Dictionary = _payload(entry)
	var full_w: float = _CARD_FULL_H * GameCard.ASPECT
	var scale_f: float = _CARD_H / _CARD_FULL_H

	var slot := Control.new()
	slot.name = "CardSlot"
	slot.custom_minimum_size = Vector2(full_w * scale_f, _CARD_H)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var card := GameCard.new()
	card.name = "Card"
	card.custom_minimum_size = Vector2(full_w, _CARD_FULL_H)
	card.size = Vector2(full_w, _CARD_FULL_H)
	card.pivot_offset = Vector2.ZERO
	card.scale = Vector2(scale_f, scale_f)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.set_card(payload)
	slot.add_child(card)
	CardPreview.attach_click(slot, payload)  # миниатюру не прочитать — клик
	return slot


# Payload карты: заклинание берём из SpellCatalog, актив — из AssetCatalog.
func _payload(entry: Variant) -> Dictionary:
	var id: String = ""
	var is_spell: bool = false
	if entry is Dictionary:
		var d: Dictionary = entry
		id = String(d.get("id", ""))
		is_spell = String(d.get("kind", "")) == "spell"
	else:
		id = String(entry)
	if is_spell:
		var sp: Dictionary = SpellCatalog.by_id(id)
		if not sp.is_empty():
			return SpellCatalog.card_payload(sp)
	var a: Dictionary = AssetCatalog.by_id(id)
	if not a.is_empty():
		return AssetCatalog.card_payload(a)
	return {"cost": "", "title": id, "subtitle": "", "desc": ""}


# Жетон приобретения: иконка + «×N» (как в панели игрока), а не строка текста.
func _token(field: String, n: int) -> Control:
	var hb := HBoxContainer.new()
	hb.name = "Token_" + field
	hb.add_theme_constant_override("separation", 4)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER

	var tex: Texture2D = _TOKEN_TEX[field]
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = tex
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	icon.custom_minimum_size = tex.get_size() * (_TOKEN_H / tex.get_size().y)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(icon)

	var lbl := UIStyle.label("×%d" % n, UIStyle.MODAL_FS_TITLE, UIColors.VALUE)
	lbl.name = "Count"
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hb.add_child(lbl)
	return hb
