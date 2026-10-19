extends CanvasLayer

## Экран паузы — открывается/закрывается по Escape на любой сцене (включая
## login и main_menu — иначе оттуда нельзя выйти из игры) и кнопкой-«гамбургером»
## в левом верхнем углу карты (toggle()).
## Autoload-синглтон: /root/PauseMenu (см. project.godot). Строится кодом.
##
## Слева — колонка меню («ПАУЗА» + пункты), посередине сквозь затемнение видна
## карта, справа (только в партии) — сводка: последние послания (лента действий и
## чат), текущие задачи (активная Тайна и Слухи), время игры (сессия, раунд, фаза).
##
## Settings — переиспользует общий SettingsDialog (тот же, что в main_menu).
##
## Если на сцене открыт диалог (settings_dialog / create_room_dialog), его
## _unhandled_key_input проглатывает Escape РАНЬШЕ нашего _unhandled_input
## (в Godot 4 _unhandled_key_input идёт первым) — так что пауза поверх
## модалок не выскакивает.

const _SETTINGS_DIALOG := preload("res://scenes/ui/settings_dialog.tscn")

const _MENU_W: float = 520.0  # ширина левой колонки
const _SIDE_W: float = 560.0  # ширина правой колонки сводки
const _TITLE_FS: int = 64
const _ITEM_FS: int = 34
const _ITEM_H: float = 72.0
const _HEAD_FS: int = 26
const _BODY_FS: int = 20
const _MESSAGES_SHOWN: int = 4  # сколько последних посланий в сводке
const _MESSAGES_KEPT: int = 30  # сколько копим (история транзиентна — с начала сессии)

var _open: bool = false
var _settings_dialog: Control = null
var _root: Control
var _menu_col: Control
var _side_col: VBoxContainer
var _items: VBoxContainer
var _continue_btn: Button
var _menu_btn: Button
var _messages_box: VBoxContainer
var _tasks_box: VBoxContainer
var _time_value: Label
var _time_box: VBoxContainer

# История посланий: [{pid, kind:"action"|"chat", id, params|nouns, time}] — новые в конце.
var _messages: Array = []
var _session_msec: int = -1  # когда началась партия (GameState.active), -1 — не идёт

# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	_build()
	# GameState — автолоад ПОЗЖЕ нас: подписываемся, когда дерево собрано.
	_connect_game_state.call_deferred()


func _connect_game_state() -> void:
	var gs: Node = get_node_or_null("/root/GameState")
	if gs == null:
		return
	gs.connect("action_announced", _on_action)
	gs.connect("chat_received", _on_chat)
	gs.connect("state_changed", _on_state_changed)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	toggle()
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if _open and _time_value != null:
		_time_value.text = _elapsed_text()


## Открыть/закрыть паузу (Escape, «гамбургер» на карте, «Продолжить»).
func toggle() -> void:
	if is_instance_valid(_settings_dialog):
		return  # открыты настройки — их закрывает сам диалог
	_open = not _open
	if _open:
		_update_for_current_scene()
	visible = _open
	get_tree().paused = _open
	if _open:
		# Фокус на первом видимом пункте — Enter/стрелки работают сразу.
		for b_v: Node in _items.get_children():
			if (b_v as Control).visible:
				(b_v as Control).grab_focus()
				break


# ── Построение ────────────────────────────────────────────────────────────────


func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP  # карта под паузой не кликается
	add_child(_root)

	var dim := ColorRect.new()
	dim.name = "Backdrop"
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	_build_menu_column()
	_build_side_column()


