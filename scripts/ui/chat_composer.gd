extends CanvasLayer

## Композер чата (Dark Souls-style). Кнопка C открывает/закрывает. Переиспользует
## ВЕЕР РУКИ (HandCarousel) — те же дуга, подъём активной карты, секции, стрелки,
## анимация, что у имущества/заклинаний. Кормит веер секциями:
##   этап TEMPLATE — одна секция шаблонов (карта = шаблон с «____» вместо слотов);
##   этап NOUN     — 8 секций-категорий существительных (◄ ► листают категории).
## «Разыгранная» карта (chat_card_played) двигает этап; на последнем слоте — отправка
## (GameState.send_chat). По центру экрана — живое превью собираемой фразы (наведённое
## слово текущего слота в [скобках]). Монтируется из world_map.

enum { STAGE_TEMPLATE, STAGE_NOUN }

# Рамка-фон превью собираемого сообщения (nine-patch: тянется центр, ornate-углы целы).
const _FRAME_TEX: Texture2D = preload("res://assets/message-frame.png")

var _open := false
var _stage := STAGE_TEMPLATE
var _phrase_id := ""
var _slot_count := 1
var _slot_idx := 0
var _picked: Array = []  # выбранные id существительных по слотам
var _focus_id := ""  # id наведённой карты (для превью)

var _fan: HandCarousel
var _preview_panel: PanelContainer
var _preview: Label


func _ready() -> void:
	layer = 96  # превью над веером (HandCarousel = layer 95)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_preview()
	_build_fan()


func _build_fan() -> void:
	_fan = HandCarousel.new()
	_fan.name = "ChatFan"
	_fan.tab_enabled = false  # открывается по C, не Tab
	_fan.keep_open = true  # серия выборов: «разыграл» НЕ закрывает веер
	add_child(_fan)
	_fan.chat_card_played.connect(_on_played)
	_fan.card_focused.connect(_on_focused)
	_fan.closed.connect(_on_fan_closed)


