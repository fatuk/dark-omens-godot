extends Control

## Карусель выбора сыщика — 3D-cover-flow в SubViewport'е.
## 5 карточек: центр крупный, по 2 поменьше с каждой стороны (с уменьшающейся
## альфой). Стрелки + клик по боковой карточке двигают карусель; центр /
## «CONFIRM SELECTION» подтверждают.
##
## Этот файл — координация: загрузка JSON, состояние, анимация, network glue.
## UI-кусочки вынесены:
##   • [CardView] — слоистая разметка карточки (портрет/рамка/бейдж/цитата).
##   • [InfoBar]  — нижняя панель статов/атрибутов/предметов.
##   • [PlayerDetailsContent] — содержимое модалки «Подробнее».
##   • [SelectionPrefs] — persist последнего выбора.

const _MODAL_SCENE := preload("res://scenes/ui/modal_dialog.tscn")

const ARROW_TEX_LEFT:  Texture2D = preload("res://assets/carousel/L_arrow.png")
const ARROW_TEX_RIGHT: Texture2D = preload("res://assets/carousel/R_arrow.png")
const CHEVRON_TEX_LEFT:  Texture2D = preload("res://assets/carousel/L_chevron.png")
const CHEVRON_TEX_RIGHT: Texture2D = preload("res://assets/carousel/R_chevron.png")
const INFO_BTN_TEX:      Texture2D = preload("res://assets/info-btn.png")

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
	Vector3(-2.8, 0.0, -0.4),  # far left
	Vector3(-1.7, 0.0, -0.1),  # left
	Vector3( 0.0, 0.0,  0.3),  # center (немного вперёд)
	Vector3( 1.7, 0.0, -0.1),  # right
	Vector3( 2.8, 0.0, -0.4),  # far right
]
const SLOT_3D_ROTATIONS_DEG := [-20.0, -10.0, 0.0, 10.0, 20.0]
# Half-width карточки = CARD_QUAD_SIZE.x/2 * scale. Сумма соседних half-width'ов
# должна быть < соответствующего spacing в SLOT_3D_POSITIONS — иначе карточки
# перекрываются. Текущие значения дают ~0.08 world unit зазор между всеми
# соседними слотами при scale center=1.3.
const SLOT_SCALES     := [0.85, 1.05, 1.3, 1.05, 0.85]
const SLOT_BRIGHTNESS := [0.45, 0.65, 1.00, 0.65, 0.45]

# Мягкая drop-тень под карточками — дочерний quad чуть больше карточки,
# тёмный полупрозрачный, со сдвигом вниз. Как ребёнок меша наследует
# трансформ — анимировать отдельно не нужно.
const SHADOW_QUAD_SCALE: float = 1.35                    # размер тени относительно карточки
const SHADOW_OFFSET     := Vector3(0.04, -0.16, -0.05)   # сдвиг: вправо-вниз + чуть назад
const SHADOW_ALPHA:      float = 0.85

# Глобальный сдвиг карточек по Y в 3D. 0 = карточки центрированы в viewport'е
# (после увеличения FOV-зумом они почти заполняют его по высоте, сдвиг больше
# не нужен). Положительное значение двигает вверх, отрицательное — вниз.
const SLOT_Y_OFFSET: float = 0.0

# Вертикально видимый размер мира в карусели на глубине карточек: 2 * cam.z *
# tan(fov/2) при cam.z=6.2 и FOV=26°. Используется для перевода 3D-сдвига
# карточек (SLOT_Y_OFFSET) в долю экрана — нужно стрелкам, чтобы их Y-якорь
# следовал за карточками. При смене CAM_*/SLOT_Y_OFFSET — пересчитай.
const _VISIBLE_WORLD_HEIGHT: float = 2.86
const ARROW_Y_ANCHOR: float = 0.5 - SLOT_Y_OFFSET / _VISIBLE_WORLD_HEIGHT

