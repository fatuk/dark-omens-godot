extends Control

## Карусель выбора сыщика — placeholder UI без графики.
## 5 карточек: центр крупный, по 2 поменьше с каждой стороны (с уменьшающейся
## альфой). Стрелки + клик по боковой карточке двигают карусель; центр /
## «CONFIRM SELECTION» подтверждают.
##
## Анимация: per-card slide. 4 видимые карточки плавно сдвигаются в соседние
## слоты, 5-я (та что должна вылететь) уезжает за край (clip_contents=true
## её скрывает) и появляется с противоположной стороны с новым контентом.
## Без cross-fade — только движение.

const _PREFS_PATH    := "user://dark_omens_prefs.cfg"
const _PREFS_SECTION := "investigator"

const _MODAL_SCENE := preload("res://scenes/ui/modal_dialog.tscn")

# Декоративные слои карточки. Иерархия (снизу вверх):
#   1. портрет сыщика
#   2. card-overlay (blend = multiply) — затемняет/тонирует портрет в стиль рамки
#   3. card-frame — узорная PNG-рамка
#   4. card-badge — фигурная подложка под имя + текст поверх неё
const CARD_OVERLAY_TEX: Texture2D = preload("res://assets/card-frame/card-overlay.png")
const CARD_FRAME_TEX:   Texture2D = preload("res://assets/card-frame/card-frame.png")
const CARD_BADGE_TEX:   Texture2D = preload("res://assets/card-frame/card-badge.png")
const ARROW_TEX_LEFT:   Texture2D = preload("res://assets/carousel/L_arrow.png")
const ARROW_TEX_RIGHT:  Texture2D = preload("res://assets/carousel/R_arrow.png")

const VISIBLE_SLOTS := 5
const CENTER_SLOT   := 2

# Per-card UI рендерится в SubViewport такого размера; затем как текстура
# натягивается на 3D-quad. Аспект 1:1 — центральная карточка квадратная,
# боковые «удлиняются» из-за perspective foreshortening.
#
# CARD_TEX_SIZE — реальный размер рендер-таргета (то, что станет текстурой).
# CARD_UI_SIZE  — логический размер, в котором живёт вёрстка контролов
# (шрифты, отступы, размеры бейджа). SubViewport.size_2d_override стрейтчит
# UI с CARD_UI_SIZE до CARD_TEX_SIZE — это даёт supersampling × 3 и резкий
# текст без перетряхивания всех числовых отступов вёрстки.
const CARD_TEX_SIZE  := Vector2i(1536, 1536)
const CARD_UI_SIZE   := Vector2i(512, 512)
const CARD_QUAD_SIZE := Vector2(1.8, 1.8)   # размер 3D-меша (мировые единицы)

# 3D-позиции/повороты/масштаб для каждого слота. Лёгкая «книжная» развёртка —
# слабые углы поворота и почти одинаковый Z, чтобы общий вид оставался
# плоским (как в макете), а не глубоким cover-flow. Центр всё равно крупнее
# за счёт SLOT_SCALES.
const SLOT_3D_POSITIONS := [
	Vector3(-3.6, 0.0, -0.3),  # far left
	Vector3(-2.0, 0.0, -0.1),  # left
	Vector3( 0.0, 0.0,  0.3),  # center (немного вперёд)
	Vector3( 2.0, 0.0, -0.1),  # right
	Vector3( 3.6, 0.0, -0.3),  # far right
]
const SLOT_3D_ROTATIONS_DEG := [-20.0, -10.0, 0.0, 10.0, 20.0]
const SLOT_SCALES     := [0.85, 1.05, 1.5, 1.05, 0.85]
const SLOT_BRIGHTNESS := [0.45, 0.65, 1.00, 0.65, 0.45]

# Камера: длиннофокусная (узкий FOV) + дальше отодвинута — это «сплющивает»
# перспективу, как телевик. При таком setup'е боковые карточки выглядят почти
# одного размера с центром, а наклон читается, но без сильных трапеций.
# Z подобрано так, чтобы карточки заполняли ~90% высоты viewport'а — иначе
# сверху и снизу карусели остаются большие пустые поля.
const CAM_POSITION := Vector3(0.0, 0.0, 6.2)
const CAM_FOV: float = 30.0

# Якоря для стрелок навигации: середина между внешней и соседней карточками
# (3D-точки x=±2.8, z=-0.2). Значение получено через perspective unproject при
# текущих CAM_POSITION/CAM_FOV и аспекте 1920/760 у _world_vp — спроецировано
# в нормализованные screen-coords. Камера статична, поэтому константа, без
# пересчёта в runtime. Если изменишь CAM_*/SLOT_3D_POSITIONS — пересчитай.
const ARROW_X_ANCHOR_FROM_EDGE: float = 0.157

const ANIM_DURATION: float = 0.50

# Атрибуты (translation_key, ключ в skills{})
const ATTRIBUTES := [
	["SKILL_STRENGTH",    "strength"],
	["SKILL_LORE",        "lore"],
	["SKILL_WILL",        "will"],
	["SKILL_INFLUENCE",   "influence"],
	["SKILL_OBSERVATION", "observation"],
]

signal investigator_selected(inv_name: String)
signal back_pressed
signal confirm_pressed
signal start_pressed   # host-only — «начать игру»

# ── Данные ────────────────────────────────────────────────────────────────────
var _investigators: Array      = []
var _inv_data:      Dictionary = {}
var _taken:         Dictionary = {}   # name -> taker_name
var _index:         int        = 0    # центральный индекс

# ── UI ────────────────────────────────────────────────────────────────────────
var _root: VBoxContainer = null   # создаётся в _ready()

