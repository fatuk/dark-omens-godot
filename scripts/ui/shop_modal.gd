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
const _FLAME_SHADER := preload("res://assets/shaders/flame_glow.gdshader")

# Живые огни поверх нарисованных (лампа слева, свеча справа): доля центра/размера
# в _stage + параметры мерцания. Тёплый additive-глоу, пляшет через flame_glow.
const _FLAMES := [
	{
		"cx": 0.074,
		"cy": 0.178,
		"w": 0.058,
		"h": 0.135,
		"intensity": 0.85,
		"speed": 6.5,
		"seed": 0.0,
		"color": Color(1.0, 0.68, 0.34),
	},
	{
		"cx": 0.959,
		"cy": 0.303,
		"w": 0.034,
		"h": 0.075,
		"intensity": 0.7,
		"speed": 9.0,
		"seed": 17.0,
		"color": Color(1.0, 0.72, 0.4),
	},
]

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
const _WORLD_VP_SIZE := Vector2i(1264, 711)  # стартовый размер 3D-вьюпорта (в раскладке
# переустанавливается ровно в размер сцены — аспект рендера = аспект показа)

# Камера над столом, смотрит вниз под углом.
static var CAM_X: float = -0.1  # X камеры (сдвиг влево-вправо)
static var CAM_DIST: float = 4.9  # Z камеры (отдаление)
static var CAM_HEIGHT: float = 2.0  # Y камеры (высота над центром ряда)
static var CAM_PITCH: float = -26.0  # наклон камеры вниз, град
static var CAM_FOV: float = 48.0

# Ряд карт: лежат на столе (наклон назад CARD_TILT), в ряд по X.
static var CARD_TILT: float = 59.0  # наклон карт назад, град (0 = стоят к камере)
static var ROW_GAP: float = 1.24  # расстояние между центрами карт (мир. ед.)
static var ROW_Y: float = -0.2  # сдвиг ряда по высоте
static var ROW_Z: float = 0.0  # сдвиг ряда по глубине

# Наведение: карта поднимается, приближается и поворачивается лицом к камере
# (освещение то же, что у лежащих — SHADED тёплыми лампами; материал не меняем).
static var HOVER_UP: float = 0.30  # подъём по Y
static var HOVER_FWD: float = 0.30  # к камере (по Z)
static var HOVER_SCALE: float = 1.40

# Свет: окружающий (базовая яркость ≈ сырой арт) + две тёплые лампы (слева = фонарь,
# справа = свеча). RANGE/ATTEN каждой лампы задают градиент распространения света
# по ряду карт (range — дальнобойность, atten — крутизна спада). Тюнятся слайдерами.
static var AMBIENT: float = 0.1  # окружающий свет (1.0 = карта в своих цветах)
# Левая лампа (фонарь).
static var LAMP_ENERGY: float = 14.8  # яркость
static var LAMP_X: float = -6.4  # позиция (X)
static var LAMP_Y: float = 3.9  # позиция (Y)
static var LAMP_Z: float = 5.5  # позиция (Z)
static var LAMP_R: float = 1.0  # цвет (R) — тёплый
static var LAMP_G: float = 0.82  # цвет (G)
static var LAMP_B: float = 0.55  # цвет (B)
static var LAMP_RANGE: float = 11.0  # дальнобойность (радиус света)
static var LAMP_ATTEN: float = 1.0  # крутизна спада (градиент): >1 — резче гаснет
# Правая лампа (свеча).
static var LAMP2_ENERGY: float = 5.2  # яркость
static var LAMP2_X: float = 6.4  # позиция (X)
static var LAMP2_Y: float = 3.9  # позиция (Y)
static var LAMP2_Z: float = 5.5  # позиция (Z)
static var LAMP2_R: float = 1.0  # цвет (R) — тёплый
static var LAMP2_G: float = 0.74  # цвет (G)
static var LAMP2_B: float = 0.42  # цвет (B)
static var LAMP2_RANGE: float = 16.5  # дальнобойность
static var LAMP2_ATTEN: float = 1.0  # крутизна спада
static var AMBIENT_R: float = 0.99  # окружающий тон (R)
static var AMBIENT_G: float = 0.97  # окружающий тон (G)
static var AMBIENT_B: float = 0.92  # окружающий тон (B)