# Камера: длиннофокусная (узкий FOV) + дальше отодвинута — это «сплющивает»
# перспективу, как телевик. При таком setup'е боковые карточки выглядят почти
# одного размера с центром, а наклон читается, но без сильных трапеций.
# FOV сужен с 30° до 26° — карточки крупнее (~+16%), плотнее заполняют viewport.
# Чем уже FOV — тем больше карточки, но и боковые сильнее уезжают за край.
const CAM_POSITION := Vector3(0.0, 0.0, 6.2)
const CAM_FOV: float = 23.0

# Якоря для стрелок навигации: середина между внешней и соседней карточками
# (3D-точки x=±3.1, z=-0.2). Значение получено через perspective unproject при
# текущих CAM_POSITION/CAM_FOV и аспекте 1920/760 у _world_vp — спроецировано
# в нормализованные screen-coords. Камера статична, поэтому константа, без
# пересчёта в runtime. Если изменишь CAM_*/SLOT_3D_POSITIONS — пересчитай.
const ARROW_X_ANCHOR_FROM_EDGE: float = 0.12

const ANIM_DURATION: float = 0.50

# Стрелка слегка дёргается «наружу» при перелистывании в её сторону.
# Параметры подобраны короткими, чтобы укладываться внутрь ANIM_DURATION
# и не отвлекать от анимации карточек.
const ARROW_NUDGE_PX:           float = 12.0
const ARROW_NUDGE_OUT_DURATION: float = 0.10
const ARROW_NUDGE_BACK_DURATION: float = 0.18

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
var _index:         int        = 0    # центральный индекс
var _placeholder_tex:  ImageTexture = null   # кешируется в _ready, не плодим на каждый _populate
var _card_shadow_tex:  ImageTexture = null   # мягкая тень-подложка, общая на все карточки

# ── UI ────────────────────────────────────────────────────────────────────────
var _root: VBoxContainer = null   # создаётся в _ready()

# 3D-карточки: каждая — MeshInstance3D с QuadMesh, чья текстура = рендер
# per-card SubViewport'а. UI внутри каждого viewport'а — CardView (см.
# scripts/ui/card_view.gd), его и держим в _card_views для обновления.
var _card_meshes: Array              = []   # MeshInstance3D[]
var _card_views:  Array[CardView]    = []

var _prev_btn:       TextureButton
var _next_btn:       TextureButton
var _carousel_area:  Control          # SubViewportContainer + 3D scene
var _world_vp:       SubViewport      # 3D scene SubViewport
var _camera:         Camera3D
# Анимации прерываемы (см. _animated_shift), без блокирующего флага _animating.

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
	_placeholder_tex = _build_placeholder_texture()
	_card_shadow_tex = _build_card_shadow_texture()

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
	_root.offset_left   = 40
	_root.offset_right  = -40
	_root.offset_top    = 30
	_root.offset_bottom = -24
	_root.add_theme_constant_override("separation", 7)
	canvas.add_child(_root)

	_load_investigators()
	_build_ui()
	call_deferred("_preselect_saved")


func get_selected() -> String:
	if _investigators.is_empty():
		return ""
	return String((_investigators[_index] as Dictionary).get("name", ""))


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


func _build_placeholder_texture() -> ImageTexture:
	# Заметно ярче UIColors.SURFACE — чтобы карточка с отсутствующим портретом
	# не сливалась с фоном панели.
	var img := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.22, 0.20, 0.30))
	return ImageTexture.create_from_image(img)


# Текстура мягкой тени: чёрный прямоугольник с альфой, плавно затухающей
# к краям (smoothstep). Низкое разрешение — тень размытая, детали не нужны.
func _build_card_shadow_texture() -> ImageTexture:
	var s: int = 128
	# Узкий мягкий край: ядро почти сплошное, размывается только по контуру —
	# тень получается «глубокой», а не блёклой.
	var falloff: float = float(s) * 0.16
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	for y in range(s):
		for x in range(s):
			var edge: float = float(mini(mini(x, s - 1 - x), mini(y, s - 1 - y)))
			var a: float = clampf(edge / falloff, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)   # smoothstep — мягче на стыке
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, a))
	return ImageTexture.create_from_image(img)