# 3D-карточки: каждая — MeshInstance3D с QuadMesh, текстура которого =
# рендер per-card UI SubViewport'а. UI-контролы внутри SubViewport'а живут
# отдельно (хранятся в _slot_portraits/names/occs/taken).
var _card_meshes:    Array = []   # MeshInstance3D[] (физические карточки в 3D)
var _card_ui_vps:    Array = []   # SubViewport[] — рендерят UI каждой карточки
var _slot_portraits: Array = []   # TextureRect портретов (внутри per-card SubViewport)
var _slot_names:     Array = []   # Label имени
var _slot_occs:      Array = []   # Label занятия
var _slot_taken:     Array = []   # Control «занято»
var _slot_frames:    Array = []   # TextureRect декоративной рамки карточки
var _slot_quotes:    Array = []   # Label с цитатой сыщика под бейджем

var _prev_btn:       TextureButton
var _next_btn:       TextureButton
var _carousel_area:  Control          # SubViewportContainer + 3D scene
var _world_vp:       SubViewport      # 3D scene SubViewport
var _camera:         Camera3D
# Анимации прерываемы (см. _animated_shift), без блокирующего флага _animating.

var _hp_bar:        ProgressBar
var _hp_label:      Label
var _sanity_bar:    ProgressBar
var _sanity_label:  Label
var _attr_value_lbls: Dictionary = {}   # field name -> Label

var _back_btn:    Button
var _confirm_btn: Button
var _start_btn:   Button       # видна только хосту
var _nm:          Node = null  # NetworkManager (читаем напрямую для room+players)


# ── Public API ────────────────────────────────────────────────────────────────

func _ready() -> void:
	MusicManager.play(MusicManager.TRACK_NO_CHOICE)
	_nm = get_node_or_null("/root/NetworkManager")

	# Полноэкранный overlay через CanvasLayer — независим от лобби-layout'а.
	var canvas := CanvasLayer.new()
	canvas.layer = 50
	add_child(canvas)

	# Тайлированный main-gb.png. mouse_filter=STOP, чтобы клики мимо UI
	# не уходили на лежащую под picker'ом сцену лобби.
	var bg := UIStyle.apply_main_bg(canvas)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP

	_root = VBoxContainer.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.offset_left   = 40
	_root.offset_right  = -40
	_root.offset_top    = 24
	_root.offset_bottom = -24
	_root.add_theme_constant_override("separation", 14)
	canvas.add_child(_root)

	_load_investigators()
	_build_ui()
	call_deferred("_preselect_saved")


func get_selected() -> String:
	if _investigators.is_empty():
		return ""
	return String((_investigators[_index] as Dictionary).get("name", ""))


func clear_selection() -> void:
	pass   # no-op для совместимости с lobby.gd


func mark_taken(inv_name: String, taker_name: String) -> void:
	if inv_name.is_empty():
		return
	_taken[inv_name] = taker_name
	_refresh_taken_overlays()


func sync_taken(taken_map: Dictionary) -> void:
	_taken = taken_map.duplicate()
	_refresh_taken_overlays()


func mark_available(inv_name: String) -> void:
	_taken.erase(inv_name)
	_refresh_taken_overlays()


# ── Загрузка данных ──────────────────────────────────────────────────────────

func _load_investigators() -> void:
	_investigators = DataLoader.load_array("res://data/investigators.json")
	if _investigators.is_empty():
		push_error("InvestigatorPicker: пустой список сыщиков")
		return
	for i: int in range(_investigators.size()):
		var inv: Dictionary = _investigators[i]
		_inv_data[inv.get("name", "")] = inv


func _placeholder_texture() -> ImageTexture:
	# Заметно ярче UIColors.SURFACE — чтобы карточка с отсутствующим портретом
	# не сливалась с фоном панели.
	var img := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.22, 0.20, 0.30))
	return ImageTexture.create_from_image(img)


func _load_portrait(inv_name: String) -> Texture2D:
	var path := "res://assets/investigators/%s.png" % inv_name
	if ResourceLoader.exists(path):
		return load(path)
	return _placeholder_texture()


# ── Построение UI ────────────────────────────────────────────────────────────

func _build_ui() -> void:
	_root.add_child(_build_top_bar())
	_root.add_child(_build_title())
	_root.add_child(_build_carousel())
	_root.add_child(_build_info_bar())
	_root.add_child(_build_action_bar())


# Минимальный top-bar — только кнопка «Подробнее» в правом углу. Открывает
# модалку с инфой о комнате + игроках + их статусе. Имя комнаты, роль и
# список игроков больше нигде не дублируются: всё это живёт в модалке.
func _build_top_bar() -> Control:
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_END

	var details_btn := Button.new()
	details_btn.text = "LOBBY_BTN_DETAILS"
	details_btn.flat = true
	details_btn.add_theme_font_size_override("font_size", 12)
	details_btn.add_theme_color_override("font_color", UIColors.ACCENT)
	details_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	details_btn.pressed.connect(_open_player_details_modal)
	hb.add_child(details_btn)
	return hb


# ── Модалка «Подробнее об игроках» ───────────────────────────────────────────

# Открывает переиспользуемую ModalDialog со списком игроков: имя + выбранный
# сыщик (или «—») + бейдж готовности. Контент ребилдится при каждом открытии,
# поэтому всегда показывает актуальное состояние NetworkManager.players.
func _open_player_details_modal() -> void:
	if _nm == null:
		return
	var modal: ModalDialog = _MODAL_SCENE.instantiate()
	add_child(modal)
	modal.set_title(tr("LOBBY_PLAYERS_DETAILS_TITLE"))
	modal.set_content(_build_player_details_list())
	# Авто-обновление пока опускаем: для v1 закрытие/открытие даёт свежий снимок.
	modal.open()


