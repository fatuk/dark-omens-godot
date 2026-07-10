class_name ShopModal
extends CanvasLayer

## Магазин (Acquire Assets). Открывается из сайдбара в городе со своим сыщиком.
##
## Визуал: полноэкранный арт лавки (shop-bg.png @2×). Карточки товаров лежат на
## красном мате-книге (перспектива — в самом арте); при наведении карточка
## приподнимается и приближается к камере; при покупке — вылетает из витрины.
## Низ прилавка: монеты·доступно, лоток кубов Влияния, кнопки долг/бросок/купить.
##
## Поток покупки:
##   1. «Бросить кубы» — бросок Влияния (хост, единая проверка CheckFlow);
##      число успехов = монеты.
##   2. В любой момент «Взять долг» — вешает «Долг» и даёт +2 монеты.
##   3. Переброс провального куба — тап по кубику.
##   4. Выбор карточек кликом (сумма ≤ монет) → «Купить».
##
## Бросок/перебросы/монеты — хост-авторитетны в GameState.active_check; модалка
## лишь отражает синкнутое состояние (реактивно по state_changed). Раскладка
## привязана к вписанному прямоугольнику арта (_stage) — тянется под любой экран.

const _BG := preload("res://assets/shop/shop-bg.png")

# Заглушка арт-окна для карт без файла арта — тёплая притенённая (в тон лавки),
# чтобы пустые слоты не читались чёрными дырами. Когда арт есть — не применяется.
const _ART_PLACEHOLDER := Color(0.47, 0.39, 0.31)

const _TRAIT_KEY := {
	"weapon": "TRAIT_WEAPON",
	"magical": "TRAIT_MAGICAL",
	"relic": "TRAIT_RELIC",
	"tome": "TRAIT_TOME",
	"teamwork": "TRAIT_TEAMWORK",
	"item": "TRAIT_ITEM",
	"trinket": "TRAIT_TRINKET",
	"task": "TRAIT_TASK",
	"service": "TRAIT_SERVICE",
	"ally": "TRAIT_ALLY",
}

# Карты рендерятся в НАСТОЯЩЕЙ 3D-сцене (Camera3D + QuadMesh на наклонной плоскости-
# столе), 3D SubViewport кладётся поверх арта лавки. Перспектива — реальная камерой,
# свет — реальным OmniLight3D (тёплая лампа): подсвечивает, а не темнит. Всё тюнится
# живьём (секции «МАГАЗИН · 3D / СВЕТ / ТЕНЬ»).
const _CARD_ASPECT := 290.0 / 459.0  # ш/в карты
const _CARD_TEX_SIZE := Vector2i(512, 810)  # разрешение UI-рендера карты (аспект 290:459)
const _CARD_QUAD := Vector2(1.0, 459.0 / 290.0)  # размер 3D-квада (мир. ед.), h>w
const _WORLD_VP_SIZE := Vector2i(1264, 711)  # 3D-вьюпорт, аспект shop-bg (2528:1422)

# Камера над столом, смотрит вниз под углом.
static var CAM_DIST: float = 4.9  # Z камеры (отдаление)
static var CAM_HEIGHT: float = 2.0  # Y камеры (высота над центром ряда)
static var CAM_PITCH: float = -26.0  # наклон камеры вниз, град
static var CAM_FOV: float = 48.0

# Ряд карт: лежат на столе (наклон назад CARD_TILT), в ряд по X.
static var CARD_TILT: float = 59.0  # наклон карт назад, град (0 = стоят к камере)
static var ROW_GAP: float = 1.24  # расстояние между центрами карт (мир. ед.)
static var ROW_Y: float = -0.2  # сдвиг ряда по высоте
static var ROW_Z: float = 0.0  # сдвиг ряда по глубине

# Наведение: карта поднимается, приближается и поворачивается лицом к камере.
static var HOVER_UP: float = 0.30  # подъём по Y
static var HOVER_FWD: float = 0.30  # к камере (по Z)
static var HOVER_SCALE: float = 1.40

