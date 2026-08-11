class_name SupplyModal
extends RefCounted

## Окно «Запасы»: что осталось в колодах и что лежит в сбросах. Вкладки —
## Активы / Врата / Улики / Монстры.
##
## Строится на общей ModalDialog (рамка, крестик, ESC, общий эффект появления),
## поэтому здесь только содержимое вкладок. Показывает синкаемое состояние, так
## что у всех за столом одна и та же картина.
##
## Сброс активов не хранится, а выводится (GameState.asset_discard_ids) — карты
## уходят от игроков множеством путей, и хранимый список однажды бы разъехался.

const _MODAL := preload("res://scenes/ui/modal_dialog.tscn")
const _CARD_H: float = 300.0  # высота миниатюры карты актива (тап — крупный просмотр)
const _CARD_FULL_H: float = 520.0  # строим в полный рост и ужимаем (как в info_bar)
const _LIST_H: float = 420.0  # высота прокручиваемой области списка

# Вкладки: ключ → подпись.
const _TABS: Array = [
	["assets", "SUPPLY_TAB_ASSETS"],
	["gates", "SUPPLY_TAB_GATES"],
	["clues", "SUPPLY_TAB_CLUES"],
	["monsters", "SUPPLY_TAB_MONSTERS"],
]

# Цвет точки-метки врат по цвету омена.
const _GATE_DOT := {
	"red": Color(0.72, 0.18, 0.16),
	"blue": Color(0.20, 0.45, 0.75),
	"green": Color(0.25, 0.62, 0.35),
}


## Открыть окно. parent — узел, к которому цеплять модалку.
static func open(parent: Node) -> void:
	var modal: ModalDialog = _MODAL.instantiate()
	modal.panel_min_width = 720
	parent.add_child(modal)
	modal.set_title(TranslationServer.translate("SUPPLY_TITLE"))

	var box := VBoxContainer.new()
	box.name = "Supply"
	box.add_theme_constant_override("separation", 12)

	var tabs := HBoxContainer.new()
	tabs.name = "Tabs"
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	tabs.add_theme_constant_override("separation", 8)
	box.add_child(tabs)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 10)
	body.custom_minimum_size = Vector2(660, _LIST_H)
	box.add_child(body)

	var buttons: Array = []
	for t_v: Variant in _TABS:
		var t: Array = t_v
		var key: String = t[0]
		var btn := UIStyle.button(String(t[1]))
		btn.name = "Tab_" + key
		btn.pressed.connect(func() -> void: _select(key, body, buttons, parent))
		tabs.add_child(btn)
		buttons.append({"key": key, "btn": btn})

	_select("assets", body, buttons, parent)
	modal.set_content(box)
	modal.open()


# Переключить вкладку: подсветить кнопку и перерисовать тело. host — узел под
# крупный просмотр карты (слой просмотра живёт над модалкой, а не внутри неё).
static func _select(key: String, body: VBoxContainer, buttons: Array, host: Node) -> void:
	for b_v: Variant in buttons:
		var b: Dictionary = b_v
		var on: bool = String(b["key"]) == key
		(b["btn"] as Button).modulate = Color.WHITE if on else UIColors.DISABLED
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	match key:
		"assets":
			_fill_assets(body, host)
		"gates":
			_fill_gates(body)
		"clues":
			_fill_clues(body)
		"monsters":
			_fill_monsters(body)


# ── Вкладки ───────────────────────────────────────────────────────────────────


static func _fill_assets(body: VBoxContainer, host: Node) -> void:
	var discard: Array = GameState.asset_discard_ids()
	body.add_child(_counts(GameState.asset_deck.size(), discard.size()))
	var flow := HFlowContainer.new()
	flow.name = "Cards"
	flow.add_theme_constant_override("h_separation", 10)
	flow.add_theme_constant_override("v_separation", 10)
	for aid_v: Variant in discard:
		flow.add_child(_asset_card(String(aid_v), host))
	body.add_child(_scroll(flow, discard.is_empty()))


static func _fill_gates(body: VBoxContainer) -> void:
	body.add_child(_counts(GameState.gate_deck.size(), GameState.gate_discard.size()))
	var list := VBoxContainer.new()
	list.name = "Gates"
	list.add_theme_constant_override("separation", 4)
	for loc_v: Variant in GameState.gate_discard:
		list.add_child(_gate_row(String(loc_v)))
	body.add_child(_scroll(list, (GameState.gate_discard as Array).is_empty()))


static func _fill_clues(body: VBoxContainer) -> void:
	body.add_child(_counts(GameState.clue_deck.size(), GameState.clue_discard.size()))
	var list := VBoxContainer.new()
	list.name = "Clues"
	list.add_theme_constant_override("separation", 4)
	for loc_v: Variant in GameState.clue_discard:
		var loc: String = loc_v
		list.add_child(_row(_loc_name(loc), loc))
	body.add_child(_scroll(list, (GameState.clue_discard as Array).is_empty()))