func _build_player_details_list() -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)

	# Шапка: имя комнаты + наша роль (хост / игрок).
	var room_lbl := Label.new()
	room_lbl.text = "Комната: %s" % _nm.room_name
	room_lbl.add_theme_font_size_override("font_size", 14)
	room_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	vb.add_child(room_lbl)

	var role_lbl := Label.new()
	role_lbl.text = "Вы — ведущий игры" if _nm.is_host() else "Ожидайте начала игры"
	role_lbl.add_theme_font_size_override("font_size", 11)
	role_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	vb.add_child(role_lbl)

	UIStyle.separator(vb)

	# Подзаголовок «ИГРОКИ».
	var hdr := Label.new()
	hdr.text = "LOBBY_PLAYERS_HEADER"
	hdr.add_theme_font_size_override("font_size", 11)
	hdr.add_theme_color_override("font_color", UIColors.MUTED)
	vb.add_child(hdr)

	var host_id: String = _nm.host_id if "host_id" in _nm else ""
	for pid: String in _nm.players.keys():
		vb.add_child(_make_player_detail_row(pid, _nm.players[pid], host_id))
	return vb


func _make_player_detail_row(pid: String, info: Dictionary, host_id: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var crown := Label.new()
	crown.text = "♛" if pid == host_id else "◆"
	crown.add_theme_font_size_override("font_size", 16)
	crown.add_theme_color_override("font_color",
		UIColors.ACCENT if pid == host_id else UIColors.MUTED)
	crown.custom_minimum_size.x = 24
	row.add_child(crown)

	var info_vb := VBoxContainer.new()
	info_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_vb.add_theme_constant_override("separation", 2)
	row.add_child(info_vb)

	var name_lbl := Label.new()
	name_lbl.text = info.get("name", pid)
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	info_vb.add_child(name_lbl)

	var inv_name: String = info.get("investigator", "")
	var inv_lbl := Label.new()
	if inv_name.is_empty():
		inv_lbl.text = "—"
		inv_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	else:
		# Investigators.display_name() возвращает translation key,
		# Godot переводит автоматически при рендере Label'а.
		inv_lbl.text = Investigators.display_name(inv_name)
		inv_lbl.add_theme_color_override("font_color", UIColors.ACCENT)
	inv_lbl.add_theme_font_size_override("font_size", 11)
	info_vb.add_child(inv_lbl)

	var tag := Label.new()
	tag.add_theme_font_size_override("font_size", 13)
	tag.custom_minimum_size.x = 100
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if pid == host_id:
		tag.text = "LOBBY_TAG_HOST"
		tag.add_theme_color_override("font_color", UIColors.ACCENT)
	elif info.get("ready", false):
		tag.text = "LOBBY_TAG_READY"
		tag.add_theme_color_override("font_color", UIColors.READY)
	else:
		tag.text = "LOBBY_TAG_WAITING"
		tag.add_theme_color_override("font_color", UIColors.MUTED)
	row.add_child(tag)

	return row


func _build_title() -> Label:
	var lbl := Label.new()
	lbl.text = "LOBBY_PICK_HEADER"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.add_theme_color_override("font_color", UIColors.ACCENT)
	return lbl


# ── Карусель ────────────────────────────────────────────────────────────────

func _build_carousel() -> Control:
	var area := Control.new()
	area.custom_minimum_size = Vector2(0, 760)
	area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_carousel_area = area

	# SubViewportContainer хостит 3D-сцену и stretch'ит её на размер area.
	var spvc := SubViewportContainer.new()
	spvc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	spvc.stretch = true
	spvc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(spvc)

	# 3D SubViewport: камера + 5 квадов карточек.
	_world_vp = SubViewport.new()
	_world_vp.size = Vector2i(1920, 760)
	_world_vp.transparent_bg = true
	_world_vp.handle_input_locally = false
	_world_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_world_vp.msaa_3d = Viewport.MSAA_4X   # сглаживание — иначе края полигонов лесенкой
	spvc.add_child(_world_vp)

	_camera = Camera3D.new()
	_camera.position   = CAM_POSITION
	_camera.fov        = CAM_FOV
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_world_vp.add_child(_camera)

	# Создаём 5 пар (UI SubViewport + 3D MeshInstance с этой текстурой).
	# UI viewport'ы рендерятся off-screen (как дети area, но они невидимы сами по себе).
	for i: int in range(VISIBLE_SLOTS):
		var ui_vp := _make_card_ui_subviewport()
		area.add_child(ui_vp)
		_card_ui_vps.append(ui_vp)
		var mesh := _make_3d_card_mesh(ui_vp)
		mesh.set_meta("logical_slot", i)
		_world_vp.add_child(mesh)
		_card_meshes.append(mesh)
		_apply_3d_slot(mesh, i)

	# Стрелки — TextureButton'ы на границе между внешней и соседней карточками
	# (см. ARROW_X_ANCHOR_FROM_EDGE). Дети area, поэтому всегда поверх 3D.
	_prev_btn = _make_arrow_btn(ARROW_TEX_LEFT)
	_position_arrow(_prev_btn, ARROW_X_ANCHOR_FROM_EDGE)
	_prev_btn.pressed.connect(_on_prev)
	area.add_child(_prev_btn)

	_next_btn = _make_arrow_btn(ARROW_TEX_RIGHT)
	_position_arrow(_next_btn, 1.0 - ARROW_X_ANCHOR_FROM_EDGE)
	_next_btn.pressed.connect(_on_next)
	area.add_child(_next_btn)

	# Клики по 3D-карточкам ловим на уровне area (spvc сам IGNORE'ит, поэтому
	# input доходит до родительского Control). Хит-тест — ray-cast из камеры.
	area.mouse_filter = Control.MOUSE_FILTER_STOP
	area.gui_input.connect(_on_carousel_gui_input)
	return area


# Создаёт SubViewport с UI карточки внутри. Возвращает SubViewport (который
# будет натянут как текстура на 3D-quad). Иерархия слоёв (снизу вверх):
# портрет → overlay (multiply) → frame → имя/занятие → taken-оверлей.
# Side-effect: добавляет нужные контролы в массивы _slot_*.
func _make_card_ui_subviewport() -> SubViewport:
	var vp := SubViewport.new()
	vp.size = CARD_TEX_SIZE
	# Supersampling: UI верстается в CARD_UI_SIZE-пространстве, но рендер-таргет
	# в 3× больше — текст становится резким на крупной центральной карточке
	# без правки всех hardcoded'нутых пиксельных отступов.
	vp.size_2d_override = CARD_UI_SIZE
	vp.size_2d_override_stretch = true
	vp.transparent_bg = true
	vp.handle_input_locally = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	# Корневой Control с clip_contents — на случай, если COVER-stretch портрета
	# выходит за пределы кадра.
	var root_ctrl := Control.new()
	root_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ctrl.clip_contents = true
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vp.add_child(root_ctrl)

	# Слой 1: портрет, COVER-stretch.
	var portrait := TextureRect.new()
	portrait.texture       = _placeholder_texture()
	portrait.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode  = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	root_ctrl.add_child(portrait)
	_slot_portraits.append(portrait)

	# Слой 2: card-overlay с blend_mode = multiply — тонирует портрет
	# под цвет рамки (тёмно-золотая палитра).
	var overlay := TextureRect.new()
	overlay.texture       = CARD_OVERLAY_TEX
	overlay.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
	overlay.stretch_mode  = TextureRect.STRETCH_SCALE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	var ov_mat := CanvasItemMaterial.new()
	ov_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	overlay.material  = ov_mat
	root_ctrl.add_child(overlay)

	# Слой 3: декоративная рамка карточки.
	var frame := TextureRect.new()
	frame.texture       = CARD_FRAME_TEX
	frame.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode  = TextureRect.STRETCH_SCALE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	root_ctrl.add_child(frame)
	_slot_frames.append(frame)

	# Слой 4: декоративный бейдж в нижней части кадра. PNG нарисован в @2×
	# относительно UI, плюс CARD_TEX_SIZE — это рендер для 3D-quad'а, который
	# дополнительно увеличивается камерой. Итого «1×» = native/4, чтобы текст
	# и завитки оставались crisp при scale=1.5 центральной карточки и не
	# вылезали за границы 512-px кадра.
	var badge_size: Vector2 = CARD_BADGE_TEX.get_size() * 0.25
	# Поднимаем бейдж выше: освобождаем нижнюю полоску под цитату.
	var bottom_gap: float = 70.0

	var badge_box := Control.new()
	badge_box.anchor_left   = 0.5
	badge_box.anchor_right  = 0.5
	badge_box.anchor_top    = 1.0
	badge_box.anchor_bottom = 1.0
	badge_box.offset_left   = -badge_size.x * 0.5
	badge_box.offset_right  =  badge_size.x * 0.5
	badge_box.offset_top    = -badge_size.y - bottom_gap
	badge_box.offset_bottom = -bottom_gap
	badge_box.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	root_ctrl.add_child(badge_box)

	var badge := TextureRect.new()
	badge.texture       = CARD_BADGE_TEX
	badge.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
	badge.stretch_mode  = TextureRect.STRETCH_SCALE
	badge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	badge_box.add_child(badge)

	# VBox с именем + занятием поверх бейджа, центрирован по обеим осям.
	# Margin'ы внутри badge_box оставляют запас под декоративные углы PNG.
	var name_vb := VBoxContainer.new()
	name_vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	name_vb.offset_left   = 40
	name_vb.offset_right  = -40
	name_vb.offset_top    = 9
	name_vb.offset_bottom = -17
	name_vb.alignment = BoxContainer.ALIGNMENT_CENTER
	name_vb.add_theme_constant_override("separation", 0)
	name_vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_box.add_child(name_vb)

	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 26)
	name_lbl.add_theme_color_override("font_color", UIColors.ACCENT)
	_apply_card_text_shadow(name_lbl)
	name_vb.add_child(name_lbl)
	_slot_names.append(name_lbl)

	var occ_lbl := Label.new()
	occ_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	occ_lbl.add_theme_font_size_override("font_size", 14)
	occ_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	_apply_card_text_shadow(occ_lbl)
	name_vb.add_child(occ_lbl)
	_slot_occs.append(occ_lbl)

	# Слой 4.5: цитата сыщика — белёсый текст с word-wrap'ом, центрирован
	# в нижней полоске под бейджем. Помещается в 2 строки при средней длине.
	var quote_lbl := Label.new()
	quote_lbl.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	quote_lbl.offset_left   = 40
	quote_lbl.offset_right  = -40
	quote_lbl.offset_top    = -63
	quote_lbl.offset_bottom = -13
	quote_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	quote_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_TOP
	quote_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	quote_lbl.add_theme_font_size_override("font_size", 14)
	quote_lbl.add_theme_color_override("font_color", Color("#8e6940"))
	_apply_card_text_shadow(quote_lbl)
	quote_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ctrl.add_child(quote_lbl)
	_slot_quotes.append(quote_lbl)

	# Слой 5: оверлей «занято» поверх всего.
	var taken_ov := _make_taken_overlay()
	taken_ov.visible = false
	root_ctrl.add_child(taken_ov)
	_slot_taken.append(taken_ov)

	return vp