# Тень под картой — отдельный квад-«drop shadow»: параллелен карте, сдвинут вниз-
# вправо, выглядывает из-под нижнего края. Не дочерний: при наведении карта
# поднимается, тень остаётся на месте. Сдвиг маленький → не «нимб» по всем краям.
static var SHADOW_ALPHA: float = 0.56
static var SHADOW_SCALE: float = 1.14  # общий размер тени относительно карты
static var SHADOW_WIDTH: float = 1.27  # доп. множитель ширины тени
static var SHADOW_X: float = 0.0  # сдвиг вправо (X)
static var SHADOW_Y: float = -0.17  # сдвиг вниз (Y)
static var SHADOW_Z: float = -0.15  # чуть за карту (Z)
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
var _lamp: OmniLight3D  # левая лампа (фонарь)
var _lamp2: OmniLight3D  # правая лампа (свеча)
var _dice_box: HBoxContainer
var _tray: DiceTray
var _coins_lbl: Label
var _roll_btn: Button
var _debt_btn: Button
var _res_btn: Button  # «потратить ресурс» — +1 монета
var _buy_btn: Button
var _cards: Array = []  # [{id, cost, card, vp, mesh, mat, hit, slot, total, hovering, buying}]
var _chrome: Array = []  # [{node, fx, fy, fw, fh}] — элементы, позиционируемые по долям

# Ряд кубов не в _chrome: его ширина зависит от числа кубов, поэтому центрируем
# по фактическому контенту (см. _center_dice_row). Вертикаль — по долям сцены.
const DICE_FY: float = 0.735
const DICE_FH: float = 0.09
var _flame_nodes: Array = []  # [{node, cx, cy, w, h}] — огни-глоу, позиция по центру-долям
var _hover_sfx: AudioStream = null  # звук шуршания при наведении (ленивый)
var _hover_sfx_tried: bool = false


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
	return (
		int(_check().get("successes", 0))
		+ (2 if _debt_taken else 0)
		+ int(_check().get("shop_resource_coins", 0))
	)  # потраченные ресурсы = монеты


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

	# Живые огни (лампа/свеча) — под 3D-картами, поверх статичного арта.
	_build_flames()

	# 3D-сцена карт (камера + свет), кладётся поверх мата — до хрома и хит-контролов.
	_build_3d_scene()

	# ── Шапка ── орнаментальный заголовок (шеврон · МАГАЗИН · шеврон) + подпись.
	var title := UIStyle.ornate_title("SHOP_TITLE", 34, UIColors.ACCENT)
	title.name = "Title"
	_stage.add_child(title)
	_chrome.append({"node": title, "fx": 0.2, "fy": 0.045, "fw": 0.6, "fh": 0.06})

	var sub := UIStyle.label("SHOP_SUBTITLE", 15, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	sub.name = "Subtitle"
	_stage.add_child(sub)
	_chrome.append({"node": sub, "fx": 0.2, "fy": 0.100, "fw": 0.6, "fh": 0.04})

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

	# ── Низ прилавка: монеты ──
	_coins_lbl = UIStyle.label("", 17, UIColors.WARNING, HORIZONTAL_ALIGNMENT_CENTER)
	_coins_lbl.name = "Coins"
	_stage.add_child(_coins_lbl)
	_chrome.append({"node": _coins_lbl, "fx": 0.25, "fy": 0.715, "fw": 0.5, "fh": 0.04})

	# Кубы Влияния — в ряду слотов на прилавке.
	_dice_box = HBoxContainer.new()
	_dice_box.name = "DiceBox"
	_dice_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_dice_box.add_theme_constant_override("separation", 10)
	_dice_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(_dice_box)
	# В _chrome НЕ кладём: ширина ряда зависит от числа кубов — центрируем отдельно
	# по контенту (_center_dice_row), иначе при переполнении бокса ряд уезжает вбок.

	# ── Кнопки: долг · бросок · купить ──
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 24)
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	_stage.add_child(btns)
	_chrome.append({"node": btns, "fx": 0.206, "fy": 0.905, "fw": 0.588, "fh": 0.06})

	# vertical SHRINK_CENTER: кнопки держат натуральную высоту текстуры и не тянутся
	# по высоте контейнера — иначе орнаментальная рамка растягивается и её нижний
	# бордюр «отрывается» тонкой линией под кнопкой.
	_debt_btn = UIStyle.button("SHOP_TAKE_DEBT", UIColors.WARNING)
	_debt_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_debt_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_debt_btn.pressed.connect(_on_take_debt)
	_debt_btn.visible = not _has_debt()
	btns.add_child(_debt_btn)

	_res_btn = UIStyle.button("SHOP_SPEND_RESOURCE", UIColors.WARNING)
	_res_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_res_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_res_btn.pressed.connect(_on_spend_resource)
	_res_btn.visible = int(GameState.my_player().get("resources", 0)) > 0
	btns.add_child(_res_btn)

	_roll_btn = UIStyle.button("SHOP_ROLL", UIColors.ACCENT)
	_roll_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roll_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_roll_btn.pressed.connect(_on_roll)
	btns.add_child(_roll_btn)

	_buy_btn = UIStyle.button("SHOP_BUY", UIColors.ACCENT)
	_buy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_buy_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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


