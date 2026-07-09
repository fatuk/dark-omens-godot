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
const _LIGHT_MAP := preload("res://assets/shop/card-light.png")  # серая карта света (soft-light)

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

# Раскладка в ДОЛЯХ прямоугольника арта (_stage). Мат-книга под карточки, прилавок
# под низ — координаты сняты по shop-bg.png.
# Тюнится живьём через TuningPanel (секция «МАГАЗИН · КАРТЫ»). static var — чтобы
# панель могла менять и пушить в открытый магазин (группа "shop_modal" → relayout).
static var CARD_TOP: float = 0.33  # верх карточек (доля высоты)
static var CARD_H: float = 0.30  # высота карточки
const _CARD_ASPECT := 290.0 / 459.0  # ш/в карточки
static var MAT_L: float = 0.12  # левый край центров карт (доля ширины)
static var MAT_R: float = 0.91  # правый край центров карт
static var HOVER_LIFT: float = 0.10  # подъём при наведении (доля высоты)
static var HOVER_SCALE: float = 1.50  # приближение к камере
const _CARD_GAP_FRAC := 0.14  # зазор между картами (доля ширины карты)
# Перспектива «карты лежат на ОДНОЙ плоскости-столе» (одноточечная): весь ряд
# проецируется единой гомографией flat-квадрат→трапеция, поэтому крайние карты
# скошены к общей точке схода, а центральная почти прямая — как реальные карты на
# книге. Наведение выпрямляет карту к зрителю (persp 0→1): 0 = лежит на столе,
# 1 = стоит лицом к камере. Карта рендерится в SubViewport и натягивается на
# проективный четырёхугольник через Polygon2D.
const _CARD_VP_SIZE := Vector2i(380, 601)  # рендер-разрешение карты (аспект 290:459)
static var PERSP_TOP: float = 0.84  # ширина дальнего (верхнего) края плоскости к ближнему
static var PERSP_SQUASH: float = 0.23  # опускание дальнего края (укорочение стола)

# Карта света (soft-light) и падающая тень. Тюнятся живьём (секции «СВЕТ»/«ТЕНЬ»).
static var LIGHT_ENABLED: bool = true  # карта света на картах магазина (чекбокс)
static var LIGHT_INTENSITY: float = 3.5  # сила карты света на лежащих картах
static var SHADOW_OFS: float = 0.03  # смещение тени вниз-вправо (доля высоты карты)
static var SHADOW_ALPHA: float = 0.63  # плотность тени
static var SHADOW_GROW: float = 0.02  # расширение тени относительно карты (виден ореол)
static var SHADOW_FEATHER: float = 0.05  # мягкость края тени (доля)

# Свет карты: художник рисует ПЛОСКУЮ серую карту card-light.png (0.5=нейтраль,
# светлее=блик, темнее=тень) — накладываем на текстуру карты режимом soft-light
# по ТОЧНОЙ формуле Photoshop (тени как парабола, света через sqrt) — чтобы игра
# совпадала с превью слоя Soft Light в фотошопе. base.a на выходе → чистые
# скруглённые углы. intensity гасится в 0 при наведении/покупке. * COLOR = modulate.
const _LIGHT_SHADER := """
shader_type canvas_item;
uniform sampler2D light_map : filter_linear;
uniform float intensity = 1.0;
void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec4 lm = texture(light_map, UV);
	vec3 s = lm.rgb;
	vec3 b = base.rgb;
	vec3 lo = 2.0 * b * s + b * b * (1.0 - 2.0 * s);
	vec3 hi = 2.0 * b * (1.0 - s) + sqrt(b) * (2.0 * s - 1.0);
	vec3 soft = mix(lo, hi, step(vec3(0.5), s));
	vec3 outc = mix(b, soft, lm.a * intensity);
	COLOR = vec4(outc, base.a) * COLOR;
}
"""

# Мягкая тень: тёмный четырёхугольник с федером края по UV (SDF-«коробка»).
const _SHADOW_SHADER := """
shader_type canvas_item;
uniform float feather = 0.26;
uniform float darkness = 0.45;
void fragment() {
	vec2 q = abs(UV - vec2(0.5));
	float d = max(q.x, q.y);
	float a = smoothstep(0.5, 0.5 - feather, d);
	COLOR = vec4(0.0, 0.0, 0.0, a * darkness);
}
"""

const _SHADOW_TEX_SIZE := 64  # размер белой текстуры-носителя UV для шейдера тени
static var _white_tex: ImageTexture  # белая NxN — носитель UV для шейдера тени

