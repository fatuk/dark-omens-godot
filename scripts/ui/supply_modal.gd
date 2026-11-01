class_name SupplyModal
extends RefCounted

## Окно «Запасы»: где сейчас лежат карты и жетоны. Вкладки — Активы / Заклинания /
## Врата / Улики / Монстры; в каждой — разделы «В колоде» · «В игре» · «Сброс»
## (у монстров — «В мешке» · «На поле»: сброса у них нет).
##
## Строится на общей ModalDialog (рамка, крестик, ESC, общий эффект появления),
## поэтому здесь только содержимое вкладок. Показывает синкаемое состояние, так
## что у всех за столом одна и та же картина.
##
## Сбросы активов и заклинаний не хранятся, а выводятся (GameState.asset_discard_ids /
## spell_discard_copies) — карты уходят от игроков множеством путей, и хранимый
## список однажды бы разъехался. «В игре» — тоже вывод: витрина, руки, поле.

const _MODAL := preload("res://scenes/ui/modal_dialog.tscn")
const _CARD_FULL_H: float = 520.0  # строим в полный рост и ужимаем (как в info_bar)
const _LIST_H: float = 420.0  # высота прокручиваемой области списка
const _LIST_W: float = 860.0  # ширина прокручиваемой области
const _CARD_GAP: float = 10.0  # зазор между миниатюрами
const _CARDS_PER_ROW: int = 4
# Полоса прокрутки съедает ширину у содержимого. Не заложив её, карты ровно
# по четверти перестают влезать в ряд, и последняя уезжает на следующую строку.
const _SCROLLBAR_W: float = 16.0


## Ширина миниатюры при заданной ширине ряда: ровно доля ряда за вычетом зазоров.
static func card_width(row_w: float) -> float:
	var usable: float = row_w - _CARD_GAP * float(_CARDS_PER_ROW - 1)
	return maxf(1.0, usable / float(_CARDS_PER_ROW))


## Стартовая ширина — до раскладки настоящая неизвестна, берём номинальную минус
## полосу прокрутки. Дальше _fit_cards пересчитает по факту.
static func _initial_card_width() -> float:
	return card_width(_LIST_W - _SCROLLBAR_W)


# Подогнать миниатюры под ФАКТИЧЕСКУЮ ширину ряда. Зовётся на resized контейнера:
# номинальная и реальная ширины расходятся (панель шире минимума), и по номиналу
# справа оставалась пустота. Порог в полпикселя гасит возможную петлю раскладки.
static func _fit_cards(flow: HFlowContainer) -> void:
	var w: float = card_width(flow.size.x)
	for slot_v: Variant in flow.get_children():
		var slot: Control = slot_v
		if absf(slot.custom_minimum_size.x - w) < 0.5:
			continue
		var card: GameCard = slot.get_node_or_null("Card") as GameCard
		if card == null:
			continue
		var scale_f: float = w / card.size.x
		card.scale = Vector2(scale_f, scale_f)
		slot.custom_minimum_size = Vector2(w, card.size.y * scale_f)


# Вкладки: ключ → подпись.
const _TABS: Array = [
	["assets", "SUPPLY_TAB_ASSETS"],
	["spells", "SUPPLY_TAB_SPELLS"],
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
	modal.panel_min_width = 940
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

	var sections := HBoxContainer.new()
	sections.name = "Sections"
	sections.alignment = BoxContainer.ALIGNMENT_CENTER
	sections.add_theme_constant_override("separation", 8)
	box.add_child(sections)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 10)
	body.custom_minimum_size = Vector2(_LIST_W, _LIST_H)
	box.add_child(body)

	var buttons: Array = []
	for t_v: Variant in _TABS:
		var t: Array = t_v
		var key: String = t[0]
		var btn := UIStyle.button(String(t[1]))
		btn.name = "Tab_" + key
		btn.pressed.connect(func() -> void: _select(key, sections, body, buttons))
		tabs.add_child(btn)
		buttons.append({"key": key, "btn": btn})

	_select("assets", sections, body, buttons)
	modal.set_content(box)
	modal.open()


