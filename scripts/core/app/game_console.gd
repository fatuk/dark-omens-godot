extends CanvasLayer

## Игровая консоль для отладки.
## Открывается/закрывается клавишей ~ (backtick/tilde).
##
## Использование из любого скрипта:
##   GameConsole.log("сообщение")
##   GameConsole.warn("предупреждение")
##   GameConsole.err("ошибка")

const MAX_ENTRIES := 300
const FONT_SIZE := 24
const HEADER_SIZE := 20

var _shown: bool = false
var _root: Control = null
var _panel: PanelContainer = null
var _scroll: ScrollContainer = null
var _log_box: VBoxContainer = null
var _input_line: LineEdit = null
var _suggest_panel: PanelContainer = null
var _suggest_box: VBoxContainer = null
var _matches: Array = []  # текущие подсказки [{text, hint}]
var _sel: int = 0  # выбранная подсказка (индекс в _matches)
var _tween: Tween = null

const _SUGGEST_MAX := 8  # сколько подсказок показывать разом
const _COLORS := ["green", "blue", "red"]  # цвета врат для gate

# Виды встреч для `enc` (зеркало DebugGrant.ENCOUNTER_KINDS) и девять Иных миров
# в каноничном написании — реле принимает только его (см. OTHER_WORLDS в relay).
const _ENC_KINDS := {
	"general": "общая встреча",
	"local": "локационная (привязана к клетке)",
	"research": "исследование (улика)",
	"gate": "врата в Иной мир",
	"mystery": "Тайна",
}
const _WORLDS := [
	"Dreamlands",
	"Yuggoth",
	"The Abyss",
	"The Underworld",
	"City of the Great Race",
	"Lost Carcosa",
	"Great Hall of Celaeno",
	"The Past",
	"The Future",
]
const _WORLD_UNKNOWN := "?"  # _resolve_world: токен задан, но ни на что не похож

# ── Публичный API ─────────────────────────────────────────────────────────────


func log(msg: String) -> void:
	_add_entry("[%s]  %s" % [_ts(), msg], Color(0.82, 0.82, 0.82))


func warn(msg: String) -> void:
	_add_entry("[%s]  ⚠ %s" % [_ts(), msg], Color(0.95, 0.82, 0.22))


func err(msg: String) -> void:
	_add_entry("[%s]  ✖ %s" % [_ts(), msg], Color(0.92, 0.28, 0.28))


## Открыта ли консоль. Для игровых экранов — глушить ввод карты, пока печатаешь.
func is_open() -> bool:
	return _shown


# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	layer = 100
	_build_ui()
	# Панель по «~» — только в dev-сборках; в релизе игрок консоль не открывает
	# (логирование через GameConsole.log при этом работает всегда).
	set_process_input(OS.is_debug_build())


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and (event as InputEventKey).pressed):
		return
	var key := event as InputEventKey
	if key.keycode == KEY_QUOTELEFT and not key.echo:
		_toggle()
		get_viewport().set_input_as_handled()
		return
	# Навигация по автодополнению — только пока строка ввода в фокусе.
	if not (_shown and is_instance_valid(_input_line) and _input_line.has_focus()):
		return
	match key.keycode:
		KEY_TAB:  # принять/дописать ближайшую подсказку (echo — автоповтор удержания)
			_accept_current()
			get_viewport().set_input_as_handled()
		KEY_UP:
			if not _matches.is_empty():
				_move_sel(-1)
				get_viewport().set_input_as_handled()
		KEY_DOWN:
			if not _matches.is_empty():
				_move_sel(1)
				get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			if _suggest_panel.visible:
				_hide_suggestions()
				get_viewport().set_input_as_handled()


