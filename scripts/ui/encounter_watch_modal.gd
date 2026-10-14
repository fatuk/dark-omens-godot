extends CanvasLayer

## Окно наблюдателя — СРОЧНАЯ ТЕЛЕГРАММА: остальные игроки «получают» сводку о
## встрече активного сыщика. Только повествование: текст встречи и оба возможных
## исхода; когда проверка сыграна — несбывшийся исход гаснет. Тип проверки, кубы и
## кнопки намеренно НЕ показываем: это не интерактив, а «сводка с места событий».
##
## Бланк — арт assets/telegram/bg.png (@2x, 1536×2048): «TELEGRAM», рамки «№ / DISPATCH
## TIME», штамп URGENT, крестик, сургуч и штамп COMMS CODE уже нарисованы. Кодом
## пишем только живое: имя сыщика под заголовком, время отправки (реальное время
## ЧИТАЮЩЕГО), код связи вида 7Y-19-KA, текст встречи и футер «встреча в процессе»
## с песочными часами. Всё раскладывается в пикселях бланка, лист масштабируется
## под высоту экрана.
##
## Данные уже синкаются: current_encounter (карта) и active_check (owner=encounter).
## Ничего нового в сеть не добавляем. Код, монтируется из world_map.

const _BG := preload("res://assets/telegram/bg.png")
const _CHEV_L := preload("res://assets/telegram/chevron-left.png")
const _CHEV_R := preload("res://assets/telegram/chevron-right.png")
const _DIVIDER := preload("res://assets/telegram/divider.png")
const _SUCCESS := preload("res://assets/telegram/success.png")
const _FAILURE := preload("res://assets/telegram/failure.png")
const _SAND_CLOCK := preload("res://assets/telegram/sand-clock.png")

# Раскладка — в пикселях бланка (1536×2048).
const _SHEET := Vector2(1536, 2048)
const _SCREEN_FRAC: float = 0.92  # доля высоты экрана под лист
const _MAX_SCALE: float = 0.5  # арт @2x — не крупнее половины натурального
const _NAME_RECT := Rect2(470, 330, 596, 64)  # имя сыщика под «TELEGRAM»
const _TIME_RECT := Rect2(136, 318, 250, 56)  # под подписью DISPATCH TIME
const _BODY_RECT := Rect2(168, 462, 1200, 1040)  # поле бланка между шапкой и печатью
const _CODE_POS := Vector2(96, 1668)  # под «COMMS CODE» на повёрнутом штампе
const _CODE_SIZE := Vector2(280, 60)
const _CODE_TILT_DEG: float = 8.0  # штамп повёрнут по часовой
const _FOOTER_RECT := Rect2(456, 1777, 630, 205)  # пустая плашка внизу
const _CLOSE_RECT := Rect2(1346, 60, 136, 134)  # крестик в арте
const _ICON_H: float = 112.0  # медальоны успеха/провала
# Шрифты — тоже в пикселях бланка (на экране ≈ ×0.5).
const _FS_NAME: int = 46
const _FS_TIME: int = 40
const _FS_HEAD: int = 40
const _FS_BODY: int = 38
const _FS_CODE: int = 38
const _FS_FOOTER: int = 36
const _FS_MIN: int = 26  # нижний предел ужатия длинного текста
# Песочные часы: пауза, затем переворот на 180°.
const _CLOCK_PAUSE: float = 1.2
const _CLOCK_FLIP: float = 0.6
const _DIM_OUTCOME: float = 0.32  # несбывшийся исход после броска

const _INK := Color(0.17, 0.12, 0.08)  # чернила на бланке
const _INK_SUCCESS := Color(0.2, 0.36, 0.18)
const _INK_FAILURE := Color(0.55, 0.14, 0.11)

var _root: Control
var _holder: Control  # масштабированный лист внутри (модальный pop — по нему)
var _sheet: Control
var _name: Label
var _time: Label
var _code: Label
var _body: VBoxContainer
var _head: Label
var _text: Label
var _success_row: Control
var _failure_row: Control
var _success_text: RichTextLabel
var _failure_text: RichTextLabel
var _clock: TextureRect
var _clock_tween: Tween