# ── Построение UI ────────────────────────────────────────────────────────────

func _build_ui() -> void:
	_root.add_child(_build_title())
	_root.add_child(_build_carousel())
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


# ── Карусель ────────────────────────────────────────────────────────────────

func _build_carousel() -> Control:
	var area := Control.new()
	area.name = "Carousel"
	# Минимум намеренно невысокий: карусель и так SIZE_EXPAND_FILL — заберёт
	# всё свободное место. Высокий минимум (был 760) при крупной InfoBar
	# выдавливал action-bar за нижний край окна.
	area.custom_minimum_size = Vector2(0, 480)
	area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_carousel_area = area

	# SubViewportContainer хостит 3D-сцену и stretch'ит её на размер area.
	var spvc := SubViewportContainer.new()
	spvc.name = "WorldVPContainer"
	spvc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	spvc.stretch = true
	spvc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(spvc)

	# 3D SubViewport: камера + 5 квадов карточек.
	# Разрешение 3840×1520 (аспект 2.526, как 1920×760 — проекция не меняется),
	# вдвое выше «логического» — иначе при stretch'е на крупную карусель рендер
	# апскейлится и текст карточек мылит. Аспект ОБЯЗАН остаться 2.526, иначе
	# поедет горизонтальная раскладка слотов.
	_world_vp = SubViewport.new()
	_world_vp.name = "WorldVP"
	_world_vp.size = Vector2i(3840, 1520)
	_world_vp.transparent_bg = true
	_world_vp.handle_input_locally = false
	# По умолчанию засыпаем — пока нет активных tween'ов меш-карточек, рендерить
	# нечего. Включается на ALWAYS в _animate_mesh_to_slot / _wrap_mesh, гасится
	# обратно в _on_mesh_tween_finished. Repaint per-card vp бампает наш UPDATE_ONCE
	# (см. _request_card_repaint).
	_world_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_world_vp.msaa_3d = Viewport.MSAA_4X   # сглаживание — иначе края полигонов лесенкой
	spvc.add_child(_world_vp)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.position   = CAM_POSITION
	_camera.fov        = CAM_FOV
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_world_vp.add_child(_camera)

	# 5 пар (UI SubViewport + 3D MeshInstance с этой текстурой). UI viewport'ы
	# off-screen дети area; внутри каждого — один CardView.
	for i: int in range(VISIBLE_SLOTS):
		var ui_vp := _make_card_ui_subviewport()
		ui_vp.name = "CardVP_%d" % i
		area.add_child(ui_vp)
		var mesh := _make_3d_card_mesh(ui_vp)
		mesh.name = "CardMesh_%d" % i
		mesh.set_meta("logical_slot", i)
		_world_vp.add_child(mesh)
		_card_meshes.append(mesh)
		_apply_3d_slot(mesh, i)

	# Виньетка по краям — поверх 3D-сцены, но ДО стрелок (стрелки остаются
	# яркими сверху, дальние карточки мягко уходят в темноту).
	area.add_child(_make_edge_vignette())

	# Стрелки — TextureButton'ы на границе между внешней и соседней карточками
	# (см. ARROW_X_ANCHOR_FROM_EDGE). Дети area, поэтому всегда поверх 3D.
	_prev_btn = _make_arrow_btn(ARROW_TEX_LEFT)
	_prev_btn.name = "PrevArrow"
	_position_arrow(_prev_btn, ARROW_X_ANCHOR_FROM_EDGE)
	_prev_btn.pressed.connect(_on_prev)
	area.add_child(_prev_btn)

	_next_btn = _make_arrow_btn(ARROW_TEX_RIGHT)
	_next_btn.name = "NextArrow"
	_position_arrow(_next_btn, 1.0 - ARROW_X_ANCHOR_FROM_EDGE)
	_next_btn.pressed.connect(_on_next)
	area.add_child(_next_btn)

	# Клики по 3D-карточкам ловим на уровне area (spvc сам IGNORE'ит, поэтому
	# input доходит до родительского Control). Хит-тест — ray-cast из камеры.
	area.mouse_filter = Control.MOUSE_FILTER_STOP
	area.gui_input.connect(_on_carousel_gui_input)
	return area