# ── Построение UI ─────────────────────────────────────────────────────────────


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)

	# Панель: нижняя половина экрана, начальные смещения = 0
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.anchor_left = 0.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.50
	_panel.anchor_bottom = 1.0
	_panel.offset_left = 0
	_panel.offset_right = 0
	_panel.offset_top = 0
	_panel.offset_bottom = 0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.03, 0.08, 0.88)
	style.border_color = Color(0.30, 0.24, 0.50, 0.70)
	style.set_border_width_all(1)
	style.set_corner_radius_all(0)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 6)
	_panel.add_child(vbox)

	var header := Label.new()
	header.name = "Header"
	header.text = "CONSOLE_HEADER"
	header.add_theme_font_size_override("font_size", HEADER_SIZE)
	header.add_theme_color_override("font_color", Color(0.45, 0.40, 0.65))
	vbox.add_child(header)

	var sep := HSeparator.new()
	sep.name = "Sep"
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color(0.30, 0.24, 0.50, 0.35)
	sep_style.content_margin_top = 0
	sep_style.content_margin_bottom = 0
	sep.add_theme_stylebox_override("separator", sep_style)
	vbox.add_child(sep)

	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vbox.add_child(_scroll)

	_log_box = VBoxContainer.new()
	_log_box.name = "LogBox"
	_log_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_box.add_theme_constant_override("separation", 2)
	_scroll.add_child(_log_box)

	# Панель автодополнения (над вводом; скрыта, пока нет подсказок).
	_suggest_panel = PanelContainer.new()
	_suggest_panel.name = "Suggest"
	_suggest_panel.visible = false
	_suggest_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sg_style := StyleBoxFlat.new()
	sg_style.bg_color = Color(0.02, 0.02, 0.05, 0.95)
	sg_style.border_color = Color(0.30, 0.24, 0.50, 0.45)
	sg_style.set_border_width_all(1)
	sg_style.content_margin_left = 8
	sg_style.content_margin_right = 8
	sg_style.content_margin_top = 4
	sg_style.content_margin_bottom = 4
	_suggest_panel.add_theme_stylebox_override("panel", sg_style)
	vbox.add_child(_suggest_panel)

	_suggest_box = VBoxContainer.new()
	_suggest_box.name = "SuggestBox"
	_suggest_box.add_theme_constant_override("separation", 1)
	_suggest_panel.add_child(_suggest_box)

	# Строка ввода debug-команд (give / spawn / gate / cond / list / who / help).
	_input_line = LineEdit.new()
	_input_line.name = "Input"
	_input_line.placeholder_text = "help · give me flesh_ward · spawn deep_one @uptown · gate @rivertown"
	_input_line.clear_button_enabled = false
	_input_line.add_theme_font_size_override("font_size", FONT_SIZE)
	var in_style := StyleBoxFlat.new()
	in_style.bg_color = Color(0.02, 0.02, 0.05, 0.9)
	in_style.border_color = Color(0.30, 0.24, 0.50, 0.55)
	in_style.set_border_width_all(1)
	in_style.content_margin_left = 8
	in_style.content_margin_right = 8
	in_style.content_margin_top = 4
	in_style.content_margin_bottom = 4
	_input_line.add_theme_stylebox_override("normal", in_style)
	_input_line.add_theme_stylebox_override("focus", in_style)
	_input_line.text_submitted.connect(_on_command_submitted)
	_input_line.text_changed.connect(_on_text_changed)
	# Пока консоль открыта, клавиатура — её: любую потерю фокуса (перерисовка UI после
	# give/spawn, модалка, клик по логу) возвращаем в строку ввода на следующем idle.
	_input_line.focus_exited.connect(_reclaim_focus)
	vbox.add_child(_input_line)


# ── Анимация ──────────────────────────────────────────────────────────────────


func _toggle() -> void:
	_shown = not _shown
	if _tween and _tween.is_valid():
		_tween.kill()

	var panel_h: float = get_viewport().get_visible_rect().size.y * 0.50

	if _shown:
		# Сдвигаем панель вниз за экран перед показом
		_panel.offset_top = panel_h
		_panel.offset_bottom = panel_h
		_root.visible = true

		_tween = create_tween()
		_tween.set_ease(Tween.EASE_OUT)
		_tween.set_trans(Tween.TRANS_QUART)
		_tween.tween_property(_panel, "offset_top", 0.0, 0.28)
		_tween.parallel().tween_property(_panel, "offset_bottom", 0.0, 0.28)
		_scroll_bottom_deferred()
		if is_instance_valid(_input_line):
			_input_line.grab_focus()
	else:
		_hide_suggestions()
		if is_instance_valid(_input_line):
			_input_line.release_focus()  # чтобы поле не ело клавиатуру в игре
		_tween = create_tween()
		_tween.set_ease(Tween.EASE_IN)
		_tween.set_trans(Tween.TRANS_QUART)
		_tween.tween_property(_panel, "offset_top", panel_h, 0.22)
		_tween.parallel().tween_property(_panel, "offset_bottom", panel_h, 0.22)
		_tween.tween_callback(func() -> void: _root.visible = false)


