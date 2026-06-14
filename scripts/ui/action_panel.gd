extends CanvasLayer

## Панель действий — видна только когда сейчас МОЙ ход в фазе action.
## Кнопки: концентрация, отдых, пас (+ обмен/состояния). Покупка билетов
## вынесена в сайдбар локации (продаётся только в городах, по типам дорог).

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _concent_btn: Button = %ConcentBtn
@onready var _rest_btn: Button = %RestBtn
@onready var _pass_btn: Button = %PassBtn
@onready var _hint_label: Label = %HintLabel

var _cond_btns: Dictionary = {}  # cond_id → Button локального действия состояния
var _trade_btn: Button = null  # кнопка «Обмен» (видна при со-локационном напарнике)
var _tickets: TicketsRow = null  # ряд билетов под кнопками (общий компонент)
var _last_tickets: int = -1  # последнее показанное число билетов (без лишних ребилдов)


func _ready() -> void:
	# Без рамки/фона — кнопки и билеты лежат прямо на полосе панели сыщика.
	_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	UIStyle.style_button(_concent_btn)
	UIStyle.style_button(_rest_btn)
	UIStyle.style_button(_pass_btn, UIColors.WARNING)
	_hint_label.add_theme_color_override("font_color", UIColors.MUTED)

	_concent_btn.pressed.connect(func() -> void: GameState.perform_action("take_concentration"))
	_rest_btn.pressed.connect(func() -> void: GameState.perform_action("rest"))
	_pass_btn.pressed.connect(func() -> void: GameState.perform_action("pass"))

	# «Обмен» — программная кнопка (как cond-кнопки). Открывает модалку обмена
	# через группу trade_modal. Видимость/блок — в _refresh.
	_trade_btn = Button.new()
	_trade_btn.name = "TradeBtn"
	_trade_btn.text = "ACTION_TRADE"
	UIStyle.style_button(_trade_btn, UIColors.ACCENT)
	_trade_btn.pressed.connect(_open_trade)
	_rest_btn.get_parent().add_child(_trade_btn)
	_rest_btn.get_parent().move_child(_trade_btn, _pass_btn.get_index())

	# Ряд билетов под кнопками (тот же компонент, что в InfoBar лобби).
	_tickets = TicketsRow.new()
	_tickets.name = "Tickets"
	_tickets.visible = false
	_rest_btn.get_parent().get_parent().add_child(_tickets)  # в VBox под ButtonsRow

	GameState.state_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var visible_now: bool = GameState.is_my_turn()
	_root.visible = visible_now
	if not visible_now:
		return
	var me: Dictionary = GameState.my_player()
	# Одно действие нельзя повторять в раунде — гасим уже использованные кнопки.
	var used: Array = me.get("actions_used", [])
	_concent_btn.disabled = used.has("take_concentration")
	_rest_btn.disabled = used.has("rest")
	_trade_btn.visible = _has_colocated_ally()
	_trade_btn.disabled = used.has("trade")
	_refresh_condition_actions(me, used)
	# Билеты под кнопками: ж/д + морские. Ребилд лишь при смене суммарного числа.
	var n_train: int = int(me.get("train_tickets", 0))
	var n_ship: int = int(me.get("ship_tickets", 0))
	if n_train + n_ship != _last_tickets:
		_last_tickets = n_train + n_ship
		_tickets.set_counts(n_train, n_ship)
	_tickets.visible = n_train + n_ship > 0
	# Биндим через LocaleBinder — строка форматированная (%d), при смене локали
	# нужно перевычислить tr() с актуальным шаблоном.
	LocaleBinder.bind(
		_hint_label,
		func() -> String:
			var m: Dictionary = GameState.my_player()
			return (
				tr("ACTION_ROUND_FMT")
				% [
					GameState.round_num,
					int(m.get("actions_left", 0)),
				]
			)
	)


# Динамические кнопки локальных действий состояний (escape, напр. Detained:
# «Влияние → сброс»). Доступны даже при cannotAct; гасятся после использования.
func _refresh_condition_actions(me: Dictionary, used: Array) -> void:
	var conds: Array = me.get("conditions", [])
	var actionable: Dictionary = {}
	for i: int in range(conds.size()):
		var cid: String = String(conds[i])
		if not (Conditions.get_def(cid).get("action", []) as Array).is_empty():
			actionable[cid] = true
	for rid_v: Variant in _cond_btns.keys():
		var rid: String = String(rid_v)
		if not actionable.has(rid):
			(_cond_btns[rid] as Node).queue_free()
			_cond_btns.erase(rid)
	for aid_v: Variant in actionable:
		var aid: String = String(aid_v)
		var btn: Button = _cond_btns.get(aid)
		if btn == null or not is_instance_valid(btn):
			btn = Button.new()
			btn.name = "CondAct_" + aid
			UIStyle.style_button(btn, UIColors.ACCENT)
			var bound_id: String = aid
			btn.pressed.connect(
				func() -> void:
					GameState.perform_action("condition_action", {"condition": bound_id})
			)
			_rest_btn.get_parent().add_child(btn)
			_cond_btns[aid] = btn
		btn.text = "▸ " + tr(Conditions.name_key(aid))
		btn.disabled = used.has("condition_action")


# Есть ли подключённый напарник на моей локации (для кнопки «Обмен»).
func _has_colocated_ally() -> bool:
	var me: Dictionary = GameState.my_player()
	var my_loc: String = String(me.get("location", ""))
	var my_id: String = String(me.get("user_id", ""))
	for pid_v: Variant in GameState.players:
		var p: Dictionary = GameState.players[pid_v]
		var ok: bool = (
			String(pid_v) != my_id
			and bool(p.get("connected", true))
			and String(p.get("location", "")) == my_loc
		)
		if ok:
			return true
	return false


func _open_trade() -> void:
	# Модалка обмена — сиблинг по имени "TradeModal" в world_map (есть в дереве с
	# загрузки сцены, не зависит от тайминга _ready/групп).
	var tm: Node = get_parent().get_node_or_null("TradeModal")
	if tm != null and tm.has_method("open"):
		tm.open()