# Левая колонка: тёмная подложка с мягким краем, заголовок, пункты меню.
func _build_menu_column() -> void:
	_menu_col = Control.new()
	_menu_col.name = "MenuColumn"
	_menu_col.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_menu_col.custom_minimum_size.x = _MENU_W
	_menu_col.size.x = _MENU_W
	_menu_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_menu_col)

	# Подложка: почти чёрная у левого края, к правому — растворяется в карту.
	var grad := Gradient.new()
	grad.set_color(0, Color(0.02, 0.018, 0.015, 0.97))
	grad.set_color(1, Color(0.02, 0.018, 0.015, 0.0))
	grad.add_point(0.78, Color(0.02, 0.018, 0.015, 0.92))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(1, 0)
	var bg := TextureRect.new()
	bg.name = "Shade"
	bg.texture = tex
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	bg.offset_right = _MENU_W + 120.0
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_col.add_child(bg)

	# Тонкая янтарная черта — граница колонки (как в макете).
	var line := ColorRect.new()
	line.name = "Edge"
	line.color = Color(UIColors.ACCENT, 0.35)
	line.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	line.offset_left = _MENU_W
	line.offset_right = _MENU_W + 1.0
	line.offset_top = 40.0
	line.offset_bottom = -40.0
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_col.add_child(line)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	margin.offset_right = _MENU_W
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 0)
	margin.add_theme_constant_override("margin_top", 70)
	_menu_col.add_child(margin)

	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 10)
	margin.add_child(vb)

	# Общий орнаментальный заголовок: шеврон · «ПАУЗА» · шеврон.
	var title := UIStyle.ornate_title("PAUSE_TITLE", _TITLE_FS, UIColors.ACCENT)
	title.custom_minimum_size.x = _MENU_W - 80.0
	vb.add_child(title)

	var gap := Control.new()
	gap.name = "Gap"
	gap.custom_minimum_size.y = 40.0
	vb.add_child(gap)

	_items = VBoxContainer.new()
	_items.name = "Items"
	_items.add_theme_constant_override("separation", 6)
	vb.add_child(_items)
	_continue_btn = _menu_item("PAUSE_RESUME", toggle)
	_menu_item("PAUSE_SETTINGS", _open_settings)
	_menu_btn = _menu_item("PAUSE_MAIN_MENU", _go_main_menu)
	_menu_item("PAUSE_LEAVE", _quit_game)


# Пункт меню: строка текста на всю ширину колонки; наведение/фокус — янтарная
# подсветка с чертой слева (как выделенный «Продолжить» в макете).
func _menu_item(key: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.name = key.capitalize().replace(" ", "")
	b.text = key
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(_MENU_W - 40.0, _ITEM_H)
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_size_override("font_size", _ITEM_FS)
	b.add_theme_color_override("font_color", UIColors.TEXT)
	for st: String in ["font_hover_color", "font_focus_color", "font_pressed_color"]:
		b.add_theme_color_override(st, UIColors.ACCENT)
	var normal := StyleBoxEmpty.new()
	normal.content_margin_left = 28.0
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("disabled", normal)
	var hot := StyleBoxFlat.new()
	hot.bg_color = Color(UIColors.ACCENT, 0.16)
	hot.border_color = UIColors.ACCENT
	hot.border_width_left = 3
	hot.content_margin_left = 28.0
	for st: String in ["hover", "focus", "pressed"]:
		b.add_theme_stylebox_override(st, hot)
	b.mouse_entered.connect(b.grab_focus)  # мышь и клавиатура подсвечивают один пункт
	b.pressed.connect(on_press)
	_items.add_child(b)
	return b


# Правая колонка: три рамки сводки партии.
func _build_side_column() -> void:
	_side_col = VBoxContainer.new()
	_side_col.name = "SideColumn"
	_side_col.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_side_col.offset_left = -_SIDE_W - 48.0
	_side_col.offset_right = -48.0
	_side_col.offset_top = 110.0
	_side_col.offset_bottom = -40.0
	_side_col.add_theme_constant_override("separation", 18)
	_side_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_side_col)
	_messages_box = _side_panel("Messages", "PAUSE_MESSAGES")
	_tasks_box = _side_panel("Tasks", "PAUSE_TASKS")
	_time_box = _side_panel("Time", "PAUSE_TIME")
	# Время сессии — справа в шапке своей рамки (как «05:42:17» в макете).
	var head: HBoxContainer = _time_box.get_node("Head")
	_time_value = UIStyle.label("", _HEAD_FS, UIColors.TEXT, HORIZONTAL_ALIGNMENT_RIGHT)
	_time_value.name = "Elapsed"
	_time_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_time_value)


# Рамка сводки: шапка-заголовок + тело (VBox, его наполняет _refresh_side).
func _side_panel(node_name: String, title_key: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.name = node_name
	UIStyle.style_modal_panel(panel)
	_side_col.add_child(panel)
	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side: String in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	for side: String in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)
	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)
	var head := HBoxContainer.new()
	head.name = "Head"
	vb.add_child(head)
	var t := UIStyle.label(title_key, _HEAD_FS, UIColors.ACCENT)
	t.name = "Title"
	head.add_child(t)
	UIStyle.separator(vb)
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 10)
	vb.add_child(body)
	return vb