# ── Логика ────────────────────────────────────────────────────────────────────


func _add_entry(text: String, color: Color) -> void:
	if _log_box.get_child_count() >= MAX_ENTRIES:
		_log_box.get_child(0).free()

	var lbl := Label.new()
	lbl.name = "Label"
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", FONT_SIZE)
	lbl.add_theme_color_override("font_color", color)
	lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	_log_box.add_child(lbl)

	if _shown:
		_scroll_bottom_deferred()


func _scroll_bottom_deferred() -> void:
	# Двух кадров хватает, чтобы контейнер пересчитал высоту после пачки строк.
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _ts() -> String:
	return Time.get_time_string_from_system()


# ── Автодополнение (shell-стиль) ──────────────────────────────────────────────
# По мере ввода над строкой всплывает список подсказок для ТЕКУЩЕГО токена
# (команда → её аргумент по контексту). Tab — принять выбранную (дописать + пробел),
# ↑/↓ — перебрать, Esc — скрыть. Кандидаты берутся из тех же каталогов/игроков,
# что и резолв, — рассинхрона «подсказали одно, приняло другое» нет.

const _COMMANDS := [
	{"text": "give", "hint": "актив/заклинание в руку"},
	{"text": "spawn", "hint": "монстр на локации"},
	{"text": "gate", "hint": "открыть врата"},
	{"text": "cond", "hint": "наложить состояние"},
	{"text": "enc", "hint": "назначить встречу игроку"},
	{"text": "list", "hint": "список каталога"},
	{"text": "who", "hint": "игроки"},
	{"text": "clear", "hint": "очистить консоль"},
	{"text": "help", "hint": "справка"},
]


func _on_text_changed(_new_text: String) -> void:
	_recompute_suggestions()


## Пересобрать список подсказок по текущему тексту и позиции токена.
func _recompute_suggestions() -> void:
	var text: String = _input_line.text
	var ends_space: bool = text.length() > 0 and text.ends_with(" ")
	var toks: Array = Array(text.split(" ", false))
	var arg_index: int = toks.size() if ends_space else maxi(0, toks.size() - 1)
	var editing: String = "" if ends_space or toks.is_empty() else String(toks[toks.size() - 1])

	# Пустой ввод в позиции команды — не сыпем весь список, ждём первый символ.
	if editing.is_empty() and arg_index == 0:
		_hide_suggestions()
		return

	var cands: Array = _candidates(toks, arg_index, editing)
	_matches = _filter(cands, editing)
	_sel = 0
	_render_suggestions()


## Кандидаты для позиции arg_index текущей команды.
func _candidates(toks: Array, arg_index: int, editing: String) -> Array:
	if arg_index == 0:
		return _COMMANDS.duplicate()
	var cmd: String = String(toks[0]).to_lower()
	match cmd:
		"give":
			return (
				_players_cands()
				if arg_index == 1
				else _as_cands(_asset_entries() + _spell_entries())
			)
		"cond", "condition":
			return _players_cands() if arg_index == 1 else _as_cands(_condition_entries())
		"enc", "encounter":
			if arg_index == 1:
				return _players_cands()
			return _enc_kind_cands() if arg_index == 2 else _world_cands()
		"spawn", "mon":
			return _location_cands() if editing.begins_with("@") else _as_cands(_monster_entries())
		"gate":
			return _location_cands() if editing.begins_with("@") else _colors_cands()
		"list", "ls":
			return _category_cands() if arg_index == 1 else _as_cands(_entries_for(String(toks[1])))
		_:
			return []


## Каталожные записи {id, label, kind} → единая форма подсказок {text, hint}.
func _as_cands(entries: Array) -> Array:
	var out: Array = []
	for e_v: Variant in entries:
		var e: Dictionary = e_v
		out.append({"text": String(e.get("id", "")), "hint": String(e.get("label", ""))})
	return out


## Отфильтровать кандидатов по вводимому префиксу: сперва begins_with, потом contains.
func _filter(cands: Array, editing: String) -> Array:
	if editing.is_empty():
		return cands
	var e: String = editing.to_lower()
	var pref: Array = []
	var sub: Array = []
	for c_v: Variant in cands:
		var t: String = String((c_v as Dictionary)["text"]).to_lower()
		if t.begins_with(e):
			pref.append(c_v)
		elif t.contains(e):
			sub.append(c_v)
	return pref + sub