# Свет: окружающий (базовая яркость ≈ сырой арт) + тёплая лампа слева-сверху.
# Позиция/цвет лампы и тон окружающего — покомпонентно (тюнятся слайдерами).
static var AMBIENT: float = 1.0  # окружающий свет (1.0 = карта в своих цветах)
static var LAMP_ENERGY: float = 2.2  # яркость лампы
static var LAMP_X: float = -3.5  # позиция лампы (X)
static var LAMP_Y: float = 3.5  # позиция лампы (Y)
static var LAMP_Z: float = 3.0  # позиция лампы (Z)
static var LAMP_R: float = 1.0  # цвет лампы (R) — тёплый
static var LAMP_G: float = 0.82  # цвет лампы (G)
static var LAMP_B: float = 0.55  # цвет лампы (B)
static var AMBIENT_R: float = 1.0  # окружающий тон (R)
static var AMBIENT_G: float = 0.97  # окружающий тон (G)
static var AMBIENT_B: float = 0.92  # окружающий тон (B)

# Тень под картой — дочерний квад чуть больше, тёмный полупрозрачный, сдвинут.
static var SHADOW_ALPHA: float = 0.5
static var SHADOW_SCALE: float = 1.12  # размер тени относительно карты
static var SHADOW_X: float = 0.04  # сдвиг тени (X, локально)
static var SHADOW_Y: float = -0.05  # сдвиг тени (Y, вниз)
static var SHADOW_Z: float = -0.02  # сдвиг тени (Z, за картой)
static var _shadow_tex: ImageTexture  # мягкая радиальная тень (ленивая, общая)

# Состояние сессии магазина (UI-локальное; бросок/монеты — в active_check).
var _debt_taken: bool = false
var _selected: Dictionary = {}  # asset_id -> cost
var _last_dice: Array = []
var _last_nonce: int = 0
var _last_can: bool = false
var _last_add: bool = false

# Узлы.
var _stage: Control  # вписанный прямоугольник арта — база для долевой раскладки
var _world_vp: SubViewport  # 3D-сцена карт (камера + меши), кладётся на арт лавки
var _camera: Camera3D
var _lamp: OmniLight3D
var _dice_box: HBoxContainer
var _tray: DiceTray
var _coins_lbl: Label
var _roll_btn: Button
var _debt_btn: Button
var _buy_btn: Button
var _cards: Array = []  # [{id, cost, card, vp, mesh, mat, hit, slot, total, hovering, buying}]
var _chrome: Array = []  # [{node, fx, fy, fw, fh}] — элементы, позиционируемые по долям


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("shop_modal")  # TuningPanel пушит сюда relayout при правке static var
	_build()
	GameState.state_changed.connect(_refresh)
	get_viewport().size_changed.connect(_layout_stage)


# Вызывается TuningPanel (группа "shop_modal") после изменения тюн-параметров карт.
func relayout() -> void:
	_layout_stage()


func open() -> void:
	visible = true


func _close() -> void:
	GameState.shop_close()
	queue_free()


# ── Доступ к активной проверке магазина ───────────────────────────────────────


func _check() -> Dictionary:
	var c: Dictionary = GameState.active_check
	return c if String(c.get("owner", "")) == "shop" else {}


func _rolled() -> bool:
	return bool(_check().get("rolled", false))


func _coins() -> int:
	return int(_check().get("successes", 0)) + (2 if _debt_taken else 0)


func _can_reroll() -> bool:
	return GameState.can_reroll_now()


func _reroll_all_available() -> bool:
	if not _rolled():
		return false
	var c: Dictionary = _check()
	return int(c.get("reroll_all_allowance", 0)) - int(c.get("reroll_all_used", 0)) > 0


# ── Сборка ───────────────────────────────────────────────────────────────────