# ── Состояние экрана ──────────────────────────────────────────────────────────


# На login / main_menu / home партии ещё/уже нет: «Продолжить» и «В меню»
# бессмысленны, сводки нет — остаются Настройки и Выход. Закрыть паузу на этих
# экранах можно повторным Escape.
func _update_for_current_scene() -> void:
	var scene := get_tree().current_scene
	var path: String = scene.scene_file_path if is_instance_valid(scene) else ""
	var on_pre_game: bool = "login" in path or "main_menu" in path or "home" in path
	_continue_btn.visible = not on_pre_game
	_menu_btn.visible = not on_pre_game
	var in_game: bool = "world_map" in path and bool(GameState.active)
	_side_col.visible = in_game
	if in_game:
		_refresh_side()


func _refresh_side() -> void:
	_fill_messages()
	_fill_tasks()
	_fill_time()


func _body(box: VBoxContainer) -> VBoxContainer:
	var body: VBoxContainer = box.get_node("Body")
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	return body


func _text(text: String, size: int, color: Color) -> Label:
	var l := UIStyle.label(text, size, color)
	l.name = "Line"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = _SIDE_W - 110.0  # минус поля рамки и отступы — иначе колонка распирается
	return l


# Послания: последние записи ленты действий и чата — кто, что, когда.
func _fill_messages() -> void:
	var body: VBoxContainer = _body(_messages_box)
	var shown: int = 0
	var locale: String = I18n.get_locale()
	for i in range(_messages.size() - 1, -1, -1):
		if shown >= _MESSAGES_SHOWN:
			break
		var m: Dictionary = _messages[i]
		var text: String = (
			Messages.render(String(m.get("id", "")), m.get("nouns", []), locale)
			if String(m.get("kind", "")) == "chat"
			else ActionLog.render(String(m.get("id", "")), m.get("params", {}), locale)
		)
		if text.is_empty():
			continue
		var head := HBoxContainer.new()
		head.name = "MessageHead"
		var who := UIStyle.label(
			GameState.name_of(String(m.get("pid", ""))), _BODY_FS + 2, UIColors.ACCENT
		)
		who.name = "Who"
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(who)
		var at := UIStyle.label(String(m.get("time", "")), _BODY_FS - 2, UIColors.MUTED)
		at.name = "At"
		head.add_child(at)
		body.add_child(head)
		body.add_child(_text(text, _BODY_FS, UIColors.TEXT))
		shown += 1
	if shown == 0:
		body.add_child(_text(tr("PAUSE_NO_MESSAGES"), _BODY_FS, UIColors.MUTED))


# Текущие задачи: активная Тайна (что сделать, прогресс по локациям/жетонам) и Слухи.
func _fill_tasks() -> void:
	var body: VBoxContainer = _body(_tasks_box)
	var m: Dictionary = GameState.current_mystery()
	if m.is_empty():
		body.add_child(_text(tr("MYSTERY_NONE_TITLE"), _BODY_FS + 2, UIColors.TEXT))
	else:
		body.add_child(_text("○  " + String(m.get("title", "")), _BODY_FS + 4, UIColors.TEXT))
		var goal: String = String(m.get("text", ""))
		if not goal.is_empty():
			body.add_child(_text(goal, _BODY_FS - 2, UIColors.MUTED))
		var sc: Dictionary = m.get("solveCondition", {})
		var target: int = int(sc.get("n", 1))
		if String(sc.get("kind", "")) == "tokensOnCard":
			body.add_child(
				_text(
					tr("MYSTERY_TOKENS_FMT") % [GameState.mystery_tokens_on_card, target],
					_BODY_FS,
					UIColors.VALUE
				)
			)
		else:
			body.add_child(
				_text(
					tr("MYSTERY_PROGRESS_FMT") % [GameState.mystery_progress, target],
					_BODY_FS,
					UIColors.VALUE
				)
			)
			for lid_v: Variant in m.get("locations", []):
				var lid: String = String(lid_v)
				var done: bool = (GameState.mystery_claimed as Array).has(lid)
				body.add_child(
					_text(
						("✓  " if done else "·  ") + tr(GameState.map.name_key(lid)),
						_BODY_FS,
						UIColors.MUTED if done else UIColors.TEXT
					)
				)
	for r_v: Variant in GameState.rumors_in_play():
		var r: Dictionary = r_v
		(
			body
			. add_child(
				_text(
					(
						"%s: %s — %d %s"
						% [
							tr("PAUSE_RUMOR"),
							String(r.get("name", "?")),
							int(r.get("tokens", 0)),
							tr("RUMOR_TOKENS_WORD"),
						]
					),
					_BODY_FS,
					UIColors.TEXT
				)
			)
		)


