class_name MonsterPreview
extends CanvasLayer

## Крупный просмотр монстра по клику на его портрет (карточка локации, «Запасы»):
## та же карта, что в окне боя — арт с наложенными числами (здоровье/стойкость
## сверху справа, ужас слева снизу, урон справа снизу, способность по центру снизу),
## под ней — проверки боя и сопротивление. Закрывается кликом в любом месте и «назад»
## (Esc / ○ / B). Одноразовый, как CardPreview.
##
##   MonsterPreview.attach_click(tile, monster_def, cur_health)

const _LAYER: int = 120  # как CardPreview: выше модалок и подсказок
const _ART_SIZE := Vector2(600, 496)  # как карта в модалке боя (арт @2× 1200×992)
const _ART_PAD := 14.0
const _FS_BIG := 44  # ужас/урон
const _FS_HP := 40  # здоровье/стойкость
const _FS_ABILITY := 15
const _BACKDROP_ALPHA := 0.7

var _root: ColorRect
var _panel: PanelContainer
var _m: Dictionary = {}
var _cur_health: int = -1


## Показать монстра m (запись каталога). cur_health ≥ 0 — раненый на поле (тек./макс.).
static func show_monster(parent: Node, m: Dictionary, cur_health: int = -1) -> MonsterPreview:
	var pv := MonsterPreview.new()
	pv.name = "MonsterPreview"
	pv._m = m
	pv._cur_health = cur_health
	parent.add_child(pv)
	return pv


## Портрет ctrl → крупный просмотр по клику (ЛКМ) или «принять» с геймпада в фокусе.
static func attach_click(ctrl: Control, m: Dictionary, cur_health: int = -1) -> void:
	ctrl.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	ctrl.gui_input.connect(
		func(event: InputEvent) -> void:
			var mb := event as InputEventMouseButton
			var click: bool = mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
			if not click and not event.is_action_pressed(&"ui_accept"):
				return
			var parent: Node = ctrl.get_tree().current_scene
			if parent == null:
				parent = ctrl.get_tree().root
			show_monster(parent, m, cur_health)
			ctrl.accept_event()  # клик по портрету — не в окно под ним
	)


func _ready() -> void:
	layer = _LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = ColorRect.new()
	_root.name = "Root"
	_root.color = Color(0, 0, 0, _BACKDROP_ALPHA)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP  # клик где угодно — закрытие
	_root.gui_input.connect(_on_input)
	UIStyle.keep_own_backdrop(_root)
	add_child(_root)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE  # клик и по окну закрывает
	UIStyle.style_modal_panel(_panel)
	_panel.custom_minimum_size.x = _ART_SIZE.x + 160.0
	center.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 14)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(vbox)
	vbox.add_child(UIStyle.ornate_title(tr(String(_m.get("nameKey", ""))), UIFonts.TITLE))
	vbox.add_child(_build_art())
	var stats: String = _stats_text()
	if not stats.is_empty():
		var l := UIStyle.label(stats, UIFonts.BODY, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
		l.name = "Stats"
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(l)
	UIStyle.modal_transition(_root, _panel, true)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(GameInput.BACK):  # Esc / ○ / B
		close()
		get_viewport().set_input_as_handled()  # «назад» не закрывает окно под просмотром


func close() -> void:
	if not is_inside_tree():
		queue_free()
		return
	var tw: Tween = UIStyle.modal_transition(_root, _panel, false)
	tw.chain().tween_callback(queue_free)


func _on_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		close()


# Карта монстра — как в окне боя: арт «под обрез» и числа поверх.
func _build_art() -> Control:
	var mid: String = String(_m.get("id", ""))
	var frame := Control.new()
	frame.name = "MonsterCard"
	frame.custom_minimum_size = _ART_SIZE
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.clip_contents = true
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := ColorRect.new()
	bg.name = "ArtBg"
	bg.color = UIColors.ART_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(bg)
	var tex: Texture2D = MonsterCatalog.card_art(mid)
	if tex != null:
		var art := TextureRect.new()
		art.name = "Art"
		art.texture = tex
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(art)
	if _m.has("horror"):
		var tough: int = MonsterCatalog.toughness_for(_m, maxi(1, GameState.players.size()))
		var hp := _overlay("Hp", _FS_HP, UIColors.WARNING, HORIZONTAL_ALIGNMENT_RIGHT)
		hp.text = "%d/%d" % [_cur_health, tough] if _cur_health >= 0 else str(tough)
		hp.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		hp.offset_left = _ART_PAD
		hp.offset_right = -_ART_PAD
		hp.offset_top = _ART_PAD
		frame.add_child(hp)
		frame.add_child(_corner("Horror", _m.get("horror", {}) as Dictionary, UIColors.WILL, false))
		frame.add_child(
			_corner("Damage", _m.get("combat", {}) as Dictionary, UIColors.STRENGTH, true)
		)
	var ability: String = String((_m.get("ability", {}) as Dictionary).get("textKey", ""))
	if not ability.is_empty():
		var ab := _overlay("Ability", _FS_ABILITY, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
		ab.text = tr(ability)
		ab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		ab.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		ab.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		ab.offset_left = 120
		ab.offset_right = -120
		ab.offset_top = -80
		ab.offset_bottom = -_ART_PAD
		frame.add_child(ab)
	return frame


# Число ужаса (слева) / урона (справа) в нижнем углу арта.
func _corner(node_name: String, stat: Dictionary, color: Color, right: bool) -> Label:
	var l := _overlay(
		node_name,
		_FS_BIG,
		color,
		HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT
	)
	l.text = str(int(stat.get("damage", 0)))
	l.set_anchors_and_offsets_preset(
		Control.PRESET_BOTTOM_RIGHT if right else Control.PRESET_BOTTOM_LEFT
	)
	l.grow_horizontal = Control.GROW_DIRECTION_BEGIN if right else Control.GROW_DIRECTION_END
	l.grow_vertical = Control.GROW_DIRECTION_BEGIN
	l.offset_bottom = -_ART_PAD + 6
	if right:
		l.offset_right = -_ART_PAD
	else:
		l.offset_left = _ART_PAD
	return l


# Подпись поверх арта: тень 1px — читается на любом фоне без затемнения арта.
func _overlay(node_name: String, fs: int, color: Color, align: HorizontalAlignment) -> Label:
	var l := UIStyle.label("", fs, color, align)
	l.name = node_name
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_color_override("font_shadow_color", Color.BLACK)
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


# Под картой: штрафы проверок боя одной строкой — только ненулевые («Воля −1 · Сила −2»;
# урон уже на арте), и сопротивление; эпический без своих статов — «как у Древнего».
func _stats_text() -> String:
	var lines: PackedStringArray = []
	if _m.has("horror"):
		var mods: PackedStringArray = []
		for key: String in ["horror", "combat"]:
			var stat: Dictionary = _m.get(key, {})
			var mod: int = int(stat.get("modifier", 0))
			var skill: String = String(stat.get("skill", "none"))
			if mod != 0 and skill != "none":
				mods.append(
					"%s %s" % [tr("SKILL_" + skill.to_upper()), ("%+d" % mod).replace("-", "−")]
				)
		if not mods.is_empty():
			lines.append(" · ".join(mods))
		if _m.has("resist"):
			lines.append(
				"%s: %s" % [tr("SIDEBAR_RESIST"), MonsterTile.resist_text(_m.get("resist"))]
			)
	elif bool(_m.get("useAncientOne", false)):
		lines.append(tr("SIDEBAR_USE_ANCIENT_ONE"))
	return "\n".join(lines)