# Создаёт MeshInstance3D с QuadMesh, у которого albedo = ViewportTexture от ui_vp.
func _make_3d_card_mesh(ui_vp: SubViewport) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = CARD_QUAD_SIZE

	var mat := StandardMaterial3D.new()
	mat.shading_mode      = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture    = ui_vp.get_texture()
	mat.transparency      = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode         = BaseMaterial3D.CULL_DISABLED   # видны с обеих сторон
	mat.texture_filter    = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = mat
	return mi


# Применяет position/rotation/scale/brightness к мешу для указанного слота (без анимации).
func _apply_3d_slot(mesh: MeshInstance3D, slot: int) -> void:
	mesh.position = SLOT_3D_POSITIONS[slot]
	mesh.rotation = Vector3(0.0, deg_to_rad(SLOT_3D_ROTATIONS_DEG[slot]), 0.0)
	var s: float = SLOT_SCALES[slot]
	mesh.scale = Vector3(s, s, 1.0)
	var b: float = SLOT_BRIGHTNESS[slot]
	var mat := mesh.material_override as StandardMaterial3D
	if mat:
		mat.albedo_color = Color(b, b, b, 1.0)


func _make_arrow_btn(tex: Texture2D) -> TextureButton:
	var b := TextureButton.new()
	b.texture_normal         = tex
	b.ignore_texture_size    = true
	b.stretch_mode           = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return b