# Создаёт SubViewport с одним CardView внутри. Возвращает SubViewport (его
# текстура натягивается на 3D-quad). size_2d_override → supersampling ×3.
func _make_card_ui_subviewport() -> SubViewport:
	var vp := SubViewport.new()
	vp.size = CARD_TEX_SIZE
	vp.size_2d_override = CARD_UI_SIZE
	vp.size_2d_override_stretch = true
	vp.transparent_bg = true
	vp.handle_input_locally = false
	# UI карточки статичен между обновлениями данных — рендерим один раз,
	# после set_data/_populate_card бампаем UPDATE_ONCE снова. Экономит fill-rate
	# (5 viewport'ов × 1536² больше не молотят каждый кадр).
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE

	var view := CardView.new(_placeholder_tex)
	view.name = "CardView"
	vp.add_child(view)
	_card_views.append(view)
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

	# Имя проставляется снаружи (per-slot index) — здесь только конструируем.
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = mat
	mi.add_child(_make_card_shadow())
	return mi


# Мягкая drop-тень — дочерний quad чуть больше карточки. Ребёнок меша,
# поэтому наследует его позицию/поворот/масштаб при анимациях слотов.
func _make_card_shadow() -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = CARD_QUAD_SIZE * SHADOW_QUAD_SCALE

	var mat := StandardMaterial3D.new()
	mat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _card_shadow_tex
	mat.albedo_color   = Color(1.0, 1.0, 1.0, SHADOW_ALPHA)
	mat.transparency   = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode      = BaseMaterial3D.CULL_DISABLED

	var sh := MeshInstance3D.new()
	sh.name = "CardShadow"
	sh.mesh = quad
	sh.material_override = mat
	sh.position = SHADOW_OFFSET   # local: за карточкой (z<0), сдвинута вниз
	return sh


# Целевая трансформация для слота — pos/rot/scale/color. Используется как
# snap-target (_apply_3d_slot) так и tween-target (_animate_mesh_to_slot / wrap).
func _slot_transform(slot: int) -> Dictionary:
	var s: float = SLOT_SCALES[slot]
	var b: float = SLOT_BRIGHTNESS[slot]
	return {
		"pos":   SLOT_3D_POSITIONS[slot] + Vector3(0.0, SLOT_Y_OFFSET, 0.0),
		"rot":   Vector3(0.0, deg_to_rad(SLOT_3D_ROTATIONS_DEG[slot]), 0.0),
		"scale": Vector3(s, s, 1.0),
		"color": Color(b, b, b, 1.0),
	}


# Материал дочернего shadow-quad'а карточки (или null).
func _card_shadow_mat(mesh: MeshInstance3D) -> StandardMaterial3D:
	var sh := mesh.get_node_or_null("CardShadow") as MeshInstance3D
	return (sh.material_override as StandardMaterial3D) if sh else null


# Применяет position/rotation/scale/brightness к мешу для указанного слота (без анимации).
func _apply_3d_slot(mesh: MeshInstance3D, slot: int) -> void:
	var t := _slot_transform(slot)
	mesh.position = t.pos
	mesh.rotation = t.rot
	mesh.scale    = t.scale
	var mat := mesh.material_override as StandardMaterial3D
	if mat:
		mat.albedo_color = t.color
	# Снап тени к полной непрозрачности — на случай прерванного wrap-fade'а.
	var smat := _card_shadow_mat(mesh)
	if smat:
		smat.albedo_color = Color(1.0, 1.0, 1.0, SHADOW_ALPHA)


