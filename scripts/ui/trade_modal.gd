extends CanvasLayer

## Модалка обмена. Обмен — действие ЛОКАЦИИ; open() зовёт кнопка «Обмен» сайдбара.
## Игрок выбирает со-локационного напарника, отмечает свои предметы/улики «отдать» и
## предметы/улики напарника «взять» → предложение (TRADE_OFFER). Партнёр принимает или
## отклоняет в TradeOfferModal; при согласии хост меняет и тратит действие инициатора
## (PhaseController.host_apply_trade_response). Модалка — сиблинг "TradeModal".
## Одноразовая, как ShopModal/GalleryModal: закрытие освобождает ноду (WorldMap
## не плодит дубликаты по имени "TradeModal" — висящая скрытая нода блокировала бы
## все следующие нажатия «Обмен»).

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

var _partner: String = ""
var _give: Dictionary = {}  # item_index (мой) → bool
var _take: Dictionary = {}  # item_index (напарника) → bool
var _give_clues: int = 0
var _take_clues: int = 0


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	_root.visible = false


# Со-локационные подключённые напарники (user_id), кроме себя.
func _allies() -> Array:
	var me: Dictionary = GameState.my_player()
	var my_loc: String = String(me.get("location", ""))
	var my_id: String = String(me.get("user_id", ""))
	var out: Array = []
	for pid_v: Variant in GameState.players:
		var pid: String = String(pid_v)
		var p: Dictionary = GameState.players[pid]
		var ok: bool = (
			pid != my_id
			and bool(p.get("connected", true))
			and not bool(p.get("dead", false))  # с Тенью не поменяешься
			and String(p.get("location", "")) == my_loc
		)
		if ok:
			out.append(pid)
	return out


## Открыть модалку обмена (зовёт панель действий). Нет напарников — no-op.
func open() -> void:
	var allies: Array = _allies()
	if allies.is_empty():
		_close()  # меняться не с кем — не оставляем невидимую ноду-блокер
		return
	_partner = String(allies[0])
	_reset_selection()
	UIStyle.modal_set_visible(_root, _panel, true)
	_build(allies)


func _reset_selection() -> void:
	_give = {}
	_take = {}
	_give_clues = 0
	_take_clues = 0


func _build(allies: Array) -> void:
	for c in _vbox.get_children():
		c.queue_free()

	_vbox.add_child(UIStyle.modal_title("TRADE_TITLE"))

	# Выбор напарника (если их несколько).
	if allies.size() > 1:
		for a_v: Variant in allies:
			var apid: String = String(a_v)
			var pb := Button.new()
			pb.name = "Partner_" + apid
			pb.text = ("▸ " if apid == _partner else "") + GameState.players[apid].get("name", apid)
			UIStyle.style_button(pb, UIColors.ACCENT if apid == _partner else UIColors.MUTED)
			pb.pressed.connect(
				func() -> void:
					_partner = apid
					_reset_selection()
					_build(allies)
			)
			_vbox.add_child(pb)
	else:
		var who := Label.new()
		who.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_BODY)
		who.name = "Partner"
		who.text = (
			"%s: %s" % [tr("TRADE_PARTNER"), GameState.players[_partner].get("name", _partner)]
		)
		_vbox.add_child(who)

	var me: Dictionary = GameState.my_player()
	var ally: Dictionary = GameState.players.get(_partner, {})
	_section("TRADE_GIVE", me.get("items", []), _give, me, true)
	_section("TRADE_TAKE", ally.get("items", []), _take, ally, false)

	var row := HBoxContainer.new()
	row.name = "Buttons"
	var ok := Button.new()
	ok.name = "ConfirmBtn"
	ok.text = "TRADE_OFFER_SEND"
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_button(ok, UIColors.ACCENT)
	ok.pressed.connect(_on_confirm)
	var cancel := Button.new()
	cancel.name = "CancelBtn"
	cancel.text = "BTN_CANCEL"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_button(cancel)
	cancel.pressed.connect(_close)
	row.add_child(ok)
	row.add_child(cancel)
	_vbox.add_child(row)


# Секция «отдать»/«взять»: чекбоксы предметов (sel[idx]) + счётчик улик. is_mine
# выбирает, какой счётчик улик правит (_give_clues/_take_clues), и его потолок.
func _section(
	title_key: String, items: Array, sel: Dictionary, owner_data: Dictionary, is_mine: bool
) -> void:
	var hdr := Label.new()
	hdr.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_LEAD)
	hdr.name = "Header"
	hdr.text = tr(title_key)
	hdr.add_theme_color_override("font_color", UIColors.ACCENT)
	_vbox.add_child(hdr)

	for i in range(items.size()):
		var idx: int = i
		var cb := CheckBox.new()
		cb.name = "Item%d" % idx
		cb.text = _item_label(items[i])
		cb.toggled.connect(func(on: bool) -> void: sel[idx] = on)
		_vbox.add_child(cb)

	var clues: int = int(owner_data.get("clues", 0))
	var sb := SpinBox.new()
	sb.name = "Clues"
	sb.min_value = 0
	sb.max_value = clues
	sb.value = 0
	sb.prefix = tr("TRADE_CLUES") + " "
	sb.value_changed.connect(
		func(v: float) -> void:
			if is_mine:
				_give_clues = int(v)
			else:
				_take_clues = int(v)
	)
	_vbox.add_child(sb)


# Отображаемое имя предмета: актив → nameKey, заклинание → name, иначе id/строка.
func _item_label(it: Variant) -> String:
	var id: String = String((it as Dictionary).get("id", "")) if it is Dictionary else String(it)
	var a: Dictionary = AssetCatalog.by_id(id)
	if not a.is_empty():
		return tr(String(a.get("nameKey", id)))
	var s: Dictionary = SpellCatalog.by_id(id)
	if not s.is_empty():
		return tr(String(s.get("name", id)))
	return id


func _on_confirm() -> void:
	var give: Array = []
	for k_v: Variant in _give:
		if bool(_give[k_v]):
			give.append(int(k_v))
	var take: Array = []
	for k_v: Variant in _take:
		if bool(_take[k_v]):
			take.append(int(k_v))
	_close()
	(
		GameState
		. act(
			RelayActions.TRADE_OFFER,
			{
				"partner": _partner,
				"give": give,
				"take": take,
				"giveClues": _give_clues,
				"takeClues": _take_clues,
			}
		)
	)


# Закрыть и освободить ноду после анимации. Имя меняем сразу: пока окно гаснет,
# повторное «Обмен» должно открыть новое, а не упереться в уходящее.
func _close() -> void:
	name = "TradeModalClosing"
	if not _root.visible:
		queue_free()
		return
	UIStyle.modal_transition(_root, _panel, false).chain().tween_callback(queue_free)
