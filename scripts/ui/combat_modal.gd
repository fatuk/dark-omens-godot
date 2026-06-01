extends CanvasLayer

## Боевая встреча. Видна активному игроку, когда current_encounter.kind ==
## "combat". Бой одноразовый: один бросок = две проверки — сначала ВОЛЯ
## (выдержать ужас), затем СИЛА (одолеть монстра). Итог — победа или нет.
## Раундов и отступления нет. Бой авторитетно у хоста (resolve_encounter).

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

# Персистентные лотки кубов (Воля/Сила) — переживают пересборку _vbox, чтобы спин
# не рвался. _last_* — история бросков (спин только на свежем результате).
var _will_tray: DiceTray
var _str_tray: DiceTray
var _last_will: Array = []
var _last_str: Array = []


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	GameState.state_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var mine: bool = GameState.is_my_encounter_turn()
	var card: Dictionary = GameState.current_encounter
	var show_it: bool = mine and String(card.get("kind", "")) == "combat"
	_root.visible = show_it
	if show_it:
		_build(card)


func _build(card: Dictionary) -> void:
	# Сохранить персистентные лотки от удаления при пересборке колонок.
	for t in [_will_tray, _str_tray]:
		if is_instance_valid(t) and t.get_parent() != null:
			t.get_parent().remove_child(t)
	for c in _vbox.get_children():
		c.queue_free()

	var res: Dictionary = card.get("resolution", {})
	var done: bool = not res.is_empty()
	# Свежий бой (Волю ещё не катили) — сброс истории бросков.
	if card.get("will", {}).is_empty() and not done:
		_last_will = []
		_last_str = []

	_vbox.add_child(UIStyle.modal_title(String(card.get("monsterName", "ENCOUNTER_TITLE"))))

	var cols := HBoxContainer.new()
	cols.name = "Columns"
	cols.add_theme_constant_override("separation", 20)
	cols.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_child(cols)
	cols.add_child(_player_col())
	cols.add_child(_center_col(card))
	cols.add_child(_monster_col(card))

	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 12)
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_child(btns)
	if done:
		btns.add_child(_button("BTN_FINISH_BIG", func() -> void: GameState.finish_encounter()))
	else:
		# Одна кнопка катит текущий шаг: сначала Воля, затем Сила (отдельные броски).
		var key: String = "COMBAT_ROLL_WILL" if not card.has("will") else "COMBAT_ROLL_STRENGTH"
		btns.add_child(_button(key, func() -> void: GameState.resolve_encounter()))
	UIStyle.scale_modal_text(_vbox)  # текст модалок крупнее (×1.5), пересборка — заново


# Переброс выбранного куба активной проверки боя (Воля/Сила) за 1 концентрацию.
func _on_die_clicked(index: int) -> void:
	GameState.reroll_encounter(index)


# Лоток создаётся лениво и переиспользуется (персистентный — переживает пересборку
# колонок). Только активный ряд (Воля до Силы, либо Сила) кликабелен.
func _ensure_tray(t: DiceTray) -> DiceTray:
	if is_instance_valid(t):
		return t
	var nt := DiceTray.new()
	nt.name = "DiceTray"
	nt.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	nt.die_selected.connect(_on_die_clicked)
	return nt


# Показать бросок: свежий → спин всех; переброс одного куба → крутится он; тот же
# бросок (ре-синк) → статикой (обновить кликабельность, не рвать спин).
func _configure_tray(tray: DiceTray, dice: Array, last: Array, can: bool) -> void:
	if last.is_empty():
		tray.play_roll(dice, can)
	elif dice == last:
		tray.show_roll(dice, can)
	else:
		var diff: int = _single_diff(last, dice)
		if diff >= 0:
			tray.reroll_die(diff, int(dice[diff]), can)
		else:
			tray.show_roll(dice, can)


# Индекс единственного отличия наборов (-1 если нет / несколько / разный размер).
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


# Пул d6 проверки (как у хоста в EncounterFlow._roll_check) — для рубашек до броска.
func _check_pool(skill: String, modifier: int) -> int:
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get(skill, 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get(skill, 0))
	return maxi(1, base + mods + modifier)


func _will_pool(card: Dictionary) -> int:
	var h: Dictionary = card.get("horror", {})
	return _check_pool(String(h.get("skill", "will")), int(h.get("modificator", 0)))


func _str_pool(card: Dictionary) -> int:
	var c: Dictionary = card.get("combat", {})
	return _check_pool(String(c.get("skill", "strength")), int(c.get("modificator", 0)))


# ── Колонки ───────────────────────────────────────────────────────────────────


func _player_col() -> VBoxContainer:
	var p: Dictionary = GameState.my_player()
	var col := VBoxContainer.new()
	col.name = "PlayerColumn"
	col.add_theme_constant_override("separation", 4)
	col.custom_minimum_size = Vector2(190, 0)
	col.add_child(_lbl(String(p.get("name", "?")), 16, UIColors.TEXT))
	col.add_child(
		_lbl(
			"%s: %d / %d" % [tr("COMBAT_HEALTH"), int(p.get("hp", 0)), int(p.get("hp_max", 0))],
			13,
			UIColors.SUCCESS
		)
	)
	col.add_child(
		_lbl(
			(
				"%s: %d / %d"
				% [tr("COMBAT_SANITY"), int(p.get("sanity", 0)), int(p.get("sanity_max", 0))]
			),
			13,
			Color(0.4, 0.7, 0.9)
		)
	)
	return col


