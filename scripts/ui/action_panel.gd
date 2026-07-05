extends CanvasLayer

## Панель действий на карте. ВСЕГДА видна; кнопки активны только в мой ход фазы
## action (иначе неактивны). Четыре иконки-медальона: Отдых, Концентрация, Ресурс,
## Пас (виджет ActionButton). Обмен — в сайдбаре локации; действия-состояний играются
## картой из веера. Бейджи над концентрацией/ресурсом — текущее кол-во у игрока.
## Справа — область билетов (резерв фикс. ширины, чтобы кнопки не съезжали); когда
## билетов нет — «Нет билетов».
##
## Всё строится в 2× (ассеты @2×) и ужимается обёрткой scale 0.5 → кант чёткий.

const _A := "res://assets/action-panel/"
const _MARGIN_R: float = 48.0  # отступ блока от правого края
const _MARGIN_B: float = 40.0  # отступ от низа
const _TICKETS_GAP: float = 20.0  # зазор кнопки ↔ область билетов
const _TICKETS_RESERVE: float = 150.0  # фикс. ширина области билетов (широкие ~141px — резерв, кнопки не съезжают)

@onready var _root: Control = $Root

var _scale: Control
var _col: VBoxContainer
var _rest_ab: ActionButton
var _conc_ab: ActionButton
var _res_ab: ActionButton
var _pass_ab: ActionButton
var _tickets: TicketsRow  # вертикальная стопка билетов
var _no_tickets: Label  # заглушка «Нет билетов» в зарезервированной области
var _last_tickets: int = -1  # без лишних ребилдов стопки
var _passing: bool = false  # идёт анимация паса — не пускаем повторный клик


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

	# Вертикальная стопка билетов — вне scale-обёртки (у неё свой внутренний масштаб).
	_tickets = TicketsRow.new()
	_tickets.name = "Tickets"
	_tickets.vertical = true
	_tickets.visible = false
	_tickets.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tickets.resized.connect(_reposition)
	_root.add_child(_tickets)

	# Заглушка «Нет билетов» — в той же зарезервированной области (место не съезжает).
	_no_tickets = Label.new()
	_no_tickets.name = "NoTickets"
	_no_tickets.text = "ACTION_NO_TICKETS"
	_no_tickets.add_theme_font_size_override("font_size", 13)
	_no_tickets.add_theme_color_override("font_color", UIColors.MUTED)
	_no_tickets.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_no_tickets.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_no_tickets.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_no_tickets.custom_minimum_size = Vector2(_TICKETS_RESERVE, 0)
	_no_tickets.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_no_tickets.resized.connect(_reposition)
	_root.add_child(_no_tickets)

	# Позиция блока (bottom-right) — пересчёт при смене размера содержимого/окна.
	_col.resized.connect(_reposition)
	_reposition()


func _tex(file: String) -> Texture2D:
	return load(_A + file + ".png") as Texture2D


# Раскладка bottom-right: справа ВСЕГДА зарезервирована область билетов (билеты или
# «Нет билетов»), блок кнопок — слева от неё (не съезжает при отсутствии билетов).
func _reposition() -> void:
	if not is_instance_valid(_scale) or not is_instance_valid(_col):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var right: float = vp.x - _MARGIN_R
	var area_left: float = right - _TICKETS_RESERVE
	if is_instance_valid(_tickets) and _tickets.visible and _tickets.get_child_count() > 0:
		var ts: Vector2 = _tickets.size
		_tickets.position = Vector2(
			area_left + (_TICKETS_RESERVE - ts.x) * 0.5, vp.y - _MARGIN_B - ts.y
		)
	if is_instance_valid(_no_tickets) and _no_tickets.visible:
		_no_tickets.position = Vector2(area_left, vp.y - _MARGIN_B - _no_tickets.size.y)
	var w: float = _col.size.x * _scale.scale.x
	var h: float = _col.size.y * _scale.scale.y
	_scale.position = Vector2(area_left - _TICKETS_GAP - w, vp.y - _MARGIN_B - h)


func _on_pass() -> void:
	if _passing:
		return
	_passing = true
	await _pass_ab.spin_overlay()  # СНАЧАЛА проворот часов, ПОТОМ действие
	GameState.perform_action(GameActions.PASS)
	_passing = false


# TODO: действие «получить ресурс» пока не реализовано в движке — заглушка.
func _on_resource() -> void:
	pass


func _refresh() -> void:
	# Панель ВСЕГДА видна; кнопки активны только в мой ход фазы action.
	var my_turn: bool = GameState.is_my_turn()
	var me: Dictionary = GameState.my_player()
	var used: Array = me.get("actions_used", [])
	_conc_ab.set_disabled(
		(
			not my_turn
			or used.has(GameActions.TAKE_CONCENTRATION)
			or int(me.get("concentration", 0)) >= GameState.MAX_CONCENTRATION
		)
	)
	_rest_ab.set_disabled(not my_turn or used.has(GameActions.REST))
	_res_ab.set_disabled(not my_turn)
	_pass_ab.set_disabled(not my_turn)
	_conc_ab.set_badge(int(me.get("concentration", 0)))
	_res_ab.set_badge(int(me.get("resources", 0)))
	# Билеты: ребилд стопки лишь при смене суммарного числа; нет билетов → заглушка.
	var n_train: int = int(me.get("train_tickets", 0))
	var n_ship: int = int(me.get("ship_tickets", 0))
	if n_train + n_ship != _last_tickets:
		_last_tickets = n_train + n_ship
		_tickets.set_counts(n_train, n_ship)
	var has_tickets: bool = n_train + n_ship > 0
	_tickets.visible = has_tickets
	_no_tickets.visible = not has_tickets
	_reposition()
