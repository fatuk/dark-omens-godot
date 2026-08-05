extends CanvasLayer

## Боевая встреча. Видна активному игроку, когда current_encounter.kind ==
## "combat". Бой одноразовый: один бросок = две проверки — сначала ВОЛЯ
## (выдержать ужас), затем СИЛА (одолеть монстра). Итог — победа или нет.
## Раундов и отступления нет. Бой авторитетно у хоста (resolve_encounter).

const _C_STEP_WILL := Color(0.4, 0.7, 0.9)  # синий — шаг Воли (ужас)

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

# Персистентные лотки кубов (Воля/Сила) — переживают пересборку _vbox, чтобы спин
# не рвался. _last_* — история бросков (спин только на свежем результате).
var _will_tray: DiceTray
var _str_tray: DiceTray
var _last_will: Array = []
var _last_str: Array = []
var _last_nonce: int = 0  # метка последнего отрисованного переброса активного шага


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	GameState.state_changed.connect(_refresh)
	_refresh()


func _exit_tree() -> void:
	# Персистентные лотки, отвязанные при последней пересборке (_build) и не
	# подвешенные обратно — шаг Силы пропущен на defeatOnHorror/defeatByTrigger —
	# не удалятся с модалкой: нода без родителя не входит в дерево. Чистим вручную.
	for t in [_will_tray, _str_tray]:
		if is_instance_valid(t) and t.get_parent() == null:
			t.free()


func _refresh() -> void:
	var mine: bool = GameState.is_my_encounter_turn()
	var card: Dictionary = GameState.current_encounter
	var show_it: bool = mine and String(card.get("kind", "")) == "combat"
	UIStyle.modal_set_visible(_root, _panel, show_it)
	if show_it:
		_build(card)


func _build(card: Dictionary) -> void:
	# Сохранить персистентные лотки от удаления при пересборке колонок.
	for t in [_will_tray, _str_tray]:
		if is_instance_valid(t) and t.get_parent() != null:
			t.get_parent().remove_child(t)
	for c in _vbox.get_children():
		c.queue_free()

	var done: bool = card.has("resolution")
	# Свежий бой (Волю ещё не катили, проверка не брошена) — сброс истории спина.
	if not card.has("will") and not bool(_chk().get("rolled", false)):
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
	# «Перебросить все кубы» (Счастливый талисман) — отдельной кнопкой, пока доступен.
	if _reroll_all_available():
		btns.add_child(_button("ENCOUNTER_REROLL_ALL", func() -> void: GameState.reroll_all_dice()))
	# Кнопка по 4 состояниям: «Бросить Волю» → «Дальше» (заморозить Волю, окно карт на
	# Силу) → «Бросить Силу» → «Завершить».
	var has_will: bool = card.has("will")
	var rolled: bool = bool(_chk().get("rolled", false))
	if done:
		btns.add_child(_button("BTN_FINISH_BIG", func() -> void: GameState.finish_encounter()))
	elif not has_will:
		var k1: String = "ENCOUNTER_CONTINUE" if rolled else "COMBAT_ROLL_WILL"
		btns.add_child(_button(k1, func() -> void: GameState.resolve_encounter()))
	elif not rolled:
		btns.add_child(
			_button("COMBAT_ROLL_STRENGTH", func() -> void: GameState.resolve_encounter())
		)
	else:
		btns.add_child(_button("BTN_FINISH_BIG", func() -> void: GameState.finish_encounter()))
	UIStyle.scale_modal_text(_vbox)  # текст модалок крупнее (×1.5), пересборка — заново


# Переброс выбранного куба: заряженным жетоном (concentration/clue) или авто-приоритетом.
func _on_die_clicked(index: int) -> void:
	GameState.reroll_die(index)


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
# бросок (ре-синк) → статикой (обновить кликабельность, не рвать спин). nonce/ri —
# метка переброса из CheckFlow: при перебросе в ТО ЖЕ значение массив не меняется,
# но nonce растёт — всё равно крутим затронутый куб (иначе клик «съеденный»). nonce<0
# — кадр без переброса (замороженный снимок), метку не трогаем.
func _configure_tray(
	tray: DiceTray, dice: Array, last: Array, can: bool, nonce: int = -1, ri: int = -1
) -> void:
	var add: bool = GameState.can_add_die_now()  # заряжен +1 → кубы < 6 кликабельны
	if last.is_empty():
		tray.play_roll(dice, can, add)
	elif dice == last:
		if nonce >= 0 and nonce != _last_nonce and ri >= 0 and ri < dice.size():
			tray.reroll_die(ri, int(dice[ri]), can, add)  # переброс в ту же грань — всё равно спин
		else:
			tray.show_roll(dice, can, add)
	else:
		var diff: int = _single_diff(last, dice)
		if diff >= 0:
			tray.reroll_die(diff, int(dice[diff]), can, add)  # переброс одного — крутится он
		elif last.size() == dice.size():
			tray.play_roll(dice, can, add)  # несколько изменилось (reroll-all) — спин всех
		else:
			tray.show_roll(dice, can, add)  # размер изменился (докинули кубы) — статикой
	if nonce >= 0:
		_last_nonce = nonce


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


