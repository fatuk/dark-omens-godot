extends Control

## Экран выбора сыщика. Координирует загрузку JSON, persist последнего выбора,
## сетевую glue (mark_taken/sync_taken) и сборку UI вокруг карусели.
##
## UI-кусочки вынесены в отдельные классы:
##   • [Carousel3D] — 3D-cover-flow карусель с анимациями и hit-test'ом.
##   • [CardView]   — слоистая разметка карточки (портрет/рамка/бейдж/цитата).
##   • [InfoBar]    — нижняя панель статов/атрибутов/предметов.
##   • [PlayerDetailsContent] — содержимое модалки «Подробнее».
##   • [SelectionPrefs] — persist последнего выбора.

const _MODAL_SCENE := preload("res://scenes/ui/modal_dialog.tscn")

const CHEVRON_TEX_LEFT:  Texture2D = preload("res://assets/carousel/L_chevron.png")
const CHEVRON_TEX_RIGHT: Texture2D = preload("res://assets/carousel/R_chevron.png")
const INFO_BTN_TEX:      Texture2D = preload("res://assets/info-btn.png")


## Эмитится при ЛЮБОЙ смене текущего сыщика — включая авто-восстановление из
## prefs при открытии picker'а. Lobby подписывается и сразу бродкастит выбор,
## чтобы остальные клиенты видели его «занятым» без ожидания Ready. Поэтому
## имя — `selection_changed`, не `investigator_selected` (последнее намекало
## бы на одноразовое подтверждение).
signal selection_changed(inv_name: String)
signal back_pressed
signal confirm_pressed
signal start_pressed   # host-only — «начать игру»

# ── Данные ────────────────────────────────────────────────────────────────────
var _investigators: Array      = []
var _taken:         Dictionary = {}   # name -> taker_name

# ── UI ────────────────────────────────────────────────────────────────────────
var _root: VBoxContainer = null   # создаётся в _ready()
var _carousel: Carousel3D = null
var _info_bar: InfoBar
var _back_btn:    Button
var _confirm_btn: Button
var _start_btn:   Button       # видна только хосту
var _nm:          Node = null  # NetworkManager (читаем напрямую для room+players)
var _player_details_modal: ModalDialog = null   # guard от двойного клика по «Подробнее»


# ── Public API ────────────────────────────────────────────────────────────────

func _ready() -> void:
	MusicManager.play(MusicManager.TRACK_NO_CHOICE)
	_nm = get_node_or_null("/root/NetworkManager")

	# Полноэкранный overlay через CanvasLayer — независим от лобби-layout'а.
	var canvas := CanvasLayer.new()
	canvas.name  = "PickerCanvas"
	canvas.layer = 50
	add_child(canvas)

	var bg := UIStyle.apply_main_bg(canvas)
	bg.name = "Background"

	_root = VBoxContainer.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Боковых отступов нет — карусель тянется до краёв экрана. Title и
	# action-bar центрированы, им это безразлично; InfoBar тоже full-width.
	_root.offset_left   = 0
	_root.offset_right  = 0
	_root.offset_top    = 30
	_root.offset_bottom = -24
	_root.add_theme_constant_override("separation", 7)
	canvas.add_child(_root)

	_load_investigators()
	_build_ui()
	call_deferred("_preselect_saved")


func get_selected() -> String:
	if _carousel == null:
		return ""
	return _carousel.selected_name()


func mark_taken(inv_name: String, taker_name: String) -> void:
	if inv_name.is_empty():
		return
	_taken[inv_name] = taker_name
	if _carousel:
		_carousel.update_taken(_taken)


func sync_taken(taken_map: Dictionary) -> void:
	_taken = taken_map.duplicate()
	if _carousel:
		_carousel.update_taken(_taken)


func mark_available(inv_name: String) -> void:
	_taken.erase(inv_name)
	if _carousel:
		_carousel.update_taken(_taken)


# ── Загрузка данных ──────────────────────────────────────────────────────────

func _load_investigators() -> void:
	_investigators = DataLoader.load_array("res://data/investigators.json")
	if _investigators.is_empty():
		push_error("InvestigatorPicker: пустой список сыщиков")


# ── Построение UI ────────────────────────────────────────────────────────────

func _build_ui() -> void:
	_root.add_child(_build_title())
	_carousel = Carousel3D.new()
	_carousel.name = "Carousel"
	_carousel.index_changed.connect(_on_carousel_index_changed)
	_carousel.center_clicked.connect(_on_confirm_pressed)
	_root.add_child(_carousel)
	_root.add_child(_build_info_bar())
	_root.add_child(_build_action_bar())
	_add_info_button_overlay()


# Иконка «info» в правом верхнем углу — на отдельном CanvasLayer (78), чтобы
# рисоваться поверх ScreenFrame (75) и под модалками (80+). Открывает модалку
# со списком игроков. Якорится в (1, 0) с симметричным отступом от обоих краёв.
const _INFO_BTN_MARGIN: int = 13

func _add_info_button_overlay() -> void:
	var top_canvas := CanvasLayer.new()
	top_canvas.name  = "InfoOverlay"
	top_canvas.layer = 78
	add_child(top_canvas)

	var info_btn := UIStyle.texture_icon_button(INFO_BTN_TEX)
	info_btn.name = "InfoBtn"
	info_btn.tooltip_text = "LOBBY_BTN_DETAILS"
	info_btn.pressed.connect(_open_player_details_modal)
	info_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	var sz: Vector2 = info_btn.custom_minimum_size
	info_btn.offset_left   = -sz.x - _INFO_BTN_MARGIN
	info_btn.offset_right  = -_INFO_BTN_MARGIN
	info_btn.offset_top    =  _INFO_BTN_MARGIN
	info_btn.offset_bottom =  _INFO_BTN_MARGIN + sz.y
	top_canvas.add_child(info_btn)


