extends CanvasLayer

## Боевая встреча. Видна активному игроку, когда current_encounter.kind ==
## "combat". Бой одноразовый: один бросок = две проверки — сначала ВОЛЯ
## (выдержать ужас), затем СИЛА (одолеть монстра). Итог — победа или нет.
## Раундов и отступления нет. Бой авторитетно у хоста (RESOLVE_ENCOUNTER).
##
## Вид — карта монстра: крупный арт с наложенными числами (здоровье/стойкость
## сверху справа, ужас слева снизу, урон справа снизу, способность по центру
## снизу), под ним ОДИН лоток кубов активного шага и одна кнопка. Шаги идут
## подряд: бросок Воли → «Применить» (заморозка, окно карт на Силу) → бросок
## Силы → «Завершить». Какой шаг идёт — подсказывает пульс числа: синий ужас
## на Воле, красный урон на Силе. Статы сыщика в окне не дублируем — они на
## панели сыщика под затемнением, как у любой другой модалки.

const _C_WILL := UIColors.WILL  # синий — шаг Воли (ужас)
const _C_STR := UIColors.STRENGTH  # красный — шаг Силы (урон)
const _C_HITS := UIColors.SUCCESS  # успехи броска, гасящие число монстра

const _ART_SIZE := Vector2(600, 496)  # арт монстра @2× 1200×992 → 1×
const _ART_PAD := 14.0  # инсет чисел от края арта
const _FS_BIG := 44  # ужас/урон
const _FS_HP := 40  # здоровье/стойкость
const _FS_HITS := 20  # успехи
const _FS_ABILITY := 15
const _FS_LOSS := 22  # «−2 Рассудок» под лотком
const _PULSE_PERIOD := 0.9  # сек на полупериод пульса
const _REVEAL_FADE := 0.25  # проявление итога, когда кубы осели

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

# Персистентные узлы — переживают пересборку _vbox на каждом синке, чтобы не рвать
# спин кубов и пульс числа. Лотки Воли/Силы отдельные: у каждого своя история
# бросков (спин только на свежем результате).
var _art: Control  # карта монстра с наложенными числами (см. _ensure_art)
var _art_for: String = ""  # id монстра, под которого собран _art
var _will_tray: DiceTray
var _str_tray: DiceTray
var _last_will: Array = []
var _last_str: Array = []
var _last_nonce: int = 0  # метка последнего отрисованного переброса активного шага
var _pulse_tw: Tween = null
var _pulse_on: Label = null  # какое число пульсирует сейчас (null — никакое)


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	_panel.custom_minimum_size.x = _ART_SIZE.x + 160.0
	# Окно меняет размер плавно, а не скачком: по высоте (исход боя, второй шаг
	# проверки) и по ширине (пул кубов шире арта монстра).
	SmoothSize.wrap(_panel)
	GameState.state_changed.connect(_refresh)
	_refresh()


func _exit_tree() -> void:
	# Персистентные ноды, отвязанные при последней пересборке (_build) и не
	# подвешенные обратно, не удалятся с модалкой: нода без родителя не входит в
	# дерево. Чистим вручную.
	for t in [_will_tray, _str_tray, _art]:
		if is_instance_valid(t) and t.get_parent() == null:
			t.free()


func _refresh() -> void:
	var mine: bool = GameState.is_my_encounter_turn()
	var card: Dictionary = GameState.current_encounter
	var show_it: bool = mine and String(card.get("kind", "")) == "combat"
	UIStyle.modal_set_visible(_root, _panel, show_it)
	if show_it:
		_build(card)
	else:
		_set_pulse(null)


