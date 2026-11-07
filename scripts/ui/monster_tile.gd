class_name MonsterTile
extends RefCounted

## Портрет монстра со статами — общий для сайдбара локации (монстры на клетке) и
## окна «Запасы» (колода монстров): одна плитка, одна подсказка, одна сетка.
##
## Ряд заполняется по ширине целиком: колонок столько, сколько влезает портретов не
## меньше TILE, и сторона растягивается, чтобы ряд лёг от края до края.

const TILE := 112.0  # МИНИМАЛЬНАЯ сторона портрета
const GAP := 8  # зазор между портретами
const _PAD := 6.0  # инсет чисел от края (при TILE; растёт со стороной)
const _FS := 28  # кегль чисел ужаса/урона (при TILE; растёт со стороной)


## Сетка портретов: зазоры и подгонка стороны под ширину ряда при каждом resized.
static func grid(node_name: String) -> HFlowContainer:
	var g := HFlowContainer.new()
	g.name = node_name
	g.add_theme_constant_override("h_separation", GAP)
	g.add_theme_constant_override("v_separation", GAP)
	g.resized.connect(fit_grid.bind(g))
	return g


## Сторона портрета, при которой ряд шириной width заполняется целиком.
static func side_for(width: float) -> float:
	if width <= 0.0:
		return TILE
	var cols: int = maxi(1, int((width + GAP) / (TILE + GAP)))
	return floorf((width - GAP * (cols - 1)) / cols)


## Подогнать портреты под ширину ряда: сторона, кегль и инсет чисел — пропорционально.
static func fit_grid(grid: HFlowContainer) -> void:
	var side: float = side_for(grid.size.x)
	var k: float = side / TILE
	for tile: Node in grid.get_children():
		(tile as Control).custom_minimum_size = Vector2(side, side)
		for num_name: String in ["Horror", "Damage"]:
			var l: Label = tile.get_node_or_null(num_name)
			if l == null:
				continue
			var right: bool = num_name == "Damage"
			l.add_theme_font_size_override("font_size", roundi(_FS * k))
			l.offset_bottom = -_PAD * k + 4
			if right:
				l.offset_right = -_PAD * k
			else:
				l.offset_left = _PAD * k


## Превью монстра — квадратный портрет, как карта в модалке боя: арт «под обрез»,
## ужас (синий) слева снизу, урон (красный) справа снизу. Полные статы (стойкость,
## проверки, сопротивление, способность) — во всплывающей подсказке. copies > 1 —
## бейдж «×N» справа сверху (колода монстров: одинаковые — одним портретом).
static func make(m: Dictionary, cur_health: int = -1, copies: int = 1) -> Control:
	var tile := WrapTooltip.new()  # подсказка со статами длинная — с переносом
	tile.name = "Monster"
	tile.custom_minimum_size = Vector2(TILE, TILE)
	tile.clip_contents = true
	tile.mouse_filter = Control.MOUSE_FILTER_PASS  # подсказка; колесо — скроллу
	tile.tooltip_text = tooltip(m, cur_health)
	tile.focus_mode = Control.FOCUS_ALL  # геймпад: ходить по монстрам, статы — в подсказке

	var bg := ColorRect.new()  # подложка: под артом с прозрачностью и вместо него
	bg.name = "ArtBg"
	bg.color = UIColors.ART_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(bg)
	var tex: Texture2D = MonsterCatalog.card_art(String(m.get("id", "")))
	if tex != null:
		var art := TextureRect.new()
		art.name = "Art"
		art.texture = tex
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.add_child(art)

	if m.has("horror"):
		var horror: int = int((m.get("horror", {}) as Dictionary).get("damage", 0))
		var combat: int = int((m.get("combat", {}) as Dictionary).get("damage", 0))
		tile.add_child(_tile_number("Horror", horror, UIColors.WILL, false))
		tile.add_child(_tile_number("Damage", combat, UIColors.STRENGTH, true))

	if copies > 1:  # одинаковые монстры в колоде — один портрет с «×N»
		tile.add_child(_copies_badge(copies))

	var frame := Panel.new()  # рамка поверх арта
	frame.name = "Frame"
	var sb := StyleBoxFlat.new()
	sb.draw_center = false
	sb.set_border_width_all(1)
	sb.border_color = UIColors.BORDER
	frame.add_theme_stylebox_override("panel", sb)
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(frame)
	MonsterPreview.attach_click(tile, m, cur_health)  # клик — крупная карта, как в бою
	return tile


