extends CanvasLayer

## Окно «вы получили»: сводка ПРИОБРЕТЕНИЙ сыщика после мифа или Расплаты — там
## выдача проходит молча, и понять, что именно пришло, было неоткуда.
## Потери и полученные состояния сюда НЕ попадают: они остаются лентой над фишкой.
##
## Источник — синкаемое players[me].gains (копит ActionFeed.collect_gains). Кнопка
## стирает запись через GameState.dismiss_gains(), поэтому окно не всплывает
## повторно на следующем синке. Строится кодом, монтируется из world_map.

const _CARD_H: float = 210.0  # высота миниатюры карты в окне
const _CARD_FULL_H: float = 520.0  # карту строим в полный рост и ужимаем (как в info_bar)
const _ROW_ICON: float = 34.0

# Приобретения-числа: поле в gains → ключ подписи. Порядок = порядок строк в окне.
const _NUM_ROWS: Array = [
	["clues", "GAINS_CLUES"],
	["resources", "GAINS_RESOURCES"],
	["focus", "GAINS_FOCUS"],
	["hp", "GAINS_HP"],
	["sanity", "GAINS_SANITY"],
	["train", "GAINS_TRAIN"],
	["ship", "GAINS_SHIP"],
]

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

	var title := UIStyle.modal_title("GAINS_TITLE")
	title.name = "Title"
	_box.add_child(title)
	UIStyle.separator(_box)

	var cards: Array = gains.get("items", [])
	if not cards.is_empty():
		var row := HBoxContainer.new()
		row.name = "Cards"
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 14)
		_box.add_child(row)
		for it_v: Variant in cards:
			row.add_child(_card_node(it_v))

	for r_v: Variant in _NUM_ROWS:
		var r: Array = r_v
		var n: int = int(gains.get(r[0], 0))
		if n > 0:
			_box.add_child(_num_row(String(r[1]), n))

	var btn := UIStyle.button("GAINS_OK", UIColors.ACCENT)
	btn.name = "OkBtn"
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(GameState.dismiss_gains)
	_box.add_child(btn)
	UIStyle.scale_modal_text(_box)


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


# Строка числового приобретения: «Улики  ×2».
func _num_row(label_key: String, n: int) -> Control:
	var row := HBoxContainer.new()
	row.name = "Row_" + label_key
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var lbl := UIStyle.label(label_key, 16)
	lbl.name = "Label"
	row.add_child(lbl)
	var val := UIStyle.label("×%d" % n, 18, UIColors.VALUE)
	val.name = "Value"
	val.custom_minimum_size.x = _ROW_ICON
	row.add_child(val)
	return row