# Пул d6 проверки (как у хоста в CheckFlow.pool) — для рубашек до броска.
func _check_pool(skill: String, modifier: int) -> int:
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get(skill, 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get(skill, 0))
	# Доп. кубы от применённых карт (рубашки растут заранее).
	var amods: Array = _chk().get("active_mods", [])
	return maxi(1, base + mods + modifier + Dice.pre_roll_bonus(amods, skill))


# Локализованное имя навыка: "will" → «Воля», "influence" → «Влияние» и т.д.
func _skill_name(skill: String) -> String:
	return tr("SKILL_" + skill.to_upper())


# Подпись шага: «Шаг N: <Навык> ±M» (модификатор монстра — видно, почему кубов мало).
func _step_label(step_key: String, test: Dictionary, default_skill: String) -> String:
	var skill: String = String(test.get("skill", default_skill))
	var txt: String = tr(step_key) % _skill_name(skill)
	var mod: int = int(test.get("modifier", 0))
	if mod != 0:
		txt += "  %s%d" % ["+" if mod > 0 else "−", absi(mod)]
	return txt


func _will_pool(card: Dictionary) -> int:
	var h: Dictionary = card.get("horror", {})
	return _check_pool(String(h.get("skill", "will")), int(h.get("modifier", 0)))


func _str_pool(card: Dictionary) -> int:
	var c: Dictionary = card.get("combat", {})
	return _check_pool(String(c.get("skill", "strength")), int(c.get("modifier", 0)))


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
			_C_STEP_WILL
		)
	)
	return col


func _center_col(card: Dictionary) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.name = "CenterColumn"
	col.add_theme_constant_override("separation", 6)
	col.custom_minimum_size = Vector2(260, 0)

	var c: Dictionary = _chk()  # активная проверка боя (Воля или Сила)
	var has_will: bool = card.has("will")  # Воля заморожена → идёт шаг Силы
	var done: bool = card.has("resolution")
	var rolled: bool = bool(c.get("rolled", false))
	var can: bool = _can_reroll()

	# Шаг 1 — проверка ужаса (обычно Воля, но монстр может тестировать иной навык,
	# напр. Влияние) — подпись по РЕАЛЬНОМУ навыку + модификатор монстра.
	col.add_child(
		_lbl(_step_label("COMBAT_STEP1", card.get("horror", {}), "will"), 15, _C_STEP_WILL)
	)
	_will_tray = _ensure_tray(_will_tray)
	col.add_child(_will_tray)
	if has_will:  # заморожен снимок — не кликабелен
		var wd: Array = (card["will"] as Dictionary).get("dice", [])
		_configure_tray(_will_tray, wd, _last_will, false)
		_last_will = wd.duplicate()
		_will_line(col, int((card["will"] as Dictionary).get("successes", 0)), card)
	elif rolled:  # Воля брошена (живая) — можно перебрасывать
		var wd: Array = c.get("dice", [])
		_configure_tray(
			_will_tray,
			wd,
			_last_will,
			can,
			int(c.get("reroll_nonce", 0)),
			int(c.get("reroll_index", -1))
		)
		_last_will = wd.duplicate()
		_will_line(col, int(c.get("successes", 0)), card)
		_reroll_hint(col, can)
	else:  # рубашки до броска Воли
		_will_tray.show_pending(_will_pool(card))
		_last_will = []

	# Шаг 2 — атака (обычно Сила). Пропускаем, если монстр повержен на шаге 1 (спец-
	# способность defeatOnPass — напр. Crazed Mob от пройденной проверки Влияния).
	if (
		has_will
		and not bool(card.get("defeated_on_horror", false))
		and not bool(card.get("defeated_by_trigger", false))
	):
		col.add_child(
			_lbl(
				_step_label("COMBAT_STEP2", card.get("combat", {}), "strength"), 15, UIColors.ACCENT
			)
		)
		_str_tray = _ensure_tray(_str_tray)
		col.add_child(_str_tray)
		if done:  # зафиксированный итог Силы
			var s: Dictionary = (card["resolution"] as Dictionary).get("strength", {})
			var sd: Array = s.get("dice", [])
			_configure_tray(_str_tray, sd, _last_str, false)
			_last_str = sd.duplicate()
			var r: Dictionary = card["resolution"]
			_str_line(
				col, int(s.get("successes", 0)), int(r.get("dealt", 0)), int(r.get("hp_loss", 0))
			)
		elif rolled:  # Сила брошена (живая) — превью исхода, можно перебрасывать
			var sd: Array = c.get("dice", [])
			_configure_tray(
				_str_tray,
				sd,
				_last_str,
				can,
				int(c.get("reroll_nonce", 0)),
				int(c.get("reroll_index", -1))
			)
			_last_str = sd.duplicate()
			var hits: int = int(c.get("successes", 0))
			var dmg: int = int((card.get("combat", {}) as Dictionary).get("damage", 0))
			_str_line(col, hits, hits, maxi(0, dmg - hits))
			_reroll_hint(col, can)
		else:
			_str_tray.show_pending(_str_pool(card))
			_last_str = []

	# Итог: финальный (done) или превью по активной Силе.
	if done or (has_will and rolled):
		var won: bool
		if done:
			won = bool((card["resolution"] as Dictionary).get("won", false))
		else:
			won = maxi(0, int(card.get("health", 0)) - int(c.get("successes", 0))) <= 0
		col.add_child(
			_lbl(
				tr("COMBAT_WIN" if won else "COMBAT_LOSS"),
				18,
				UIColors.SUCCESS if won else UIColors.DANGER,
				HORIZONTAL_ALIGNMENT_CENTER
			)
		)
	return col