var _sig: String = ""  # подпись состояния — чтобы не перерисовывать каждый синк
var _telegram: String = ""  # какая встреча сейчас на бланке (новая — новые время и код)
var _dismissed: String = ""  # закрыта крестиком — до следующей встречи


func _ready() -> void:
	layer = 79  # под модалками проверок/Порога (86/87) и оверлеями Тени
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	GameState.state_changed.connect(_refresh)
	get_viewport().size_changed.connect(_layout)
	_refresh()


# ── Сборка ────────────────────────────────────────────────────────────────────


func _build() -> void:
	# Полноэкранный якорь: кликам не мешаем (ловит только сам лист).
	_root = Control.new()
	_root.name = "WatchAnchor"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_holder = Control.new()
	_holder.name = "Telegram"
	_holder.mouse_filter = Control.MOUSE_FILTER_STOP  # лист не «прокликивается» на карту
	center.add_child(_holder)

	_sheet = Control.new()
	_sheet.name = "Sheet"
	_sheet.size = _SHEET
	_sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_holder.add_child(_sheet)

	var bg := TextureRect.new()
	bg.name = "Blank"
	bg.texture = _BG
	bg.size = _SHEET
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_child(bg)

	_name = _ink_label("Name", _FS_NAME, HORIZONTAL_ALIGNMENT_CENTER)
	_place(_name, _NAME_RECT)
	_time = _ink_label("DispatchTime", _FS_TIME, HORIZONTAL_ALIGNMENT_CENTER)
	_place(_time, _TIME_RECT)

	_code = _ink_label("CommsCode", _FS_CODE, HORIZONTAL_ALIGNMENT_CENTER)
	_code.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_code.position = _CODE_POS
	_code.size = _CODE_SIZE
	_code.pivot_offset = _CODE_SIZE * 0.5
	_code.rotation_degrees = _CODE_TILT_DEG
	_sheet.add_child(_code)

	_build_body()
	_build_footer()
	_build_close()
	_root.visible = false
	_layout()


func _build_body() -> void:
	_body = VBoxContainer.new()
	_body.name = "Body"
	_body.add_theme_constant_override("separation", 22)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(_body, _BODY_RECT)

	_head = _section_header(_body, "EncounterHeader", "TELEGRAM_ENCOUNTER")
	_text = _ink_label("Text", _FS_BODY, HORIZONTAL_ALIGNMENT_CENTER)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(_text)

	_body.add_child(_divider("Divider1"))
	_section_header(_body, "OutcomesHeader", "TELEGRAM_OUTCOMES")
	_success_row = _outcome_row("SuccessRow", _SUCCESS)
	_success_text = _success_row.get_node("Text")
	_body.add_child(_success_row)
	_body.add_child(_divider("Divider2"))
	_failure_row = _outcome_row("FailureRow", _FAILURE)
	_failure_text = _failure_row.get_node("Text")
	_body.add_child(_failure_row)


func _build_footer() -> void:
	var row := HBoxContainer.new()
	row.name = "Footer"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 24)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(row, _FOOTER_RECT)

	# Часы крутятся вокруг центра — держим их в фиксированной коробке.
	var box := Control.new()
	box.name = "ClockBox"
	box.custom_minimum_size = _SAND_CLOCK.get_size()
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(box)
	_clock = TextureRect.new()
	_clock.name = "SandClock"
	_clock.texture = _SAND_CLOCK
	_clock.size = _SAND_CLOCK.get_size()
	_clock.pivot_offset = _SAND_CLOCK.get_size() * 0.5
	_clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_clock)

	var lbl := UIStyle.label("TELEGRAM_IN_PROGRESS", _FS_FOOTER, UIColors.ACCENT)
	lbl.name = "InProgress"
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lbl)


# Крестик нарисован в арте — поверх него прозрачная кнопка.
func _build_close() -> void:
	var btn := Button.new()
	btn.name = "Close"
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	btn.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	btn.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_place(btn, _CLOSE_RECT)
	btn.pressed.connect(
		func() -> void:
			_dismissed = _telegram
			_refresh()
	)