func _render_suggestions() -> void:
	for ch: Node in _suggest_box.get_children():
		ch.free()
	if _matches.is_empty():
		_hide_suggestions()
		return
	var shown: int = mini(_matches.size(), _SUGGEST_MAX)
	for i: int in range(shown):
		var m: Dictionary = _matches[i]
		var lbl := Label.new()
		lbl.name = "Sg%d" % i
		var hint: String = String(m.get("hint", ""))
		lbl.text = (
			("▸ " if i == _sel else "  ") + String(m["text"]) + ("  — " + hint if hint else "")
		)
		lbl.add_theme_font_size_override("font_size", FONT_SIZE - 4)
		var col: Color = Color(0.90, 0.78, 0.42) if i == _sel else Color(0.55, 0.52, 0.45)
		lbl.add_theme_color_override("font_color", col)
		_suggest_box.add_child(lbl)
	if _matches.size() > shown:
		var more := Label.new()
		more.name = "More"
		more.text = "  … ещё %d" % (_matches.size() - shown)
		more.add_theme_font_size_override("font_size", FONT_SIZE - 4)
		more.add_theme_color_override("font_color", Color(0.45, 0.42, 0.38))
		_suggest_box.add_child(more)
	_suggest_panel.visible = true


func _move_sel(delta: int) -> void:
	if _matches.is_empty():
		return
	var shown: int = mini(_matches.size(), _SUGGEST_MAX)
	_sel = wrapi(_sel + delta, 0, shown)
	_render_suggestions()


## Принять выбранную подсказку: заменить текущий токен и дописать пробел.
func _accept_current() -> void:
	if _matches.is_empty():
		_recompute_suggestions()  # ещё не считали (сразу Tab) — посчитать и, если есть, принять
		if _matches.is_empty():
			return
	var pick: Dictionary = _matches[clampi(_sel, 0, _matches.size() - 1)]
	var text: String = _input_line.text
	var ends_space: bool = text.length() > 0 and text.ends_with(" ")
	var toks: Array = Array(text.split(" ", false))
	if ends_space or toks.is_empty():
		toks.append(String(pick["text"]))
	else:
		toks[toks.size() - 1] = String(pick["text"])
	var new_text: String = " ".join(PackedStringArray(toks)) + " "
	_input_line.text = new_text
	_input_line.caret_column = new_text.length()
	_recompute_suggestions()  # показать подсказки следующего аргумента


func _hide_suggestions() -> void:
	_matches = []
	_sel = 0
	if is_instance_valid(_suggest_box):
		for ch: Node in _suggest_box.get_children():
			ch.free()
	if is_instance_valid(_suggest_panel):
		_suggest_panel.visible = false


# Кандидаты-обёртки: приводим к общей форме {text, hint}.
func _players_cands() -> Array:
	var out: Array = [{"text": "me", "hint": "ты (хост)"}]
	for p_v: Variant in _players():
		var p: Dictionary = p_v
		out.append({"text": String(p["name"]), "hint": String(p["investigator"])})
	return out


func _location_cands() -> Array:
	var out: Array = []
	for e_v: Variant in _location_entries():
		var e: Dictionary = e_v
		out.append({"text": "@" + String(e["id"]), "hint": String(e["label"])})
	return out


func _colors_cands() -> Array:
	var out: Array = []
	for c: String in _COLORS:
		out.append({"text": c, "hint": "цвет врат"})
	return out


func _category_cands() -> Array:
	var out: Array = []
	for c: String in ["assets", "spells", "monsters", "conditions", "locations"]:
		out.append({"text": c, "hint": "категория"})
	return out


# ── Debug-команды ─────────────────────────────────────────────────────────────
# Строка ввода дёргает хост-авторитетные фасады GameState.debug_* (гейт: dev-сборка
# + хост). Резолв id по каталогам (частичное совпадение по id или переводу имени);
# при неоднозначности печатаем кандидатов. Таргет игрока: me/self, точный pid, номер
# из `who`, либо часть имени/сыщика. Локация в spawn/gate — токеном с префиксом «@».