# У монстров сброса нет: побеждённый сразу возвращается в мешок. Показываем мешок.
static func _fill_monsters(body: VBoxContainer) -> void:
	var bag: Array = GameState.monster_bag
	var lbl := UIStyle.label("SUPPLY_MONSTERS_HINT", 15, UIColors.MUTED)
	lbl.name = "Hint"
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size.x = 640
	body.add_child(lbl)
	body.add_child(_counts(bag.size(), -1))

	var counts: Dictionary = {}
	for m_v: Variant in bag:
		var mid: String = String(m_v)
		counts[mid] = int(counts.get(mid, 0)) + 1
	var list := VBoxContainer.new()
	list.name = "Monsters"
	list.add_theme_constant_override("separation", 4)
	for mid_v: Variant in counts:
		var mid: String = mid_v
		var m: Dictionary = MonsterCatalog.by_id(mid)
		var name_key: String = String(m.get("nameKey", mid))
		var n: int = int(counts[mid])
		list.add_child(_row(name_key if n <= 1 else "%s  ×%d" % [name_key, n], mid))
	body.add_child(_scroll(list, bag.is_empty()))


# ── Кусочки ───────────────────────────────────────────────────────────────────


# Строка счётчиков «в колоде N · в сбросе M». discard < 0 — сброса у сущности нет.
static func _counts(deck: int, discard: int) -> Control:
	var hb := HBoxContainer.new()
	hb.name = "Counts"
	hb.add_theme_constant_override("separation", 18)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	var d := UIStyle.label(TranslationServer.translate("SUPPLY_IN_DECK") % deck, 17, UIColors.VALUE)
	d.name = "DeckCount"
	hb.add_child(d)
	if discard >= 0:
		var s := UIStyle.label(
			TranslationServer.translate("SUPPLY_IN_DISCARD") % discard, 17, UIColors.MUTED
		)
		s.name = "DiscardCount"
		hb.add_child(s)
	return hb


# Прокручиваемая область под содержимое сброса. empty — показать «пусто» вместо него.
static func _scroll(content: Control, empty: bool) -> Control:
	if empty:
		var lbl := UIStyle.label("SUPPLY_EMPTY", 15, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		lbl.name = "Empty"
		lbl.custom_minimum_size = Vector2(640, _LIST_H)
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		return lbl
	var sc := ScrollContainer.new()
	sc.name = "Scroll"
	sc.custom_minimum_size = Vector2(660, _LIST_H)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(content)
	return sc


# Имя узла делаем УНИКАЛЬНЫМ: одинаковые имена Godot переименовывает в @Label@N,
# и в дереве сцены строки становится не отличить друг от друга.
static func _row(text: String, node_name: String) -> Label:
	var lbl := UIStyle.label(text, 16)
	lbl.name = "Row_" + node_name
	return lbl


# Строка врат: точка цвета омена + имя локации.
static func _gate_row(loc_id: String) -> Control:
	var hb := HBoxContainer.new()
	hb.name = "GateRow_" + loc_id
	hb.add_theme_constant_override("separation", 8)
	var dot := ColorRect.new()
	dot.name = "Dot"
	dot.color = _GATE_DOT.get(_gate_color(loc_id), UIColors.MUTED)
	dot.custom_minimum_size = Vector2(14, 14)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(dot)
	hb.add_child(_row(_loc_name(loc_id), loc_id))
	return hb


static func _gate_color(loc_id: String) -> String:
	for l_v: Variant in GameState.call("_load_locations"):
		var l: Dictionary = l_v
		if String(l.get("id", "")) == loc_id:
			return String(l.get("gateColor", ""))
	return ""


# Ключ перевода имени локации; нет в данных (номерной спейс без записи) — сам id.
static func _loc_name(loc_id: String) -> String:
	for l_v: Variant in GameState.call("_load_locations"):
		var l: Dictionary = l_v
		if String(l.get("id", "")) == loc_id:
			return String(l.get("name", loc_id))
	return loc_id


# Миниатюра карты актива — GameCard в полный рост, ужатый через scale. Тап по ней
# открывает крупный просмотр: в миниатюре текст способности всё равно не прочитать.
static func _asset_card(asset_id: String, host: Node) -> Control:
	var full_w: float = _CARD_FULL_H * GameCard.ASPECT
	var scale_f: float = _CARD_H / _CARD_FULL_H
	var slot := Control.new()
	slot.name = "CardSlot_" + asset_id
	slot.custom_minimum_size = Vector2(full_w * scale_f, _CARD_H)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var card := GameCard.new()
	card.name = "Card"
	card.custom_minimum_size = Vector2(full_w, _CARD_FULL_H)
	card.size = Vector2(full_w, _CARD_FULL_H)
	card.pivot_offset = Vector2.ZERO
	card.scale = Vector2(scale_f, scale_f)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var a: Dictionary = AssetCatalog.by_id(asset_id)
	var payload: Dictionary = (
		AssetCatalog.card_payload(a)
		if not a.is_empty()
		else {"cost": "", "title": asset_id, "subtitle": "", "desc": ""}
	)
	card.set_card(payload)
	slot.add_child(card)
	slot.gui_input.connect(
		func(event: InputEvent) -> void:
			if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
				CardPreview.show_card(host, payload)
	)
	return slot