# Крупное число в нижнем углу портрета (right — правый угол), с тенью, как в бою.
static func _tile_number(node_name: String, value: int, color: Color, right: bool) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = str(value)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", _FS)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color.BLACK)
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.set_anchors_and_offsets_preset(
		Control.PRESET_BOTTOM_RIGHT if right else Control.PRESET_BOTTOM_LEFT
	)
	l.grow_horizontal = Control.GROW_DIRECTION_BEGIN if right else Control.GROW_DIRECTION_END
	l.grow_vertical = Control.GROW_DIRECTION_BEGIN
	l.offset_bottom = -_PAD + 4
	if right:
		l.offset_right = -_PAD
	else:
		l.offset_left = _PAD
	return l


## Подсказка портрета: имя, стойкость (тек./макс., если ранен), проверки, способность.
static func tooltip(m: Dictionary, cur_health: int = -1) -> String:
	var lines: PackedStringArray = [_t(String(m.get("nameKey", "")))]
	if m.has("horror"):
		var tough: int = MonsterCatalog.toughness_for(m, maxi(1, GameState.players.size()))
		lines.append(
			(
				("%s: %d / %d" % [_t("SIDEBAR_TOUGHNESS"), cur_health, tough])
				if cur_health >= 0
				else ("%s: %d" % [_t("SIDEBAR_TOUGHNESS"), tough])
			)
		)
		lines.append(stat_line("SIDEBAR_HORROR", m.get("horror", {})))
		lines.append(stat_line("SIDEBAR_COMBAT", m.get("combat", {})))
		if m.has("resist"):
			lines.append("%s: %s" % [_t("SIDEBAR_RESIST"), resist_text(m.get("resist"))])
	elif bool(m.get("useAncientOne", false)):
		lines.append(_t("SIDEBAR_USE_ANCIENT_ONE"))
	var ability: String = String((m.get("ability", {}) as Dictionary).get("textKey", ""))
	if not ability.is_empty():
		lines.append(_t(ability))
	return "\n".join(lines)


# Строка проверки: «Ужас: Воля −1 · урон 2».
static func stat_line(label_key: String, stat: Dictionary) -> String:
	var skill: String = String(stat.get("skill", "none"))
	var skill_tr: String = _t("SKILL_" + skill.to_upper())
	var mod: int = int(stat.get("modifier", 0))
	var mod_s: String = ("%+d" % mod).replace("-", "−") if mod != 0 else "0"
	return (
		"%s: %s %s · %s %d"
		% [_t(label_key), skill_tr, mod_s, _t("SIDEBAR_DAMAGE"), int(stat.get("damage", 0))]
	)


# Текст сопротивления монстра: «физическое»/«магическое» (resist — строка/массив).
static func resist_text(r: Variant) -> String:
	var types: Array = r if r is Array else [r]
	var parts: PackedStringArray = []
	for t: Variant in types:
		parts.append(_t("RESIST_PHYSICAL" if String(t) == "physical" else "RESIST_MAGICAL"))
	return ", ".join(parts)


# Бейдж «×N» в правом верхнем углу портрета.
static func _copies_badge(n: int) -> Label:
	var l := Label.new()
	l.name = "Copies"
	l.text = "×%d" % n
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", UIColors.VALUE)
	l.add_theme_color_override("font_shadow_color", Color.BLACK)
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	l.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	l.offset_top = _PAD - 2
	l.offset_right = -_PAD
	return l


# tr() — метод Node, из static его звать нельзя.
static func _t(key: String) -> String:
	return String(TranslationServer.translate(key))