# Якорит стрелку в (x_anchor, 0.5) родителя. Множитель 0.25, а не общий для
# проекта 0.5: PNG нарисован в более высоком разрешении (≈@4×), визуально на
# 0.5 был в 2× крупнее макета.
func _position_arrow(btn: TextureButton, x_anchor: float) -> void:
	var size: Vector2 = btn.texture_normal.get_size() * 0.25
	btn.anchor_left   = x_anchor
	btn.anchor_right  = x_anchor
	btn.anchor_top    = 0.5
	btn.anchor_bottom = 0.5
	btn.offset_left   = -size.x * 0.5
	btn.offset_right  =  size.x * 0.5
	btn.offset_top    = -size.y * 0.5
	btn.offset_bottom =  size.y * 0.5


# Лёгкая чёрная тень для текста на карточке — повышает читаемость поверх
# неоднородного фона бейджа/портрета. Значения подобраны под 512-px логический
# UI-размер; supersampling до 1536 (см. CARD_TEX_SIZE) сделает её мягкой.
func _apply_card_text_shadow(lbl: Label) -> void:
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.add_theme_constant_override("shadow_outline_size", 2)


func _make_taken_overlay() -> Control:
	var ov := ColorRect.new()
	ov.color = Color(0, 0, 0, 0.6)
	ov.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lbl := Label.new()
	lbl.text = "PICKER_TAKEN"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.add_theme_color_override("font_color", UIColors.DANGER)
	lbl.add_theme_font_size_override("font_size", 18)
	ov.add_child(lbl)
	return ov


# ── Layout / population ─────────────────────────────────────────────────────

# Никаких visible-border'ов — рамка нарисована в card-frame PNG. Центральная
# карточка визуально выделена своим SLOT_SCALE и яркостью SLOT_BRIGHTNESS.
# Функция оставлена пустой как точка расширения (например, добавить glow).
func _refresh_borders() -> void:
	pass


func _populate_card(phys_idx: int, inv: Dictionary) -> void:
	var inv_name: String = inv.get("name", "")
	(_slot_portraits[phys_idx] as TextureRect).texture = _load_portrait(inv_name)
	(_slot_names[phys_idx]     as Label).text = inv.get("displayName", inv_name)
	(_slot_occs[phys_idx]      as Label).text = inv.get("occupation", "")
	# Цитата приходит как translation key (например "INV_SILAS_MARSH_QUOTE"),
	# Godot переводит автоматически. Кавычки-«ёлочки» — внутри переводов,
	# здесь дополнительно НЕ оборачиваем (иначе получаются двойные).
	var quote_key: String = inv.get("quote", "")
	if phys_idx < _slot_quotes.size():
		var ql: Label = _slot_quotes[phys_idx]
		ql.text = tr(quote_key) if not quote_key.is_empty() else ""
	(_slot_taken[phys_idx]     as Control).visible = _taken.has(inv_name) and inv_name != get_selected()


func _refresh_slots() -> void:
	if _investigators.is_empty():
		return
	var n: int = _investigators.size()
	for i: int in range(_card_meshes.size()):
		var mesh: MeshInstance3D = _card_meshes[i]
		var slot: int = int(mesh.get_meta("logical_slot", i))
		var data_idx: int = (_index + slot - CENTER_SLOT + n) % n
		_populate_card(i, _investigators[data_idx])
		_apply_3d_slot(mesh, slot)
	_refresh_borders()
	_refresh_info_bar()


func _refresh_taken_overlays() -> void:
	if _investigators.is_empty():
		return
	var n: int = _investigators.size()
	var current: String = get_selected()
	for i: int in range(_card_meshes.size()):
		var mesh: MeshInstance3D = _card_meshes[i]
		var slot: int = int(mesh.get_meta("logical_slot", i))
		var data_idx: int = (_index + slot - CENTER_SLOT + n) % n
		var inv_name: String = _investigators[data_idx].get("name", "")
		(_slot_taken[i] as Control).visible = _taken.has(inv_name) and inv_name != current


# ── Инфо-блок (низ) ──────────────────────────────────────────────────────────

func _build_info_bar() -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 16)
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(_build_stats_panel())
	hb.add_child(_build_attributes_panel())
	hb.add_child(_build_items_panel())
	return hb