func _on_command_submitted(text: String) -> void:
	_input_line.clear()
	_hide_suggestions()
	var line: String = text.strip_edges()
	if line.is_empty():
		return
	_add_entry("> " + line, Color(0.55, 0.75, 0.95))
	var parts: PackedStringArray = line.split(" ", false)
	if parts.is_empty():
		return
	var cmd: String = parts[0].to_lower()
	var args: Array = Array(parts).slice(1)
	match cmd:
		"help", "?":
			_cmd_help()
		"who", "players":
			_cmd_who()
		"clear", "cls":
			_cmd_clear()
		"list", "ls":
			_cmd_list(args)
		"give":
			_cmd_give(args)
		"spawn", "mon":
			_cmd_spawn(args)
		"gate":
			_cmd_gate(args)
		"cond", "condition":
			_cmd_cond(args)
		"enc", "encounter":
			_cmd_enc(args)
		_:
			err("неизвестная команда «%s» — введите `help`" % cmd)
	_scroll_bottom_deferred()  # вывод команды мог добавить строки — промотать вниз
	_reclaim_focus()  # держим фокус для цепочки команд


# Вернуть фокус строке ввода, если консоль открыта, а фокус ушёл (или вот-вот уйдёт:
# зовётся и из focus_exited, и после команды). Отложенно — в момент сигнала фокус ещё
# переезжает, и синхронный grab_focus не липнет; проверка _shown в самом коллбэке,
# чтобы закрытие консоли (release_focus в _toggle) не перехватывалось.
func _reclaim_focus() -> void:
	if _shown and is_instance_valid(_input_line):
		_grab_input_focus.call_deferred()


func _grab_input_focus() -> void:
	if _shown and is_instance_valid(_input_line) and not _input_line.has_focus():
		_input_line.grab_focus()


func _cmd_help() -> void:
	self.log("Команды debug-консоли (только хост, dev-сборка):")
	self.log("  give <игрок> <карта>        — актив или заклинание в руку")
	self.log("  spawn <монстр> [@локация]   — монстр на локации (по умолч. — твоя)")
	self.log("  gate [@локация] [цвет]      — открыть врата (+1 монстр)")
	self.log("  cond <игрок> <состояние>    — наложить состояние")
	self.log("  enc <игрок> <вид> [мир]     — назначить встречу на следующий ход")
	self.log("  list assets|spells|monsters|conditions|locations [фильтр]")
	self.log("  who                         — игроки и их id/локации")
	self.log("  clear                       — очистить консоль")
	self.log(
		"Игрок: me · часть имени/сыщика · номер из `who`. Карта/монстр: id или часть названия."
	)
	self.log("Автодополнение: набирай и Tab — принять/дописать, ↑/↓ — выбрать, Esc — скрыть.")


func _cmd_who() -> void:
	var ps: Array = _players()
	if ps.is_empty():
		warn("игра не идёт — игроков нет")
		return
	for i: int in range(ps.size()):
		var p: Dictionary = ps[i]
		self.log(
			(
				"  %d. %s [%s]  pid=%s  @%s"
				% [i + 1, p["name"], p["investigator"], p["pid"], p["location"]]
			)
		)


func _cmd_clear() -> void:
	for c: Node in _log_box.get_children():
		c.free()


func _cmd_list(args: Array) -> void:
	if args.is_empty():
		err("list assets|spells|monsters|conditions|locations [фильтр]")
		return
	var cat: String = String(args[0]).to_lower()
	var filter: String = _join(args.slice(1))
	var entries: Array = _entries_for(cat)
	if entries.is_empty():
		err("неизвестная категория «%s»" % cat)
		return
	var hits: Array = _search(filter, entries) if not filter.is_empty() else entries
	self.log("%s: %d" % [cat, hits.size()])
	for i: int in range(mini(hits.size(), 40)):
		var e: Dictionary = hits[i]
		self.log("  %s — %s" % [e["id"], e["label"]])
	if hits.size() > 40:
		self.log("  … ещё %d (уточните фильтр)" % (hits.size() - 40))


func _cmd_give(args: Array) -> void:
	if args.size() < 2:
		err("give <игрок> <карта>")
		return
	var pid: String = _resolve_pid(String(args[0]))
	if pid.is_empty():
		err("не нашёл игрока «%s» (см. `who`)" % args[0])
		return
	var query: String = _join(args.slice(1))
	var hit: Dictionary = _resolve_one(query, _asset_entries() + _spell_entries())
	if hit.is_empty():
		return
	if String(hit.get("kind", "")) == "spell":
		self.log(GameState.debug_exec("give_spell", pid, String(hit["id"])))
	else:
		self.log(GameState.debug_exec("give_asset", pid, String(hit["id"])))


