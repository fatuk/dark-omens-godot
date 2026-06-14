extends CanvasLayer

## Интерактивный каст заклинания. Видна владельцу GameState.casting_spell. Показывает
## карту заклинания (фронт), кубы spell-проверки и кнопки «Бросить кубы»/«Применить».
##
## Поток (как магазин):
##   1. «Бросить кубы» — бросок навыка заклинания (хост, единая проверка CheckFlow).
##   2. Переброс провального куба — тап по кубу: бесплатные от карт → концентрация →
##      улика (общий механизм). Карты руки (веер, Tab) активируются прямо здесь.
##   3. «Применить» — резолв фронта (onPass при успехе) + случайной рубашки; расплату
##      затем показывает cast_result_modal.
##
## Бросок/перебросы — хост-авторитетны в active_check (owner="spell"); модалка лишь
## отражает синкнутое состояние (реактивно по state_changed).

const _CARD_MIN := Vector2(290, 459)

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

var _sig: String = ""  # подпись текущего каста (перестраиваем карту только при смене)
var _last_dice: Array = []
var _last_can: bool = false

var _dice_box: HBoxContainer
var _tray: DiceTray
var _roll_btn: Button
var _apply_btn: Button


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	UIStyle.style_modal_panel(_panel)
	GameState.state_changed.connect(_refresh)
	_refresh()


# ── Доступ к стейту ───────────────────────────────────────────────────────────


# Активный каст этого игрока (иначе {}).
func _cast() -> Dictionary:
	var cs: Dictionary = GameState.casting_spell
	return cs if String(cs.get("pid", "")) == _my_id() else {}


# Активная проверка, если она spell-проверка (иначе {}).
func _chk() -> Dictionary:
	var c: Dictionary = GameState.active_check
	return c if String(c.get("owner", "")) == "spell" else {}


func _my_id() -> String:
	return String(GameState.my_player().get("user_id", ""))


func _rolled() -> bool:
	return bool(_chk().get("rolled", false))


# Доступен ли «перебросить все провальные кубы разом» (Счастливый талисман).
func _reroll_all_available() -> bool:
	if not _rolled():
		return false
	var c: Dictionary = _chk()
	return int(c.get("reroll_all_allowance", 0)) - int(c.get("reroll_all_used", 0)) > 0


# ── Обновление ────────────────────────────────────────────────────────────────


func _refresh() -> void:
	var cs: Dictionary = _cast()
	var show: bool = not cs.is_empty()
	_root.visible = show
	if not show:
		_sig = ""
		_last_dice = []
		return
	var sig: String = "%s|%d" % [String(cs.get("spell_id", "")), int(cs.get("item_index", -1))]
	if sig != _sig:
		_sig = sig
		_last_dice = []
		_build(cs)
	_render_dice()
	_update_buttons()


func _build(cs: Dictionary) -> void:
	for c in _vbox.get_children():
		c.queue_free()
	_tray = null

	var spell: Dictionary = SpellCatalog.by_id(String(cs.get("spell_id", "")))
	_vbox.add_child(UIStyle.modal_title("CAST_TITLE"))

	# Карта заклинания (фронт) по центру.
	var card_row := HBoxContainer.new()
	card_row.name = "CardRow"
	card_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_child(card_row)
	var card := GameCard.new()
	card.name = "SpellCard"
	card.custom_minimum_size = _CARD_MIN
	card.set_card(SpellCatalog.card_payload(spell))
	card_row.add_child(card)

	# Кубы spell-проверки.
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

	UIStyle.scale_modal_text(_panel)  # текст модалок крупнее (×1.5)


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
		_tray.show_pending(_cast_pool())  # рубашки до броска
		return
	var dice: Array = _chk().get("dice", [])
	var can: bool = GameState.can_reroll_now()
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
	elif can != _last_can:
		_tray.show_roll(dice, can)  # та же раскладка, сменилась кликабельность
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


# Пул кубов навыка каста до броска (для рубашек): навык + skill_mods + modifier + доп.кубы.
func _cast_pool() -> int:
	var c: Dictionary = _chk()
	var skill: String = String(c.get("skill", "lore"))
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get(skill, 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get(skill, 0))
	var bonus: int = Dice.pre_roll_bonus(c.get("active_mods", []), skill)
	return maxi(1, base + mods + int(c.get("modifier", 0)) + bonus)


# ── Действия ───────────────────────────────────────────────────────────────────


func _on_roll() -> void:
	if _rolled():
		# Повторное нажатие после броска = «перебросить все кубы» (Талисман).
		if _reroll_all_available():
			GameState.reroll_all_dice()
		return
	_roll_btn.disabled = true  # хост катит и пришлёт active_check синком
	GameState.spell_cast_roll()


func _on_die_clicked(index: int) -> void:
	if not GameState.can_reroll_now():
		return
	GameState.reroll_die(index)  # маршрутится по owner="spell" → spell_cast_reroll


func _on_apply() -> void:
	_apply_btn.disabled = true
	GameState.spell_cast_apply()  # резолв; расплату покажет cast_result_modal


func _update_buttons() -> void:
	if is_instance_valid(_roll_btn):
		if _rolled() and _reroll_all_available():
			_roll_btn.text = "ENCOUNTER_REROLL_ALL"
			_roll_btn.disabled = false
		else:
			_roll_btn.text = "CAST_ROLL"
			_roll_btn.disabled = _rolled()
	if is_instance_valid(_apply_btn):
		_apply_btn.disabled = not _rolled()  # применить можно только после броска
