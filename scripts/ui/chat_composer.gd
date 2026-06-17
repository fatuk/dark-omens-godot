extends CanvasLayer

## Композер чата (Dark Souls-style). C открывает/закрывает. Этапы:
##   TEMPLATE — веер шаблонов фраз (карта = шаблон с «____» вместо слотов);
##   NOUN     — веер существительных с СЕКЦИЯМИ-категориями (◄ ► / A D листают секции,
##              колесо прокручивает слова), последовательно по слотам шаблона;
##   READY    — все слоты заполнены → «Отправить»/«Назад».
## По центру экрана — живое превью собираемой фразы (текущий слот в [скобках] на hover).
## Реюз GameCard + Messages + геометрии веера (зеркало hand_carousel, без инвентаря).
## Отправка — GameState.send_chat(phrase_id, noun_ids). Монтируется из world_map.

enum { STAGE_TEMPLATE, STAGE_NOUN, STAGE_READY }

const CARD_W := 150.0
const CARD_H := 237.0  # ≈ CARD_W / GameCard.ASPECT
const GAP_X := 118.0  # шаг между картами веера
const SPREAD := 4.0  # градусов наклона между соседями
const ARC := 2.2  # глубина дуги (края ниже центра)
const VISIBLE := 9  # сколько карт показываем окном

var _open := false
var _stage := STAGE_TEMPLATE
var _phrase_id := ""
var _slot_count := 1
var _slot_idx := 0  # какой слот заполняем
var _picked: Array = []  # выбранные id существительных по слотам
var _section_idx := 0  # активная секция-категория (NOUN)
var _scroll := 0  # левый индекс видимого окна карт
var _hover_id := ""  # id под курсором (для превью)

var _root: ColorRect
var _fan: Control
var _cards: Array = []  # видимые GameCard
var _preview: Label
var _title: Label
var _hint: Label
var _arrow_l: Button
var _arrow_r: Button
var _back_btn: Button
var _send_btn: Button


func _ready() -> void:
	layer = 92  # над модалками (86–90), ниже паузы/консоли (100)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


# ── Ввод ──────────────────────────────────────────────────────────────────────


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key: int = (event as InputEventKey).keycode
		if key == KEY_C:
			# Не воровать 'c' у текстовых полей (консоль/лобби).
			var foc: Control = get_viewport().gui_get_focus_owner()
			if foc is LineEdit or foc is TextEdit:
				return
			toggle()
			get_viewport().set_input_as_handled()
			return
		if not _open:
			return
		match key:
			KEY_ESCAPE:
				close()
				get_viewport().set_input_as_handled()
			KEY_LEFT, KEY_A:
				if _stage == STAGE_NOUN:
					_switch_section(-1)
					get_viewport().set_input_as_handled()
			KEY_RIGHT, KEY_D:
				if _stage == STAGE_NOUN:
					_switch_section(1)
					get_viewport().set_input_as_handled()
		return
	if (
		_open
		and _stage != STAGE_READY
		and event is InputEventMouseButton
		and (event as InputEventMouseButton).pressed
	):
		var mb: int = (event as InputEventMouseButton).button_index
		if mb == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll_window(1)
			get_viewport().set_input_as_handled()
		elif mb == MOUSE_BUTTON_WHEEL_UP:
			_scroll_window(-1)
			get_viewport().set_input_as_handled()


# ── Открытие/закрытие ─────────────────────────────────────────────────────────


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func open() -> void:
	if _open:
		return
	_open = true
	_root.visible = true
	_stage = STAGE_TEMPLATE
	_phrase_id = ""
	_slot_count = 1
	_slot_idx = 0
	_picked = []
	_section_idx = 0
	_scroll = 0
	_hover_id = ""
	_refresh()


func close() -> void:
	if not _open:
		return
	_open = false
	_root.visible = false


# ── Данные текущего этапа ─────────────────────────────────────────────────────


func _locale() -> String:
	return I18n.get_locale()


# Список карт текущего этапа: [{id, label}].
func _items() -> Array:
	var out: Array = []
	if _stage == STAGE_TEMPLATE:
		for p_v: Variant in Messages.phrases():
			var p: Dictionary = p_v
			out.append(
				{"id": String(p.get("id", "")), "label": _template_label(String(p.get("id", "")))}
			)
	elif _stage == STAGE_NOUN:
		var cat: String = Messages.CATEGORY_ORDER[_section_idx]
		for n_v: Variant in Messages.nouns_in(cat):
			var n: Dictionary = n_v
			out.append(
				{"id": String(n.get("id", "")), "label": _noun_word(String(n.get("id", "")))}
			)
	return out


