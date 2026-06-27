extends CanvasLayer

## Магазин (Acquire Assets). Открывается из сайдбара в городе со своим сыщиком.
##
## Поток покупки:
##   1. «Бросить кубы» — бросок Влияния (хост, единая проверка CheckFlow);
##      число успехов = монеты.
##   2. В любой момент «Взять долг» — вешает «Долг» и даёт +2 монеты.
##   3. Переброс провального куба — тап по кубику: бесплатные от карт →
##      концентрация → улика (общий механизм проверки).
##   4. Карты руки (веер, Tab) активируются прямо здесь — это та же проверка.
##   5. Выбор карточек кликом (сумма ≤ монет) → «Купить».
##
## Бросок/перебросы/монеты — хост-авторитетны в GameState.active_check; модалка
## лишь отражает синкнутое состояние (реактивно по state_changed).

const _CARD_MIN := Vector2(290, 459)  # = размер наведённой карты веера (186·1.56 × 294·1.56)

const _TRAIT_KEY := {
	"weapon": "TRAIT_WEAPON",
	"magical": "TRAIT_MAGICAL",
	"relic": "TRAIT_RELIC",
	"tome": "TRAIT_TOME",
	"teamwork": "TRAIT_TEAMWORK",
	"item": "TRAIT_ITEM",
	"trinket": "TRAIT_TRINKET",
	"task": "TRAIT_TASK",
	"service": "TRAIT_SERVICE",
	"ally": "TRAIT_ALLY",
}

# Состояние сессии магазина (UI-локальное; бросок/монеты — в active_check).
var _debt_taken: bool = false
var _selected: Dictionary = {}  # asset_id -> cost
var _last_dice: Array = []  # последний показанный набор (спин только на свежем)
var _last_nonce: int = 0  # метка последнего отрисованного переброса (CheckFlow.reroll_nonce)
var _last_can: bool = false  # последнее состояние кликабельности (для обновления без смены кубов)

# Узлы для обновления.
var _dice_box: HBoxContainer
var _tray: DiceTray  # переиспользуемый лоток кубов
var _coins_lbl: Label
var _roll_btn: Button
var _debt_btn: Button
var _buy_btn: Button
var _cards: Array = []  # [{id, cost, panel}]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	GameState.state_changed.connect(_refresh)


func open() -> void:
	visible = true


func _close() -> void:
	# Снять отложенную передачу хода и активную проверку (host_apply_shop_close).
	GameState.shop_close()
	queue_free()


# ── Доступ к активной проверке магазина ───────────────────────────────────────


# Активная проверка, если она магазинная (иначе {}).
func _check() -> Dictionary:
	var c: Dictionary = GameState.active_check
	return c if String(c.get("owner", "")) == "shop" else {}


func _rolled() -> bool:
	return bool(_check().get("rolled", false))


# Монеты = успехи броска + бонус долга (+2 только если долг ВЗЯТ в этом походе;
# уже висящее состояние «Долг» из прошлого похода монет не даёт).
func _coins() -> int:
	return int(_check().get("successes", 0)) + (2 if _debt_taken else 0)


# Остаток бесплатных перебросов от карт.
func _free_rerolls() -> int:
	var c: Dictionary = _check()
	return maxi(0, int(c.get("reroll_allowance", 0)) - int(c.get("rerolls_used", 0)))


# Можно ли перебросить тапом: бесплатно от карт или заряжен жетон. Концентрация/
# улика — только через розыгрыш жетона на проверку (не авто-тратой по тапу).
func _can_reroll() -> bool:
	return GameState.can_reroll_now()


# Доступен ли «перебросить все провальные кубы разом» (Счастливый талисман).
func _reroll_all_available() -> bool:
	if not _rolled():
		return false
	var c: Dictionary = _check()
	return int(c.get("reroll_all_allowance", 0)) - int(c.get("reroll_all_used", 0)) > 0


# ── Сборка ───────────────────────────────────────────────────────────────────