func _ink_label(node_name: String, fs: int, align: int) -> Label:
	var l := UIStyle.label("", fs, _INK, align)
	l.name = node_name
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _place(c: Control, r: Rect2) -> void:
	c.position = r.position
	c.size = r.size
	_sheet.add_child(c)


# «◆ ЗАГОЛОВОК ◆» — шевроны из арта по бокам.
func _section_header(parent: Control, node_name: String, key: String) -> Label:
	var row := HBoxContainer.new()
	row.name = node_name
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)
	row.add_child(_icon("ChevronL", _CHEV_L, _CHEV_L.get_size()))
	var l := _ink_label("Label", _FS_HEAD, HORIZONTAL_ALIGNMENT_CENTER)
	l.text = key
	row.add_child(l)
	row.add_child(_icon("ChevronR", _CHEV_R, _CHEV_R.get_size()))
	return l


func _divider(node_name: String) -> TextureRect:
	var d := _icon(node_name, _DIVIDER, Vector2(_BODY_RECT.size.x, _DIVIDER.get_height()))
	d.stretch_mode = TextureRect.STRETCH_SCALE
	return d


func _outcome_row(node_name: String, tex: Texture2D) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = node_name
	row.add_theme_constant_override("separation", 28)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var w: float = _ICON_H * tex.get_width() / tex.get_height()
	var icon := _icon("Icon", tex, Vector2(w, _ICON_H))
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)
	var rt := RichTextLabel.new()
	rt.name = "Text"
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.add_theme_color_override("default_color", _INK)
	row.add_child(rt)
	return row


func _icon(node_name: String, tex: Texture2D, sz: Vector2) -> TextureRect:
	var t := TextureRect.new()
	t.name = node_name
	t.texture = tex
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = sz
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


# Лист — под высоту экрана (арт @2x, не крупнее половины).
func _layout() -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var s: float = minf(_MAX_SCALE, vp.y * _SCREEN_FRAC / _SHEET.y)
	_sheet.scale = Vector2(s, s)
	_holder.custom_minimum_size = _SHEET * s
	_holder.size = _SHEET * s


# ── Состояние ─────────────────────────────────────────────────────────────────


# Чужая ли сейчас встреча (я — наблюдатель). Погибшая Тень тоже наблюдатель.
func _watching_pid() -> String:
	if not GameState.active or GameState.phase != Phases.ENCOUNTER:
		return ""
	var pid: String = GameState.current_pid()
	if pid.is_empty() or pid == NetworkManager.my_user_id:
		return ""  # моя встреча — её показывает обычная модалка встречи
	return pid


# Активный узел карты: у ветвящихся (gate/mystery) — stage1 либо ветка по итогу
# первой проверки; у плоской встречи — сама карта.
func _node(card: Dictionary) -> Dictionary:
	var kind: String = String(card.get("kind", ""))
	if kind != "gate" and kind != "mystery":
		return card
	if int(card.get("stage", 0)) <= 0:
		return card.get("stage1", {})
	var branches: Dictionary = card.get("branches", {})
	return branches.get(String(card.get("branch", "success")), {})


# Проверка встречи (owner=encounter) — из неё берём только факт «сыграно» и исход.
func _check() -> Dictionary:
	var c: Dictionary = GameState.active_check
	return c if String(c.get("owner", "")) == "encounter" else {}