# ── Живые огни (лампа/свеча) ──────────────────────────────────────────────────


# Мерцающий тёплый глоу поверх нарисованных огоньков. Каждый — ColorRect с
# additive-шейдером flame_glow; позиция/размер по долям _stage (в раскладке).
func _build_flames() -> void:
	for f_v: Variant in _FLAMES:
		var f: Dictionary = f_v
		var mat := ShaderMaterial.new()
		mat.shader = _FLAME_SHADER
		mat.set_shader_parameter("glow_color", f.color)
		mat.set_shader_parameter("intensity", f.intensity)
		mat.set_shader_parameter("flicker_speed", f.speed)
		mat.set_shader_parameter("seed", f.seed)
		var rect := ColorRect.new()
		rect.name = "Flame"
		rect.color = Color.WHITE  # шейдер сам считает цвет
		rect.material = mat
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_stage.add_child(rect)
		_flame_nodes.append({"node": rect, "cx": f.cx, "cy": f.cy, "w": f.w, "h": f.h})


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

	# Две тёплые лампы — реальный свет: подсвечивают карты, не темнят.
	_lamp = OmniLight3D.new()
	_lamp.name = "LampLeft"
	_world_vp.add_child(_lamp)
	_lamp2 = OmniLight3D.new()
	_lamp2.name = "LampRight"
	_world_vp.add_child(_lamp2)

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
	_camera.position = Vector3(CAM_X, CAM_HEIGHT, CAM_DIST)
	_camera.rotation = Vector3(deg_to_rad(CAM_PITCH), 0.0, 0.0)
	_camera.fov = CAM_FOV
	if _camera.environment:
		_camera.environment.ambient_light_color = Color(AMBIENT_R, AMBIENT_G, AMBIENT_B)
		_camera.environment.ambient_light_energy = AMBIENT
	if is_instance_valid(_lamp):
		_lamp.position = Vector3(LAMP_X, LAMP_Y, LAMP_Z)
		_lamp.light_color = Color(LAMP_R, LAMP_G, LAMP_B)
		_lamp.light_energy = LAMP_ENERGY
		_lamp.omni_range = LAMP_RANGE
		_lamp.omni_attenuation = LAMP_ATTEN
	if is_instance_valid(_lamp2):
		_lamp2.position = Vector3(LAMP2_X, LAMP2_Y, LAMP2_Z)
		_lamp2.light_color = Color(LAMP2_R, LAMP2_G, LAMP2_B)
		_lamp2.light_energy = LAMP2_ENERGY
		_lamp2.omni_range = LAMP2_RANGE
		_lamp2.omni_attenuation = LAMP2_ATTEN


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
	_world_vp.add_child(mesh)

	# Тень — отдельный меш на столе (не ребёнок карты), кладётся под карту в раскладке.
	var shadow := _make_shadow_mesh(idx)
	_world_vp.add_child(shadow)

	# Хит-контрол (2D) — позиция/размер считаются проекцией покоящейся карты в раскладке.
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
		"shadow": shadow,
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