# Открывает переиспользуемую ModalDialog со списком игроков. Контент
# собирает PlayerDetailsContent — снимок NetworkManager на момент открытия.
func _open_player_details_modal() -> void:
	if _nm == null:
		return
	if is_instance_valid(_player_details_modal):
		return   # уже открыт — игнорируем повторный клик
	_player_details_modal = _MODAL_SCENE.instantiate()
	add_child(_player_details_modal)
	_player_details_modal.tree_exited.connect(func() -> void: _player_details_modal = null)
	_player_details_modal.set_title(tr("LOBBY_PLAYERS_DETAILS_TITLE"))
	# v1: снапшот NetworkManager на момент открытия. Если игрок зайдёт/выйдет,
	# пока модалка висит — список устареет. Обновление через сигналы — позже.
	_player_details_modal.set_content(PlayerDetailsContent.build(_nm))
	_player_details_modal.open()


func _build_title() -> Control:
	var hb := HBoxContainer.new()
	hb.name = "TitleRow"
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_theme_constant_override("separation", 14)
	hb.add_child(_make_chevron(CHEVRON_TEX_LEFT))
	var title := UIStyle.label("LOBBY_PICK_HEADER", 28, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	title.name = "Title"
	hb.add_child(title)
	hb.add_child(_make_chevron(CHEVRON_TEX_RIGHT))
	return hb


# Декоративный шеврон сбоку от заголовка. PNG нарисован в более высоком
# разрешении (≈@4×) — как стрелки в той же папке carousel/, см. memory.
func _make_chevron(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.name             = "Chevron"
	r.texture          = tex
	r.expand_mode      = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode     = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = tex.get_size() * 0.25
	r.mouse_filter     = Control.MOUSE_FILTER_IGNORE
	return r


# ── Инфо-блок (низ) ──────────────────────────────────────────────────────────

func _build_info_bar() -> Control:
	_info_bar = InfoBar.new()
	_info_bar.name = "InfoBar"
	return _info_bar


# ── Кнопки действий ─────────────────────────────────────────────────────────

func _build_action_bar() -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.name = "ActionBar"
	hb.add_theme_constant_override("separation", 12)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER

	_back_btn = Button.new()
	_back_btn.name = "BackBtn"
	_back_btn.text = "BTN_BACK"
	UIStyle.style_button(_back_btn, UIColors.MUTED)
	# Только ширина — высоту задаёт style_button (= высота ассета). Переопределять
	# высоту нельзя: текст калибруется под неё, рамка разъедется с надписью.
	_back_btn.custom_minimum_size.x = 160
	_back_btn.pressed.connect(func() -> void: back_pressed.emit())
	hb.add_child(_back_btn)

	_confirm_btn = Button.new()
	_confirm_btn.name = "ConfirmBtn"
	_confirm_btn.text = "PICKER_CONFIRM"
	UIStyle.style_button(_confirm_btn, UIColors.ACCENT)
	_confirm_btn.custom_minimum_size.x = 280
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	hb.add_child(_confirm_btn)

	_start_btn = Button.new()
	_start_btn.name = "StartBtn"
	_start_btn.text = "LOBBY_BTN_START_GAME"
	UIStyle.style_button(_start_btn, UIColors.ACCENT)
	_start_btn.custom_minimum_size.x = 220
	_start_btn.pressed.connect(func() -> void: start_pressed.emit())
	hb.add_child(_start_btn)
	_update_start_btn_visibility()

	return hb


func _update_start_btn_visibility() -> void:
	if not is_instance_valid(_start_btn) or _nm == null:
		return
	_start_btn.visible = _nm.is_host()


# Публичные хелперы для lobby.gd — после refactor'а кнопок «Готов»/«Начать»:
# UI теперь живёт в picker, а бизнес-логика — в lobby.

# После нажатия «Готов» — блокируем кнопку и меняем текст.
func lock_confirm() -> void:
	if not is_instance_valid(_confirm_btn):
		return
	_confirm_btn.disabled = true
	_confirm_btn.text     = "LOBBY_BTN_READY_DONE"


# Хост: включить/выключить кнопку «Начать игру».
func set_start_enabled(enabled: bool) -> void:
	if not is_instance_valid(_start_btn):
		return
	_start_btn.disabled = not enabled


# ── Реакция на карусель ──────────────────────────────────────────────────────

# Любая смена центральной карточки (включая первичный set_data в _preselect_saved)
# обновляет нижнюю инфо-панель и эмитит selection_changed наружу (лобби сразу
# бродкастит выбор, не дожидаясь Ready).
func _on_carousel_index_changed(idx: int) -> void:
	if _info_bar and idx >= 0 and idx < _investigators.size():
		_info_bar.update(_investigators[idx])
	_emit_selection()


func _on_confirm_pressed() -> void:
	confirm_pressed.emit()
	_emit_selection()


func _emit_selection() -> void:
	var inv_name: String = get_selected()
	SelectionPrefs.save(inv_name)
	selection_changed.emit(inv_name)


# ── Сохранение / восстановление выбора ─────────────────────────────────────

func _preselect_saved() -> void:
	if _investigators.is_empty() or _carousel == null:
		return
	var start_idx: int = 0
	var saved: String = SelectionPrefs.load_last()
	if not saved.is_empty():
		for i: int in range(_investigators.size()):
			if _investigators[i].get("name", "") == saved:
				start_idx = i
				break
	# set_data сам эмитит index_changed → подцепится _on_carousel_index_changed,
	# который обновит InfoBar и проэмитит selection_changed.
	_carousel.set_data(_investigators, _taken, start_idx)