func _build_stats_panel() -> PanelContainer:
	var p := PanelContainer.new()
	UIStyle.style_panel(p, 14)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_stretch_ratio = 1.0
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	p.add_child(vb)
	vb.add_child(_make_bar_row("STATS_HEALTH",  Color(0.85, 0.20, 0.20), true))
	vb.add_child(_make_bar_row("STATS_SANITY",  Color(0.30, 0.55, 0.85), false))
	var tickets_lbl := Label.new()
	tickets_lbl.text = "STATS_TICKETS"
	tickets_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	tickets_lbl.add_theme_font_size_override("font_size", 11)
	vb.add_child(tickets_lbl)
	return p


func _make_bar_row(caption_key: String, color: Color, is_hp: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var caption := Label.new()
	caption.text = caption_key
	caption.custom_minimum_size = Vector2(70, 0)
	caption.add_theme_color_override("font_color", UIColors.MUTED)
	caption.add_theme_font_size_override("font_size", 11)
	row.add_child(caption)
	var bar := ProgressBar.new()
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(120, 14)
	var fg := StyleBoxFlat.new()
	fg.bg_color = color
	fg.set_corner_radius_all(3)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.05, 0.08)
	bg.set_corner_radius_all(3)
	bg.border_color = UIColors.BORDER
	bg.set_border_width_all(1)
	bar.add_theme_stylebox_override("fill", fg)
	bar.add_theme_stylebox_override("background", bg)
	row.add_child(bar)
	var val := Label.new()
	val.text = "—"
	val.add_theme_color_override("font_color", UIColors.TEXT)
	val.add_theme_font_size_override("font_size", 11)
	val.custom_minimum_size = Vector2(48, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	if is_hp:
		_hp_bar = bar; _hp_label = val
	else:
		_sanity_bar = bar; _sanity_label = val
	return row


func _build_attributes_panel() -> PanelContainer:
	var p := PanelContainer.new()
	UIStyle.style_panel(p, 14)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_stretch_ratio = 1.5
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	p.add_child(vb)
	var hdr := Label.new()
	hdr.text = "SECTION_ATTRIBUTES"
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hdr.add_theme_color_override("font_color", UIColors.MUTED)
	hdr.add_theme_font_size_override("font_size", 11)
	vb.add_child(hdr)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(hb)
	for i: int in range(ATTRIBUTES.size()):
		var key:   String = ATTRIBUTES[i][0]
		var field: String = ATTRIBUTES[i][1]
		hb.add_child(_make_attr_box(key, field))
	return p


func _make_attr_box(label_key: String, field: String) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.custom_minimum_size = Vector2(56, 0)
	var name_lbl := Label.new()
	name_lbl.text = label_key
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	name_lbl.add_theme_font_size_override("font_size", 10)
	col.add_child(name_lbl)
	var icon_panel := Panel.new()
	icon_panel.custom_minimum_size = Vector2(36, 36)
	var icon_style := StyleBoxFlat.new()
	icon_style.bg_color = Color(0.10, 0.09, 0.16)
	icon_style.border_color = UIColors.BORDER
	icon_style.set_border_width_all(1)
	icon_style.set_corner_radius_all(18)
	icon_panel.add_theme_stylebox_override("panel", icon_style)
	col.add_child(icon_panel)
	var val := Label.new()
	val.text = "—"
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.add_theme_color_override("font_color", UIColors.ACCENT)
	val.add_theme_font_size_override("font_size", 18)
	col.add_child(val)
	_attr_value_lbls[field] = val
	return col


func _build_items_panel() -> PanelContainer:
	var p := PanelContainer.new()
	UIStyle.style_panel(p, 14)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_stretch_ratio = 1.0
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	p.add_child(vb)
	var hdr := Label.new()
	hdr.text = "SECTION_STARTING_ITEMS"
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hdr.add_theme_color_override("font_color", UIColors.MUTED)
	hdr.add_theme_font_size_override("font_size", 11)
	vb.add_child(hdr)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(hb)
	for i: int in range(3):
		hb.add_child(_make_item_slot())
	return p


func _make_item_slot() -> Control:
	var slot := PanelContainer.new()
	slot.custom_minimum_size = Vector2(64, 80)
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.08, 0.07, 0.13)
	s.border_color = UIColors.BORDER
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	slot.add_theme_stylebox_override("panel", s)
	var lbl := Label.new()
	lbl.text = "—"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", UIColors.MUTED)
	slot.add_child(lbl)
	return slot


# ── Кнопки действий ─────────────────────────────────────────────────────────

func _build_action_bar() -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 12)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER

	_back_btn = Button.new()
	_back_btn.text = "BTN_BACK"
	UIStyle.style_button(_back_btn, UIColors.MUTED)
	_back_btn.custom_minimum_size = Vector2(160, 44)
	_back_btn.pressed.connect(func() -> void: back_pressed.emit())
	hb.add_child(_back_btn)

	_confirm_btn = Button.new()
	_confirm_btn.text = "PICKER_CONFIRM"
	UIStyle.style_button(_confirm_btn, UIColors.ACCENT)
	_confirm_btn.custom_minimum_size = Vector2(280, 44)
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	hb.add_child(_confirm_btn)

	_start_btn = Button.new()
	_start_btn.text = "LOBBY_BTN_START_GAME"
	UIStyle.style_button(_start_btn, UIColors.ACCENT)
	_start_btn.custom_minimum_size = Vector2(220, 44)
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


# ── Навигация и анимация ────────────────────────────────────────────────────

func _on_prev() -> void:
	_animated_shift(-1)


func _on_next() -> void:
	_animated_shift(1)


func _on_confirm_pressed() -> void:
	confirm_pressed.emit()
	_emit_selection()


