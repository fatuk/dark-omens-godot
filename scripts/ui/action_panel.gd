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
const _REST_MODAL := preload("res://scenes/ui/modal_dialog.tscn")
const _MARGIN_R: float = 48.0  # отступ блока от правого края
const _MARGIN_B: float = 40.0  # отступ от низа
const _TICKETS_GAP: float = 20.0  # зазор кнопки ↔ область билетов
const _TICKETS_RESERVE: float = 150.0  # фикс. ширина области билетов (широкие ~141px — резерв, кнопки не съезжают)
const _CLUE_ICON := "res://assets/map/clue-icon.png"

@onready var _root: Control = $Root

var _scale: Control
var _col: VBoxContainer
var _rest_ab: ActionButton
var _conc_ab: ActionButton
var _res_ab: ActionButton
var _pass_ab: ActionButton
var _ability_btn: Button  # спец-действие сыщика (скрыта, если способности нет)
var _tickets: TicketsRow  # вертикальная стопка билетов
var _no_tickets: Label  # заглушка «Нет билетов» в зарезервированной области
var _clue: HBoxContainer  # индикатор улик [иконка ×N] сверху области билетов
var _clue_count: Label
var _last_tickets: int = -1  # без лишних ребилдов стопки
var _busy: bool = false  # идёт анимация действия (пас/жетон) — держим флоу, блочим клики


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

	_rest_ab.pressed.connect(_on_rest)
	_conc_ab.pressed.connect(_on_concentration)
	_res_ab.pressed.connect(_on_resource)
	_pass_ab.pressed.connect(_on_pass)

	# Спец-действие сыщика: у медальонов нет арта под него, поэтому пока текстовая
	# кнопка под рядом. Видна только у сыщика со способностью (data/investigators.json).
	# TODO(дизайн): свой медальон в общем ряду, когда появится арт.
	_ability_btn = UIStyle.button("", UIColors.ACCENT)
	_ability_btn.name = "AbilityBtn"
	_ability_btn.visible = false
	_ability_btn.pressed.connect(_on_ability)
	_col.add_child(_ability_btn)

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

	# Индикатор улик — [иконка ×N] сверху области билетов (виден при уликах > 0).
	_clue = HBoxContainer.new()
	_clue.name = "Clue"
	_clue.add_theme_constant_override("separation", 4)
	_clue.alignment = BoxContainer.ALIGNMENT_CENTER
	_clue.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clue.visible = false
	var ci := TextureRect.new()
	ci.name = "ClueIcon"
	ci.texture = load(_CLUE_ICON)
	ci.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ci.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ci.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	ci.custom_minimum_size = Vector2(52, 52)
	ci.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clue.add_child(ci)
	_clue_count = Label.new()
	_clue_count.name = "ClueCount"
	_clue_count.add_theme_font_size_override("font_size", 26)
	_clue_count.add_theme_color_override("font_color", UIColors.VALUE)
	_clue_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_clue_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clue.add_child(_clue_count)
	_clue.resized.connect(_reposition)
	_root.add_child(_clue)

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
	var w: float = _col.size.x * _scale.scale.x
	var h: float = _col.size.y * _scale.scale.y
	var top: float = vp.y - _MARGIN_B - h
	var bottom: float = vp.y - _MARGIN_B
	# Улики — сверху области. Верх выравниваем по ВЕРХУ медальона кнопки (не по верху
	# блока: там бейдж-строка, а иконки-медальоны на её высоту ниже).
	if is_instance_valid(_clue) and _clue.visible:
		var clue_top: float = top + ActionButton.ICON_TOP_2X * _scale.scale.y
		_clue.position = Vector2(area_left + (_TICKETS_RESERVE - _clue.size.x) * 0.5, clue_top)
	# Билеты / заглушка — снизу области, по центру.
	if is_instance_valid(_tickets) and _tickets.visible and _tickets.get_child_count() > 0:
		var ts: Vector2 = _tickets.size
		_tickets.position = Vector2(area_left + (_TICKETS_RESERVE - ts.x) * 0.5, bottom - ts.y)
	if is_instance_valid(_no_tickets) and _no_tickets.visible:
		_no_tickets.position = Vector2(area_left, bottom - _no_tickets.size.y)
	_scale.position = Vector2(area_left - _TICKETS_GAP - w, top)