# Шаблон с «____» вместо слотов — для карты-превью шаблона.
func _template_label(phrase_id: String) -> String:
	return Messages.fill(phrase_id, ["____", "____"], _locale())


func _noun_word(noun_id: String) -> String:
	return String(Messages.noun(noun_id).get(_locale(), Messages.noun(noun_id).get("en", "")))


# ── Сборка каркаса ────────────────────────────────────────────────────────────


func _build() -> void:
	_root = ColorRect.new()
	_root.name = "Root"
	_root.color = Color(0, 0, 0, 0.62)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP  # ловим клики мимо карт/кнопок
	_root.visible = false
	add_child(_root)

	# Превью собираемой фразы — по центру-верху.
	var prev_panel := PanelContainer.new()
	prev_panel.name = "PreviewPanel"
	UIStyle.style_modal_panel(prev_panel, 26)
	prev_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	prev_panel.position = Vector2(0, 90)
	prev_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.add_child(prev_panel)
	_preview = UIStyle.label("…", 40, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_preview.name = "Preview"
	_preview.custom_minimum_size = Vector2(560, 0)
	_preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prev_panel.add_child(_preview)

	# Подсказка/заголовок секции — над веером.
	_title = UIStyle.label("", 26, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_title.name = "SectionTitle"
	_title.set_anchors_preset(Control.PRESET_CENTER)
	_title.anchor_top = 0.55
	_title.anchor_bottom = 0.55
	_title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_title)

	# Веер карт — контейнер у низа по центру (позиции карт задаём вручную).
	_fan = Control.new()
	_fan.name = "Fan"
	_fan.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_fan)

	# Стрелки переключения секций (NOUN) — по бокам.
	_arrow_l = UIStyle.button("◄", UIColors.ACCENT)
	_arrow_l.name = "ArrowL"
	_arrow_l.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_arrow_l.position = Vector2(40, 0)
	_arrow_l.pressed.connect(func() -> void: _switch_section(-1))
	_root.add_child(_arrow_l)
	_arrow_r = UIStyle.button("►", UIColors.ACCENT)
	_arrow_r.name = "ArrowR"
	_arrow_r.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_arrow_r.position = Vector2(-100, 0)
	_arrow_r.pressed.connect(func() -> void: _switch_section(1))
	_root.add_child(_arrow_r)

	# Кнопки внизу: Назад · Отмена · Отправить.
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 18)
	btns.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	btns.position = Vector2(0, -40)
	btns.grow_horizontal = Control.GROW_DIRECTION_BOTH
	btns.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(btns)
	_back_btn = UIStyle.button("CHAT_BACK", UIColors.ACCENT)
	_back_btn.pressed.connect(_go_back)
	btns.add_child(_back_btn)
	var cancel_btn := UIStyle.button("CHAT_CANCEL", UIColors.ACCENT)
	cancel_btn.pressed.connect(close)
	btns.add_child(cancel_btn)
	_send_btn = UIStyle.button("CHAT_SEND", UIColors.ACCENT)
	_send_btn.pressed.connect(_send)
	btns.add_child(_send_btn)

	# Подсказка по управлению — мелким у низа.
	_hint = UIStyle.label("CHAT_HINT", 18, Color(0.6, 0.6, 0.66), HORIZONTAL_ALIGNMENT_CENTER)
	_hint.name = "Hint"
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.position = Vector2(0, -8)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_hint)


# ── Обновление UI ─────────────────────────────────────────────────────────────


func _refresh() -> void:
	if not _open:
		return
	var noun_stage: bool = _stage == STAGE_NOUN
	_arrow_l.visible = noun_stage
	_arrow_r.visible = noun_stage
	_title.visible = _stage != STAGE_READY
	_back_btn.visible = _stage != STAGE_TEMPLATE
	_send_btn.visible = _stage == STAGE_READY
	if _stage == STAGE_TEMPLATE:
		_title.text = "CHAT_PICK_TEMPLATE"
	elif noun_stage:
		_title.text = Messages.category_title(Messages.CATEGORY_ORDER[_section_idx], _locale())
	_rebuild_fan()
	_update_preview()


