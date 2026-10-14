extends CanvasLayer

## Общая модалка ВИДИМОЙ проверки test-узла Effect-DSL (Detained/Debt-действие, вложенный
## test встречи, Расплата). Dual-mode: в ПАРАЛЛЕЛЬНОЙ Расплате читает свой per-player слот
## players[me].reckoning_pending/reckoning_check и роутит бросок/перебросы/применить в
## reckoning_*-фасады; иначе — единый pending_check/active_check (owner="effectCheck").
## Показывает карту-носитель (subject), кубы и «Бросить»/«Применить» — как каст ритуала.
## Хост-авторитетно; модалка лишь отражает синк. Код, монтируется из world_map.

const _CARD_MIN := Vector2(290, 459)

var _root: ColorRect
var _panel: PanelContainer
var _vbox: VBoxContainer
var _dice_box: HBoxContainer
var _tray: DiceTray
var _roll_btn: Button
var _apply_btn: Button

var _sig: String = ""
var _last_dice: Array = []
var _last_can: bool = false
var _last_add: bool = false  # доступность +1 (addToDie) — тоже влияет на кликабельность
var _last_nonce: int = 0  # метка последнего отрисованного переброса (CheckFlow.reroll_nonce)


func _ready() -> void:
	layer = 86  # как cast_check_modal
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_frame()
	GameState.state_changed.connect(_refresh)
	_refresh()


func _build_frame() -> void:
	_root = ColorRect.new()
	_root.name = "Root"
	_root.color = Color(0, 0, 0, 0.55)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP  # ловим клики мимо панели
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
		margin.add_theme_constant_override("margin_" + side, 18)
	_panel.add_child(margin)

	_vbox = VBoxContainer.new()
	_vbox.name = "VBox"
	_vbox.add_theme_constant_override("separation", 12)
	margin.add_child(_vbox)


# ── Доступ к стейту ───────────────────────────────────────────────────────────


# Моя ожидающая проверка Расплаты (per-player слот players[me].reckoning_pending), {} — нет.
func _reck() -> Dictionary:
	return GameState.my_player().get("reckoning_pending", {})


# Режим параллельной Расплаты (своя проверка в игроке, не в едином pending_check).
func _reck_mode() -> bool:
	return not _reck().is_empty()


# Ожидающая видимая проверка этого игрока: сначала параллельная Расплата (per-player
# слот), иначе одиночный pending_check (фаза действий/встреча). {} — нет.
func _pc() -> Dictionary:
	var r: Dictionary = _reck()
	if not r.is_empty():
		return r
	var pc: Dictionary = GameState.pending_check
	return pc if String(pc.get("pid", "")) == _my_id() else {}


# Источник кубов: слот Расплаты players[me].reckoning_check в режиме Расплаты, иначе
# единый active_check (если это проверка движка test).
func _chk() -> Dictionary:
	if _reck_mode():
		return GameState.my_player().get("reckoning_check", {})
	var c: Dictionary = GameState.active_check
	return c if String(c.get("owner", "")) == "effectCheck" else {}


func _my_id() -> String:
	return String(GameState.my_player().get("user_id", ""))


func _rolled() -> bool:
	return bool(_chk().get("rolled", false))


func _reroll_all_available() -> bool:
	if not _rolled():
		return false
	var c: Dictionary = _chk()
	return int(c.get("reroll_all_allowance", 0)) - int(c.get("reroll_all_used", 0)) > 0


# ── Обновление ────────────────────────────────────────────────────────────────


func _refresh() -> void:
	var pc: Dictionary = _pc()
	var active: bool = not pc.is_empty()
	UIStyle.modal_set_visible(_root, _panel, active)
	if not active:
		_sig = ""
		_last_dice = []
		return
	var sig: String = String(pc.get("path", "")) + "|" + String(pc.get("cid", pc.get("driver", "")))
	if sig != _sig:
		_sig = sig
		_last_dice = []
		_build(pc)
	_render_dice()
	_update_buttons()