func _build() -> void:
	# Полупрозрачный фон — блокирует карту под магазином.
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0, 0, 0, 0.75)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	# Арт лавки — вписан по центру (KEEP_ASPECT), весь виден.
	var bg := TextureRect.new()
	bg.name = "ShopBg"
	bg.texture = _BG
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.add_child(bg)

	# Сцена — прямоугольник ровно по вписанному арту; всё позиционируем в его долях.
	_stage = Control.new()
	_stage.name = "Stage"
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.add_child(_stage)

	# 3D-сцена карт (камера + свет), кладётся поверх мата — до хрома и хит-контролов.
	_build_3d_scene()

	# ── Шапка ──
	var title := UIStyle.label("SHOP_TITLE", 34, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	title.name = "Title"
	_stage.add_child(title)
	_chrome.append({"node": title, "fx": 0.2, "fy": 0.035, "fw": 0.6, "fh": 0.06})

	var sub := UIStyle.label("SHOP_SUBTITLE", 15, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	sub.name = "Subtitle"
	_stage.add_child(sub)
	_chrome.append({"node": sub, "fx": 0.2, "fy": 0.10, "fw": 0.6, "fh": 0.04})

	# Крестик закрытия — поверх нарисованного X в арте.
	var close := Button.new()
	close.name = "Close"
	close.text = "✕"
	close.flat = true
	close.add_theme_font_size_override("font_size", 22)
	close.add_theme_color_override("font_color", UIColors.MUTED)
	close.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close.pressed.connect(_close)
	_stage.add_child(close)
	_chrome.append({"node": close, "fx": 0.945, "fy": 0.02, "fw": 0.045, "fh": 0.06})

	# ── Карточки на мате ──
	var offer: Array = _offer()
	for i in range(offer.size()):
		_build_asset_card(offer[i], i, offer.size())

	# ── Низ прилавка: монеты · доступно ──
	_coins_lbl = UIStyle.label("", 17, UIColors.WARNING, HORIZONTAL_ALIGNMENT_CENTER)
	_coins_lbl.name = "Coins"
	_stage.add_child(_coins_lbl)
	_chrome.append({"node": _coins_lbl, "fx": 0.25, "fy": 0.735, "fw": 0.5, "fh": 0.04})

	# Кубы Влияния — в ряду слотов на прилавке.
	_dice_box = HBoxContainer.new()
	_dice_box.name = "DiceBox"
	_dice_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_dice_box.add_theme_constant_override("separation", 10)
	_dice_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(_dice_box)
	_chrome.append({"node": _dice_box, "fx": 0.3, "fy": 0.785, "fw": 0.4, "fh": 0.09})

	# ── Кнопки: долг · бросок · купить ──
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 24)
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	_stage.add_child(btns)
	_chrome.append({"node": btns, "fx": 0.08, "fy": 0.905, "fw": 0.84, "fh": 0.06})

	_debt_btn = UIStyle.button("SHOP_TAKE_DEBT", UIColors.WARNING)
	_debt_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_debt_btn.pressed.connect(_on_take_debt)
	_debt_btn.visible = not _has_debt()
	btns.add_child(_debt_btn)

	_roll_btn = UIStyle.button("SHOP_ROLL", UIColors.ACCENT)
	_roll_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roll_btn.pressed.connect(_on_roll)
	btns.add_child(_roll_btn)

	_buy_btn = UIStyle.button("SHOP_BUY", UIColors.ACCENT)
	_buy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_buy_btn.pressed.connect(_on_buy)
	btns.add_child(_buy_btn)

	visible = false
	_layout_stage()
	_refresh()


# Список ассетов витрины: из GameState.shop_reserve, иначе — статичный фолбэк.
func _offer() -> Array:
	var out: Array = []
	for aid in GameState.shop_reserve:
		var a: Dictionary = AssetCatalog.by_id(String(aid))
		if not a.is_empty():
			out.append(a)
	if out.is_empty():
		out = AssetCatalog.shop_offer(4)
	return out


# ── 3D-сцена: камера, свет, окружение ─────────────────────────────────────────


func _build_3d_scene() -> void:
	# SubViewportContainer стрейтчит 3D-сцену на размер _stage (вписанный арт).
	var spvc := SubViewportContainer.new()
	spvc.name = "WorldVPContainer"
	spvc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	spvc.stretch = true
	spvc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(spvc)

	_world_vp = SubViewport.new()
	_world_vp.name = "WorldVP"
	_world_vp.size = _WORLD_VP_SIZE
	_world_vp.transparent_bg = true
	_world_vp.msaa_3d = Viewport.MSAA_4X  # сглаживание краёв квадов
	_world_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	spvc.add_child(_world_vp)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.environment = _make_environment()
	_world_vp.add_child(_camera)

	# Тёплая лампа слева-сверху — реальный свет: подсвечивает карты, не темнит.
	_lamp = OmniLight3D.new()
	_lamp.name = "Lamp"
	_lamp.omni_range = 30.0
	_world_vp.add_child(_lamp)

	_apply_camera_light()


# Окружение только ради ambient-света (без неба/фона — vp прозрачный).
func _make_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(AMBIENT_R, AMBIENT_G, AMBIENT_B)
	env.ambient_light_energy = AMBIENT
	return env


# Камера/свет из тюн-параметров (вызывается в раскладке для живого тюна).
func _apply_camera_light() -> void:
	if not is_instance_valid(_camera):
		return
	_camera.position = Vector3(0.0, CAM_HEIGHT, CAM_DIST)
	_camera.rotation = Vector3(deg_to_rad(CAM_PITCH), 0.0, 0.0)
	_camera.fov = CAM_FOV
	if _camera.environment:
		_camera.environment.ambient_light_color = Color(AMBIENT_R, AMBIENT_G, AMBIENT_B)
		_camera.environment.ambient_light_energy = AMBIENT
	if is_instance_valid(_lamp):
		_lamp.position = Vector3(LAMP_X, LAMP_Y, LAMP_Z)
		_lamp.light_color = Color(LAMP_R, LAMP_G, LAMP_B)
		_lamp.light_energy = LAMP_ENERGY


# ── Карта: UI-SubViewport → 3D-quad ───────────────────────────────────────────


func _build_asset_card(a: Dictionary, idx: int, total: int) -> void:
	var aid: String = String(a.get("id", ""))
	var cost: int = int(a.get("cost", 0))
	var traits: Array = a.get("traits", [])
	var trait_id: String = String(traits[-1]) if not traits.is_empty() else "item"

	# UI карты рендерится в SubViewport (off-screen), его текстура = albedo 3D-квада.
	var vp := SubViewport.new()
	vp.name = "CardVP_%d" % idx
	vp.size = _CARD_TEX_SIZE
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.disable_3d = true
	var card := GameCard.new()
	card.name = "Card"
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.set_font_scale(float(_CARD_TEX_SIZE.x) / HandCarousel.CARD_W)
	(
		card
		. set_card(
			{
				"cost": cost,
				"title": a.get("nameKey", ""),
				"subtitle": _TRAIT_KEY.get(trait_id, trait_id.to_upper()),
				"desc": a.get("abilityKey", ""),
				"art": AssetCatalog.card_art(aid),
				"art_color": _ART_PLACEHOLDER,
			}
		)
	)
	vp.add_child(card)
	add_child(vp)  # off-screen SubViewport (текстуру берёт материал квада)

	# 3D-меш карты: QuadMesh, SHADED-материал (реагирует на свет), albedo = текстура.
	var quad := QuadMesh.new()
	quad.size = _CARD_QUAD
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = vp.get_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var mesh := MeshInstance3D.new()
	mesh.name = "CardMesh_%d" % idx
	mesh.mesh = quad
	mesh.material_override = mat
	mesh.add_child(_make_shadow_mesh())
	_world_vp.add_child(mesh)

	# Хит-контрол (2D) — позиция/размер считаются проекцией 3D-квада в _process.
	var hit := Control.new()
	hit.name = "Hit_%d" % idx
	hit.mouse_filter = Control.MOUSE_FILTER_STOP
	hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_stage.add_child(hit)

	var entry := {
		"id": aid,
		"cost": cost,
		"card": card,
		"vp": vp,
		"mesh": mesh,
		"mat": mat,
		"hit": hit,
		"slot": idx,
		"total": total,
		"buying": false,
		"hovering": false,
	}
	_cards.append(entry)

	hit.mouse_entered.connect(func() -> void: _hover_card(entry, true))
	hit.mouse_exited.connect(func() -> void: _hover_card(entry, false))
	hit.gui_input.connect(
		func(ev: InputEvent) -> void:
			if (
				ev is InputEventMouseButton
				and (ev as InputEventMouseButton).pressed
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
			):
				_toggle_card(aid, cost)
	)


# Дочерний quad-тень: чуть больше карты, тёмный полупрозрачный, сдвинут за/вниз.
# Как ребёнок меша наследует его трансформ при наведении/вылете.
func _make_shadow_mesh() -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = _CARD_QUAD * SHADOW_SCALE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _shadow_texture()
	mat.albedo_color = Color(0, 0, 0, SHADOW_ALPHA)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var sh := MeshInstance3D.new()
	sh.name = "CardShadow"
	sh.mesh = quad
	sh.material_override = mat
	sh.position = Vector3(SHADOW_X, SHADOW_Y, SHADOW_Z)
	return sh


func _shadow_node(mesh: MeshInstance3D) -> MeshInstance3D:
	return mesh.get_node_or_null("CardShadow") as MeshInstance3D


func _shadow_mat(mesh: MeshInstance3D) -> StandardMaterial3D:
	var sh := _shadow_node(mesh)
	return (sh.material_override as StandardMaterial3D) if sh else null


# Мягкая радиальная тень: чёрный с альфа-спадом от центра. Ленивая, общая.
func _shadow_texture() -> ImageTexture:
	if _shadow_tex == null:
		var n := 128
		var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
		var c := (n - 1) * 0.5
		for y in range(n):
			for x in range(n):
				var d: float = Vector2(x - c, y - c).length() / c
				var a: float = clampf(1.0 - d, 0.0, 1.0)
				img.set_pixel(x, y, Color(0.0, 0.0, 0.0, a * a))
		_shadow_tex = ImageTexture.create_from_image(img)
	return _shadow_tex


func _has_debt() -> bool:
	return (GameState.my_player().get("conditions", []) as Array).has("debt")


# ── Раскладка по вписанному арту ──────────────────────────────────────────────


# Вписанный по центру прямоугольник арта (KEEP_ASPECT) внутри вьюпорта.
func _fitted_rect() -> Rect2:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var ta: float = _BG.get_size().x / _BG.get_size().y
	var va: float = vp.x / vp.y
	var w: float
	var h: float
	if va > ta:  # экран шире арта → вписываем по высоте
		h = vp.y
		w = h * ta
	else:
		w = vp.x
		h = w / ta
	return Rect2((vp - Vector2(w, h)) * 0.5, Vector2(w, h))


func _layout_stage() -> void:
	if not is_instance_valid(_stage):
		return
	var r: Rect2 = _fitted_rect()
	_stage.position = r.position
	_stage.size = r.size
	var s: Vector2 = r.size
	# Хром — по долям.
	for e_v: Variant in _chrome:
		var e: Dictionary = e_v
		var node: Control = e.node
		node.position = Vector2(e.fx * s.x, e.fy * s.y)
		node.custom_minimum_size = Vector2(e.fw * s.x, e.fh * s.y)
		node.size = node.custom_minimum_size
	# 3D-раскладка ряда карт: по X с шагом ROW_GAP, наклон назад CARD_TILT. Камера/свет
	# — из тюн-параметров. Хит-контролы двигаются за проекцией мешей в _process.
	_apply_camera_light()
	var total: int = _cards.size()
	var row_w: float = float(maxi(total - 1, 0)) * ROW_GAP
	for i in range(total):
		var e: Dictionary = _cards[i]
		var pos := Vector3(float(i) * ROW_GAP - row_w * 0.5, ROW_Y, ROW_Z)
		e["rest_pos"] = pos
		var mesh: MeshInstance3D = e.mesh
		if not bool(e.get("buying", false)) and not bool(e.get("hovering", false)):
			mesh.position = pos
			mesh.rotation = Vector3(deg_to_rad(-CARD_TILT), 0.0, 0.0)
			mesh.scale = Vector3.ONE
		var sh := _shadow_node(mesh)
		if sh:
			(sh.mesh as QuadMesh).size = _CARD_QUAD * SHADOW_SCALE
			sh.position = Vector3(SHADOW_X, SHADOW_Y, SHADOW_Z)
			var smat := sh.material_override as StandardMaterial3D
			if smat:
				smat.albedo_color = Color(0.0, 0.0, 0.0, SHADOW_ALPHA)
		_update_hit_rect(e)


# Хит-контрол под проекцией 3D-квада карты (экранный bbox 4 углов → _stage-координаты).
func _update_hit_rect(e: Dictionary) -> void:
	if not is_instance_valid(_camera) or not is_instance_valid(_stage):
		return
	var mesh: MeshInstance3D = e.mesh
	var hw: float = _CARD_QUAD.x * 0.5
	var hh: float = _CARD_QUAD.y * 0.5
	var xf: Transform3D = mesh.global_transform
	var pts := [
		xf * Vector3(-hw, hh, 0.0),
		xf * Vector3(hw, hh, 0.0),
		xf * Vector3(hw, -hh, 0.0),
		xf * Vector3(-hw, -hh, 0.0),
	]
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p_v: Variant in pts:
		var sp: Vector2 = _camera.unproject_position(p_v)
		mn = Vector2(minf(mn.x, sp.x), minf(mn.y, sp.y))
		mx = Vector2(maxf(mx.x, sp.x), maxf(mx.y, sp.y))
	var sc: Vector2 = _stage.size / Vector2(_WORLD_VP_SIZE)
	var hit: Control = e.hit
	hit.position = mn * sc
	hit.size = (mx - mn) * sc


# Хит-контролы следуют за анимируемыми (наведение/вылет) картами покадрово.
func _process(_delta: float) -> void:
	for e_v: Variant in _cards:
		_update_hit_rect(e_v)


# ── Наведение: подъём, приближение и поворот к камере ─────────────────────────


func _hover_card(entry: Dictionary, on: bool) -> void:
	if bool(entry.get("buying", false)):
		return
	entry["hovering"] = on
	var mesh: MeshInstance3D = entry.mesh
	var rest_pos: Vector3 = entry.get("rest_pos", mesh.position)
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(
		Tween.EASE_OUT
	)
	if on:
		tw.tween_property(mesh, "position", rest_pos + Vector3(0.0, HOVER_UP, HOVER_FWD), 0.18)
		tw.tween_property(mesh, "rotation", _face_rotation(), 0.18)
		tw.tween_property(mesh, "scale", Vector3.ONE * HOVER_SCALE, 0.18)
	else:
		tw.tween_property(mesh, "position", rest_pos, 0.18)
		tw.tween_property(mesh, "rotation", Vector3(deg_to_rad(-CARD_TILT), 0.0, 0.0), 0.18)
		tw.tween_property(mesh, "scale", Vector3.ONE, 0.18)


# Поворот «лицом к камере» — перпендикулярно взгляду (компенсируем pitch камеры).
func _face_rotation() -> Vector3:
	return Vector3(deg_to_rad(CAM_PITCH), 0.0, 0.0)


# ── Кубы (переиспользуемый лоток, рендер из active_check) ──────────────────────


func _ensure_tray() -> void:
	if is_instance_valid(_tray):
		return
	_tray = DiceTray.new()
	_tray.name = "DiceTray"
	_tray.die_selected.connect(_on_die_clicked)
	_dice_box.add_child(_tray)


func _render_dice() -> void:
	if not is_instance_valid(_dice_box):
		return
	_ensure_tray()
	if not _rolled():
		if not _last_dice.is_empty():
			_last_dice = []
		_tray.show_pending(_influence_pool())
		return
	var dice: Array = _check().get("dice", [])
	var can: bool = _can_reroll()
	var add: bool = GameState.can_add_die_now()
	var nonce: int = int(_check().get("reroll_nonce", 0))
	if dice != _last_dice:
		var prev: Array = _last_dice
		var diff: int = _single_diff(prev, dice)
		_last_dice = dice.duplicate()
		if prev.is_empty():
			_tray.play_roll(dice, can, add)
		elif diff >= 0:
			_tray.reroll_die(diff, int(dice[diff]), can, add)
		elif prev.size() == dice.size():
			_tray.play_roll(dice, can, add)
		else:
			_tray.show_roll(dice, can, add)
		_last_can = can
		_last_add = add
		_last_nonce = nonce
	elif nonce != _last_nonce:
		var ri: int = int(_check().get("reroll_index", -1))
		if ri >= 0 and ri < dice.size():
			_tray.reroll_die(ri, int(dice[ri]), can, add)
		_last_can = can
		_last_add = add
		_last_nonce = nonce
	elif can != _last_can or add != _last_add:
		_tray.show_roll(dice, can, add)
		_last_can = can
		_last_add = add


func _single_diff(a: Array, b: Array) -> int:
	if a.size() != b.size():
		return -1
	var idx: int = -1
	for i in range(a.size()):
		if int(a[i]) != int(b[i]):
			if idx >= 0:
				return -1
			idx = i
	return idx


func _influence_pool() -> int:
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get("influence", 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get("influence", 0))
	var bonus: int = Dice.pre_roll_bonus(_check().get("active_mods", []), "influence")
	return maxi(1, base + mods + bonus)


# ── Действия ───────────────────────────────────────────────────────────────────


func _on_roll() -> void:
	if _rolled():
		if _reroll_all_available():
			GameState.reroll_all_dice()
		return
	_roll_btn.disabled = true
	GameState.shop_begin()


func _on_take_debt() -> void:
	if _debt_taken or _has_debt():
		return
	_debt_taken = true
	_debt_btn.disabled = true
	GameState.shop_take_debt()
	_refresh()


func _on_die_clicked(index: int) -> void:
	if not _can_reroll():
		return
	GameState.reroll_die(index)


func _toggle_card(aid: String, cost: int) -> void:
	if _selected.has(aid):
		_selected.erase(aid)
	elif cost <= _coins() - _spent():
		_selected[aid] = cost
	_refresh()


func _on_buy() -> void:
	if _selected.is_empty():
		return
	# Купленные карточки вылетают из витрины, затем грант и закрытие.
	for e_v: Variant in _cards:
		var e: Dictionary = e_v
		if _selected.has(e.id):
			_fly_out(e)
	GameState.shop_grant(_selected.keys())
	await get_tree().create_timer(0.32).timeout
	_close()


# Карта уходит из витрины: рывок к камере вверх + растворение.
func _fly_out(entry: Dictionary) -> void:
	entry["buying"] = true
	var mesh: MeshInstance3D = entry.mesh
	var mat: StandardMaterial3D = entry.mat
	var rest_pos: Vector3 = entry.get("rest_pos", mesh.position)
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_property(mesh, "position", rest_pos + Vector3(0.0, 1.6, 2.8), 0.30)
	tw.tween_property(mesh, "rotation", _face_rotation(), 0.30)
	tw.tween_property(mesh, "scale", Vector3.ONE * 1.4, 0.30)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.30)
	var smat := _shadow_mat(mesh)
	if smat:
		tw.tween_property(smat, "albedo_color:a", 0.0, 0.22)  # тень гаснет с картой