func _center_col(card: Dictionary) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.name = "CenterColumn"
	col.add_theme_constant_override("separation", 6)
	col.custom_minimum_size = Vector2(260, 0)

	var will: Dictionary = card.get("will", {})
	var has_will: bool = not will.is_empty()
	var res: Dictionary = card.get("resolution", {})
	var done: bool = not res.is_empty()
	var foc: int = int(GameState.my_player().get("concentration", 0))
	var can_focus: bool = foc > 0 and not bool(card.get("committed", false))

	# Шаг 1 — Воля (ужас): отдельный бросок. Перебрасывается, пока не катнули Силу.
	col.add_child(_lbl(tr("COMBAT_WILL"), 15, Color(0.4, 0.7, 0.9)))
	_will_tray = _ensure_tray(_will_tray)
	col.add_child(_will_tray)
	if has_will:
		var wd: Array = will.get("dice", [])
		_configure_tray(_will_tray, wd, _last_will, can_focus and not done)
		_last_will = wd.duplicate()
		var sl: int = int(card.get("sanity_loss", 0))
		var line: String = "%s: %d" % [tr("ENCOUNTER_SUCCESSES"), int(will.get("successes", 0))]
		if sl > 0:
			line += " · −%d %s" % [sl, tr("COMBAT_SANITY")]
		col.add_child(_lbl(line, 12, UIColors.TEXT))
	else:
		_will_tray.show_pending(_will_pool(card))  # рубашки до броска Воли
		_last_will = []

	# Шаг 2 — Сила (атака): показываем ТОЛЬКО после броска Воли (последовательно).
	if has_will:
		col.add_child(_lbl(tr("COMBAT_STRENGTH"), 15, UIColors.ACCENT))
		_str_tray = _ensure_tray(_str_tray)
		col.add_child(_str_tray)
		if done:
			var s: Dictionary = res.get("strength", {})
			var sd: Array = s.get("dice", [])
			_configure_tray(_str_tray, sd, _last_str, can_focus)
			_last_str = sd.duplicate()
			col.add_child(
				_lbl(
					(
						"%s: %d · %s −%d"
						% [
							tr("ENCOUNTER_SUCCESSES"),
							int(s.get("successes", 0)),
							tr("SIDEBAR_TOUGHNESS"),
							int(res.get("dealt", 0))
						]
					),
					12,
					UIColors.TEXT
				)
			)
			if int(res.get("hp_loss", 0)) > 0:
				col.add_child(
					_lbl("−%d %s" % [int(res["hp_loss"]), tr("COMBAT_HEALTH")], 12, UIColors.DANGER)
				)
		else:
			_str_tray.show_pending(_str_pool(card))  # рубашки до броска Силы
			_last_str = []

	# Итог
	if done:
		var won: bool = bool(res.get("won", false))
		col.add_child(
			_lbl(
				tr("COMBAT_WIN" if won else "COMBAT_LOSS"),
				18,
				UIColors.SUCCESS if won else UIColors.DANGER,
				HORIZONTAL_ALIGNMENT_CENTER
			)
		)
	return col


func _monster_col(card: Dictionary) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.name = "MonsterColumn"
	col.add_theme_constant_override("separation", 4)
	col.custom_minimum_size = Vector2(190, 0)
	var combat: Dictionary = card.get("combat", {})
	var horror: Dictionary = card.get("horror", {})
	# enc.health — здоровье монстра НА СТАРТЕ боя; после атаки показываем итоговое
	# (resolution.health_after), т.к. эффекты применяются только при завершении.
	var res: Dictionary = card.get("resolution", {})
	var mon_health: int = (
		int(res.get("health_after", card.get("health", 0)))
		if not res.is_empty()
		else int(card.get("health", 0))
	)
	col.add_child(
		_lbl(
			"%s: %d / %d" % [tr("SIDEBAR_TOUGHNESS"), mon_health, int(card.get("toughness", 0))],
			14,
			UIColors.WARNING
		)
	)
	col.add_child(
		_lbl(
			(
				"%s: %d · %s: %d"
				% [
					tr("COMBAT_MDMG"),
					int(combat.get("damage", 0)),
					tr("SIDEBAR_HORROR"),
					int(horror.get("damage", 0))
				]
			),
			12,
			UIColors.TEXT
		)
	)
	var ab: String = String(card.get("abilityKey", ""))
	if not ab.is_empty():
		var al := _lbl(ab, 11, UIColors.MUTED)  # ключ перевода способности
		al.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		al.custom_minimum_size = Vector2(190, 0)
		col.add_child(al)
	return col


# ── Хелперы ───────────────────────────────────────────────────────────────────


func _lbl(
	text: String, size: int, color: Color, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT
) -> Label:
	var l := Label.new()
	l.name = "Label"
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	return l


func _button(key: String, on_press: Callable, color: Color = UIColors.ACCENT) -> Button:
	var b := Button.new()
	b.name = "Button"
	b.text = key
	UIStyle.style_button(b, color)
	b.pressed.connect(on_press)
	return b