# Квад-тень: лежит плашмя на столе, тёмный полупрозрачный. Позиция/наклон —
# в раскладке (_layout_stage) относительно основания карты.
# Размер квада тени: общий множитель SHADOW_SCALE, ширина — доп. SHADOW_WIDTH.
func _shadow_size() -> Vector2:
	return Vector2(_CARD_QUAD.x * SHADOW_SCALE * SHADOW_WIDTH, _CARD_QUAD.y * SHADOW_SCALE)


func _make_shadow_mesh(idx: int) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = _shadow_size()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _shadow_texture()
	mat.albedo_color = Color(0, 0, 0, SHADOW_ALPHA)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var sh := MeshInstance3D.new()
	sh.name = "CardShadow_%d" % idx
	sh.mesh = quad
	sh.material_override = mat
	return sh


func _shadow_mat(entry: Dictionary) -> StandardMaterial3D:
	var sh: MeshInstance3D = entry.get("shadow")
	return (sh.material_override as StandardMaterial3D) if sh else null


# Тень в форме карты: мягкий скруглённый прямоугольник аспекта карты (чёрный
# с растушёванным краем), чтобы силуэт тени повторял карту, а не был пятном.
# Ленивая, общая. Текстура в аспекте _CARD_QUAD → на квад ложится без искажения.
func _shadow_texture() -> ImageTexture:
	if _shadow_tex == null:
		var w := 192
		var h := int(round(192.0 * _CARD_QUAD.y / _CARD_QUAD.x))
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		var feather: float = float(w) * 0.16  # мягкость края
		var radius: float = float(w) * 0.14  # скругление углов
		var hx: float = w * 0.5
		var hy: float = h * 0.5
		var bx: float = hx - feather - radius  # внутр. полупрямоугольник
		var by: float = hy - feather - radius
		for y in range(h):
			for x in range(w):
				var qx: float = absf(x + 0.5 - hx) - bx
				var qy: float = absf(y + 0.5 - hy) - by
				# SDF скруглённого прямоугольника: <=0 внутри, растёт наружу
				var d: float = Vector2(maxf(qx, 0.0), maxf(qy, 0.0)).length() - radius
				var a: float = clampf(1.0 - d / feather, 0.0, 1.0)
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
	_center_dice_row()  # ряд кубов — по центру сцены, по фактической ширине контента
	# Огни — по центру-долям (glow-квадрат центрируется на нарисованном огоньке).
	for e_v: Variant in _flame_nodes:
		var e: Dictionary = e_v
		var node: Control = e.node
		var sz := Vector2(e.w * s.x, e.h * s.y)
		node.size = sz
		node.position = Vector2(e.cx * s.x, e.cy * s.y) - sz * 0.5
	# 3D-раскладка ряда карт: по X с шагом ROW_GAP, наклон назад CARD_TILT. Камера/свет
	# — из тюн-параметров. Хит-контролы — проекция покоящихся мешей (см. _update_hit_rect).
	# 3D-вьюпорт держим ровно в размер сцены: аспект рендера = аспект показа (иначе
	# SubViewportContainer растягивает картинку и проекция для хитбоксов «плывёт»).
	if is_instance_valid(_world_vp):
		_world_vp.size = Vector2i(maxi(1, int(round(s.x))), maxi(1, int(round(s.y))))
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
		# Тень: drop-shadow — параллельна карте (тот же наклон), сдвинута вниз-вправо,
		# так выглядывает из-под нижнего края (плоская тень при пологой камере не видна).
		# Всегда в покое: при наведении карта поднимается над тенью. Покупаемую не трогаем.
		var sh: MeshInstance3D = e.get("shadow")
		if sh and not bool(e.get("buying", false)):
			(sh.mesh as QuadMesh).size = _shadow_size()
			sh.position = pos + Vector3(SHADOW_X, SHADOW_Y, SHADOW_Z)
			sh.rotation = Vector3(deg_to_rad(-CARD_TILT), 0.0, 0.0)
			var smat := sh.material_override as StandardMaterial3D
			if smat:
				smat.albedo_color = Color(0.0, 0.0, 0.0, SHADOW_ALPHA)
		_update_hit_rect(e)