func _on_ability() -> void:
	if _busy:
		return
	# Встроенный вид, требующий ввода (Мэй Линь) — открываем выбор; обычная
	# DSL-программа исполняется сразу.
	var inv: String = String(GameState.my_player().get("investigator", ""))
	if Investigators.ability_kind(inv) == "convertVitality":
		_show_convert_vitality()
		return
	_busy = true
	GameState.perform_action(GameActions.INVESTIGATOR_ABILITY)
	_busy = false


# Модалка способности «внутреннее равновесие»: выбрать, из какого запаса потратить
# и сколько — столько же вернётся в другой. Пределы: источник не опускаем ниже 1,
# приёмник не переливаем выше максимума (те же гварды дублирует хост).
func _show_convert_vitality() -> void:
	var me: Dictionary = GameState.my_player()
	var hp: int = int(me.get("hp", 0))
	var san: int = int(me.get("sanity", 0))
	var hp_room: int = maxi(0, int(me.get("hp_max", 0)) - hp)
	var san_room: int = maxi(0, int(me.get("sanity_max", 0)) - san)
	# Сколько максимум можно перелить в каждую сторону.
	var max_hp_to_san: int = mini(maxi(0, hp - 1), san_room)
	var max_san_to_hp: int = mini(maxi(0, san - 1), hp_room)
	if max_hp_to_san <= 0 and max_san_to_hp <= 0:
		return  # переливать нечего — молча ничего не делаем

	var modal: ModalDialog = _REST_MODAL.instantiate()
	add_child(modal)
	modal.set_title(tr(String(GameState.my_ability().get("name", ""))))
	var box := VBoxContainer.new()
	box.name = "ConvertAlloc"
	box.add_theme_constant_override("separation", 12)
	var hint := UIStyle.label("ABILITY_CONVERT_PROMPT", 15)
	hint.name = "Hint"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 360
	box.add_child(hint)

	var state := {"hp": 0, "san": 0}  # сколько тратим ИЗ здоровья / ИЗ рассудка
	var rows := {}
	var upd_ref := {"fn": Callable()}
	if max_hp_to_san > 0:
		rows["hp"] = _alloc_row(box, "ABILITY_CONVERT_HP_TO_SAN", state, "hp", upd_ref)
	if max_san_to_hp > 0:
		rows["san"] = _alloc_row(box, "ABILITY_CONVERT_SAN_TO_HP", state, "san", upd_ref)
	# Направление одно за раз: набрал в одной строке — вторая блокируется.
	var upd := func() -> void:
		for k_v: Variant in rows:
			var k: String = k_v
			var r: Dictionary = rows[k]
			(r["count"] as Label).text = str(state[k])
			var cap: int = max_hp_to_san if k == "hp" else max_san_to_hp
			var other: int = int(state["san"] if k == "hp" else state["hp"])
			(r["plus"] as Button).disabled = int(state[k]) >= cap or other > 0
			(r["minus"] as Button).disabled = int(state[k]) <= 0
	upd_ref["fn"] = upd
	upd.call()

	var confirm := UIStyle.button("ABILITY_CONFIRM", UIColors.ACCENT)
	confirm.name = "Confirm"
	var confirmed := {"v": false}
	confirm.pressed.connect(
		func() -> void:
			confirmed["v"] = true
			modal.close()
	)
	box.add_child(confirm)
	modal.set_content(box)
	modal.closed.connect(
		func() -> void:
			if not confirmed["v"]:
				return
			var from: String = "hp" if int(state["hp"]) > 0 else "sanity"
			var amount: int = maxi(int(state["hp"]), int(state["san"]))
			if amount <= 0:
				return
			GameState.perform_action(
				GameActions.INVESTIGATOR_ABILITY, {"from": from, "amount": amount}
			)
	)
	modal.open()