# Горизонтальная виньетка: непрозрачно-чёрная у левого/правого края,
# плавно сходит в прозрачность к центру (16% ширины на затухание с каждой
# стороны). Прячет жёсткий обрез дальних карточек.
func _make_edge_vignette() -> TextureRect:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.16, 0.84, 1.0])
	grad.colors  = PackedColorArray([
		Color(0.0, 0.0, 0.0, 1.0),
		Color(0.0, 0.0, 0.0, 0.0),
		Color(0.0, 0.0, 0.0, 0.0),
		Color(0.0, 0.0, 0.0, 1.0),
	])

	var tex := GradientTexture2D.new()
	tex.gradient  = grad
	tex.width     = 512
	tex.height    = 1
	tex.fill      = GradientTexture2D.FILL_LINEAR
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to   = Vector2(1.0, 0.0)

	var rect := TextureRect.new()
	rect.name         = "EdgeVignette"
	rect.texture      = tex
	rect.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


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
	var tex_size: Vector2 = btn.texture_normal.get_size() * 0.25
	btn.anchor_left   = x_anchor
	btn.anchor_right  = x_anchor
	btn.anchor_top    = ARROW_Y_ANCHOR
	btn.anchor_bottom = ARROW_Y_ANCHOR
	btn.offset_left   = -tex_size.x * 0.5
	btn.offset_right  =  tex_size.x * 0.5
	btn.offset_top    = -tex_size.y * 0.5
	btn.offset_bottom =  tex_size.y * 0.5
	# Запоминаем «домашние» offset'ы — к ним возвращаемся после nudge'а
	# (см. _animate_arrow_nudge).
	btn.set_meta("rest_offset_left",  btn.offset_left)
	btn.set_meta("rest_offset_right", btn.offset_right)


# Короткий «pulse» соответствующей стрелки наружу + возврат. direction:
# +1 → next (правая стрелка дёргается вправо), -1 → prev (левая влево).
# Анимирует offset_left/offset_right симметрично, чтобы размер кнопки
# не менялся. При спам-кликах прерывает предыдущий tween и стартует
# новый с текущей позиции.
func _animate_arrow_nudge(direction: int) -> void:
	var btn: TextureButton = _next_btn if direction > 0 else _prev_btn
	if not is_instance_valid(btn) or not btn.has_meta("rest_offset_left"):
		return
	if btn.has_meta("__nudge_tw"):
		var prev = btn.get_meta("__nudge_tw")
		if prev and (prev as Tween).is_valid():
			(prev as Tween).kill()
	var rest_l: float = btn.get_meta("rest_offset_left")
	var rest_r: float = btn.get_meta("rest_offset_right")
	var d: float = float(direction) * ARROW_NUDGE_PX
	var tw := btn.create_tween().set_trans(Tween.TRANS_QUAD)
	# Phase 1 — дёрг наружу (оба offset'а параллельно).
	tw.tween_property(btn, "offset_left",  rest_l + d, ARROW_NUDGE_OUT_DURATION).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(btn, "offset_right", rest_r + d, ARROW_NUDGE_OUT_DURATION).set_ease(Tween.EASE_OUT)
	# Phase 2 — возврат в rest (chain ждёт phase 1).
	tw.chain().tween_property(btn, "offset_left",  rest_l, ARROW_NUDGE_BACK_DURATION).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(btn, "offset_right", rest_r, ARROW_NUDGE_BACK_DURATION).set_ease(Tween.EASE_IN)
	btn.set_meta("__nudge_tw", tw)


# ── Layout / population ─────────────────────────────────────────────────────

func _populate_card(phys_idx: int, inv: Dictionary) -> void:
	var view: CardView = _card_views[phys_idx]
	view.set_data(inv)
	var inv_name: String = inv.get("name", "")
	view.set_taken(_taken.has(inv_name) and inv_name != get_selected())
	_request_card_repaint(phys_idx)


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
	if _info_bar:
		_info_bar.update(_investigators[_index])


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
		_card_views[i].set_taken(_taken.has(inv_name) and inv_name != current)
		_request_card_repaint(i)