# Хит-контрол = проекция ПОКОЯЩЕЙСЯ карты (её слота на столе), а НЕ анимируемого
# меша. Иначе поднятая карта (масштаб/сдвиг к камере) растит хитбокс и он налезает
# на соседей — курсор отрывается от карты. Слот фиксирован → наведение однозначно.
func _update_hit_rect(e: Dictionary) -> void:
	if not is_instance_valid(_camera) or not is_instance_valid(_stage):
		return
	var mesh: MeshInstance3D = e.mesh
	var rest_pos: Vector3 = e.get("rest_pos", mesh.position)
	var xf := Transform3D(Basis.from_euler(Vector3(deg_to_rad(-CARD_TILT), 0.0, 0.0)), rest_pos)
	var hw: float = _CARD_QUAD.x * 0.5
	var hh: float = _CARD_QUAD.y * 0.5
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
	var sc: Vector2 = _stage.size / Vector2(_world_vp.size)
	var hit: Control = e.hit
	hit.position = mn * sc
	hit.size = (mx - mn) * sc


# ── Наведение: подъём, приближение и поворот к камере ─────────────────────────


func _hover_card(entry: Dictionary, on: bool) -> void:
	if bool(entry.get("buying", false)):
		return
	entry["hovering"] = on
	if on:
		_play_hover_sfx()  # шуршание карты — как в веере
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


# Звук шуршания карты при наведении — тот же файл/вариации, что у веера
# (HandCarousel), чтобы совпадал по звучанию и тюнился в одном месте. Ленивая
# загрузка: пока файла нет — молчит.
func _play_hover_sfx() -> void:
	if not _hover_sfx_tried:
		_hover_sfx_tried = true
		if ResourceLoader.exists(HandCarousel.SCROLL_SFX_PATH):
			_hover_sfx = load(HandCarousel.SCROLL_SFX_PATH)
	if _hover_sfx != null:
		SfxManager.play_variation(
			_hover_sfx,
			HandCarousel.SCROLL_VARIATIONS,
			HandCarousel.SCROLL_PITCH,
			HandCarousel.SCROLL_SEGMENTS
		)


# Поворот «лицом к камере» — перпендикулярно взгляду (компенсируем pitch камеры).
func _face_rotation() -> Vector3:
	return Vector3(deg_to_rad(CAM_PITCH), 0.0, 0.0)


# ── Кубы (переиспользуемый лоток, рендер из active_check) ──────────────────────


func _ensure_tray() -> void:
	if is_instance_valid(_tray):
		return
	_tray = DiceTray.new()
	_tray.name = "DiceTray"
	# Шире расставляем кубы именно в магазине (у общего лотка separation=8).
	_tray.add_theme_constant_override("separation", 28)
	_tray.die_selected.connect(_on_die_clicked)
	_dice_box.add_child(_tray)