func _on_pass() -> void:
	if _busy:
		return
	_busy = true
	SfxManager.play(SfxManager.SFX_PASS)
	await _pass_ab.spin_overlay()  # СНАЧАЛА проворот часов, ПОТОМ действие
	GameState.perform_action(GameActions.PASS)
	_busy = false


func _on_rest() -> void:
	if _busy:
		return
	var me: Dictionary = GameState.my_player()
	var res: int = int(me.get("resources", 0))
	var hp_room: int = _rest_room(me, "hp", "hp_max")
	var san_room: int = _rest_room(me, "sanity", "sanity_max")
	# Есть ресурсы и место сверх базового отдыха → спросить распределение; иначе — сразу.
	if res > 0 and (hp_room > 0 or san_room > 0):
		_show_rest_alloc(res, hp_room, san_room)
	else:
		await _do_rest({})


# Свободное место стата ПОСЛЕ базового лечения отдыха (+1, с потолком) — сколько
# ещё можно долечить ресурсами.
func _rest_room(me: Dictionary, cur_key: String, max_key: String) -> int:
	var after_base: int = mini(int(me.get(max_key, 0)), int(me.get(cur_key, 0)) + 1)
	return int(me.get(max_key, 0)) - after_base


func _do_rest(payload: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	# Случайный из 5 участков лечения (segments имеют приоритет над variations).
	SfxManager.play_variation(SfxManager.SFX_REST, 5, 0.0, SfxManager.REST_SEGMENTS)
	await _rest_ab.pop_token()  # жетон летит «в камеру», флоу ждёт; ПОТОМ действие
	GameState.perform_action(GameActions.REST, payload)
	_busy = false


# Модалка распределения ресурсов при отдыхе: +1 здоровью/рассудку за жетон, в пределах
# запаса и свободного места. Подтверждение → отдых с payload; закрытие (ESC/фон) — отмена.
func _show_rest_alloc(res: int, hp_room: int, san_room: int) -> void:
	var modal: ModalDialog = _REST_MODAL.instantiate()
	add_child(modal)
	modal.set_title(tr("ACTION_REST_TITLE"))
	var box := VBoxContainer.new()
	box.name = "RestAlloc"
	box.add_theme_constant_override("separation", 12)
	var hint := UIStyle.label("ACTION_REST_RES_PROMPT", 15)
	hint.name = "Hint"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 360
	box.add_child(hint)

	var state := {"hp": 0, "san": 0}
	var rows := {}  # key → {count, plus, minus}
	var upd_ref := {"fn": Callable()}
	if hp_room > 0:
		rows["hp"] = _alloc_row(box, "ACTION_REST_RES_HP", state, "hp", upd_ref)
	if san_room > 0:
		rows["san"] = _alloc_row(box, "ACTION_REST_RES_SAN", state, "san", upd_ref)
	var upd := func() -> void:
		var total: int = int(state["hp"]) + int(state["san"])
		for k_v: Variant in rows:
			var k: String = k_v
			var r: Dictionary = rows[k]
			(r["count"] as Label).text = str(state[k])
			var room: int = hp_room if k == "hp" else san_room
			(r["plus"] as Button).disabled = int(state[k]) >= room or total >= res
			(r["minus"] as Button).disabled = int(state[k]) <= 0
	upd_ref["fn"] = upd
	upd.call()

	var confirm := UIStyle.button("ACTION_REST_RES_CONFIRM", UIColors.ACCENT)
	confirm.name = "Confirm"
	var confirmed := {"v": false}
	confirm.pressed.connect(
		func() -> void:
			confirmed["v"] = true
			modal.close()
	)
	box.add_child(confirm)
	modal.set_content(box)
	modal.closed.connect(
		func() -> void:
			if confirmed["v"]:
				_do_rest({"res_hp": int(state["hp"]), "res_san": int(state["san"])})
	)
	modal.open()


# Строка-степпер «метка [−] N [+]» для распределения ресурса. Мутирует state[key],
# зовёт upd_ref.fn после каждого изменения (пересчёт меток и доступности кнопок).
func _alloc_row(
	box: VBoxContainer, label_key: String, state: Dictionary, key: String, upd_ref: Dictionary
) -> Dictionary:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % key
	row.add_theme_constant_override("separation", 10)
	var lbl := UIStyle.label(label_key, 15)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var minus := UIStyle.button("−")
	minus.name = "Minus"
	var count := UIStyle.label("0", 17, UIColors.VALUE, HORIZONTAL_ALIGNMENT_CENTER)
	count.name = "Count"
	count.custom_minimum_size.x = 32
	var plus := UIStyle.button("+")
	plus.name = "Plus"
	minus.pressed.connect(
		func() -> void:
			state[key] = maxi(0, int(state[key]) - 1)
			(upd_ref["fn"] as Callable).call()
	)
	plus.pressed.connect(
		func() -> void:
			state[key] = int(state[key]) + 1
			(upd_ref["fn"] as Callable).call()
	)
	row.add_child(minus)
	row.add_child(count)
	row.add_child(plus)
	box.add_child(row)
	return {"count": count, "plus": plus, "minus": minus}


func _on_concentration() -> void:
	if _busy:
		return
	_busy = true
	SfxManager.play(SfxManager.SFX_CONCENTRATION_GET)
	await _conc_ab.pop_token()  # жетон летит «в камеру», флоу ждёт; ПОТОМ +1 к счёту
	GameState.perform_action(GameActions.TAKE_CONCENTRATION)
	_busy = false


func _on_resource() -> void:
	if _busy:
		return
	_busy = true
	SfxManager.play(SfxManager.SFX_RESOURCE_GET)
	await _res_ab.pop_token()  # жетон летит «в камеру», флоу ждёт; ПОТОМ +1 к счёту
	GameState.perform_action(GameActions.TAKE_RESOURCE)
	_busy = false


func _refresh() -> void:
	# Панель ВСЕГДА видна; кнопки активны только в мой ход фазы action.
	var my_turn: bool = GameState.is_my_turn()
	var me: Dictionary = GameState.my_player()
	# Тень не ходит/не покупает/не ездит — прячем всю панель действий целиком.
	_root.visible = not bool(me.get(PlayerKeys.DEAD, false))
	if not _root.visible:
		return
	var used: Array = me.get("actions_used", [])
	_conc_ab.set_disabled(
		(
			not my_turn
			or used.has(GameActions.TAKE_CONCENTRATION)
			or int(me.get("concentration", 0)) >= GameState.MAX_CONCENTRATION
		)
	)
	_rest_ab.set_disabled(not my_turn or used.has(GameActions.REST))
	_res_ab.set_disabled(
		(
			not my_turn
			or used.has(GameActions.TAKE_RESOURCE)
			or int(me.get("resources", 0)) >= GameState.MAX_RESOURCES
		)
	)
	_pass_ab.set_disabled(not my_turn)
	# Спец-действие: кнопка есть только у сыщика со способностью; подпись — из данных.
	# Способность = DSL-программа ЛИБО встроенный вид (kind), поэтому спрашиваем
	# каталог, а не поле `do` — иначе виды вроде convertVitality остаются без кнопки.
	var has_ability: bool = Investigators.has_ability(String(me.get("investigator", "")))
	_ability_btn.visible = has_ability
	if has_ability:
		_ability_btn.text = String(GameState.my_ability().get("name", "ACTION_ABILITY_TITLE"))
		_ability_btn.disabled = not GameState.can_use_ability()
	_conc_ab.set_badge(int(me.get("concentration", 0)))
	_res_ab.set_badge(int(me.get("resources", 0)))
	# Инфо-колонка (улика + билеты) гаснет вместе с кнопками, когда не мой ход.
	var info_mod: Color = Color.WHITE if my_turn else UIColors.DISABLED
	_clue.modulate = info_mod
	_tickets.modulate = info_mod
	_no_tickets.modulate = info_mod
	# Улики — [иконка ×N] сверху области билетов (видны всегда, «×0» когда нет).
	_clue_count.text = "×%d" % int(me.get("clues", 0))
	_clue.visible = true
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