# ── Обновление UI ───────────────────────────────────────────────────────────────


func _spent() -> int:
	var s: int = 0
	for c in _selected.values():
		s += int(c)
	return s


func _refresh() -> void:
	_render_dice()
	var coins: int = _coins()
	var remaining: int = coins - _spent()
	if is_instance_valid(_coins_lbl):
		_coins_lbl.text = (
			"%s: %d   ·   %s: %d" % [tr("SHOP_COINS"), coins, tr("SHOP_REMAINING"), remaining]
		)
	if is_instance_valid(_roll_btn):
		if _rolled() and _reroll_all_available():
			_roll_btn.text = "ENCOUNTER_REROLL_ALL"
			_roll_btn.disabled = false
		else:
			_roll_btn.text = "SHOP_ROLL"
			_roll_btn.disabled = _rolled()
	if is_instance_valid(_debt_btn):
		_debt_btn.visible = not _has_debt()
	if is_instance_valid(_buy_btn):
		_buy_btn.disabled = _selected.is_empty()
	# Недоступные НЕ затемняем (доступность покажем иначе позже). Лишь лёгкая
	# тёплая подсветка выбранной карты (тинт albedo материала).
	for e_v: Variant in _cards:
		var e: Dictionary = e_v
		if bool(e.get("buying", false)):
			continue
		var mat: StandardMaterial3D = e.mat
		mat.albedo_color = Color(1.2, 1.14, 0.9) if _selected.has(e.id) else Color.WHITE