# CardView лежит внутри SubViewport'а с UPDATE_ONCE — после изменения данных
# нужно явно попросить vp перерисоваться (один кадр и обратно в спящий режим).
# Заодно дёргаем _world_vp — он использует ViewportTexture этих карточек, и
# если он сейчас спит, нужно отрендерить ещё один кадр с обновлённой текстурой.
func _request_card_repaint(phys_idx: int) -> void:
	var vp := _card_views[phys_idx].get_parent() as SubViewport
	if vp:
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	if _world_vp and _world_vp.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
		_world_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


# Будит _world_vp на ALWAYS — нужно, когда стартует tween-движение карточки.
# Гасится обратно в _on_mesh_tween_finished, когда все tween'ы кончились.
func _wake_world_vp() -> void:
	if _world_vp:
		_world_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS


# Хук на tween.finished каждого меша. Если активных tween'ов больше нет —
# усыпляем _world_vp. .kill() сигнал не эмитит, но _kill_mesh_tween всегда
# следует за созданием нового tween'а в _animated_shift, так что mode остаётся
# ALWAYS до настоящего конца анимации.
func _on_mesh_tween_finished() -> void:
	for m: MeshInstance3D in _card_meshes:
		if not m.has_meta("__tween"):
			continue
		var t = m.get_meta("__tween")
		if t and (t as Tween).is_valid() and (t as Tween).is_running():
			return
	if _world_vp:
		_world_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED


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
	_back_btn.custom_minimum_size = Vector2(160, 44)
	_back_btn.pressed.connect(func() -> void: back_pressed.emit())
	hb.add_child(_back_btn)

	_confirm_btn = Button.new()
	_confirm_btn.name = "ConfirmBtn"
	_confirm_btn.text = "PICKER_CONFIRM"
	UIStyle.style_button(_confirm_btn, UIColors.ACCENT)
	_confirm_btn.custom_minimum_size = Vector2(280, 44)
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	hb.add_child(_confirm_btn)

	_start_btn = Button.new()
	_start_btn.name = "StartBtn"
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
	SelectionPrefs.save(inv_name)
	selection_changed.emit(inv_name)


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
		var hit_v: Variant = plane.intersects_ray(ray_origin, ray_dir)
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
	# Wrap-логика ниже предполагает |delta| < VISIBLE_SLOTS — при большем
	# скачке формула `new_slot ± VISIBLE_SLOTS` даст некорректный wrap_slot.
	# Сейчас delta всегда ±1/±2, assert ловит регрессию.
	assert(absi(delta) < VISIBLE_SLOTS, "delta too large for current wrap formula")

	SfxManager.play(SfxManager.SFX_SLIDE)
	_animate_arrow_nudge(1 if delta > 0 else -1)

	# Прерываем любую незаконченную анимацию: kill tween'ов + snap к logical_slot.
	for i: int in range(_card_meshes.size()):
		_kill_mesh_tween(_card_meshes[i], i)

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

	if _info_bar:
		_info_bar.update(_investigators[_index])


# Прерывает активный tween у меша (если есть) и снапает меш в его текущий
# logical_slot с правильными данными — гарантирует консистентное состояние,
# от которого корректно стартует новая анимация.
func _kill_mesh_tween(mesh: MeshInstance3D, phys_idx: int) -> void:
	if mesh.has_meta("__tween"):
		var t = mesh.get_meta("__tween")
		if t and (t as Tween).is_valid():
			(t as Tween).kill()
		mesh.remove_meta("__tween")
	# Снап позиции/поворота/яркости + актуализация данных карточки.
	var slot: int = int(mesh.get_meta("logical_slot", phys_idx))
	_apply_3d_slot(mesh, slot)
	if not _investigators.is_empty():
		var n: int = _investigators.size()
		var data_idx: int = (_index + slot - CENTER_SLOT + n) % n
		_populate_card(phys_idx, _investigators[data_idx])