# Время игры: сессия (в шапке), раунд и фаза, Рок до пробуждения Древнего.
func _fill_time() -> void:
	var body: VBoxContainer = _body(_time_box)
	_time_value.text = _elapsed_text()
	body.add_child(
		_text(
			tr("PAUSE_ROUND_FMT") % [int(GameState.round_num), tr(_phase_key())],
			_BODY_FS + 2,
			UIColors.TEXT
		)
	)
	var clock: int = int(GameState.campaign.get("doomClock", 0))
	if clock > 0:
		body.add_child(
			_text(tr("PAUSE_DOOM_FMT") % [int(GameState.doom), clock], _BODY_FS, UIColors.MUTED)
		)


func _phase_key() -> String:
	match String(GameState.phase):
		Phases.ACTION:
			return "PHASE_ACTION"
		Phases.ENCOUNTER:
			return "PHASE_ENCOUNTER"
		Phases.MYTHOS:
			return "PHASE_MYTHOS"
	return String(GameState.phase)


func _elapsed_text() -> String:
	if _session_msec < 0:
		return "—"
	var s: int = int((Time.get_ticks_msec() - _session_msec) / 1000)
	return "%02d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]


# ── История посланий и сессия ─────────────────────────────────────────────────


func _on_action(pid: String, action_id: String, params: Dictionary) -> void:
	_remember({"pid": pid, "kind": "action", "id": action_id, "params": params})


func _on_chat(pid: String, phrase_id: String, noun_ids: Array) -> void:
	_remember({"pid": pid, "kind": "chat", "id": phrase_id, "nouns": noun_ids})


func _remember(m: Dictionary) -> void:
	m["time"] = Time.get_time_string_from_system().substr(0, 5)
	_messages.append(m)
	if _messages.size() > _MESSAGES_KEPT:
		_messages.pop_front()


# Партия началась — засекаем сессию; закончилась — сбрасываем и историю.
func _on_state_changed() -> void:
	var active: bool = bool(GameState.active)
	if active and _session_msec < 0:
		_session_msec = Time.get_ticks_msec()
	elif not active and _session_msec >= 0:
		_session_msec = -1
		_messages.clear()


# ── Settings (через общий SettingsDialog) ─────────────────────────────────────


func _open_settings() -> void:
	if is_instance_valid(_settings_dialog):
		return  # уже открыт
	_menu_col.visible = false
	_side_col.visible = false
	_settings_dialog = _SETTINGS_DIALOG.instantiate()
	_settings_dialog.name = "SettingsDialog"
	_settings_dialog.show_server_url = false  # в идущей игре сервер не меняется
	_root.add_child(_settings_dialog)
	# По обоим сигналам (saved + cancelled) поведение одно — вернуться к
	# паузе. Сам диалог делает queue_free.
	_settings_dialog.tree_exited.connect(
		func() -> void:
			_settings_dialog = null
			_menu_col.visible = true
			_update_for_current_scene()
	)


# ── Прочие кнопки ─────────────────────────────────────────────────────────────


func _go_main_menu() -> void:
	_open = false
	visible = false
	get_tree().paused = false
	var nm: Node = get_node_or_null("/root/NetworkManager")
	if nm:
		(nm as Node).call("leave_room")
	SceneManager.go("main_menu")


func _quit_game() -> void:
	get_tree().paused = false
	# Через NetworkManager.leave_and_quit: шлём leave_room до закрытия, чтобы relay
	# сразу промоутил нового хоста (иначе обрыв уводит хоста в 12с grace).
	var nm: Node = get_node_or_null("/root/NetworkManager")
	if nm and nm.has_method("leave_and_quit"):
		nm.leave_and_quit()
	else:
		get_tree().quit()
