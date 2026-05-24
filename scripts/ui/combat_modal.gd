extends CanvasLayer

## Боевая встреча. Видна активному игроку, когда current_encounter.kind ==
## "combat". Бой одноразовый: один бросок = две проверки — сначала ВОЛЯ
## (выдержать ужас), затем СИЛА (одолеть монстра). Итог — победа или нет.
## Раундов и отступления нет. Бой авторитетно у хоста (resolve_encounter).

@onready var _root:  Control        = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox:  VBoxContainer  = %VBox


func _ready() -> void:
	UIStyle.style_panel(_panel, 24)
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
	for c in _vbox.get_children():
		c.queue_free()

	var res: Dictionary = card.get("resolution", {})
	var done: bool = not res.is_empty()

	var title := Label.new()
	title.text = String(card.get("monsterName", "ENCOUNTER_TITLE"))
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", UIColors.ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(title)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 20)
	cols.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_child(cols)
	cols.add_child(_player_col())
	cols.add_child(_center_col(card))
	cols.add_child(_monster_col(card))

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 12)
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_child(btns)
	if done:
		btns.add_child(_button("BTN_FINISH_BIG", func() -> void: GameState.finish_encounter()))
	else:
		# Одна кнопка катит текущий шаг: сначала Воля, затем Сила (отдельные броски).
		var key: String = "COMBAT_ROLL_WILL" if not card.has("will") else "COMBAT_ROLL_STRENGTH"
		btns.add_child(_button(key, func() -> void: GameState.resolve_encounter()))


# ── Колонки ───────────────────────────────────────────────────────────────────

func _player_col() -> VBoxContainer:
	var p: Dictionary = GameState.my_player()
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.custom_minimum_size = Vector2(190, 0)
	col.add_child(_lbl(String(p.get("name", "?")), 16, UIColors.TEXT))
	col.add_child(_lbl("%s: %d / %d" % [tr("COMBAT_HEALTH"), int(p.get("hp", 0)), int(p.get("hp_max", 0))], 13, UIColors.SUCCESS))
	col.add_child(_lbl("%s: %d / %d" % [tr("COMBAT_SANITY"), int(p.get("sanity", 0)), int(p.get("sanity_max", 0))], 13, Color(0.4, 0.7, 0.9)))
	return col


func _center_col(card: Dictionary) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.custom_minimum_size = Vector2(260, 0)

	var will: Dictionary = card.get("will", {})
	var has_will: bool = not will.is_empty()
	var res: Dictionary = card.get("resolution", {})
	var done: bool = not res.is_empty()

	# Шаг 1 — Воля (ужас): отдельный бросок.
	col.add_child(_lbl(tr("COMBAT_WILL"), 15, Color(0.4, 0.7, 0.9)))
	if has_will:
		var sl: int = int(card.get("sanity_loss", 0))
		var line: String = "%s: %d" % [tr("ENCOUNTER_SUCCESSES"), int(will.get("successes", 0))]
		if sl > 0:
			line += " · −%d %s" % [sl, tr("COMBAT_SANITY")]
		col.add_child(_lbl(line, 12, UIColors.TEXT))
	else:
		col.add_child(_lbl(tr("COMBAT_WILL_HINT"), 11, UIColors.MUTED))

	# Шаг 2 — Сила (атака): второй отдельный бросок.
	col.add_child(_lbl(tr("COMBAT_STRENGTH"), 15, UIColors.ACCENT))
	if done:
		var s: Dictionary = res.get("strength", {})
		col.add_child(_lbl("%s: %d · %s −%d" % [tr("ENCOUNTER_SUCCESSES"), int(s.get("successes", 0)), tr("SIDEBAR_TOUGHNESS"), int(res.get("dealt", 0))], 12, UIColors.TEXT))
		if int(res.get("hp_loss", 0)) > 0:
			col.add_child(_lbl("−%d %s" % [int(res["hp_loss"]), tr("COMBAT_HEALTH")], 12, UIColors.DANGER))
	else:
		col.add_child(_lbl(tr("COMBAT_STRENGTH_HINT"), 11, UIColors.MUTED))

	# Итог
	if done:
		var won: bool = bool(res.get("won", false))
		col.add_child(_lbl(tr("COMBAT_WIN" if won else "COMBAT_LOSS"), 18,
			UIColors.SUCCESS if won else UIColors.DANGER, HORIZONTAL_ALIGNMENT_CENTER))
	return col


func _monster_col(card: Dictionary) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.custom_minimum_size = Vector2(190, 0)
	var combat: Dictionary = card.get("combat", {})
	var horror: Dictionary = card.get("horror", {})
	col.add_child(_lbl("%s: %d / %d" % [tr("SIDEBAR_TOUGHNESS"), int(card.get("health", 0)), int(card.get("toughness", 0))], 14, UIColors.WARNING))
	col.add_child(_lbl("%s: %d · %s: %d" % [tr("COMBAT_MDMG"), int(combat.get("damage", 0)), tr("SIDEBAR_HORROR"), int(horror.get("damage", 0))], 12, UIColors.TEXT))
	var ab: String = String(card.get("abilityKey", ""))
	if not ab.is_empty():
		var al := _lbl(ab, 11, UIColors.MUTED)   # ключ перевода способности
		al.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		al.custom_minimum_size = Vector2(190, 0)
		col.add_child(al)
	return col


# ── Хелперы ───────────────────────────────────────────────────────────────────

func _lbl(text: String, size: int, color: Color, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	return l


func _button(key: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = key
	UIStyle.style_button(b)
	b.pressed.connect(on_press)
	return b
