extends CanvasLayer

## Панель действий — видна только когда сейчас МОЙ ход в фазе action.
## 4 кнопки: купить билет, взять концентрацию, отдохнуть, пас.

@onready var _root:    Control       = $Root
@onready var _panel:   PanelContainer = %Panel
@onready var _ticket_btn:   Button = %TicketBtn
@onready var _concent_btn:  Button = %ConcentBtn
@onready var _rest_btn:     Button = %RestBtn
@onready var _pass_btn:     Button = %PassBtn
@onready var _hint_label:   Label  = %HintLabel


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
	# Одно действие нельзя повторять в раунде — гасим уже использованные кнопки.
	var used: Array = GameState.my_player().get("actions_used", [])
	_ticket_btn.disabled  = used.has("buy_ticket")
	_concent_btn.disabled = used.has("take_concentration")
	_rest_btn.disabled    = used.has("rest")
	# Биндим через LocaleBinder — строка форматированная (%d), при смене локали
	# нужно перевычислить tr() с актуальным шаблоном.
	LocaleBinder.bind(_hint_label, func() -> String:
		var me: Dictionary = GameState.my_player()
		return tr("ACTION_ROUND_FMT") % [
			GameState.round_num,
			int(me.get("actions_left", 0)),
		])