func _emit_selection() -> void:
	var inv_name: String = get_selected()
	_save_selection(inv_name)
	investigator_selected.emit(inv_name)


# ── Клики по карточкам ──────────────────────────────────────────────────────

# gui_input на _carousel_area. Левый клик → ray-cast в плоскость карточек,
# попавший слот определяет дельту перематывания (slot - CENTER_SLOT).
func _on_carousel_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var slot: int = _hit_test_card(mb.position)
	if slot < 0:
		return
	var delta: int = slot - CENTER_SLOT
	if delta == 0:
		_on_confirm_pressed()
	else:
		_animated_shift(delta)
	_carousel_area.accept_event()


# Возвращает logical_slot карточки, по которой кликнули, либо -1.
# Делает ray-cast из камеры в мировые плоскости карточек и проверяет
# попадание в bounds квада (CARD_QUAD_SIZE в локальных координатах).
func _hit_test_card(local_click_pos: Vector2) -> int:
	if not is_instance_valid(_camera) or _card_meshes.is_empty():
		return -1
	# spvc стрейтчит _world_vp.size в свой on-screen size; пересчитываем клик
	# в координаты SubViewport'а, в которых живёт камера.
	var spvc_size: Vector2 = _carousel_area.size
	if spvc_size.x <= 0.0 or spvc_size.y <= 0.0:
		return -1
	var vp_size: Vector2 = Vector2(_world_vp.size)
	var vp_pos := Vector2(
		local_click_pos.x * (vp_size.x / spvc_size.x),
		local_click_pos.y * (vp_size.y / spvc_size.y)
	)
	var ray_origin: Vector3 = _camera.project_ray_origin(vp_pos)
	var ray_dir:    Vector3 = _camera.project_ray_normal(vp_pos)

	var best_slot: int   = -1
	var best_dist: float = INF
	var half := CARD_QUAD_SIZE * 0.5
	for i: int in range(_card_meshes.size()):
		var mesh: MeshInstance3D = _card_meshes[i]
		var xform: Transform3D = mesh.global_transform
		# Плоскость карточки: нормаль = +Z локального basis в мировых координатах.
		var normal: Vector3 = xform.basis.z.normalized()
		var plane := Plane(normal, xform.origin.dot(normal))
		var hit_v = plane.intersects_ray(ray_origin, ray_dir)
		if hit_v == null:
			continue
		var hit: Vector3 = hit_v
		# В локальных координатах меша квад центрирован на (0,0) с size CARD_QUAD_SIZE.
		var local_hit: Vector3 = xform.affine_inverse() * hit
		if absf(local_hit.x) <= half.x and absf(local_hit.y) <= half.y:
			var d: float = ray_origin.distance_to(hit)
			if d < best_dist:
				best_dist = d
				best_slot = int(mesh.get_meta("logical_slot", i))
	return best_slot


# Сдвиг карусели на delta позиций (знаковый). delta=+1/-1 — соседний шаг,
# delta=±2 — прыжок через одну (клик по дальней боковой карточке).
#
# Анимации ПРЕРЫВАЕМЫ: если предыдущий shift ещё играет, мы убиваем все
# активные tween'ы, мгновенно снапаем каждый меш в его текущий logical_slot
# (с правильными данными), и от этого состояния запускаем новую анимацию.
# Это даёт мгновенную отзывчивость на клики при быстром перематывании.
func _animated_shift(delta: int) -> void:
	if _investigators.is_empty() or delta == 0:
		return

	SfxManager.play(SfxManager.SFX_SLIDE)

	# Прерываем любую незаконченную анимацию: kill tween'ов + snap к logical_slot.
	for m: MeshInstance3D in _card_meshes:
		_kill_mesh_tween(m)

	var n: int = _investigators.size()
	var step: int = delta                       # знаковая величина (±1, ±2, …)
	var step_sign: int = 1 if step > 0 else -1
	_index = ((_index + step) % n + n) % n

	for i: int in range(_card_meshes.size()):
		var mesh: MeshInstance3D = _card_meshes[i]
		var current_slot: int = int(mesh.get_meta("logical_slot", i))
		var new_slot: int = current_slot - step
		if new_slot >= 0 and new_slot < VISIBLE_SLOTS:
			_animate_mesh_to_slot(mesh, new_slot)
			mesh.set_meta("logical_slot", new_slot)
		else:
			var wrap_slot: int = (new_slot + VISIBLE_SLOTS) if new_slot < 0 \
				else (new_slot - VISIBLE_SLOTS)
			_wrap_mesh(mesh, i, step_sign, wrap_slot)
			mesh.set_meta("logical_slot", wrap_slot)

	_refresh_borders()
	_refresh_info_bar()


# Прерывает активный tween у меша (если есть) и снапает меш в его текущий
# logical_slot с правильными данными — гарантирует консистентное состояние,
# от которого корректно стартует новая анимация.
func _kill_mesh_tween(mesh: MeshInstance3D) -> void:
	if mesh.has_meta("__tween"):
		var t = mesh.get_meta("__tween")
		if t and (t as Tween).is_valid():
			(t as Tween).kill()
		mesh.remove_meta("__tween")
	# Снап позиции/поворота/яркости + актуализация данных карточки.
	var phys_idx: int = _card_meshes.find(mesh)
	if phys_idx < 0:
		return
	var slot: int = int(mesh.get_meta("logical_slot", phys_idx))
	_apply_3d_slot(mesh, slot)
	if not _investigators.is_empty():
		var n: int = _investigators.size()
		var data_idx: int = (_index + slot - CENTER_SLOT + n) % n
		_populate_card(phys_idx, _investigators[data_idx])