# Перестроить видимое окно карт веера (или спрятать на READY).
func _rebuild_fan() -> void:
	for c: GameCard in _cards:
		c.queue_free()
	_cards = []
	if _stage == STAGE_READY:
		return
	var items: Array = _items()
	var n: int = items.size()
	if n == 0:
		return
	_scroll = clampi(_scroll, 0, maxi(0, n - VISIBLE))
	var first: int = _scroll
	var last: int = mini(n, first + VISIBLE)
	var count: int = last - first
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var baseline := Vector2(vp.x * 0.5, vp.y - CARD_H * 0.62)
	for k: int in range(count):
		var gi: int = first + k
		var item: Dictionary = items[gi]
		var card := GameCard.new()
		card.name = "Card_%d" % gi
		card.custom_minimum_size = Vector2(CARD_W, CARD_H)
		card.size = Vector2(CARD_W, CARD_H)
		card.pivot_offset = card.size * 0.5
		card.set_card({"title": String(item.get("label", "")), "glyph": ""})
		var off: float = float(k) - float(count - 1) * 0.5
		card.position = baseline + Vector2(off * GAP_X, off * off * ARC) - card.size * 0.5
		card.rotation = deg_to_rad(off * SPREAD)
		card.mouse_entered.connect(_on_card_hover.bind(String(item.get("id", ""))))
		card.mouse_exited.connect(_on_card_exit.bind(String(item.get("id", ""))))
		card.gui_input.connect(_on_card_input.bind(String(item.get("id", ""))))
		_fan.add_child(card)
		_cards.append(card)


func _update_preview() -> void:
	_preview.text = _compose_preview()


# Текст превью: выбранные слова; текущий слот — [hover] (или ____); будущие ____.
func _compose_preview() -> String:
	if _phrase_id.is_empty():
		return "…"
	var words: Array = []
	for i: int in range(_slot_count):
		if i < _picked.size() and not String(_picked[i]).is_empty():
			words.append(_noun_word(String(_picked[i])))
		elif i == _slot_idx and _stage == STAGE_NOUN and not _hover_id.is_empty():
			words.append("[%s]" % _noun_word(_hover_id))
		else:
			words.append("____")
	return Messages.fill(_phrase_id, words, _locale())


# ── Взаимодействие ────────────────────────────────────────────────────────────


func _on_card_hover(id: String) -> void:
	if _stage == STAGE_TEMPLATE:
		_preview.text = _template_label(id)
	else:
		_hover_id = id
		_update_preview()


func _on_card_exit(id: String) -> void:
	if _hover_id == id:
		_hover_id = ""
		_update_preview()
	if _stage == STAGE_TEMPLATE:
		_update_preview()


func _on_card_input(event: InputEvent, id: String) -> void:
	if (
		event is InputEventMouseButton
		and (event as InputEventMouseButton).pressed
		and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
	):
		_pick(id)


# Выбор карты на текущем этапе.
func _pick(id: String) -> void:
	if _stage == STAGE_TEMPLATE:
		_phrase_id = id
		_slot_count = Messages.slots(id)
		_picked = []
		_slot_idx = 0
		_stage = STAGE_NOUN
		_section_idx = 0
		_scroll = 0
		_hover_id = ""
	elif _stage == STAGE_NOUN:
		if _slot_idx < _picked.size():
			_picked[_slot_idx] = id
		else:
			_picked.append(id)
		_hover_id = ""
		if _slot_idx + 1 < _slot_count:
			_slot_idx += 1
			_section_idx = 0
			_scroll = 0
		else:
			_stage = STAGE_READY
	_refresh()


func _go_back() -> void:
	if _stage == STAGE_READY:
		_stage = STAGE_NOUN
		_slot_idx = _slot_count - 1
		if _slot_idx < _picked.size():
			_picked.remove_at(_slot_idx)
		_section_idx = 0
		_scroll = 0
	elif _stage == STAGE_NOUN:
		if _slot_idx > 0:
			_slot_idx -= 1
			if _slot_idx < _picked.size():
				_picked.remove_at(_slot_idx)
			_section_idx = 0
			_scroll = 0
		else:
			_stage = STAGE_TEMPLATE
			_phrase_id = ""
			_picked = []
	_hover_id = ""
	_refresh()


func _switch_section(d: int) -> void:
	if _stage != STAGE_NOUN:
		return
	var n: int = Messages.CATEGORY_ORDER.size()
	_section_idx = (_section_idx + d + n) % n
	_scroll = 0
	_hover_id = ""
	_refresh()


func _scroll_window(d: int) -> void:
	var n: int = _items().size()
	var new_scroll: int = clampi(_scroll + d, 0, maxi(0, n - VISIBLE))
	if new_scroll != _scroll:
		_scroll = new_scroll
		_rebuild_fan()


func _send() -> void:
	if _stage != STAGE_READY or _phrase_id.is_empty():
		return
	GameState.send_chat(_phrase_id, _picked)
	close()
