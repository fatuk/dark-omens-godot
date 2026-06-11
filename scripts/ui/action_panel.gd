extends CanvasLayer

## Панель действий — видна только когда сейчас МОЙ ход в фазе action.
## 4 кнопки: купить билет, взять концентрацию, отдохнуть, пас.

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _ticket_btn: Button = %TicketBtn
@onready var _concent_btn: Button = %ConcentBtn
@onready var _rest_btn: Button = %RestBtn
@onready var _pass_btn: Button = %PassBtn
@onready var _hint_label: Label = %HintLabel

var _cond_btns: Dictionary = {}  # cond_id → Button локального действия состояния


func _ready() -> void:
	UIStyle.style_panel(_panel, 16)
	UIStyle.style_button(_ticket_btn)
	UIStyle.style_button(_concent_btn)
	UIStyle.style_button(_rest_btn)
	UIStyle.style_button(_pass_btn, UIColors.WARNING)
	_hint_label.add_theme_color_override("font_color", UIColors.MUTED)

	_ticket_btn.pressed.connect(func() -> void: GameState.perform_action("buy_ticket"))
	_concent_btn.pressed.connect(func() -> void: GameState.perform_action("take_concentration"))
	_rest_btn.pressed.connect(func() -> void: GameState.perform_action("rest"))
	_pass_btn.pressed.connect(func() -> void: GameState.perform_action("pass"))

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
	_ticket_btn.disabled = used.has("buy_ticket")
	_concent_btn.disabled = used.has("take_concentration")
	_rest_btn.disabled = used.has("rest")
	_refresh_condition_actions(me, used)
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