# Плавно переводит mesh в позицию/поворот/масштаб/яркость указанного слота.
# Tween сохраняется в meta, чтобы прерывание извне могло его убить.
func _animate_mesh_to_slot(mesh: MeshInstance3D, slot: int) -> void:
	var target_pos: Vector3 = SLOT_3D_POSITIONS[slot]
	var target_rot: Vector3 = Vector3(0.0, deg_to_rad(SLOT_3D_ROTATIONS_DEG[slot]), 0.0)
	var s: float = SLOT_SCALES[slot]
	var target_scale: Vector3 = Vector3(s, s, 1.0)
	var b: float = SLOT_BRIGHTNESS[slot]
	var target_color: Color = Color(b, b, b, 1.0)
	var mat := mesh.material_override as StandardMaterial3D
	var tw := mesh.create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(mesh, "position", target_pos,   ANIM_DURATION)
	tw.tween_property(mesh, "rotation", target_rot,   ANIM_DURATION)
	tw.tween_property(mesh, "scale",    target_scale, ANIM_DURATION)
	if mat:
		tw.tween_property(mat, "albedo_color", target_color, ANIM_DURATION)
	mesh.set_meta("__tween", tw)


# Wrap-анимация одним прерываемым tween-чейном: phase 1 (вылет+fade out) →
# callback (data swap + teleport на entry side) → phase 2 (въезд+fade in).
# Без await — иначе при kill'е промежуточный код повиснет.
func _wrap_mesh(mesh: MeshInstance3D, phys_idx: int, direction: int,
		wrap_slot: int) -> void:
	var off_dist: float = 7.0
	# direction>0 — карусель прокручивается вперёд: карточка вылетает влево,
	# появляется справа (wrap_slot=VISIBLE_SLOTS-1). Зеркально для direction<0.
	var off_x:   float = -off_dist if direction > 0 else  off_dist
	var entry_x: float =  off_dist if direction > 0 else -off_dist

	var target_pos: Vector3 = SLOT_3D_POSITIONS[wrap_slot]
	var target_rot: Vector3 = Vector3(0.0, deg_to_rad(SLOT_3D_ROTATIONS_DEG[wrap_slot]), 0.0)
	var s: float = SLOT_SCALES[wrap_slot]
	var target_scale: Vector3 = Vector3(s, s, 1.0)
	var b: float = SLOT_BRIGHTNESS[wrap_slot]
	var target_color: Color = Color(b, b, b, 1.0)
	var mat := mesh.material_override as StandardMaterial3D
	var off_pos   := Vector3(off_x,   mesh.position.y, mesh.position.z)
	var entry_pos := Vector3(entry_x, target_pos.y,    target_pos.z)

	var tw := mesh.create_tween().set_trans(Tween.TRANS_CUBIC)

	# Phase 1 (parallel): вылет за край + alpha→0.
	tw.tween_property(mesh, "position", off_pos, ANIM_DURATION * 0.5).set_ease(Tween.EASE_IN)
	if mat:
		var fade := mat.albedo_color
		fade.a = 0.0
		tw.parallel().tween_property(mat, "albedo_color", fade, ANIM_DURATION * 0.5).set_ease(Tween.EASE_IN)

	# Mid (sequential after phase 1): подменяем данные + телепорт на entry side.
	tw.chain().tween_callback(func() -> void:
		var n: int = _investigators.size()
		var data_idx: int = (_index + wrap_slot - CENTER_SLOT + n) % n
		_populate_card(phys_idx, _investigators[data_idx])
		mesh.position = entry_pos
		mesh.rotation = target_rot
		mesh.scale    = target_scale
		if mat:
			mat.albedo_color = Color(b, b, b, 0.0)
	)

	# Phase 2 (parallel): въезд в слот + alpha→target_brightness.
	tw.tween_property(mesh, "position", target_pos, ANIM_DURATION * 0.5).set_ease(Tween.EASE_OUT)
	if mat:
		tw.parallel().tween_property(mat, "albedo_color", target_color, ANIM_DURATION * 0.5).set_ease(Tween.EASE_OUT)

	mesh.set_meta("__tween", tw)


func _refresh_info_bar() -> void:
	if _investigators.is_empty():
		return
	var inv: Dictionary = _investigators[_index]
	var hp_max:  int = int(inv.get("health", 0))
	var san_max: int = int(inv.get("sanity", 0))
	if _hp_bar:
		_hp_bar.max_value = float(maxi(1, hp_max))
		_hp_bar.value     = float(hp_max)
	if _hp_label:
		_hp_label.text = "%d / %d" % [hp_max, hp_max]
	if _sanity_bar:
		_sanity_bar.max_value = float(maxi(1, san_max))
		_sanity_bar.value     = float(san_max)
	if _sanity_label:
		_sanity_label.text = "%d / %d" % [san_max, san_max]
	var sk: Dictionary = inv.get("skills", {})
	for field: String in _attr_value_lbls.keys():
		(_attr_value_lbls[field] as Label).text = str(int(sk.get(field, 0)))


# ── Сохранение / восстановление выбора ─────────────────────────────────────

func _save_selection(inv_name: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_PREFS_PATH)
	cfg.set_value(_PREFS_SECTION, "last_investigator", inv_name)
	cfg.save(_PREFS_PATH)


func _load_saved_selection() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(_PREFS_PATH) != OK:
		return ""
	return cfg.get_value(_PREFS_SECTION, "last_investigator", "")


func _preselect_saved() -> void:
	if _investigators.is_empty():
		return
	var saved: String = _load_saved_selection()
	if not saved.is_empty():
		for i: int in range(_investigators.size()):
			if _investigators[i].get("name", "") == saved:
				_index = i
				break
	_refresh_slots()
	_emit_selection()