func _build(card: Dictionary) -> void:
	# Сохранить персистентные ноды от удаления при пересборке.
	for t in [_will_tray, _str_tray, _art]:
		if is_instance_valid(t) and t.get_parent() != null:
			t.get_parent().remove_child(t)
	for c in _vbox.get_children():
		c.queue_free()

	var c: Dictionary = _chk()  # активная проверка боя (Воля или Сила)
	var has_will: bool = card.has("will")  # Воля заморожена → идёт шаг Силы
	var done: bool = card.has("resolution")
	var rolled: bool = bool(c.get("rolled", false))
	var can: bool = _can_reroll()
	# Свежий бой (Волю ещё не катили, проверка не брошена) — сброс истории спина.
	if not has_will and not rolled:
		_last_will = []
		_last_str = []
	# Шаг Силы есть, если монстр не повержен на шаге 1 (defeatOnPass / триггер карты)
	# и у него вообще есть атака (Призрак: combat.skill none → бой кончается Волей).
	var skip_str: bool = (
		bool(card.get("defeated_on_horror", false))
		or bool(card.get("defeated_by_trigger", false))
		or bool(card.get("no_strength_step", false))
	)
	var str_step: bool = has_will and not skip_str
	# Кубы активного шага ещё крутятся — итог (успехи на карте, потери) держим
	# скрытым, иначе он виден раньше выпавших граней. Проявит _on_roll_settled.
	var masked: bool = false

	_vbox.add_child(
		UIStyle.ornate_title(
			String(card.get("monsterName", "ENCOUNTER_TITLE")), UIStyle.MODAL_FS_TITLE
		)
	)
	_vbox.add_child(_ensure_art(card))

	# ── Лоток активного шага ──
	if not has_will:
		_will_tray = _ensure_tray(_will_tray)
		_vbox.add_child(_will_tray)
		if rolled:  # Воля брошена (живая) — можно перебрасывать
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
		else:  # до броска Воли — полный пул с пометками
			var wp: Dictionary = _will_pool(card)
			_will_tray.set_pool_marks(int(wp["bonus"]), int(wp["blocked"]))
			_will_tray.show_pending(
				int(wp["pool"]), String((card.get("horror", {}) as Dictionary).get("skill", "will"))
			)
	elif str_step:
		_str_tray = _ensure_tray(_str_tray)
		_vbox.add_child(_str_tray)
		if done:  # зафиксированный итог Силы
			var s: Dictionary = (card["resolution"] as Dictionary).get("strength", {})
			var sd: Array = s.get("dice", [])
			_configure_tray(_str_tray, sd, _last_str, false)
			_last_str = sd.duplicate()
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
		else:  # pre-roll Силы — окно карт усиления (оружие +Сила до броска)
			var sp: Dictionary = _str_pool(card)
			_str_tray.set_pool_marks(int(sp["bonus"]), int(sp["blocked"]))
			_str_tray.show_pending(
				int(sp["pool"]),
				String((card.get("combat", {}) as Dictionary).get("skill", "strength"))
			)
			_last_str = []
	if not done and rolled:
		var active: DiceTray = _str_tray if str_step else _will_tray
		masked = is_instance_valid(active) and active.is_rolling()
	_update_art(card, str_step, done, masked)

	# ── Что будет с сыщиком, если принять расклад: потери по итогу шагов ──
	_loss_lines(card, str_step, done, masked)

	# ── Кнопки ──
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 12)
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_child(btns)
	# «Перебросить все кубы» (Счастливый талисман) — отдельной кнопкой, пока доступен.
	if _reroll_all_available():
		btns.add_child(
			_button("ENCOUNTER_REROLL_ALL", func() -> void: GameState.act(RelayActions.REROLL_ALL))
		)
	# Одна кнопка по состоянию: «Бросить кубы» (Воля) → «Применить» (заморозить Волю,
	# сразу шаг Силы в pre-roll) → «Бросить кубы» (Сила) → «Завершить».
	if done or (str_step and rolled):
		btns.add_child(
			_button("BTN_FINISH_BIG", func() -> void: GameState.act(RelayActions.FINISH_ENCOUNTER))
		)
	else:
		var key: String = "CAST_APPLY" if (not has_will and rolled) else "COMBAT_ROLL"
		btns.add_child(_button(key, func() -> void: GameState.act(RelayActions.RESOLVE_ENCOUNTER)))


# ── Карта монстра ─────────────────────────────────────────────────────────────