func _build(pc: Dictionary) -> void:
	for c in _vbox.get_children():
		c.queue_free()
	_tray = null

	_vbox.add_child(UIStyle.modal_title("CHECK_TITLE"))

	# Карта-носитель (subject) по центру, если передана.
	var subject: Dictionary = pc.get("subject", {})
	if not subject.is_empty():
		var card_row := HBoxContainer.new()
		card_row.name = "CardRow"
		card_row.alignment = BoxContainer.ALIGNMENT_CENTER
		_vbox.add_child(card_row)
		var card := GameCard.new()
		card.name = "SubjectCard"
		card.custom_minimum_size = _CARD_MIN
		card.set_card(subject)
		card_row.add_child(card)
		CardPreview.attach_click(card, subject)

	# Кубы проверки.
	_dice_box = HBoxContainer.new()
	_dice_box.name = "DiceBox"
	_dice_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_dice_box.add_theme_constant_override("separation", 6)
	_dice_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_child(_dice_box)

	# Кнопки: бросок · применить.
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 16)
	_vbox.add_child(btns)

	_roll_btn = UIStyle.button("CAST_ROLL", UIColors.ACCENT)
	_roll_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roll_btn.pressed.connect(_on_roll)
	btns.add_child(_roll_btn)

	_apply_btn = UIStyle.button("CAST_APPLY", UIColors.ACCENT)
	_apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_btn.pressed.connect(_on_apply)
	btns.add_child(_apply_btn)


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
	_tray.set_roller(_my_id())  # Благословение/Проклятие сдвигают порог подсветки
	if not _rolled():
		if not _last_dice.is_empty():
			_last_dice = []
		var pb: Dictionary = _pool()
		_tray.set_pool_marks(int(pb["bonus"]), int(pb["blocked"]))
		_tray.show_pending(int(pb["pool"]), String(_chk().get("skill", "")))
		return
	var dice: Array = _chk().get("dice", [])
	var can: bool = _can_reroll()
	var add: bool = GameState.dice.can_add(_reck_mode())  # заряжен +1 → кубы < 6 кликабельны
	var nonce: int = int(_chk().get("reroll_nonce", 0))
	if dice != _last_dice:
		var prev: Array = _last_dice
		var diff: int = _single_diff(prev, dice)
		_last_dice = dice.duplicate()
		if prev.is_empty():
			_tray.play_roll(dice, can, add)
		elif diff >= 0:
			_tray.reroll_die(diff, int(dice[diff]), can, add)
		elif prev.size() == dice.size():
			_tray.play_roll(dice, can, add)
		else:
			_tray.show_roll(dice, can, add)
		_last_can = can
		_last_add = add
		_last_nonce = nonce
	elif nonce != _last_nonce:
		# Переброс выпал в ТО ЖЕ значение: массив кубов не изменился, но фокус потрачен
		# и переброс был. Всё равно крутим затронутый куб — иначе клик выглядит
		# «смазанным»/съеденным (фокус ушёл, куб не дёрнулся).
		var ri: int = int(_chk().get("reroll_index", -1))
		if ri >= 0 and ri < dice.size():
			_tray.reroll_die(ri, int(dice[ri]), can, add)
		_last_can = can
		_last_add = add
		_last_nonce = nonce
	elif can != _last_can or add != _last_add:
		_tray.show_roll(dice, can, add)
		_last_can = can
		_last_add = add


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


# Пул кубов навыка проверки до броска (для рубашек): навык + skill_mods + modifier + доп.кубы.
# Разбор пула: {pool, bonus, blocked} — ряд показывает полный пул сыщика,
# добавленные/отнятые кубы помечены цветом (см. DiceTray.set_pool_marks).
func _pool() -> Dictionary:
	var c: Dictionary = _chk()
	var skill: String = String(c.get("skill", "influence"))
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get(skill, 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get(skill, 0))
	var extra: int = Dice.pre_roll_bonus(c.get("active_mods", []), skill)
	return Dice.pool_breakdown(base, mods, int(c.get("modifier", 0)), extra)


# ── Действия ───────────────────────────────────────────────────────────────────


# Можно ли перебросить куб сейчас — в режиме Расплаты свой per-player счётчик.
func _can_reroll() -> bool:
	return GameState.dice.can_reroll(_reck_mode())


func _on_roll() -> void:
	if _rolled():
		if _reroll_all_available():
			if _reck_mode():
				GameState.act(RelayActions.RECKONING_REROLL_ALL)
			else:
				GameState.act(RelayActions.REROLL_ALL)
		return
	_roll_btn.disabled = true
	if _reck_mode():
		GameState.act(RelayActions.RECKONING_ROLL)
	else:
		GameState.act(RelayActions.CHECK_ROLL)


func _on_die_clicked(index: int) -> void:
	if not _can_reroll():
		return
	GameState.dice.tap(index, _reck_mode())  # Расплата — свой слот, иначе по owner


func _on_apply() -> void:
	_apply_btn.disabled = true
	if _reck_mode():
		GameState.act(RelayActions.RECKONING_APPLY)
	else:
		GameState.act(RelayActions.RESOLVE_PENDING_CHECK)


func _update_buttons() -> void:
	if is_instance_valid(_roll_btn):
		if _rolled() and _reroll_all_available():
			_roll_btn.text = "ENCOUNTER_REROLL_ALL"
			_roll_btn.disabled = false
		else:
			_roll_btn.text = "CAST_ROLL"
			_roll_btn.disabled = _rolled()
	if is_instance_valid(_apply_btn):
		_apply_btn.disabled = not _rolled()  # применить только после броска
