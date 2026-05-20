class_name Carousel3D
extends Control

## 3D-cover-flow карусели сыщиков. 5 видимых карточек: центр крупный, по 2
## поменьше с каждой стороны (с уменьшающейся яркостью). Стрелки + клик по
## боковой карточке двигают, клик по центру эмитит [signal center_clicked].
##
## Внутри: камера в SubViewport'е, 5 MeshInstance3D (QuadMesh) с per-card
## UI-SubViewport'ами как текстурами. Анимации прерываемы (мгновенный отклик
## на спам-клики). Стрелки слегка «дёргаются» наружу при shift'е.
##
## API:
##   set_data(investigators, taken, start_index) — заполнить и снапнуть индекс
##   update_taken(taken)                          — обновить overlay'и занятости
##   current_index() -> int                       — индекс центральной карточки
##   selected_name()  -> String                   — имя сыщика по центру
##
## Сигналы:
##   index_changed(idx)  — на любой shift (включая первичный set_data)
##   center_clicked()    — клик по центральной карточке


const ARROW_TEX_LEFT:  Texture2D = preload("res://assets/carousel/L_arrow.png")
const ARROW_TEX_RIGHT: Texture2D = preload("res://assets/carousel/R_arrow.png")

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
const SHADOW_QUAD_SCALE: float = 1.2                  # размер тени относительно карточки
const SHADOW_OFFSET     := Vector3(0.0, -0.15, 0.0)   # сдвиг: вниз
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


## Любая смена центра — включая первичный set_data и shift по стрелке/клику.
signal index_changed(idx: int)

## Клик по центральной карточке.
signal center_clicked


# ── Данные (своя копия — picker может иметь свою) ────────────────────────────
var _investigators: Array      = []
var _taken:         Dictionary = {}
var _index:         int        = 0


# ── 3D-сцена ─────────────────────────────────────────────────────────────────
var _card_meshes: Array              = []   # MeshInstance3D[]
var _card_views:  Array[CardView]    = []
var _prev_btn:    TextureButton
var _next_btn:    TextureButton
var _world_vp:    SubViewport
var _camera:      Camera3D
var _placeholder_tex: ImageTexture
var _card_shadow_tex: ImageTexture


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_placeholder_tex = _build_placeholder_texture()
	_card_shadow_tex = _build_card_shadow_texture()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical   = Control.SIZE_EXPAND_FILL
	# Минимум намеренно невысокий: карусель и так SIZE_EXPAND_FILL — заберёт
	# всё свободное место. Высокий минимум (был 760) при крупной InfoBar
	# выдавливал action-bar за нижний край окна.
	custom_minimum_size = Vector2(0, 480)

	_build_3d_scene()
	_build_arrows()

	# Клики по 3D-карточкам ловим на уровне self (spvc сам IGNORE'ит, поэтому
	# input доходит до родительского Control). Хит-тест — ray-cast из камеры.
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(_on_gui_input)


# ── Public API ───────────────────────────────────────────────────────────────

## Заполняет карусель данными и снапает на start_index. Эмитит index_changed.
func set_data(investigators: Array, taken: Dictionary, start_index: int = 0) -> void:
	_investigators = investigators
	_taken         = taken.duplicate()
	if _investigators.is_empty():
		return
	var n: int = _investigators.size()
	_index = ((start_index % n) + n) % n
	_refresh_slots()
	index_changed.emit(_index)


## Обновляет map занятости (без анимации).
func update_taken(taken: Dictionary) -> void:
	_taken = taken.duplicate()
	_refresh_taken_overlays()


func current_index() -> int:
	return _index


func selected_name() -> String:
	if _investigators.is_empty():
		return ""
	return String((_investigators[_index] as Dictionary).get("name", ""))


# ── Сборка 3D-сцены ──────────────────────────────────────────────────────────

func _build_3d_scene() -> void:
	# SubViewportContainer хостит 3D-сцену и stretch'ит её на размер self.
	var spvc := SubViewportContainer.new()
	spvc.name = "WorldVPContainer"
	spvc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	spvc.stretch = true
	spvc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(spvc)

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
	# off-screen дети self; внутри каждого — один CardView.
	for i: int in range(VISIBLE_SLOTS):
		var ui_vp := _make_card_ui_subviewport()
		ui_vp.name = "CardVP_%d" % i
		add_child(ui_vp)
		var mesh := _make_3d_card_mesh(ui_vp)
		mesh.name = "CardMesh_%d" % i
		mesh.set_meta("logical_slot", i)
		_world_vp.add_child(mesh)
		_card_meshes.append(mesh)
		_apply_3d_slot(mesh, i)


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


# ── Стрелки ──────────────────────────────────────────────────────────────────

func _build_arrows() -> void:
	_prev_btn = _make_arrow_btn(ARROW_TEX_LEFT)
	_prev_btn.name = "PrevArrow"
	_position_arrow(_prev_btn, ARROW_X_ANCHOR_FROM_EDGE)
	_prev_btn.pressed.connect(func() -> void: _animated_shift(-1))
	add_child(_prev_btn)

	_next_btn = _make_arrow_btn(ARROW_TEX_RIGHT)
	_next_btn.name = "NextArrow"
	_position_arrow(_next_btn, 1.0 - ARROW_X_ANCHOR_FROM_EDGE)
	_next_btn.pressed.connect(func() -> void: _animated_shift(1))
	add_child(_next_btn)


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


# ── Заполнение карточек ──────────────────────────────────────────────────────

func _populate_card(phys_idx: int, inv: Dictionary) -> void:
	var view: CardView = _card_views[phys_idx]
	view.set_data(inv)
	var inv_name: String = inv.get("name", "")
	view.set_taken(_taken.has(inv_name) and inv_name != selected_name())
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


func _refresh_taken_overlays() -> void:
	if _investigators.is_empty():
		return
	var n: int = _investigators.size()
	var current: String = selected_name()
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


# ── Клики по карточкам ───────────────────────────────────────────────────────

# gui_input на self. Левый клик → ray-cast в плоскость карточек, попавший
# слот определяет дельту перематывания (slot - CENTER_SLOT).
func _on_gui_input(event: InputEvent) -> void:
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
		center_clicked.emit()
	else:
		_animated_shift(delta)
	accept_event()


# Возвращает logical_slot карточки, по которой кликнули, либо -1.
# Делает ray-cast из камеры в мировые плоскости карточек и проверяет
# попадание в bounds квада (CARD_QUAD_SIZE в локальных координатах).
func _hit_test_card(local_click_pos: Vector2) -> int:
	if not is_instance_valid(_camera) or _card_meshes.is_empty():
		return -1
	# spvc стрейтчит _world_vp.size в свой on-screen size; пересчитываем клик
	# в координаты SubViewport'а, в которых живёт камера.
	if size.x <= 0.0 or size.y <= 0.0:
		return -1
	var vp_size: Vector2 = Vector2(_world_vp.size)
	var vp_pos := Vector2(
		local_click_pos.x * (vp_size.x / size.x),
		local_click_pos.y * (vp_size.y / size.y)
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


# ── Анимация shift'а ─────────────────────────────────────────────────────────

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

	index_changed.emit(_index)


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


# ── Текстуры (placeholder и тень) ────────────────────────────────────────────

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
