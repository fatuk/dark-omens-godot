extends CanvasLayer

## Общая модалка ВИДИМОЙ проверки test-узла Effect-DSL (Detained/Debt-действие, вложенный
## test встречи, Расплата). Dual-mode: в ПАРАЛЛЕЛЬНОЙ Расплате читает свой per-player слот
## players[me].reckoning_pending/reckoning_check и роутит бросок/перебросы/применить в
## reckoning_*-фасады; иначе — единый pending_check/active_check (owner="effectCheck").
## Показывает карту-носитель (subject), кубы и «Бросить»/«Применить» — как каст ритуала.
## Хост-авторитетно; модалка лишь отражает синк. Код, монтируется из world_map.
##
## Проверка СОСТОЯНИЯ (subject — карта состояния: Расплата, «Задержан», оборот) идёт на
## листе по арту cards/condition/condition-cast.png — как каст заклинания на своём:
## заголовок сверху, карта в центре, кубы на столе, кнопки у нижнего края, живой огонь
## в фонаре. Прочие проверки — обычная панель.

const _CARD_MIN := Vector2(290, 459)

const _SHEET_TEX: Texture2D = preload("res://assets/cards/condition/condition-cast.png")
const _SHEET_H: float = 940.0
const _CARD_CENTER := Vector2(0.5, 0.372)
const _CARD_H_FRAC: float = 0.535
const _Z_TITLE := Rect2(0.12, 0.038, 0.76, 0.06)
const _Z_DICE := Rect2(0.10, 0.665, 0.80, 0.165)
const _Z_BUTTONS := Rect2(0.14, 0.86, 0.72, 0.085)
# Керосиновая лампа справа на подоконнике (доли листа, замерены по картинке).
const _FLAMES := [
	{"cx": 0.956, "cy": 0.528, "w": 0.05, "h": 0.08, "intensity": 0.85, "speed": 6.5, "seed": 3.0},
]

var _root: ColorRect
var _panel: PanelContainer
var _vbox: VBoxContainer
var _sheet_panel: PanelContainer  # лист проверки состояния
var _sheet: Control
var _sheet_mode: bool = false
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

	_sheet_panel = PanelContainer.new()
	_sheet_panel.name = "SheetPanel"
	_sheet_panel.visible = false
	center.add_child(_sheet_panel)
	var parts: Dictionary = CardSheet.build(_sheet_panel, _SHEET_TEX, _SHEET_H)
	_sheet = parts["sheet"]
	CardSheet.add_flames(parts["bg"], parts["size"], _FLAMES)


# ── Доступ к стейту ───────────────────────────────────────────────────────────


# Моя ожидающая проверка Расплаты (per-player слот players[me].reckoning_pending), {} — нет.
func _reck() -> Dictionary:
	return GameState.my_player().get("reckoning_pending", {})


# Режим параллельной Расплаты (своя проверка в игроке, не в едином pending_check).
func _reck_mode() -> bool:
	return not _reck().is_empty()


# Подпись под заголовком: что привело к проверке (встреча / карта Мифа — у них нет
# карты-носителя на экране).
func _add_check_caption(pc: Dictionary) -> void:
	var src: Dictionary = pc.get("source", {})
	var src_name: String = String(src.get("name", "")).strip_edges()
	var key: String = {"encounter": "CHECK_SOURCE_ENCOUNTER", "mythos": "CHECK_SOURCE_MYTHOS"}.get(
		String(src.get("kind", "")), ""
	)
	if not key.is_empty() and not src_name.is_empty():
		var lbl: Label = UIStyle.label(
			tr(key) % tr(src_name), UIFonts.LEAD, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER
		)
		lbl.name = "Source"
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_vbox.add_child(lbl)


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
	if active:
		_sheet_mode = (String((pc.get("subject", {}) as Dictionary).get("kind", "")) == "condition")
		_panel.visible = not _sheet_mode
		_sheet_panel.visible = _sheet_mode
	UIStyle.modal_set_visible(_root, _sheet_panel if _sheet_mode else _panel, active)
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
	for c in _sheet.get_children():
		if c.name != "Background":
			_sheet.remove_child(c)
			c.queue_free()
	_tray = null
	if _sheet_mode:
		_build_sheet_content(pc)
		return

	_vbox.add_child(UIStyle.modal_title("CHECK_TITLE"))
	_add_check_caption(pc)

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
	_add_buttons(btns)


# Проверка состояния на листе: орнаментальный заголовок, крупная карта по центру,
# кубы на столе, кнопки у нижнего края (раскладка как у каста заклинания).
func _build_sheet_content(pc: Dictionary) -> void:
	var title_zone := CardSheet.zone(_sheet, "TitleZone", _Z_TITLE)
	var title := UIStyle.ornate_title("CONDITION_CHECK_TITLE", UIFonts.TITLE, UIColors.ACCENT)
	title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title_zone.add_child(title)

	var subject: Dictionary = pc.get("subject", {})
	var card_h: float = _SHEET_H * _CARD_H_FRAC
	var card_size := Vector2(card_h * GameCard.ASPECT, card_h)
	var card := GameCard.new()
	card.name = "SubjectCard"
	card.custom_minimum_size = card_size
	card.size = card_size
	card.position = (
		Vector2(_sheet.custom_minimum_size.x * _CARD_CENTER.x, _SHEET_H * _CARD_CENTER.y)
		- card_size * 0.5
	)
	card.set_font_scale(card_size.x / HandCarousel.CARD_W)  # текст в пропорции, как в веере
	card.set_card(subject)
	_sheet.add_child(card)
	CardPreview.attach_click(card, subject)

	var dice_zone := CardSheet.zone(_sheet, "DiceZone", _Z_DICE)
	_dice_box = HBoxContainer.new()
	_dice_box.name = "DiceBox"
	_dice_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_dice_box.add_theme_constant_override("separation", 6)
	_dice_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dice_zone.add_child(_dice_box)

	var btn_zone := CardSheet.zone(_sheet, "ButtonsZone", _Z_BUTTONS)
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 16)
	btns.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn_zone.add_child(btns)
	_add_buttons(btns)
	for b: Button in [_roll_btn, _apply_btn]:
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER


# Кнопки: бросок · применить.
func _add_buttons(btns: HBoxContainer) -> void:
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