# Центрирует ряд кубов по горизонтали на середине сцены, исходя из фактической
# ширины контента (число кубов может меняться) — не зависит от фикс. долей.
func _center_dice_row() -> void:
	if not is_instance_valid(_dice_box) or not is_instance_valid(_stage):
		return
	var s: Vector2 = _stage.size
	_dice_box.custom_minimum_size = Vector2(0.0, DICE_FH * s.y)  # ширину — по контенту
	var dw: float = _dice_box.get_combined_minimum_size().x
	_dice_box.size = Vector2(dw, DICE_FH * s.y)
	_dice_box.position = Vector2(s.x * 0.5 - dw * 0.5, DICE_FY * s.y)


func _render_dice() -> void:
	if not is_instance_valid(_dice_box):
		return
	_ensure_tray()
	if not _rolled():
		if not _last_dice.is_empty():
			_last_dice = []
		var pb: Dictionary = _pool()
		_tray.set_pool_marks(int(pb["bonus"]), int(pb["blocked"]))
		_tray.show_pending(int(pb["pool"]), "influence")
		_center_dice_row()  # число кубов могло измениться — перецентрировать ряд
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
	_center_dice_row()  # число кубов могло измениться — перецентрировать ряд


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


# Разбор пула Влияния: {pool, bonus, blocked} — см. DiceTray.set_pool_marks.
func _pool() -> Dictionary:
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get("influence", 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get("influence", 0))
	var extra: int = Dice.pre_roll_bonus(_check().get("active_mods", []), "influence")
	return Dice.pool_breakdown(base, mods, 0, extra)


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


# Потратить ресурс: −1 ресурс у сыщика, +1 монета в этой сессии (host-авторитетно
# через active_check.shop_resource_coins; счётчик монет обновится по синку).
func _on_spend_resource() -> void:
	if int(GameState.my_player().get("resources", 0)) <= 0:
		return
	GameState.shop_spend_resource()
	_refresh()


func _on_die_clicked(index: int) -> void:
	# reroll_die сам решает: заряжен +1 (addToDie) → кладёт его на куб; иначе
	# перебрасывает (с внутренней валидацией валюты). Гард _can_reroll() глушил
	# клик «+1», когда переброса нет — из-за этого «+1 к значению» не применялся.
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
	var smat := _shadow_mat(entry)
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
	if is_instance_valid(_coins_lbl):
		_coins_lbl.text = "%s: %d" % [tr("SHOP_COINS"), coins]
	if is_instance_valid(_roll_btn):
		if _rolled() and _reroll_all_available():
			_roll_btn.text = "ENCOUNTER_REROLL_ALL"
			_roll_btn.disabled = false
		else:
			_roll_btn.text = "SHOP_ROLL"
			_roll_btn.disabled = _rolled()
	if is_instance_valid(_debt_btn):
		_debt_btn.visible = not _has_debt()
	if is_instance_valid(_res_btn):
		_res_btn.visible = int(GameState.my_player().get("resources", 0)) > 0
	if is_instance_valid(_buy_btn):
		_buy_btn.disabled = _selected.is_empty()
	# Недоступные НЕ затемняем (доступность покажем иначе позже). Тёплый тинт выбора +
	# яркость наведения — в _card_albedo (общий источник, чтобы не конфликтовали).
	for e_v: Variant in _cards:
		var e: Dictionary = e_v
		if bool(e.get("buying", false)):
			continue
		(e.mat as StandardMaterial3D).albedo_color = _card_albedo(e)


# Цвет-множитель albedo карты: тёплый тинт если выбрана, иначе белый. Освещение —
# тёплые лампы (SHADED), одинаково для лежащих и наведённых карт.
func _card_albedo(entry: Dictionary) -> Color:
	return Color(1.2, 1.14, 0.9) if _selected.has(entry.id) else Color.WHITE