func _cmd_spawn(args: Array) -> void:
	if args.is_empty():
		err("spawn <монстр> [@локация]")
		return
	var loc: String = _pop_location(args)
	if loc.is_empty():
		loc = _my_location()
	if loc.is_empty():
		err("не указана локация (@локация) и не удалось взять твою")
		return
	var hit: Dictionary = _resolve_one(_join(args), _monster_entries())
	if hit.is_empty():
		return
	self.log(GameState.debug_exec("spawn", loc, String(hit["id"])))


func _cmd_gate(args: Array) -> void:
	var loc: String = _pop_location(args)
	var color: String = _join(args).to_lower()  # опциональный цвет
	self.log(GameState.debug_exec("gate", loc, color))


func _cmd_cond(args: Array) -> void:
	if args.size() < 2:
		err("cond <игрок> <состояние>")
		return
	var pid: String = _resolve_pid(String(args[0]))
	if pid.is_empty():
		err("не нашёл игрока «%s» (см. `who`)" % args[0])
		return
	var hit: Dictionary = _resolve_one(_join(args.slice(1)), _condition_entries())
	if hit.is_empty():
		return
	self.log(GameState.debug_exec("condition", pid, String(hit["id"])))


## Назначить игроку встречу на его следующий ход встречи: вид (general/local/
## research/gate/mystery) и, для врат, конкретный Иной мир. Выбор типа встречи у
## этого игрока при этом пропускается — иначе меню было бы ложным.
func _cmd_enc(args: Array) -> void:
	if args.size() < 2:
		err("enc <игрок> <вид> [мир] — вид: %s" % ", ".join(_ENC_KINDS.keys()))
		return
	var pid: String = _resolve_pid(String(args[0]))
	if pid.is_empty():
		err("не нашёл игрока «%s» (см. `who`)" % args[0])
		return
	var kind: String = String(args[1]).to_lower()
	# Мир может быть из нескольких слов («City of the Great Race») — склеиваем хвост
	# и приводим к каноничному написанию: реле принимает только его.
	var world: String = _resolve_world(_join(args.slice(2)))
	if world == _WORLD_UNKNOWN:
		err("миры: %s" % ", ".join(_WORLDS))
		return
	self.log(GameState.debug_exec("encounter", pid, kind, world))


## Хвост команды → каноничное имя мира ("" если не задан, _WORLD_UNKNOWN если мимо).
func _resolve_world(token: String) -> String:
	var t: String = token.strip_edges()
	if t.is_empty():
		return ""
	for w: String in _WORLDS:
		if w.to_lower() == t.to_lower():
			return w
	for w: String in _WORLDS:
		if w.to_lower().contains(t.to_lower()):
			return w
	return _WORLD_UNKNOWN


func _enc_kind_cands() -> Array:
	var out: Array = []
	for k_v: Variant in _ENC_KINDS:
		out.append({"text": String(k_v), "hint": String(_ENC_KINDS[k_v])})
	return out


func _world_cands() -> Array:
	var out: Array = []
	for w: String in _WORLDS:
		out.append({"text": w, "hint": "Иной мир (только для gate)"})
	return out


# ── Резолв ────────────────────────────────────────────────────────────────────


## Токен игрока → pid ("" если не найден). me/self → свой; точный pid; номер из
## `who` (1-based); иначе часть имени игрока или сыщика (регистронезависимо).
func _resolve_pid(token: String) -> String:
	var t: String = token.strip_edges().to_lower()
	if t.is_empty() or t == "me" or t == "self":
		return GameState.debug_exec("mypid")
	var ps: Array = _players()
	for p_v: Variant in ps:
		if String((p_v as Dictionary)["pid"]).to_lower() == t:
			return String((p_v as Dictionary)["pid"])
	if t.is_valid_int():
		var idx: int = t.to_int() - 1
		if idx >= 0 and idx < ps.size():
			return String((ps[idx] as Dictionary)["pid"])
	for p_v: Variant in ps:
		var p: Dictionary = p_v
		if (
			String(p["name"]).to_lower().contains(t)
			or String(p["investigator"]).to_lower().contains(t)
		):
			return String(p["pid"])
	return ""