# Арт с наложенными числами. Собирается один раз на монстра (id) и переиспользуется
# между синками — иначе пульс перезапускался бы на каждом перебросе.
func _ensure_art(card: Dictionary) -> Control:
	var mid: String = String(card.get("monsterId", ""))
	if is_instance_valid(_art) and _art_for == mid:
		return _art
	if is_instance_valid(_art):
		_set_pulse(null)
		_art.free()
	_art_for = mid

	var frame := Control.new()
	frame.name = "MonsterCard"
	frame.custom_minimum_size = _ART_SIZE
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.clip_contents = true

	var tex: Texture2D = MonsterCatalog.card_art(mid)
	var bg := ColorRect.new()  # подложка: под артом с прозрачностью и вместо него
	bg.name = "ArtBg"
	bg.color = UIColors.ART_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(bg)
	if tex != null:
		var art := TextureRect.new()
		art.name = "Art"
		art.texture = tex
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(art)
	# Здоровье / стойкость — сверху справа.
	var hp := _overlay_lbl("Hp", _FS_HP, UIColors.WARNING, HORIZONTAL_ALIGNMENT_RIGHT)
	hp.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	hp.offset_left = _ART_PAD
	hp.offset_right = -_ART_PAD
	hp.offset_top = _ART_PAD
	frame.add_child(hp)

	# Ужас (шаг Воли) — слева снизу; урон (шаг Силы) — справа снизу. Число крупно,
	# успехи броска мелко зелёным рядом — они и гасят это число (3 −2 = потеря 1).
	frame.add_child(_stat_block("Horror", _C_WILL, false))
	frame.add_child(_stat_block("Damage", _C_STR, true))

	# Способность монстра — по центру снизу, между числами.
	var ab := _overlay_lbl("Ability", _FS_ABILITY, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	ab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ab.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	ab.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	ab.offset_left = 120
	ab.offset_right = -120
	ab.offset_top = -80
	ab.offset_bottom = -_ART_PAD
	frame.add_child(ab)

	_art = frame
	return frame


# Блок «число монстра − успехи» в нижнем углу арта. right — правый угол (урон).
func _stat_block(node_name: String, color: Color, right: bool) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.name = node_name
	box.add_theme_constant_override("separation", 4)
	box.alignment = BoxContainer.ALIGNMENT_END if right else BoxContainer.ALIGNMENT_BEGIN
	box.set_anchors_and_offsets_preset(
		Control.PRESET_BOTTOM_RIGHT if right else Control.PRESET_BOTTOM_LEFT
	)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN if right else Control.GROW_DIRECTION_END
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	box.offset_bottom = -_ART_PAD + 6
	if right:
		box.offset_right = -_ART_PAD
	else:
		box.offset_left = _ART_PAD
	var num := _overlay_lbl("Value", _FS_BIG, color, HORIZONTAL_ALIGNMENT_CENTER)
	num.resized.connect(func() -> void: num.pivot_offset = num.size / 2.0)  # пульс из центра
	var hits := _overlay_lbl("Hits", _FS_HITS, _C_HITS, HORIZONTAL_ALIGNMENT_LEFT)
	hits.size_flags_vertical = Control.SIZE_SHRINK_END
	box.add_child(num)
	box.add_child(hits)
	return box


# Подпись поверх арта: чёрная тень со сдвигом 1px, чтобы читалась на любом фоне
# без затемнения самого арта; клики — сквозь.
func _overlay_lbl(node_name: String, fs: int, color: Color, align: HorizontalAlignment) -> Label:
	var l := _lbl("", fs, color, align)
	l.name = node_name
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_color_override("font_shadow_color", Color.BLACK)
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


# Живые значения на карте + какой из шагов пульсирует.
func _update_art(card: Dictionary, str_step: bool, done: bool, masked: bool = false) -> void:
	var combat: Dictionary = card.get("combat", {})
	var horror: Dictionary = card.get("horror", {})
	# enc.health — здоровье монстра НА СТАРТЕ боя; после атаки показываем итоговое
	# (resolution.health_after), т.к. эффекты применяются только при завершении.
	# Успехи каждого шага: замороженные (will / resolution.strength) либо живые из
	# активной проверки; до броска — нет (-1 → пусто).
	var res: Dictionary = card.get("resolution", {})
	var c: Dictionary = _chk()
	var live: int = (
		int(c.get("successes", 0)) if bool(c.get("rolled", false)) and not masked else -1
	)
	# Здоровье монстра: на старте боя; на шаге Силы — превью после удара (успехи бьют
	# стойкость), по итогу — зафиксированное. Итог боя виден прямо на карте.
	var mon_health: int = int(card.get("health", 0))
	var will_damages: bool = bool(horror.get("damageWithSuccesses", false))
	if not res.is_empty():
		mon_health = int(res.get("health_after", mon_health))
	elif str_step and live >= 0:
		mon_health = maxi(0, mon_health - live - int(card.get("will_dealt", 0)))
	elif will_damages and not card.has("will") and live >= 0:
		mon_health = maxi(0, mon_health - live)  # превью: успехи Воли бьют стойкость
	(_art.get_node("Hp") as Label).text = "%d/%d" % [mon_health, int(card.get("toughness", 0))]
	var will_hits: int = (
		int((card["will"] as Dictionary).get("successes", 0)) if card.has("will") else live
	)
	if bool(card.get("no_horror_step", false)):
		will_hits = -1  # ужаса нет — пустая клетка, не «−0»
	var str_hits: int = -1
	if bool(card.get("no_strength_step", false)):
		str_hits = -1  # атаки не было — пустая клетка, не «−0»
	elif done:
		str_hits = int((res.get("strength", {}) as Dictionary).get("successes", 0))
	elif str_step:
		str_hits = live
	_set_stat(_art.get_node("Horror"), horror, will_hits)
	_set_stat(_art.get_node("Damage"), combat, str_hits)
	var ab: Label = _art.get_node("Ability")
	var key: String = String(card.get("abilityKey", ""))
	ab.text = tr(key) if not key.is_empty() else ""

	# Пульс: шаг Воли — ужас (синий), шаг Силы — урон (красный), итог — тишина.
	if done:
		_set_pulse(null)
	elif str_step:
		_set_pulse(_art.get_node("Damage/Value"))
	else:
		_set_pulse(_art.get_node("Horror/Value"))


func _set_stat(box: HBoxContainer, test: Dictionary, hits: int) -> void:
	(box.get_node("Value") as Label).text = str(int(test.get("damage", 0)))
	(box.get_node("Hits") as Label).text = "" if hits < 0 else "−%d" % hits


# Пульс числа активного шага: плавное дыхание масштаба и яркости. Тот же target —
# не перезапускаем (иначе на каждом синке дёргалось бы с нуля).
func _set_pulse(target: Label) -> void:
	if target == _pulse_on and (target == null or (_pulse_tw != null and _pulse_tw.is_valid())):
		return
	if _pulse_tw != null and _pulse_tw.is_valid():
		_pulse_tw.kill()
	_pulse_tw = null
	if is_instance_valid(_pulse_on):
		_pulse_on.scale = Vector2.ONE
		_pulse_on.modulate = Color.WHITE
	_pulse_on = target
	if target == null:
		return
	_pulse_tw = target.create_tween().set_loops()
	_pulse_tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_pulse_tw.tween_property(target, "scale", Vector2(1.18, 1.18), _PULSE_PERIOD)
	_pulse_tw.parallel().tween_property(target, "modulate", Color(1.35, 1.35, 1.35), _PULSE_PERIOD)
	_pulse_tw.tween_property(target, "scale", Vector2.ONE, _PULSE_PERIOD)
	_pulse_tw.parallel().tween_property(target, "modulate", Color.WHITE, _PULSE_PERIOD)


# ── Кубы ──────────────────────────────────────────────────────────────────────


# Переброс выбранного куба: заряженным жетоном (concentration/clue) или авто-приоритетом.
func _on_die_clicked(index: int) -> void:
	GameState.dice.tap(index)


# Лоток создаётся лениво и переиспользуется (персистентный — переживает пересборку).
func _ensure_tray(t: DiceTray) -> DiceTray:
	if is_instance_valid(t):
		return t
	var nt := DiceTray.new()
	nt.name = "DiceTray"
	nt.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	nt.die_selected.connect(_on_die_clicked)
	nt.roll_settled.connect(_on_roll_settled)
	return nt


# Кубы осели — пересобрать окно уже с итогом (лоток не перекрутится: тот же бросок
# рисуется статикой) и плавно проявить то, что было скрыто на время спина.
func _on_roll_settled() -> void:
	if not _root.visible or String(GameState.current_encounter.get("kind", "")) != "combat":
		return
	if not GameState.is_my_encounter_turn():
		return
	_build(GameState.current_encounter)
	var reveal: Array = [_art.get_node("Horror/Hits"), _art.get_node("Damage/Hits")]
	for n in _vbox.get_children():
		if String(n.name).begins_with("Loss"):
			reveal.append(n)
	for n_v: Variant in reveal:
		var n: CanvasItem = n_v
		n.modulate.a = 0.0
		n.create_tween().tween_property(n, "modulate:a", 1.0, _REVEAL_FADE)


# Показать бросок: свежий → спин всех; переброс одного куба → крутится он; тот же
# бросок (ре-синк) → статикой (обновить кликабельность, не рвать спин). nonce/ri —
# метка переброса из CheckFlow: при перебросе в ТО ЖЕ значение массив не меняется,
# но nonce растёт — всё равно крутим затронутый куб (иначе клик «съеденный»). nonce<0
# — кадр без переброса (замороженный снимок), метку не трогаем.
func _configure_tray(
	tray: DiceTray, dice: Array, last: Array, can: bool, nonce: int = -1, ri: int = -1
) -> void:
	var add: bool = GameState.dice.can_add()  # заряжен +1 → кубы < 6 кликабельны
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
# Разбор пула: {pool, bonus, blocked} — см. DiceTray.set_pool_marks.
func _pool(skill: String, modifier: int) -> Dictionary:
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get(skill, 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get(skill, 0))
	# Доп. кубы от применённых карт (рубашки растут заранее).
	var amods: Array = _chk().get("active_mods", [])
	var extra: int = Dice.pre_roll_bonus(amods, skill)
	return Dice.pool_breakdown(base, mods, modifier, extra)


func _will_pool(card: Dictionary) -> Dictionary:
	var h: Dictionary = card.get("horror", {})
	return _pool(String(h.get("skill", "will")), int(h.get("modifier", 0)))


func _str_pool(card: Dictionary) -> Dictionary:
	var c: Dictionary = card.get("combat", {})
	return _pool(String(c.get("skill", "strength")), int(c.get("modifier", 0)))


# Активная проверка боя (active_check, если владелец — бой; иначе пусто).
func _chk() -> Dictionary:
	var c: Dictionary = GameState.active_check
	return c if String(c.get("owner", "")) == "combat" else {}


# Доступен ли переброс: карта (бесплатно) / концентрация / улика, пока бой не зафиксирован.
func _can_reroll() -> bool:
	if bool(GameState.current_encounter.get("committed", false)):
		return false
	return GameState.dice.can_reroll()


# Доступен ли «перебросить все провальные кубы разом» (Талисман) на текущем шаге.
func _reroll_all_available() -> bool:
	if bool(GameState.current_encounter.get("committed", false)):
		return false
	var c: Dictionary = _chk()
	if not bool(c.get("rolled", false)):
		return false
	return int(c.get("reroll_all_allowance", 0)) - int(c.get("reroll_all_used", 0)) > 0


# ── Потери сыщика под лотком ──────────────────────────────────────────────────


# Только последствия для сыщика при принятии текущего расклада: −N рассудка после
# броска Воли (и дальше, пока бой не закрыт), −N здоровья после броска Силы. За
# вычетом уже предотвращённого картами (бинты/виски). Без потерь — строки нет.
func _loss_lines(card: Dictionary, str_step: bool, done: bool, masked: bool = false) -> void:
	var c: Dictionary = _chk()
	var rolled: bool = bool(c.get("rolled", false)) and not masked
	var sanity_loss: int = -1
	if card.has("will"):
		sanity_loss = int(card.get("sanity_loss", 0))
	elif rolled:
		var hd: int = int((card.get("horror", {}) as Dictionary).get("damage", 0))
		sanity_loss = maxi(0, hd - int(c.get("successes", 0)))
	if sanity_loss > 0:
		sanity_loss = maxi(0, sanity_loss - int(card.get("prevented_sanity", 0)))
	var hp_loss: int = -1
	if done:
		hp_loss = int((card["resolution"] as Dictionary).get("hp_loss", 0))
	elif str_step and rolled:
		var dmg: int = int((card.get("combat", {}) as Dictionary).get("damage", 0))
		hp_loss = maxi(0, dmg - int(c.get("successes", 0)))
	if hp_loss > 0:
		hp_loss = maxi(0, hp_loss - int(card.get("prevented_hp", 0)))
	if sanity_loss > 0:
		var ls: Label = _lbl("−%d %s" % [sanity_loss, tr("COMBAT_SANITY")], _FS_LOSS, _C_WILL)
		ls.name = "LossSanity"
		_vbox.add_child(ls)
	if hp_loss > 0:
		var lh: Label = _lbl("−%d %s" % [hp_loss, tr("COMBAT_HEALTH")], _FS_LOSS, _C_STR)
		lh.name = "LossHealth"
		_vbox.add_child(lh)
	# Кубик способности (defeatOnDie): что выпало и чем кончилось.
	if card.has("ability_die"):
		var won: bool = bool(card.get("defeated_on_horror", false))
		_vbox.add_child(
			_lbl(
				(
					tr("COMBAT_ABILITY_DIE_WON" if won else "COMBAT_ABILITY_DIE_LOST")
					% int(card["ability_die"])
				),
				_FS_LOSS,
				UIColors.SUCCESS if won else UIColors.MUTED
			)
		)


# ── Хелперы ───────────────────────────────────────────────────────────────────


func _lbl(
	text: String, size: int, color: Color, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER
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