# Состояние сессии магазина (UI-локальное; бросок/монеты — в active_check).
var _debt_taken: bool = false
var _selected: Dictionary = {}  # asset_id -> cost
var _last_dice: Array = []
var _last_nonce: int = 0
var _last_can: bool = false
var _last_add: bool = false

# Узлы.
var _stage: Control  # вписанный прямоугольник арта — база для долевой раскладки
var _dice_box: HBoxContainer
var _tray: DiceTray
var _coins_lbl: Label
var _roll_btn: Button
var _debt_btn: Button
var _buy_btn: Button
var _cards: Array = []  # [{id, cost, card, rest_pos, rest_scale, rot, hovering, buying}]
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


func _build_asset_card(a: Dictionary, idx: int, total: int) -> void:
	var aid: String = String(a.get("id", ""))
	var cost: int = int(a.get("cost", 0))
	var traits: Array = a.get("traits", [])
	var trait_id: String = String(traits[-1]) if not traits.is_empty() else "item"

	# GameCard рендерится в SubViewport (нативный размер), затем натягивается на
	# квадрат-кейстоун (перспектива стола) через Polygon2D.
	var vp := SubViewport.new()
	vp.name = "CardVP"
	vp.size = _CARD_VP_SIZE
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.disable_3d = true
	var card := GameCard.new()
	card.name = "Card"
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Карта рендерится в SubViewport крупнее эталона веера — масштабируем шрифты в
	# той же пропорции, чтобы текст относительно карты был как в веере.
	card.set_font_scale(float(_CARD_VP_SIZE.x) / HandCarousel.CARD_W)
	(
		card
		. set_card(
			{
				"cost": cost,
				"title": a.get("nameKey", ""),
				"subtitle": _TRAIT_KEY.get(trait_id, trait_id.to_upper()),
				"desc": a.get("abilityKey", ""),
				"art": AssetCatalog.card_art(aid),
				# Заглушка для карт без файла арта — тёплая притенённая, а не почти-чёрная
				# навья по умолчанию (когда арт есть — этот цвет игнорируется).
				"art_color": _ART_PLACEHOLDER,
			}
		)
	)
	vp.add_child(card)

	# Мягкая падающая тень — отдельный Polygon2D на столе (не в host: не поднимается
	# с картой при наведении, остаётся лежать). Добавляется ДО host → рисуется под
	# картой, но над матом (z по умолчанию; z=-1 уводил бы за фон-арт).
	var shadow := Polygon2D.new()
	shadow.name = "Shadow_%d" % idx
	shadow.texture = _shadow_texture()  # белая NxN — носитель UV 0..1 для шейдера
	var st: float = float(_SHADOW_TEX_SIZE)
	shadow.uv = PackedVector2Array([Vector2(0, 0), Vector2(st, 0), Vector2(st, st), Vector2(0, st)])
	shadow.material = _make_shader_material(_SHADOW_SHADER)
	_stage.add_child(shadow)

	var host := Node2D.new()
	host.name = "PerspCard_%d" % idx
	host.add_child(vp)
	var poly := Polygon2D.new()
	poly.name = "Poly"
	poly.texture = vp.get_texture()
	poly.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var lmat := _make_shader_material(_LIGHT_SHADER)  # карта света (soft-light)
	lmat.set_shader_parameter("light_map", _LIGHT_MAP)
	lmat.set_shader_parameter("intensity", LIGHT_INTENSITY)
	poly.material = lmat
	host.add_child(poly)
	_stage.add_child(host)

	# Хит-тест — прозрачный Control поверх области карты (наведение/клик).
	var hit := Control.new()
	hit.name = "Hit_%d" % idx
	hit.mouse_filter = Control.MOUSE_FILTER_STOP
	hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_stage.add_child(hit)

	var entry := {
		"id": aid,
		"cost": cost,
		"host": host,
		"poly": poly,
		"vp": vp,
		"card": card,
		"hit": hit,
		"shadow": shadow,
		"idx": idx,
		"total": total,
		"buying": false,
		"hovering": false,
		"persp": 0.0,
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


# ShaderMaterial из кода шейдера (один на карту — свои uniform'ы под тюн).
func _make_shader_material(code: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = code
	mat.shader = sh
	return mat


# Белая NxN текстура — носитель UV для шейдера тени. Polygon2D без текстуры не даёт
# UV в шейдере, а с 1×1 текстурой + шейдером ничего не рисуется (баг Godot) — нужна
# «настоящая» текстура. Ленивая, общая на все карты.
func _shadow_texture() -> ImageTexture:
	if _white_tex == null:
		var img := Image.create(_SHADOW_TEX_SIZE, _SHADOW_TEX_SIZE, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_white_tex = ImageTexture.create_from_image(img)
	return _white_tex


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
	# Карты лежат на уходящем столе — ОДНОТОЧЕЧНАЯ перспектива всего ряда. Ближний
	# (нижний) край карт выкладывается по горизонтали, дальний (верхний) край сужается
	# к общей точке схода vp_x (в PERSP_TOP раз) и приподнят на укороченную высоту
	# (перспективное укорочение длины). Все вертикали ряда сходятся в одну точку над
	# центром → крайние карты скошены, центральная почти прямая.
	var total: int = _cards.size()
	var vp_x: float = (MAT_L + MAT_R) * 0.5 * s.x  # горизонт. позиция точки схода
	var near_span: float = (MAT_R - MAT_L) * s.x  # ширина ближнего края ряда
	var foreshorten: float = clampf(1.0 - PERSP_SQUASH, 0.3, 1.0)  # доля длины на экране
	# Ширина карты: min(горизонтальная укладка N карт, вертикальный бюджет CARD_H).
	var card_w_fit: float = 0.0
	if total > 0:
		card_w_fit = near_span / (float(total) + float(total + 1) * _CARD_GAP_FRAC)
	var card_w_v: float = CARD_H * s.y * _CARD_ASPECT / foreshorten
	var card_w: float = minf(card_w_fit, card_w_v)
	var card_hf: float = foreshorten * card_w / _CARD_ASPECT  # экранная высота (укороч.)
	var gap: float = _CARD_GAP_FRAC * card_w
	var row_w: float = float(total) * card_w + float(maxi(total - 1, 0)) * gap
	var start_x: float = vp_x - row_w * 0.5
	var y_near: float = (CARD_TOP + CARD_H) * s.y  # низ карт (ближний край)
	var y_far: float = y_near - card_hf  # верх карт (дальний край)
	for i in range(total):
		var e: Dictionary = _cards[i]
		var near_l: float = start_x + float(i) * (card_w + gap)
		var near_r: float = near_l + card_w
		# Дальний край сужается к точке схода vp_x в PERSP_TOP раз.
		var far_l: float = vp_x + (near_l - vp_x) * PERSP_TOP
		var far_r: float = vp_x + (near_r - vp_x) * PERSP_TOP
		var c_tl := Vector2(far_l, y_far)
		var c_tr := Vector2(far_r, y_far)
		var c_br := Vector2(near_r, y_near)
		var c_bl := Vector2(near_l, y_near)
		var center: Vector2 = (c_tl + c_tr + c_br + c_bl) * 0.25
		e["rest_quad"] = PackedVector2Array(
			[c_tl - center, c_tr - center, c_br - center, c_bl - center]
		)
		# Прямой (лицом к камере) прямоугольник полной длины — цель наведения.
		var fhw: float = card_w * 0.5
		var fhh: float = card_w / _CARD_ASPECT * 0.5
		e["front_quad"] = PackedVector2Array(
			[Vector2(-fhw, -fhh), Vector2(fhw, -fhh), Vector2(fhw, fhh), Vector2(-fhw, fhh)]
		)
		e["rest_center"] = center
		e["card_w"] = card_w
		e["card_h"] = card_w / _CARD_ASPECT
		# Тень — тот же четырёхугольник, расширен и смещён вниз-вправо, лежит на столе.
		var g: float = 1.0 + SHADOW_GROW
		var shadow: Polygon2D = e.shadow
		shadow.polygon = PackedVector2Array(
			[(c_tl - center) * g, (c_tr - center) * g, (c_br - center) * g, (c_bl - center) * g]
		)
		shadow.position = center + Vector2(SHADOW_OFS * 0.45, SHADOW_OFS) * card_hf
		var smat: ShaderMaterial = shadow.material
		smat.set_shader_parameter("darkness", SHADOW_ALPHA)
		smat.set_shader_parameter("feather", SHADOW_FEATHER)
		# Хит-область — экранный bbox лежащей карты (наведение/клик).
		var minx: float = minf(c_bl.x, far_l)
		var maxx: float = maxf(c_br.x, far_r)
		var hit: Control = e.hit
		hit.position = Vector2(minx, y_far)
		hit.size = Vector2(maxx - minx, y_near - y_far)
		if not bool(e.get("buying", false)) and not bool(e.get("hovering", false)):
			var host: Node2D = e.host
			host.position = center
			host.scale = Vector2.ONE
			_apply_persp(e, 0.0)  # лежит на столе
			var lit: float = LIGHT_INTENSITY if LIGHT_ENABLED else 0.0
			(e.poly as Polygon2D).material.set_shader_parameter("intensity", lit)


# ── Наведение: подъём и приближение к камере ──────────────────────────────────


func _hover_card(entry: Dictionary, on: bool) -> void:
	if bool(entry.get("buying", false)):
		return
	entry["hovering"] = on
	var host: Node2D = entry.host
	var rc: Vector2 = entry.get("rest_center", host.position)
	var lift: float = HOVER_LIFT * (float(entry.get("card_h", 1.0)) / CARD_H)
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(
		Tween.EASE_OUT
	)
	# Выпрямляем карту к зрителю (persp 0→1) + подъём и приближение.
	tw.tween_method(
		func(v: float) -> void: _apply_persp(entry, v), float(entry.persp), 1.0 if on else 0.0, 0.16
	)
	# Гасим карту света: поднятая карта — «как есть, у камеры» (без бликов/теней).
	var lmat: ShaderMaterial = (entry.poly as Polygon2D).material
	var i_cur: float = lmat.get_shader_parameter("intensity")
	var i_rest: float = LIGHT_INTENSITY if LIGHT_ENABLED else 0.0
	tw.tween_method(
		func(v: float) -> void: lmat.set_shader_parameter("intensity", v),
		i_cur,
		0.0 if on else i_rest,
		0.16
	)
	if on:
		host.z_index = 10  # приподнятая карта — поверх соседей
		tw.tween_property(host, "position", rc - Vector2(0, lift), 0.16)
		tw.tween_property(host, "scale", Vector2.ONE * HOVER_SCALE, 0.16)
	else:
		host.z_index = 0
		tw.tween_property(host, "position", rc, 0.16)
		tw.tween_property(host, "scale", Vector2.ONE, 0.16)


# Натянуть текстуру карты на четырёхугольник. t: 0 — лежит на столе (проекция
# гомографией, скошена к точке схода), 1 — выпрямлена лицом к камере. Интерполяция
# между сохранёнными rest_quad и front_quad. Вершины TL,TR,BR,BL (origin — центр).
func _apply_persp(entry: Dictionary, t: float) -> void:
	entry["persp"] = t
	var poly: Polygon2D = entry.poly
	var rq: PackedVector2Array = entry.get("rest_quad", PackedVector2Array())
	var fq: PackedVector2Array = entry.get("front_quad", PackedVector2Array())
	if rq.size() != 4 or fq.size() != 4:
		return
	poly.polygon = PackedVector2Array(
		[rq[0].lerp(fq[0], t), rq[1].lerp(fq[1], t), rq[2].lerp(fq[2], t), rq[3].lerp(fq[3], t)]
	)
	var vs := Vector2(_CARD_VP_SIZE)
	poly.uv = PackedVector2Array(
		[Vector2(0, 0), Vector2(vs.x, 0), Vector2(vs.x, vs.y), Vector2(0, vs.y)]
	)


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


# Карта уходит из витрины: выпрямляется, рывок к камере вверх + растворение.
func _fly_out(entry: Dictionary) -> void:
	entry["buying"] = true
	var host: Node2D = entry.host
	host.z_index = 20
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_method(func(v: float) -> void: _apply_persp(entry, v), float(entry.persp), 1.0, 0.30)
	tw.tween_property(host, "position:y", host.position.y - float(entry.card_h) * 0.8, 0.30)
	tw.tween_property(host, "scale", Vector2.ONE * 1.4, 0.30)
	tw.tween_property(entry.poly, "modulate:a", 0.0, 0.30)
	tw.tween_property(entry.shadow, "modulate:a", 0.0, 0.22)  # тень гаснет с картой
	# Улетающая карта — «как есть» (гасим карту света).
	(entry.poly as Polygon2D).material.set_shader_parameter("intensity", 0.0)


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
	# тёплая подсветка выбранной карты.
	for e_v: Variant in _cards:
		var e: Dictionary = e_v
		if bool(e.get("buying", false)):
			continue
		var poly: Polygon2D = e.poly
		poly.modulate = Color(1.2, 1.14, 0.9) if _selected.has(e.id) else Color.WHITE