# Активная проверка боя (active_check, если владелец — бой; иначе пусто).
func _chk() -> Dictionary:
	var c: Dictionary = GameState.active_check
	return c if String(c.get("owner", "")) == "combat" else {}


# Бесплатные перебросы от активированных карт (allowance − использовано).
func _free_rerolls() -> int:
	var c: Dictionary = _chk()
	return maxi(0, int(c.get("reroll_allowance", 0)) - int(c.get("rerolls_used", 0)))


# Доступен ли переброс: карта (бесплатно) / концентрация / улика, пока бой не зафиксирован.
func _can_reroll() -> bool:
	if bool(GameState.current_encounter.get("committed", false)):
		return false
	return GameState.can_reroll_now()


# Доступен ли «перебросить все провальные кубы разом» (Талисман) на текущем шаге.
func _reroll_all_available() -> bool:
	if bool(GameState.current_encounter.get("committed", false)):
		return false
	var c: Dictionary = _chk()
	if not bool(c.get("rolled", false)):
		return false
	return int(c.get("reroll_all_allowance", 0)) - int(c.get("reroll_all_used", 0)) > 0


# Строка под кубами Воли: успехи + потеря рассудка (max(0, horror.damage − успехи)).
func _will_line(col: VBoxContainer, succ: int, card: Dictionary) -> void:
	var hd: int = int((card.get("horror", {}) as Dictionary).get("damage", 0))
	var sl: int = maxi(0, hd - succ)
	var line: String = "%s: %d" % [tr("ENCOUNTER_SUCCESSES"), succ]
	if sl > 0:
		line += " · −%d %s" % [sl, tr("COMBAT_SANITY")]
	col.add_child(_lbl(line, 12, UIColors.TEXT))


# Строка под кубами Силы: успехи + урон стойкости + потеря здоровья.
func _str_line(col: VBoxContainer, succ: int, dealt: int, hp_loss: int) -> void:
	col.add_child(
		_lbl(
			"%s: %d · %s −%d" % [tr("ENCOUNTER_SUCCESSES"), succ, tr("SIDEBAR_TOUGHNESS"), dealt],
			12,
			UIColors.TEXT
		)
	)
	if hp_loss > 0:
		col.add_child(_lbl("−%d %s" % [hp_loss, tr("COMBAT_HEALTH")], 12, UIColors.DANGER))


# Подсказка о перебросе живого шага: карта (бесплатно) → концентрация → улика.
func _reroll_hint(col: VBoxContainer, can: bool) -> void:
	# can → готовы к перебросу (бесплатно или заряжен жетон) → нажать куб. Иначе, если
	# есть концентрация/улика — подсказать перетащить жетон.
	var free: int = _free_rerolls()
	var txt: String = ""
	if can:
		txt = (tr("ENCOUNTER_REROLL_FREE") % free) if free > 0 else tr("ENCOUNTER_REROLL_TAP")
	elif GameState.has_reroll_resource():
		txt = tr("ENCOUNTER_REROLL_DRAG")
	if not txt.is_empty():
		col.add_child(_lbl(txt, 11, UIColors.MUTED))


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