func _build() -> void:
	var bg := ColorRect.new()
	bg.name = "Backdrop"
	bg.color = Color(0, 0, 0, 0.6)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	UIStyle.style_modal_panel(panel)
	panel.custom_minimum_size = Vector2(1120, 0)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	vb.add_child(UIStyle.modal_header("SHOP_TITLE", _close))
	vb.add_child(UIStyle.label("SHOP_SUBTITLE", 14, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	UIStyle.separator(vb)

	# Витрина — ряд карт по центру.
	var cards := HBoxContainer.new()
	cards.name = "Cards"
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("separation", 14)
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(cards)
	for a in _offer():
		cards.add_child(_build_asset_card(a))

	UIStyle.separator(vb)

	# Монеты · доступно — над кубами.
	_coins_lbl = UIStyle.label("", 16, UIColors.WARNING, HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(_coins_lbl)

	# Кубы Влияния — по центру (переиспользуемый лоток).
	_dice_box = HBoxContainer.new()
	_dice_box.name = "DiceBox"
	_dice_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_dice_box.add_theme_constant_override("separation", 6)
	_dice_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(_dice_box)

	# Ряд кнопок: долг · бросок · купить.
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 16)
	vb.add_child(btns)

	_debt_btn = UIStyle.button("SHOP_TAKE_DEBT", UIColors.WARNING)
	_debt_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_debt_btn.pressed.connect(_on_take_debt)
	_debt_btn.visible = not _has_debt()  # уже есть «Долг» → не предлагаем ещё
	btns.add_child(_debt_btn)

	_roll_btn = UIStyle.button("SHOP_ROLL", UIColors.ACCENT)
	_roll_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roll_btn.pressed.connect(_on_roll)
	btns.add_child(_roll_btn)

	_buy_btn = UIStyle.button("SHOP_BUY", UIColors.ACCENT)
	_buy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_buy_btn.pressed.connect(_on_buy)
	btns.add_child(_buy_btn)

	# Закрытие — только крестиком в шапке.
	UIStyle.scale_modal_text(panel)  # текст модалок крупнее (×1.5)
	visible = false
	_refresh()


# Список ассетов витрины: из GameState.shop_reserve, иначе — статичный фолбэк.
func _offer() -> Array:
	var out: Array = []
	for aid in GameState.shop_reserve:
		var a: Dictionary = AssetCatalog.by_id(String(aid))
		if not a.is_empty():
			out.append(a)
	if out.is_empty():
		out = AssetCatalog.shop_offer(4)
	return out


func _build_asset_card(a: Dictionary) -> Control:
	var aid: String = String(a.get("id", ""))
	var cost: int = int(a.get("cost", 0))
	var traits: Array = a.get("traits", [])
	var trait_id: String = String(traits[-1]) if not traits.is_empty() else "item"

	var card := GameCard.new()
	card.name = "Card"
	card.custom_minimum_size = _CARD_MIN
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	(
		card
		. set_card(
			{
				"cost": cost,
				"title": a.get("nameKey", ""),
				"subtitle": _TRAIT_KEY.get(trait_id, trait_id.to_upper()),
				"desc": a.get("abilityKey", ""),
			}
		)
	)
	card.gui_input.connect(
		func(ev: InputEvent) -> void:
			if (
				ev is InputEventMouseButton
				and (ev as InputEventMouseButton).pressed
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
			):
				_toggle_card(aid, cost)
	)

	_cards.append({"id": aid, "cost": cost, "panel": card})
	return card


func _has_debt() -> bool:
	return (GameState.my_player().get("conditions", []) as Array).has("debt")


# ── Кубы (переиспользуемый лоток, рендер из active_check) ──────────────────────


func _ensure_tray() -> void:
	if is_instance_valid(_tray):
		return
	_tray = DiceTray.new()
	_tray.name = "DiceTray"
	_tray.die_selected.connect(_on_die_clicked)
	_dice_box.add_child(_tray)


func _render_dice() -> void:
	if not is_instance_valid(_dice_box):
		return
	_ensure_tray()
	if not _rolled():
		if not _last_dice.is_empty():
			_last_dice = []
		_tray.show_pending(_influence_pool())  # рубашки до броска
		return
	var dice: Array = _check().get("dice", [])
	var can: bool = _can_reroll()
	var nonce: int = int(_check().get("reroll_nonce", 0))
	if dice != _last_dice:
		var prev: Array = _last_dice
		var diff: int = _single_diff(prev, dice)
		_last_dice = dice.duplicate()
		if prev.is_empty():
			_tray.play_roll(dice, can)  # свежий бросок — спин
		elif diff >= 0:
			_tray.reroll_die(diff, int(dice[diff]), can)  # переброс одного — крутится он
		elif prev.size() == dice.size():
			_tray.play_roll(dice, can)  # несколько изменилось (reroll-all) — спин всех
		else:
			_tray.show_roll(dice, can)  # размер изменился (докинули кубы) — статикой
		_last_can = can
		_last_nonce = nonce
	elif nonce != _last_nonce:
		# Переброс в ТО ЖЕ значение: массив не изменился, но nonce вырос — крутим
		# затронутый куб, иначе клик «съеденный» (фокус ушёл, куб не дёрнулся).
		var ri: int = int(_check().get("reroll_index", -1))
		if ri >= 0 and ri < dice.size():
			_tray.reroll_die(ri, int(dice[ri]), can)
		_last_can = can
		_last_nonce = nonce
	elif can != _last_can:
		# Кубы те же, но кликабельность изменилась (активировали карту-переброс
		# после броска) — обновляем лоток статикой, иначе кубик не нажать.
		_tray.show_roll(dice, can)
		_last_can = can


# Индекс единственного отличия наборов (-1 если 0 или >1 отличий / разные размеры).
func _single_diff(a: Array, b: Array) -> int:
	if a.size() != b.size():
		return -1
	var idx: int = -1
	for i in range(a.size()):
		if int(a[i]) != int(b[i]):
			if idx >= 0:
				return -1
			idx = i
	return idx


# Пул d6 Влияния до броска (для рубашек): навык + модификаторы + доп.кубы карт.
func _influence_pool() -> int:
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get("influence", 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get("influence", 0))
	var bonus: int = Dice.pre_roll_bonus(_check().get("active_mods", []), "influence")
	return maxi(1, base + mods + bonus)


# ── Действия ───────────────────────────────────────────────────────────────────


func _on_roll() -> void:
	if _rolled():
		# Повторное нажатие после броска = «перебросить все кубы» (Талисман).
		if _reroll_all_available():
			GameState.reroll_all_dice()  # хост перебросит провальные и пришлёт синком
		return
	_roll_btn.disabled = true  # хост катит и пришлёт active_check синком
	GameState.shop_begin()  # бросок = действие acquire_assets + старт+бросок проверки


func _on_take_debt() -> void:
	if _debt_taken or _has_debt():
		return
	_debt_taken = true
	_debt_btn.disabled = true
	GameState.shop_take_debt()  # вешает «Долг» (без дублей), +2 монеты
	_refresh()


# Клик по кубу — переброс: заряженным жетоном (concentration/clue) или авто-приоритетом.
func _on_die_clicked(index: int) -> void:
	if not _can_reroll():
		return
	GameState.reroll_die(index)  # хост перебросит и пришлёт active_check синком


func _toggle_card(aid: String, cost: int) -> void:
	if _selected.has(aid):
		_selected.erase(aid)
	elif cost <= _coins() - _spent():  # по карману?
		_selected[aid] = cost
	_refresh()


func _on_buy() -> void:
	if _selected.is_empty():
		return
	GameState.shop_grant(_selected.keys())  # действие уже потрачено на броске
	_close()


# ── Обновление UI ───────────────────────────────────────────────────────────────


func _spent() -> int:
	var s: int = 0
	for c in _selected.values():
		s += int(c)
	return s


func _refresh() -> void:
	_render_dice()
	var coins: int = _coins()
	var remaining: int = coins - _spent()
	if is_instance_valid(_coins_lbl):
		_coins_lbl.text = (
			"%s: %d   ·   %s: %d" % [tr("SHOP_COINS"), coins, tr("SHOP_REMAINING"), remaining]
		)
	if is_instance_valid(_roll_btn):
		# После броска кнопка превращается в «Перебросить кубы», пока доступен reroll-all.
		if _rolled() and _reroll_all_available():
			_roll_btn.text = "ENCOUNTER_REROLL_ALL"
			_roll_btn.disabled = false
		else:
			_roll_btn.text = "SHOP_ROLL"
			_roll_btn.disabled = _rolled()
	if is_instance_valid(_debt_btn):
		_debt_btn.visible = not _has_debt()
	if is_instance_valid(_buy_btn):
		_buy_btn.disabled = _selected.is_empty()
	for e in _cards:
		var panel: Control = e.panel
		var sel: bool = _selected.has(e.id)
		var affordable: bool = sel or int(e.cost) <= remaining
		if sel:
			panel.modulate = Color(1.25, 1.18, 0.85)  # выбрано — тёплая подсветка
		elif affordable:
			panel.modulate = Color(1, 1, 1)
		else:
			panel.modulate = Color(0.5, 0.5, 0.5)  # не по карману — тускло
