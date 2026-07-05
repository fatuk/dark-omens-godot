extends CanvasLayer

## Панель действий — видна только когда сейчас МОЙ ход в фазе action.
## Четыре иконки-медальона: Отдых, Концентрация, Ресурс, Пас (виджет ActionButton).
## Обмен вынесен в сайдбар локации; действия-состояния играются картой из веера —
## здесь их больше нет. Бейджи под концентрацией/ресурсом — текущее кол-во у игрока.
##
## Всё строится в 2× (ассеты @2×) и ужимается обёрткой scale 0.5 → кант чёткий.

const _A := "res://assets/action-panel/"
const _MARGIN_R: float = 48.0  # отступ блока от правого края
const _MARGIN_B: float = 40.0  # отступ от низа
const _HINT_FONT: int = 26  # 2× → 13 на экране
const _TICKETS_GAP: float = 20.0  # зазор кнопки ↔ столбец билетов

@onready var _root: Control = $Root

var _scale: Control
var _col: VBoxContainer
var _hint: Label
var _rest_ab: ActionButton
var _conc_ab: ActionButton
var _res_ab: ActionButton
var _pass_ab: ActionButton
var _tickets: TicketsRow  # вертикальная стопка билетов справа от кнопок
var _last_tickets: int = -1  # без лишних ребилдов стопки


func _ready() -> void:
	_build()
	GameState.state_changed.connect(_refresh)
	get_viewport().size_changed.connect(_reposition)
	_refresh()


func _build() -> void:
	# Обёртка scale 0.5: содержимое строим в НАТУРАЛЬНОМ 2×, показываем в половину.
	_scale = Control.new()
	_scale.name = "Scale"
	_scale.scale = Vector2(0.5, 0.5)
	_scale.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_scale)

	_col = VBoxContainer.new()
	_col.name = "Col"
	_col.alignment = BoxContainer.ALIGNMENT_CENTER
	_col.add_theme_constant_override("separation", 6)
	_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scale.add_child(_col)

	_hint = Label.new()
	_hint.name = "Hint"
	_hint.add_theme_font_size_override("font_size", _HINT_FONT)
	_hint.add_theme_color_override("font_color", UIColors.MUTED)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_col.add_child(_hint)

	var row := HBoxContainer.new()
	row.name = "Buttons"
	row.add_theme_constant_override("separation", 30)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_child(row)

	_rest_ab = ActionButton.new(_tex("rest-icon"), _tex("rest-title"), "ACTION_REST_TITLE")
	_conc_ab = ActionButton.new(
		_tex("concentration-icon"), _tex("concentration-title"), "ACTION_FOCUS_TITLE", null, true
	)
	_res_ab = ActionButton.new(
		_tex("resource-icon"), _tex("resource-title"), "ACTION_RESOURCE_TITLE", null, true
	)
	_pass_ab = ActionButton.new(
		_tex("pass-icon"), _tex("pass-title"), "ACTION_PASS_TITLE", _tex("hourglass")
	)
	for ab: ActionButton in [_rest_ab, _conc_ab, _res_ab, _pass_ab]:
		row.add_child(ab)

	_rest_ab.pressed.connect(func() -> void: GameState.perform_action(GameActions.REST))
	_conc_ab.pressed.connect(
		func() -> void: GameState.perform_action(GameActions.TAKE_CONCENTRATION)
	)
	_res_ab.pressed.connect(_on_resource)
	_pass_ab.pressed.connect(_on_pass)

	# Вертикальная стопка билетов — справа от кнопок, вне scale-обёртки (у неё свой
	# внутренний масштаб, второе ужатие сделало бы билеты крошечными).
	_tickets = TicketsRow.new()
	_tickets.name = "Tickets"
	_tickets.vertical = true
	_tickets.visible = false
	_tickets.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tickets.resized.connect(_reposition)
	_root.add_child(_tickets)

	# Позиция блока (bottom-right) — пересчёт при смене размера содержимого/окна.
	_col.resized.connect(_reposition)
	_reposition()


func _tex(name: String) -> Texture2D:
	return load(_A + name + ".png") as Texture2D


# Раскладка bottom-right: билеты у правого края, блок кнопок слева от них.
func _reposition() -> void:
	if not is_instance_valid(_scale) or not is_instance_valid(_col):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var right: float = vp.x - _MARGIN_R
	var tickets_w: float = 0.0
	if is_instance_valid(_tickets) and _tickets.visible and _tickets.get_child_count() > 0:
		var ts: Vector2 = _tickets.size
		_tickets.position = Vector2(right - ts.x, vp.y - _MARGIN_B - ts.y)
		tickets_w = ts.x + _TICKETS_GAP
	var w: float = _col.size.x * _scale.scale.x
	var h: float = _col.size.y * _scale.scale.y
	_scale.position = Vector2(right - tickets_w - w, vp.y - _MARGIN_B - h)


func _on_pass() -> void:
	_pass_ab.spin_overlay()  # часы прокручиваются на 360°
	GameState.perform_action(GameActions.PASS)


# TODO: действие «получить ресурс» пока не реализовано в движке — заглушка.
func _on_resource() -> void:
	pass


func _refresh() -> void:
	var visible_now: bool = GameState.is_my_turn()
	_root.visible = visible_now
	if not visible_now:
		return
	var me: Dictionary = GameState.my_player()
	var used: Array = me.get("actions_used", [])
	# Концентрация: занята, если брал в раунде ИЛИ достигнут потолок.
	_conc_ab.set_disabled(
		(
			used.has(GameActions.TAKE_CONCENTRATION)
			or int(me.get("concentration", 0)) >= GameState.MAX_CONCENTRATION
		)
	)
	_conc_ab.set_badge(int(me.get("concentration", 0)))
	_rest_ab.set_disabled(used.has(GameActions.REST))
	_res_ab.set_badge(int(me.get("resources", 0)))
	# Билеты: ж/д + морские. Ребилд стопки лишь при смене суммарного числа.
	var n_train: int = int(me.get("train_tickets", 0))
	var n_ship: int = int(me.get("ship_tickets", 0))
	if n_train + n_ship != _last_tickets:
		_last_tickets = n_train + n_ship
		_tickets.set_counts(n_train, n_ship)
	_tickets.visible = n_train + n_ship > 0
	# Подсказка «Раунд N · осталось действий: M» — форматируется, через LocaleBinder.
	LocaleBinder.bind(
		_hint,
		func() -> String:
			var m: Dictionary = GameState.my_player()
			return tr("ACTION_ROUND_FMT") % [GameState.round_num, int(m.get("actions_left", 0))]
	)
	_reposition()