func _refresh() -> void:
	var pid: String = _watching_pid()
	var card: Dictionary = GameState.current_encounter
	var telegram: String = "%s|%s" % [pid, String(card.get("name", ""))]
	# Прячем: моя встреча / нет карты / игрок ещё выбирает тип / бой (своя модалка) /
	# телеграмму закрыли крестиком (до следующей встречи).
	# НЕ называть `show` — затеняет метод CanvasLayer.show() (предупреждение движка).
	var watching: bool = (
		not pid.is_empty()
		and not card.is_empty()
		and (GameState.encounter_choices as Array).is_empty()
		and String(card.get("kind", "")) != "combat"
		and telegram != _dismissed
	)
	if not watching:
		UIStyle.modal_set_visible(_root, _holder, false)
		_stop_clock()
		_sig = ""
		return

	var node: Dictionary = _node(card)
	var chk: Dictionary = _check()
	var rolled: bool = bool(chk.get("rolled", false))
	var passed: bool = bool(chk.get("passed", false))
	# Перерисовываем только при смене содержимого (синк прилетает часто).
	var sig: String = (
		"%s|%d|%s|%s" % [telegram, int(card.get("stage", 0)), str(rolled), str(passed)]
	)
	UIStyle.modal_set_visible(_root, _holder, true)
	_start_clock()
	if sig == _sig:
		return
	_sig = sig

	if telegram != _telegram:
		# Новая телеграмма: время отправки — реальное время читающего, код — свежий.
		_telegram = telegram
		_time.text = dispatch_time()
		_code.text = comms_code()
	_name.text = _investigator_name(pid).to_upper()
	var nm: String = String(card.get("name", "")).strip_edges()
	_head.text = nm.to_upper() if not nm.is_empty() else tr("TELEGRAM_ENCOUNTER")
	_text.text = String(node.get("mainText", "")).strip_edges()
	_success_text.text = _outcome_bbcode(
		"TELEGRAM_SUCCESS", _INK_SUCCESS, String(node.get("successText", ""))
	)
	_failure_text.text = _outcome_bbcode(
		"TELEGRAM_FAILURE", _INK_FAILURE, String(node.get("failureText", ""))
	)
	# Сыграно — несбывшийся исход гаснет.
	_success_row.modulate.a = 1.0 if not rolled or passed else _DIM_OUTCOME
	_failure_row.modulate.a = 1.0 if not rolled or not passed else _DIM_OUTCOME
	_fit_text.call_deferred()


func _investigator_name(pid: String) -> String:
	var inv: String = String((GameState.players.get(pid, {}) as Dictionary).get("investigator", ""))
	if inv.is_empty():
		return GameState.name_of(pid)
	return tr(Investigators.display_name(inv))


func _outcome_bbcode(key: String, col: Color, text: String) -> String:
	return (
		"[color=#%s]%s[/color] %s"
		% [col.to_html(false), tr(key), text.strip_edges().replace("[", "[lb]")]
	)


# Длинная встреча — ужимаем шрифты тела, пока всё не влезет в поле бланка.
func _fit_text() -> void:
	var fs: int = _FS_BODY
	while true:
		_text.add_theme_font_size_override("font_size", fs)
		for rt: RichTextLabel in [_success_text, _failure_text]:
			rt.add_theme_font_size_override("normal_font_size", fs)
		if _body.get_combined_minimum_size().y <= _BODY_RECT.size.y or fs <= _FS_MIN:
			break
		fs -= 2
	_body.size = _BODY_RECT.size


# ── Песочные часы ─────────────────────────────────────────────────────────────


# Пауза — переворот на 180° — пауза… Пока телеграмма открыта.
func _start_clock() -> void:
	if _clock_tween != null and _clock_tween.is_valid():
		return
	_clock_tween = create_tween().set_loops()
	_clock_tween.tween_interval(_CLOCK_PAUSE)
	(
		_clock_tween
		. tween_property(_clock, "rotation", PI, _CLOCK_FLIP)
		. as_relative()
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_IN_OUT)
	)


func _stop_clock() -> void:
	if _clock_tween != null and _clock_tween.is_valid():
		_clock_tween.kill()
	_clock_tween = null
	if is_instance_valid(_clock):
		_clock.rotation = 0.0


# ── Время и код ───────────────────────────────────────────────────────────────


## Время отправки — реальное время ЧИТАЮЩЕГО игрока, «ЧЧ:ММ».
static func dispatch_time() -> String:
	var t: Dictionary = Time.get_time_dict_from_system()
	return "%02d:%02d" % [int(t["hour"]), int(t["minute"])]


## Код связи как в макете: цифра+буква, две цифры, две буквы — «7Y-19-KA».
static func comms_code(rng: RandomNumberGenerator = null) -> String:
	var r: RandomNumberGenerator = rng
	if r == null:
		r = RandomNumberGenerator.new()
		r.randomize()
	var letters: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	var letter := func() -> String: return letters[r.randi_range(0, letters.length() - 1)]
	return (
		"%d%s-%02d-%s%s"
		% [r.randi_range(1, 9), letter.call(), r.randi_range(0, 99), letter.call(), letter.call()]
	)