# Переключить вкладку: подсветить кнопку, собрать разделы и открыть первый.
static func _select(
	key: String, sections: HBoxContainer, body: VBoxContainer, buttons: Array
) -> void:
	_highlight(buttons, key)
	for c in sections.get_children():
		sections.remove_child(c)
		c.queue_free()
	var secs: Array = _sections(key)
	var sec_buttons: Array = []
	for s_v: Variant in secs:
		var s: Dictionary = s_v
		var btn := UIStyle.button(TranslationServer.translate(String(s["title"])) % int(s["count"]))
		btn.name = "Section_" + String(s["key"])
		UIFonts.apply(btn, UIFonts.LABEL)
		btn.pressed.connect(func() -> void: _show_section(s, body, sec_buttons))
		sections.add_child(btn)
		sec_buttons.append({"key": String(s["key"]), "btn": btn})
	_show_section(secs[0], body, sec_buttons)


static func _show_section(s: Dictionary, body: VBoxContainer, sec_buttons: Array) -> void:
	_highlight(sec_buttons, String(s["key"]))
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	var hint: String = String(s.get("hint", ""))
	if not hint.is_empty():
		var lbl := UIStyle.label(hint, UIFonts.BODY, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		lbl.name = "Hint"
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.custom_minimum_size.x = _LIST_W
		body.add_child(lbl)
	var build: Callable = s["build"]
	body.add_child(_scroll(build.call(), int(s["count"]) == 0))


static func _highlight(buttons: Array, key: String) -> void:
	for b_v: Variant in buttons:
		var b: Dictionary = b_v
		var on: bool = String(b["key"]) == key
		(b["btn"] as Button).modulate = Color.WHITE if on else UIColors.DISABLED


# ── Разделы вкладок: {key, title, count, build: Callable → Control, hint?} ────


static func _sections(tab: String) -> Array:
	match tab:
		"assets":
			return _asset_sections()
		"spells":
			return _spell_sections()
		"gates":
			return _gate_sections()
		"clues":
			return _clue_sections()
		_:
			return _monster_sections()


static func _section(key: String, title: String, items: Array, build: Callable) -> Dictionary:
	return {"key": key, "title": title, "count": items.size(), "build": build.bind(items)}


static func _asset_sections() -> Array:
	var deck: Array = GameState.asset_deck.duplicate()
	var play: Array = GameState.shop_reserve.duplicate()  # витрина + руки сыщиков
	for p_v: Variant in GameState.players.values():
		for it_v: Variant in (p_v as Dictionary).get("items", []):
			if it_v is Dictionary and String((it_v as Dictionary).get("kind", "")) == "spell":
				continue
			var aid: String = AssetCatalog.entry_id(it_v)
			if not AssetCatalog.by_id(aid).is_empty():
				play.append(aid)
	var discard: Array = GameState.asset_discard_ids()
	return [
		_section("deck", "SUPPLY_SEC_DECK", deck, _asset_cards),
		_section("play", "SUPPLY_SEC_PLAY", play, _asset_cards),
		_section("discard", "SUPPLY_SEC_DISCARD", discard, _asset_cards),
	]


# Копия заклинания — {id, back}; в списках показываем лицо карты, копии одного
# заклинания — одной миниатюрой «×N» (обороты разные, лицо одно).
static func _spell_sections() -> Array:
	var deck: Array = []
	for c_v: Variant in GameState.spell_deck:
		deck.append(String((c_v as Dictionary).get("id", "")))
	var play: Array = []
	for p_v: Variant in GameState.players.values():
		for it_v: Variant in (p_v as Dictionary).get("items", []):
			if it_v is Dictionary and String((it_v as Dictionary).get("kind", "")) == "spell":
				play.append(String((it_v as Dictionary).get("id", "")))
	var discard: Array = []
	for c_v: Variant in GameState.spell_discard_copies():
		discard.append(String((c_v as Dictionary).get("id", "")))
	return [
		_section("deck", "SUPPLY_SEC_DECK", deck, _spell_cards),
		_section("play", "SUPPLY_SEC_PLAY", play, _spell_cards),
		_section("discard", "SUPPLY_SEC_DISCARD", discard, _spell_cards),
	]


static func _gate_sections() -> Array:
	return [
		_section("deck", "SUPPLY_SEC_DECK", GameState.gate_deck.duplicate(), _gate_rows),
		_section("play", "SUPPLY_SEC_PLAY", GameState.gates.keys(), _gate_rows),
		_section("discard", "SUPPLY_SEC_DISCARD", GameState.gate_discard.duplicate(), _gate_rows),
	]


# Улика в игре — жетон на поле или карта на руках у сыщика (ключ — локация улики).
static func _clue_sections() -> Array:
	var play: Array = []
	for loc_v: Variant in GameState.clue_board_ids:
		play.append_array(GameState.clue_board_ids[loc_v] as Array)
	for p_v: Variant in GameState.players.values():
		play.append_array((p_v as Dictionary).get(PlayerKeys.CLUE_IDS, []) as Array)
	return [
		_section("deck", "SUPPLY_SEC_DECK", GameState.clue_deck.duplicate(), _clue_rows),
		_section("play", "SUPPLY_SEC_PLAY", play, _clue_rows),
		_section("discard", "SUPPLY_SEC_DISCARD", GameState.clue_discard.duplicate(), _clue_rows),
	]


# У монстров сброса нет: побеждённый сразу возвращается в мешок.
static func _monster_sections() -> Array:
	var board: Array = []
	for loc_v: Variant in GameState.monsters:
		for m_v: Variant in GameState.monsters[loc_v] as Array:
			board.append(
				String((m_v as Dictionary).get("id", "")) if m_v is Dictionary else str(m_v)
			)
	var bag: Dictionary = _section(
		"bag", "SUPPLY_SEC_BAG", (GameState.monster_bag as Array).duplicate(), _monster_tiles
	)
	bag["hint"] = "SUPPLY_MONSTERS_HINT"
	return [bag, _section("board", "SUPPLY_SEC_BOARD", board, _monster_tiles)]


# ── Содержимое разделов ──────────────────────────────────────────────────────


static func _asset_cards(ids: Array) -> Control:
	var flow := _card_flow()
	var counts: Dictionary = _count(ids)
	for aid_v: Variant in counts:
		var aid: String = aid_v
		var a: Dictionary = AssetCatalog.by_id(aid)
		var payload: Dictionary = (
			AssetCatalog.card_payload(a)
			if not a.is_empty()
			else {"cost": "", "title": aid, "subtitle": "", "desc": ""}
		)
		flow.add_child(_card_slot(payload, "CardSlot_" + aid, int(counts[aid])))
	return flow


static func _spell_cards(ids: Array) -> Control:
	var flow := _card_flow()
	var counts: Dictionary = _count(ids)
	for sid_v: Variant in counts:
		var sid: String = sid_v
		var s: Dictionary = SpellCatalog.by_id(sid)
		var payload: Dictionary = (
			SpellCatalog.card_payload(s) if not s.is_empty() else {"title": sid, "desc": ""}
		)
		flow.add_child(_card_slot(payload, "CardSlot_" + sid, int(counts[sid])))
	return flow


static func _gate_rows(locs: Array) -> Control:
	var list := VBoxContainer.new()
	list.name = "Gates"
	list.add_theme_constant_override("separation", 4)
	for loc_v: Variant in _sorted_by_name(locs):
		list.add_child(_gate_row(String(loc_v)))
	return list


static func _clue_rows(locs: Array) -> Control:
	var list := VBoxContainer.new()
	list.name = "Clues"
	list.add_theme_constant_override("separation", 4)
	for loc_v: Variant in _sorted_by_name(locs):
		var loc: String = loc_v
		list.add_child(_row(_loc_name(loc), loc))
	return list


# Портреты со статами — как в сайдбаре локации; одинаковые — одним портретом «×N».
static func _monster_tiles(ids: Array) -> Control:
	var counts: Dictionary = _count(ids)
	var grid: HFlowContainer = MonsterTile.grid("Monsters")
	for mid_v: Variant in counts:
		var mid: String = mid_v
		var m: Dictionary = GameState.monster_def(mid)
		if m.is_empty():
			continue
		var tile: Control = MonsterTile.make(m, -1, int(counts[mid]))
		tile.name = "Monster_" + mid
		grid.add_child(tile)
	return grid


# ── Кусочки ───────────────────────────────────────────────────────────────────


# id → сколько раз встречается (порядок — первого появления).
static func _count(ids: Array) -> Dictionary:
	var out: Dictionary = {}
	for v: Variant in ids:
		out[String(v)] = int(out.get(String(v), 0)) + 1
	return out


# Локации по имени на текущем языке — длинный список колоды так легче просмотреть.
static func _sorted_by_name(locs: Array) -> Array:
	var out: Array = locs.duplicate()
	out.sort_custom(
		func(a: Variant, b: Variant) -> bool:
			return (
				TranslationServer.translate(_loc_name(String(a)))
				< TranslationServer.translate(_loc_name(String(b)))
			)
	)
	return out


static func _card_flow() -> HFlowContainer:
	var flow := HFlowContainer.new()
	flow.name = "Cards"
	flow.add_theme_constant_override("h_separation", int(_CARD_GAP))
	flow.add_theme_constant_override("v_separation", int(_CARD_GAP))
	flow.resized.connect(func() -> void: _fit_cards(flow))
	return flow


# Прокручиваемая область под содержимое раздела. empty — показать «пусто» вместо него.
static func _scroll(content: Control, empty: bool) -> Control:
	if empty:
		content.queue_free()
		var lbl := UIStyle.label(
			"SUPPLY_EMPTY", UIFonts.BODY, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER
		)
		lbl.name = "Empty"
		lbl.custom_minimum_size = Vector2(_LIST_W, _LIST_H)
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		return lbl
	var sc := ScrollContainer.new()
	sc.name = "Scroll"
	sc.follow_focus = true  # геймпад: прокрутка за плиткой в фокусе
	sc.custom_minimum_size = Vector2(_LIST_W, _LIST_H)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(content)
	return sc


# Имя узла делаем УНИКАЛЬНЫМ: одинаковые имена Godot переименовывает в @Label@N,
# и в дереве сцены строки становится не отличить друг от друга.
static func _row(text: String, node_name: String) -> Label:
	var lbl := UIStyle.label(text, UIFonts.BODY)
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
	return GameState.map.gate_color(loc_id)


# Ключ перевода имени локации; нет в данных (номерной спейс без записи) — сам id.
static func _loc_name(loc_id: String) -> String:
	return GameState.map.name_key(loc_id)


# Миниатюра карты — GameCard в полный рост, ужатый через scale; count > 1 — метка «×N»
# (копии одной карты). Тап открывает крупный просмотр: в миниатюре текст не прочитать.
static func _card_slot(payload: Dictionary, node_name: String, count: int = 1) -> Control:
	var full_w: float = _CARD_FULL_H * GameCard.ASPECT
	# Ведём размер от ШИРИНЫ (доля списка), высота идёт следом по пропорции карты.
	var scale_f: float = _initial_card_width() / full_w
	var slot := Control.new()
	slot.name = node_name
	slot.custom_minimum_size = Vector2(_initial_card_width(), _CARD_FULL_H * scale_f)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var card := GameCard.new()
	card.name = "Card"
	card.custom_minimum_size = Vector2(full_w, _CARD_FULL_H)
	card.size = Vector2(full_w, _CARD_FULL_H)
	card.pivot_offset = Vector2.ZERO
	card.scale = Vector2(scale_f, scale_f)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.set_font_scale(full_w / HandCarousel.CARD_W)  # пропорция текста как в веере
	card.set_card(payload)
	slot.add_child(card)
	if count > 1:
		var badge := UIStyle.label("×%d" % count, UIFonts.LEAD, UIColors.TEXT_BRIGHT)
		badge.name = "Count"
		badge.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		badge.add_theme_constant_override("outline_size", 6)
		badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		badge.position += Vector2(-8, 4)
		badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		slot.add_child(badge)
	CardPreview.attach_click(slot, payload)  # крупный просмотр по клику, как везде
	return slot
