extends CanvasLayer

## Магазин (Acquire Assets). Открывается из сайдбара в городе со своим сыщиком.
##
## Поток покупки:
##   1. «Бросить кубы» — бросок Влияния; число успехов = монеты.
##   2. В любой момент «Взять долг» — сразу вешает состояние «Долг» (без дублей)
##      и даёт +2 монеты.
##   3. Выбор карточек кликом — суммарная цена не должна превышать монеты.
##   4. «Купить» — покупает выбранное и закрывает модалку.
##
## Бросок и подсчёт монет — на клиенте (интерактивный выбор), фактические покупки
## применяет хост на «Купить» (GameState.shop_buy_asset), долг — сразу
## (GameState.shop_take_debt).

const _CARD_MIN := Vector2(210, 332)  # пропорции рамки asset-card (аспект ≈0.632)
const _EYE := "◉"

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

# Состояние сессии магазина.
var _coins: int = 0
var _rolls: Array = []  # значения брошенных кубов (для переброса)
var _rolled: bool = false
var _debt_taken: bool = false
var _selected: Dictionary = {}  # asset_id -> cost

# Узлы для обновления.
var _dice_box: HBoxContainer
var _coins_lbl: Label
var _roll_btn: Button
var _debt_btn: Button
var _buy_btn: Button
var _cards: Array = []  # [{id, cost, panel}]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func open() -> void:
	visible = true


func _close() -> void:
	# Снять отложенную передачу хода (если бросок был последним действием —
	# ход уйдёт только сейчас). No-op, если игрок не начинал поход (не бросал).
	GameState.shop_close()
	queue_free()


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
	# из синкаемого резерва (после покупки хост заменяет купленные новыми).
	for a in _offer():
		cards.add_child(_build_asset_card(a))

	UIStyle.separator(vb)

	# Монеты · доступно — над кубами.
	_coins_lbl = UIStyle.label("", 16, UIColors.WARNING, HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(_coins_lbl)

	# Кубы Влияния — по центру.
	_dice_box = HBoxContainer.new()
	_dice_box.name = "DiceBox"
	_dice_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_dice_box.add_theme_constant_override("separation", 6)
	_dice_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(_dice_box)
	_render_dice([])  # пустой пул до броска

	# Ряд кнопок: бросок · долг · купить.
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 16)
	vb.add_child(btns)

	_roll_btn = UIStyle.button("SHOP_ROLL", UIColors.ACCENT)
	_roll_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roll_btn.pressed.connect(_on_roll)
	btns.add_child(_roll_btn)

	_debt_btn = UIStyle.button("SHOP_TAKE_DEBT", UIColors.WARNING)
	_debt_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_debt_btn.pressed.connect(_on_take_debt)
	_debt_btn.visible = not _has_debt()  # уже есть «Долг» → не предлагаем ещё
	btns.add_child(_debt_btn)

	_buy_btn = UIStyle.button("SHOP_BUY", UIColors.ACCENT)
	_buy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_buy_btn.pressed.connect(_on_buy)
	btns.add_child(_buy_btn)

	# Закрытие — только крестиком в шапке (кнопки «Отменить» нет).
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

	# Единый компонент карты (та же рамка, что у карт руки). nameKey/abilityKey —
	# ключи переводов, Label в GameCard их автопереводит. Стоимость — в гербе
	# рамки, поэтому отдельную строку «проверка» не дублируем.
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


# ── Кубы ───────────────────────────────────────────────────────────────────────


func _render_dice(rolls: Array) -> void:
	for c in _dice_box.get_children():
		c.queue_free()
	# Единый компонент проверки. После броска провальные кубы кликабельны для
	# переброса за концентрацию (как во встречах/бою).
	var tray := DiceTray.new()
	tray.name = "DiceTray"
	_dice_box.add_child(tray)
	if rolls.is_empty():
		tray.show_pending(_influence_pool())  # кубы до броска
	else:
		tray.die_selected.connect(_on_die_clicked)
		tray.show_roll(rolls, _focus() > 0)


func _influence_pool() -> int:
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get("influence", 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get("influence", 0))
	return maxi(1, base + mods)


# ── Действия ───────────────────────────────────────────────────────────────────


func _on_roll() -> void:
	if _rolled:
		return
	_rolled = true
	GameState.shop_begin()  # бросок = совершённое действие (раз за раунд)
	_rolls = Dice.roll(_influence_pool())
	_recompute_coins()
	_render_dice(_rolls)
	_roll_btn.disabled = true
	_refresh()


func _on_take_debt() -> void:
	if _debt_taken or _has_debt():
		return
	_debt_taken = true
	_recompute_coins()
	GameState.shop_take_debt()  # сразу вешает состояние «Долг» (без дублей)
	_debt_btn.disabled = true
	_refresh()


# Монеты = успехи текущего броска + бонус долга. Пересчитывается при броске,
# перебросе и взятии долга (успехи могут только вырасти при перебросе).
func _recompute_coins() -> void:
	_coins = Dice.count_successes(_rolls) + (2 if _debt_taken else 0)


func _focus() -> int:
	return int(GameState.my_player().get("concentration", 0))


# Клик по провальному кубу — переброс за концентрацию (как во встречах/бою).
# Хост авторитетно списывает фокус; переброс и монеты — локально (бросок
# магазина клиентский).
func _on_die_clicked(index: int) -> void:
	if _focus() <= 0:
		return
	if not Dice.reroll_failure(_rolls, index):
		return  # успех или неверный индекс — фокус не тратим
	GameState.shop_reroll()
	_recompute_coins()
	_render_dice(_rolls)
	_refresh()


func _toggle_card(aid: String, cost: int) -> void:
	if _selected.has(aid):
		_selected.erase(aid)
	else:
		if cost <= _coins - _spent():  # по карману?
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
	var remaining: int = _coins - _spent()
	if _coins_lbl:
		_coins_lbl.text = (
			"%s: %d   ·   %s: %d" % [tr("SHOP_COINS"), _coins, tr("SHOP_REMAINING"), remaining]
		)
	if _buy_btn:
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