func _build_preview() -> void:
	_preview_panel = PanelContainer.new()
	_preview_panel.name = "PreviewPanel"
	_preview_panel.add_theme_stylebox_override("panel", _make_frame_style())
	_preview_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_preview_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_preview_panel.position = Vector2(0, 160)  # отступ от верхней полосы
	_preview_panel.visible = false
	# Ассет рамки нарисован в @2× → строим превью в двойном размере (шрифт/ширина
	# ×2) и ужимаем контейнер в scale 0.5. Так ornate-кант рисуется крупно = чётко,
	# а на экране рамка выходит в задуманную половину, а не вдвое толще.
	_preview_panel.scale = Vector2(0.5, 0.5)
	_preview_panel.resized.connect(_recenter_preview)
	add_child(_preview_panel)
	_preview = UIStyle.label("…", 84, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_preview.name = "Preview"
	_preview.custom_minimum_size = Vector2(1040, 0)
	_preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_panel.add_child(_preview)


# scale 0.5 сжимает панель к её pivot; ставим pivot по верх-центру, иначе превью
# уедет влево. Пересчёт на каждый resized — текст слота меняет ширину панели.
func _recenter_preview() -> void:
	_preview_panel.pivot_offset = Vector2(_preview_panel.size.x * 0.5, 0.0)


# StyleBoxTexture из message-frame.png (749×300). Nine-patch: ornate-кант не тянется
# (texture_margin), плоский центр растягивается под длину фразы. content_margin —
# отступ текста, чтобы не лез на кант. Значения подобраны на глаз — при желании
# правятся здесь.
func _make_frame_style() -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = _FRAME_TEX
	sb.texture_margin_left = 72
	sb.texture_margin_right = 72
	sb.texture_margin_top = 46
	sb.texture_margin_bottom = 46
	sb.content_margin_left = 88
	sb.content_margin_right = 88
	sb.content_margin_top = 100
	sb.content_margin_bottom = 100
	return sb


# ── Ввод (только C; ◄ ► / колесо / Esc обрабатывает сам веер) ─────────────────


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if (event as InputEventKey).keycode != KEY_C:
		return
	var foc: Control = get_viewport().gui_get_focus_owner()
	if foc is LineEdit or foc is TextEdit:
		return  # не воровать 'c' у текстовых полей (консоль/лобби)
	if _open:
		close()
	else:
		open()
	get_viewport().set_input_as_handled()


# ── Открытие/закрытие ─────────────────────────────────────────────────────────


func open() -> void:
	if _open:
		return
	_open = true
	_stage = STAGE_TEMPLATE
	_phrase_id = ""
	_slot_count = 1
	_slot_idx = 0
	_picked = []
	_focus_id = ""
	_preview_panel.visible = true
	_set_template_sections()
	_fan.open()
	_update_preview()


func close() -> void:
	if not _open:
		return
	_open = false
	_preview_panel.visible = false
	_fan.close()


# Веер закрылся сам (Esc / клик мимо) — отменяем композицию.
func _on_fan_closed() -> void:
	if _open:
		_open = false
		_preview_panel.visible = false


# ── Секции веера по этапам ────────────────────────────────────────────────────


func _locale() -> String:
	return I18n.get_locale()


func _set_template_sections() -> void:
	var sections: Array = []
	for cat: String in Messages.PHRASE_CATEGORY_ORDER:
		var items: Array = []
		for p_v: Variant in Messages.phrases_in(cat):
			var pid: String = String((p_v as Dictionary).get("id", ""))
			items.append({"kind": "chat", "id": pid, "title": _template_label(pid)})
		sections.append({"title": Messages.phrase_category_title(cat, _locale()), "items": items})
	_fan.set_sections(sections)


func _set_noun_sections() -> void:
	var sections: Array = []
	for cat: String in Messages.CATEGORY_ORDER:
		var items: Array = []
		for n_v: Variant in Messages.nouns_in(cat):
			var nid: String = String((n_v as Dictionary).get("id", ""))
			items.append({"kind": "chat", "id": nid, "title": _noun_word(nid)})
		sections.append({"title": Messages.category_title(cat, _locale()), "items": items})
	_fan.set_sections(sections)


func _template_label(phrase_id: String) -> String:
	return Messages.fill(phrase_id, ["____", "____"], _locale())


func _noun_word(noun_id: String) -> String:
	var n: Dictionary = Messages.noun(noun_id)
	return String(n.get(_locale(), n.get("en", "")))


# ── Реакция на веер ───────────────────────────────────────────────────────────


func _on_played(id: String) -> void:
	if not _open:
		return
	if _stage == STAGE_TEMPLATE:
		_phrase_id = id
		_slot_count = Messages.slots(id)
		_picked = []
		_slot_idx = 0
		_stage = STAGE_NOUN
		_focus_id = ""
		_set_noun_sections()
		_update_preview()
		return
	# Этап слов: записываем выбор в текущий слот.
	if _slot_idx < _picked.size():
		_picked[_slot_idx] = id
	else:
		_picked.append(id)
	_focus_id = ""
	if _slot_idx + 1 < _slot_count:
		_slot_idx += 1
		_set_noun_sections()  # обновить веер для следующего слота
		_update_preview()
	else:
		GameState.send_chat(_phrase_id, _picked)
		close()


func _on_focused(item: Dictionary) -> void:
	if not _open:
		return
	_focus_id = String(item.get("id", ""))
	_update_preview()


# ── Превью ────────────────────────────────────────────────────────────────────


func _update_preview() -> void:
	_preview.text = _compose_preview()


func _compose_preview() -> String:
	if _stage == STAGE_TEMPLATE:
		if not _focus_id.is_empty():
			return _template_label(_focus_id)
		return tr("CHAT_PICK_TEMPLATE")
	var words: Array = []
	for i: int in range(_slot_count):
		if i < _picked.size() and not String(_picked[i]).is_empty():
			words.append(_noun_word(String(_picked[i])))
		elif i == _slot_idx and not _focus_id.is_empty():
			words.append("[%s]" % _noun_word(_focus_id))
		else:
			words.append("____")
	return Messages.fill(_phrase_id, words, _locale())