## Единственное совпадение из entries по query. {} + сообщение об ошибке/кандидатах,
## если 0 или >1. Точное совпадение id имеет приоритет над частичными.
func _resolve_one(query: String, entries: Array) -> Dictionary:
	if query.strip_edges().is_empty():
		err("пустой запрос")
		return {}
	var hits: Array = _search(query, entries)
	if hits.is_empty():
		err("ничего не нашёл по «%s»" % query)
		return {}
	if hits.size() > 1:
		warn("неоднозначно «%s» — уточните:" % query)
		for i: int in range(mini(hits.size(), 12)):
			self.log(
				"  %s — %s" % [(hits[i] as Dictionary)["id"], (hits[i] as Dictionary)["label"]]
			)
		if hits.size() > 12:
			self.log("  … ещё %d" % (hits.size() - 12))
		return {}
	return hits[0]


## Матч по query: точный id → сразу; иначе частичное по id или переводу названия.
func _search(query: String, entries: Array) -> Array:
	var q: String = query.strip_edges().to_lower()
	if q.is_empty():
		return []
	for e_v: Variant in entries:
		if String((e_v as Dictionary)["id"]).to_lower() == q:
			return [e_v]
	var out: Array = []
	for e_v: Variant in entries:
		var e: Dictionary = e_v
		if String(e["id"]).to_lower().contains(q) or String(e["label"]).to_lower().contains(q):
			out.append(e)
	return out


# ── Источники (каталоги → [{id, label, kind}]) ────────────────────────────────


func _entries_for(cat: String) -> Array:
	match cat:
		"assets", "asset":
			return _asset_entries()
		"spells", "spell":
			return _spell_entries()
		"monsters", "monster", "mon":
			return _monster_entries()
		"conditions", "condition", "cond":
			return _condition_entries()
		"locations", "location", "loc":
			return _location_entries()
		_:
			return []


func _asset_entries() -> Array:
	var out: Array = []
	for a_v: Variant in AssetCatalog.all():
		var a: Dictionary = a_v
		out.append(
			{
				"id": String(a.get("id", "")),
				"label": tr(String(a.get("nameKey", ""))),
				"kind": "asset"
			}
		)
	return out


func _spell_entries() -> Array:
	var out: Array = []
	for s_v: Variant in SpellCatalog.all():
		var s: Dictionary = s_v
		out.append(
			{"id": String(s.get("id", "")), "label": tr(String(s.get("name", ""))), "kind": "spell"}
		)
	return out


func _monster_entries() -> Array:
	var out: Array = []
	for m_v: Variant in MonsterCatalog.all():
		var m: Dictionary = m_v
		out.append(
			{
				"id": String(m.get("id", "")),
				"label": tr(String(m.get("nameKey", ""))),
				"kind": "monster"
			}
		)
	return out


func _condition_entries() -> Array:
	var out: Array = []
	for cid_v: Variant in Conditions.all_ids():
		var cid: String = String(cid_v)
		out.append({"id": cid, "label": tr(Conditions.name_key(cid)), "kind": "condition"})
	return out


func _location_entries() -> Array:
	var out: Array = []
	for l_v: Variant in GameState.map.all():
		var l: Dictionary = l_v
		var lid: String = String(l.get("id", ""))
		out.append({"id": lid, "label": tr(String(l.get("nameKey", lid))), "kind": "location"})
	return out


# ── Утилиты разбора ───────────────────────────────────────────────────────────


## Вынуть из args токен-локацию (префикс «@») и удалить его из массива. "" если нет.
func _pop_location(args: Array) -> String:
	for i: int in range(args.size()):
		var t: String = String(args[i])
		if t.begins_with("@"):
			args.remove_at(i)
			return t.substr(1)
	return ""


func _my_location() -> String:
	var pid: String = GameState.debug_exec("mypid")
	for p_v: Variant in _players():
		if String((p_v as Dictionary)["pid"]) == pid:
			return String((p_v as Dictionary)["location"])
	return ""


## Игроки из публичного GameState.players → [{pid, name, investigator, location}].
func _players() -> Array:
	var out: Array = []
	for pid_v: Variant in GameState.players:
		var pid: String = String(pid_v)
		var p: Dictionary = GameState.players[pid]
		(
			out
			. append(
				{
					"pid": pid,
					"name": String(p.get("name", pid)),
					"investigator": String(p.get("investigator", "")),
					"location": String(p.get("location", "")),
				}
			)
		)
	return out


func _join(a: Array) -> String:
	return " ".join(PackedStringArray(a))