# Плавно переводит mesh в позицию/поворот/масштаб/яркость указанного слота.
# Tween сохраняется в meta, чтобы прерывание извне могло его убить.
func _animate_mesh_to_slot(mesh: MeshInstance3D, slot: int) -> void:
	var t := _slot_transform(slot)
	var mat := mesh.material_override as StandardMaterial3D
	var tw := mesh.create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(mesh, "position", t.pos,   ANIM_DURATION)
	tw.tween_property(mesh, "rotation", t.rot,   ANIM_DURATION)
	tw.tween_property(mesh, "scale",    t.scale, ANIM_DURATION)
	if mat:
		tw.tween_property(mat, "albedo_color", t.color, ANIM_DURATION)
	tw.finished.connect(_on_mesh_tween_finished)
	mesh.set_meta("__tween", tw)
	_wake_world_vp()


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

	var t := _slot_transform(wrap_slot)
	var mat := mesh.material_override as StandardMaterial3D
	var smat := _card_shadow_mat(mesh)   # тень фейдится в ногу с карточкой
	var off_pos   := Vector3(off_x,   mesh.position.y, mesh.position.z)
	var entry_pos := Vector3(entry_x, t.pos.y,         t.pos.z)
	var transparent_color: Color = t.color
	transparent_color.a = 0.0
	var shadow_hidden  := Color(1.0, 1.0, 1.0, 0.0)
	var shadow_visible := Color(1.0, 1.0, 1.0, SHADOW_ALPHA)

	var tw := mesh.create_tween().set_trans(Tween.TRANS_CUBIC)

	# Phase 1 (parallel): вылет за край + alpha→0 (карточка и тень).
	tw.tween_property(mesh, "position", off_pos, ANIM_DURATION * 0.5).set_ease(Tween.EASE_IN)
	if mat:
		var fade := mat.albedo_color
		fade.a = 0.0
		tw.parallel().tween_property(mat, "albedo_color", fade, ANIM_DURATION * 0.5).set_ease(Tween.EASE_IN)
	if smat:
		tw.parallel().tween_property(smat, "albedo_color", shadow_hidden, ANIM_DURATION * 0.5).set_ease(Tween.EASE_IN)

	# Mid: подменяем данные + телепорт на entry side.
	tw.chain().tween_callback(func() -> void:
		var n: int = _investigators.size()
		var data_idx: int = (_index + wrap_slot - CENTER_SLOT + n) % n
		_populate_card(phys_idx, _investigators[data_idx])
		mesh.position = entry_pos
		mesh.rotation = t.rot
		mesh.scale    = t.scale
		if mat:
			mat.albedo_color = transparent_color
		if smat:
			smat.albedo_color = shadow_hidden
	)

	# Phase 2 (parallel): въезд в слот + alpha→target (карточка и тень).
	tw.tween_property(mesh, "position", t.pos, ANIM_DURATION * 0.5).set_ease(Tween.EASE_OUT)
	if mat:
		tw.parallel().tween_property(mat, "albedo_color", t.color, ANIM_DURATION * 0.5).set_ease(Tween.EASE_OUT)
	if smat:
		tw.parallel().tween_property(smat, "albedo_color", shadow_visible, ANIM_DURATION * 0.5).set_ease(Tween.EASE_OUT)

	tw.finished.connect(_on_mesh_tween_finished)
	mesh.set_meta("__tween", tw)
	_wake_world_vp()


# ── Сохранение / восстановление выбора ─────────────────────────────────────

func _preselect_saved() -> void:
	if _investigators.is_empty():
		return
	var saved: String = SelectionPrefs.load_last()
	if not saved.is_empty():
		for i: int in range(_investigators.size()):
			if _investigators[i].get("name", "") == saved:
				_index = i
				break
	_refresh_slots()
	_emit_selection()
