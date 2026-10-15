class_name GameCard
extends Control

## Единый компонент игровой карты на рамке asset/card-frame.png — для карт товаров
## (магазин) и карт руки (веер). Рисует рамку и раскладывает контент по её зонам
## (стоимость / арт / заголовок / описание). Когда зоны/рамка поменяются — правка
## в одном месте, и обе колоды обновятся.
##
## API: set_card({cost, title, subtitle?, desc, art? : Texture2D, art_color?, glyph?,
##                frame? : Texture2D, layout? : "clue"})
##   frame  — полно-артовая рамка (карта Концентрации, улика);
##   layout — "clue": раскладка улики (заголовок, подзаголовок, описание по тёмному
##            окну на всю карту) вместо плашек рамки актива.

const FRAME_TEX: Texture2D = preload("res://assets/cards/asset/card-frame.png")

## Аспект рамки (ширина/высота). Карту задавать в этих пропорциях, иначе рамка
## растянется. 1768×2796.
const ASPECT: float = 1768.0 / 2796.0

## Радиус скругления углов арт-слоя (px). Арт лежит ПОД рамкой; в прозрачных
## скруглённых углах рамки торчали бы прямоугольные углы арта — режем по радиусу.
const ART_CORNER_RADIUS: float = 24.0

const _ROUND_CORNERS_SHADER := """
shader_type canvas_item;
uniform float radius_px = 24.0;
uniform vec2 rect_px = vec2(100.0, 100.0);
void fragment() {
	vec2 q = abs(UV * rect_px - rect_px * 0.5) - (rect_px * 0.5 - vec2(radius_px));
	float dist = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius_px;
	COLOR.a *= 1.0 - smoothstep(-1.0, 1.0, dist);
}
"""

# Процедурный клубящийся дым (карта-сообщение). FBM-шум с domain-warp по TIME —
# анимируется сам, без _process. Светлые космы поверх тёмного окна рамки; мягкая
# маска гасит края, чтобы дым жил в центре и не лез на орнамент.
const _SMOKE_SHADER := """
shader_type canvas_item;
uniform float speed = 0.06;
uniform float scale = 3.0;
uniform float intensity = 0.55;
uniform vec3 tint : source_color = vec3(0.72, 0.75, 0.78);
uniform vec2 seed = vec2(0.0);  // свой на каждую карту: сдвиг области шума + фазы

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash(i), b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0)), d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 5; i++) { v += a * vnoise(p); p *= 2.0; a *= 0.5; }
	return v;
}

void fragment() {
	float t = TIME * speed + seed.x * 10.0;
	vec2 uv = UV * scale + seed;
	vec2 q = vec2(fbm(uv + vec2(0.0, t)), fbm(uv + vec2(5.2, -t)));
	float f = fbm(uv + q * 2.0 + vec2(t * 0.5, t * 0.3));
	f = smoothstep(0.35, 0.9, f);
	vec2 m = smoothstep(vec2(0.0), vec2(0.4), UV) * smoothstep(vec2(0.0), vec2(0.4), 1.0 - UV);
	float alpha = f * m.x * m.y * intensity;
	COLOR = vec4(tint, alpha);
}
"""

# Зоны контента — доли рамки (x, y, w, h ∈ 0..1). Подобраны под asset/card-frame.png.
const Z_COST := Rect2(0.075, 0.050, 0.160, 0.100)  # центр ≈ (0.12, 0.085) — герб-компас
const Z_ART := Rect2(0.025, 0.025, 0.950, 0.515)  # арт ПОД рамкой, 95% ширины, упёрт вверх
const Z_TITLE := Rect2(0.110, 0.555, 0.780, 0.092)
const Z_DESC := Rect2(0.120, 0.695, 0.760, 0.235)
# Плашка карты-сообщения (chat): текст фразы по центру нижнего пергамента новой
# рамки cards/chat/card-frame.png. Своя зона — эмблема-облачко уже вшита в рамку.
const Z_MSG := Rect2(0.130, 0.640, 0.740, 0.270)
# Клубящийся дым карты-сообщения — во внутренней тёмной области над плашкой.
# Затухает к краям (мягкая маска), чтобы не перекрыть орнамент-кант рамки.
const Z_SMOKE := Rect2(0.075, 0.075, 0.850, 0.520)

# Карта-улика (layout "clue"): рамка cards/clue/card-frame.png — под эмблемой-глазом
# тёмная шапка из двух полос: заголовок (имя локации) — в верхней, подзаголовок (имя
# улики) — в узкой под тонким разделителем; ниже — пергамент с описанием тёмной тушью.
# Не влезло — прокрутка курсором, как у остальных карт. Зоны — доли рамки (замерены по
# ассету 1768×2796: полосы шапки 0.192–0.278 и 0.283–0.340, пергамент ≈0.36–0.90).
const Z_CLUE_TITLE := Rect2(0.120, 0.195, 0.760, 0.083)
const Z_CLUE_SUB := Rect2(0.120, 0.285, 0.760, 0.052)
const Z_CLUE_DESC := Rect2(0.170, 0.385, 0.660, 0.490)

const C_COST_TXT := UIColors.ACCENT  # янтарь — как заголовок
const C_TITLE_TXT := UIColors.ACCENT  # янтарь на синей плашке
const C_SUB_TXT := Color(0.62, 0.72, 0.82)  # приглушённый голубой — трейт
const C_DESC_TXT := Color(0, 0, 0)  # чёрный — на пергаменте
const C_MSG_TXT := Color(0.12, 0.09, 0.06)  # тёмная тушь — фраза на пергаменте карты-сообщения
const C_CLUE_TITLE := Color(0.93, 0.88, 0.78)  # имя локации — светлый пергамент по шапке
const C_CLUE_SUB := Color(0.70, 0.78, 0.68)  # имя улики — приглушённый серо-зелёный
const C_CLUE_DESC := Color(0.17, 0.12, 0.08)  # описание — тёмная тушь на пергаменте

# Параметры дыма карты-сообщения — static (дефолт + правятся в панели тюнинга Ctrl+M).
# Сеттер панели пишет их и дёргает refresh_smoke() у живых карт (группа "smoke_card").
static var SMOKE_SPEED: float = 0.17  # скорость клубления
static var SMOKE_SCALE: float = 1.0  # крупность космов
static var SMOKE_INTENSITY: float = 0.55  # плотность/яркость
static var SMOKE_TINT: Color = Color(0.25, 0.41, 0.65)  # цвет дыма (холодный синеватый)
const C_ART_FILL := UIColors.ART_BG  # заглушка арт-слота (закрывает белый бокс)
const C_GLYPH := Color(0.55, 0.48, 0.35)

# Скролл описания курсором (когда текст не влезает в зону пергамента): позиция
# курсора по вертикали (клампится к высоте блока) задаёт направление и скорость —
# выше центра скроллит вверх, ниже вниз, по центру стоит; линейно к краям.
const _DESC_SCROLL_MAX_SPEED := 75.0  # px/сек на краях (вдвое медленнее прежнего)
const _DESC_SCROLL_DEADZONE := 0.04  # доля высоты от центра, где скролл стоит
const _DESC_LABEL_H := 2000.0  # заведомо большая высота лейбла (любое описание влезет)
const _DESC_BOTTOM_PAD := 4.0  # нижний запас, чтобы последняя строка не подрезалась

# Базовые размеры шрифтов (px) — откалиброваны под карту веера (HandCarousel.CARD_W
# ≈ 186 px). Магазин рендерит карту в SubViewport крупнее эталона, поэтому масштабирует
# их через set_font_scale(), чтобы пропорция текста к карте совпадала с веером.
const FS_COST := 20
const FS_TITLE := 14
const FS_TITLE_MIN_RATIO := 0.6  # длинный заголовок ужимаем не ниже 60% базы
const FS_SUB := 9
const FS_DESC := 12
const FS_GLYPH := 40
const FS_MSG := 21
const FS_CLUE_TITLE := 18
const FS_CLUE_SUB := 12
const FS_CLUE_DESC := 13  # описание улики; не влезает — прокрутка курсором (_process)
var _font_scale: float = 1.0
var _layout: String = ""  # "" — карта актива/жетона; "clue" — улика

var _cost: Label
var _title: Label
var _sub: Label
var _desc: Label
var _desc_offset: float = 0.0  # текущий сдвиг описания вверх (px), 0..overflow
var _scroll_src: Control = null  # чужой контрол, чьё наведение крутит описание (просмотр)
var _art: TextureRect
var _art_fill: ColorRect
var _glyph: Label
var _frame: TextureRect
var _message: Label  # карта-сообщение (chat): одна центрированная фраза в плашке
var _smoke: ColorRect  # клубящийся дым в окне карты-сообщения (поверх рамки)
var _desc_zone: Control  # зона описания — у улики переезжает в Z_CLUE_DESC
var _clue_title: Label  # заголовок улики (имя локации) — своя зона над окном
var _clue_sub: Label


func _init() -> void:
	_build()
	resized.connect(_fit_title)  # ширина плашки известна только после раскладки


func _build() -> void:
	# Арт — ПОД рамкой: виден сквозь прозрачное окно рамки (мягкие края окна
	# растушёвывают его). Слот шире окна, COVER заполняет ширину.
	var art_zone := _zone("Art", Z_ART)
	_art_fill = ColorRect.new()
	_art_fill.name = "ArtFill"
	_art_fill.color = C_ART_FILL
	_art_fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_zone.add_child(_art_fill)
	_art = TextureRect.new()
	_art.name = "Art"
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art.visible = false
	art_zone.add_child(_art)
	_glyph = _centered_label("Glyph", _fs(FS_GLYPH), C_GLYPH)
	art_zone.add_child(_glyph)

	# Скругляем углы арт-слоя по радиусу (один материал на заливку и текстуру);
	# rect_px обновляем по фактическому размеру зоны.
	var round_mat := ShaderMaterial.new()
	var round_sh := Shader.new()
	round_sh.code = _ROUND_CORNERS_SHADER
	round_mat.shader = round_sh
	round_mat.set_shader_parameter("radius_px", ART_CORNER_RADIUS)
	_art_fill.material = round_mat
	_art.material = round_mat
	art_zone.resized.connect(
		func() -> void: round_mat.set_shader_parameter("rect_px", art_zone.size)
	)

	# Рамка — ПОВЕРХ арта: бронзовый кант и плашки рисуются над артом, прозрачное
	# окно открывает арт.
	_frame = TextureRect.new()
	_frame.name = "Frame"
	_frame.texture = FRAME_TEX
	_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_frame.stretch_mode = TextureRect.STRETCH_SCALE
	_frame.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_frame)

	# Дым карты-сообщения — ПОВЕРХ рамки, в тёмном окне (зона добавлена после рамки).
	# Виден только для карт с полем message; шейдер анимируется по TIME сам.
	var smoke_zone := _zone("SmokeZone", Z_SMOKE)
	_smoke = ColorRect.new()
	_smoke.name = "Smoke"
	_smoke.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_smoke.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var smoke_mat := ShaderMaterial.new()
	var smoke_sh := Shader.new()
	smoke_sh.code = _SMOKE_SHADER
	smoke_mat.shader = smoke_sh
	_smoke.material = smoke_mat
	# Свой сид на карту — иначе у всех карт дым синхронный и одинаковый.
	smoke_mat.set_shader_parameter("seed", Vector2(randf(), randf()) * 100.0)
	_smoke.visible = false
	smoke_zone.add_child(_smoke)
	add_to_group("smoke_card")  # панель тюнинга пушит сюда uniform'ы
	refresh_smoke()

	# Стоимость — в гербе сверху-слева.
	var cost_zone := _zone("Cost", Z_COST)
	_cost = _centered_label("CostLabel", _fs(FS_COST), C_COST_TXT)
	cost_zone.add_child(_cost)

	# Заголовок + трейт — на синей плашке.
	var title_zone := _zone("Title", Z_TITLE)
	var tvb := VBoxContainer.new()
	tvb.name = "TitleVB"
	tvb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tvb.alignment = BoxContainer.ALIGNMENT_CENTER
	tvb.add_theme_constant_override("separation", 0)
	tvb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_zone.add_child(tvb)
	_title = _centered_label("Name", _fs(FS_TITLE), C_TITLE_TXT)
	_title.clip_text = true
	tvb.add_child(_title)
	_sub = _centered_label("Subtitle", _fs(FS_SUB), C_SUB_TXT)
	_sub.clip_text = true
	tvb.add_child(_sub)

	# Описание — на пергаменте. Чёрный текст; не влезает → desc_zone клипует, а сам
	# текст (заведомо высокий Label) сдвигается курсором при наведении (_process).
	# Зона/лейбл — IGNORE, чтобы наведение ловила сама карта (self).
	var desc_zone := _zone("Desc", Z_DESC)
	desc_zone.clip_contents = true
	_desc_zone = desc_zone
	_desc = Label.new()
	_desc.name = "DescLabel"
	_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desc.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.add_theme_font_size_override("font_size", _fs(FS_DESC))
	_desc.add_theme_color_override("font_color", C_DESC_TXT)
	_desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Ширина = зоне (anchor 0..1), верх у зоны; высота заведомо большая — текст
	# рисуется с верха, лишнее клипует desc_zone. Скролл двигает offset_top/bottom.
	_desc.anchor_left = 0.0
	_desc.anchor_right = 1.0
	_desc.anchor_top = 0.0
	_desc.anchor_bottom = 0.0
	_desc.offset_left = 0.0
	_desc.offset_right = 0.0
	_desc.offset_top = 0.0
	_desc.offset_bottom = _DESC_LABEL_H
	desc_zone.add_child(_desc)

	# Карта-сообщение (chat): одна крупная центрированная фраза в плашке новой рамки.
	# Своей арт-зоны/заголовка нет — эмблема вшита в рамку, текст ложится в Z_MSG.
	var msg_zone := _zone("Msg", Z_MSG)
	_message = Label.new()
	_message.name = "MessageLabel"
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_message.add_theme_font_size_override("font_size", _fs(FS_MSG))
	_message.add_theme_color_override("font_color", C_MSG_TXT)
	_message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_message.visible = false
	msg_zone.add_child(_message)

	# Улика: заголовок и подзаголовок — свои зоны поверх тёмного окна рамки улики.
	# Описание — общий _desc, его зона переезжает в set_card.
	var ct_zone := _zone("ClueTitle", Z_CLUE_TITLE)
	_clue_title = _centered_label("ClueTitle", _fs(FS_CLUE_TITLE), C_CLUE_TITLE)
	_clue_title.clip_text = true
	_clue_title.visible = false
	ct_zone.add_child(_clue_title)
	var cs_zone := _zone("ClueSub", Z_CLUE_SUB)
	_clue_sub = _centered_label("ClueSubtitle", _fs(FS_CLUE_SUB), C_CLUE_SUB)
	_clue_sub.clip_text = true
	_clue_sub.visible = false
	cs_zone.add_child(_clue_sub)
	resized.connect(_fit_clue)

	mouse_entered.connect(_on_desc_hover_start)
	mouse_exited.connect(_on_desc_hover_end)
	set_process(false)  # покадровый скролл включается только под курсором


## Заполнить карту. Поля: cost, title, subtitle?, desc, art? (Texture2D),
## art_color? (Color заглушки), glyph? (символ-заглушка).
func set_card(d: Dictionary) -> void:
	# Карта-сообщение (chat): единственный текст — фраза по центру плашки; служебные
	# зоны (цена/заголовок/трейт/описание) прячем, всё остальное рисует рамка.
	var is_msg: bool = d.has("message")
	_message.visible = is_msg
	_message.text = String(d.get("message", ""))
	_smoke.visible = is_msg  # клубящийся дым в окне только у карт-сообщений
	_layout = String(d.get("layout", ""))
	var is_clue: bool = _layout == "clue"

	# Стоимость — герб-компас; для жетонов/карт без цены поле не задаём → герб скрыт.
	_cost.visible = (not is_msg) and d.has("cost")
	if _cost.visible:
		_cost.text = str(d["cost"])
	# Заголовок/подзаголовок: у улики — свои зоны над окном, плашечные лейблы актива
	# прячем; иначе наоборот.
	_title.text = String(d.get("title", ""))
	_title.visible = not is_msg and not is_clue
	_fit_title()
	_sub.text = String(d.get("subtitle", ""))
	_sub.visible = (not is_msg) and (not is_clue) and not _sub.text.is_empty()
	_clue_title.text = _title.text
	_clue_title.visible = is_clue
	_clue_sub.text = _sub.text
	_clue_sub.visible = is_clue and not _clue_sub.text.is_empty()
	# Описание: у улики — пергамент под шапкой, тёмная тушь и крупнее; у актива —
	# пергамент рамки, чёрный, базовый размер.
	_set_zone_rect(_desc_zone, Z_CLUE_DESC if is_clue else Z_DESC)
	_desc.add_theme_color_override("font_color", C_CLUE_DESC if is_clue else C_DESC_TXT)
	# Улика — повествование по пергаменту: ровно слева, как абзац; у актива — по центру.
	_desc.horizontal_alignment = (
		HORIZONTAL_ALIGNMENT_LEFT if is_clue else HORIZONTAL_ALIGNMENT_CENTER
	)
	_desc.add_theme_font_size_override("font_size", _fs(FS_CLUE_DESC if is_clue else FS_DESC))
	_desc.text = String(d.get("desc", ""))
	_desc.visible = not is_msg
	_fit_clue()
	_on_desc_hover_end()  # новый текст — гасим скролл и возвращаем к началу

	# Кастомная рамка (frame): ПОЛНО-артовая карта (арт+рамка+пергамент единым
	# изображением, напр. карта Концентрации). Тогда своя арт-зона/глиф не нужны —
	# всё рисует рамка; текст ложится в зоны Title/Desc (совпадают по разметке).
	var frame_tex: Texture2D = d.get("frame", null)
	_frame.texture = frame_tex if frame_tex != null else FRAME_TEX

	var tex: Texture2D = d.get("art", null)
	if frame_tex != null:
		_art.visible = false
		_glyph.visible = false
		_art_fill.color = Color(0, 0, 0, 0)  # прозрачно — полно-артовая рамка сама всё рисует
	elif tex != null:
		_art.texture = tex
		_art.visible = true
		_glyph.visible = false
	else:
		_art.visible = false
		_art_fill.color = d.get("art_color", C_ART_FILL)
		_glyph.text = String(d.get("glyph", ""))
		_glyph.visible = not _glyph.text.is_empty()


# Переложить параметры дыма из static в материал (панель тюнинга дёргает по группе).
func refresh_smoke() -> void:
	var m := _smoke.material as ShaderMaterial
	if m == null:
		return
	m.set_shader_parameter("speed", SMOKE_SPEED)
	m.set_shader_parameter("scale", SMOKE_SCALE)
	m.set_shader_parameter("intensity", SMOKE_INTENSITY)
	m.set_shader_parameter("tint", SMOKE_TINT)


# ── скролл описания курсором ───────────────────────────────────────────────────


# Наведение на карту — включаем покадровый скролл (если есть переполнение, оно
# проверяется в _process). Уход курсора / новый текст — выключаем и в начало.
func _on_desc_hover_start() -> void:
	set_process(true)


func _on_desc_hover_end() -> void:
	set_process(false)
	_desc_offset = 0.0
	_apply_desc_offset()


# Двигаем высокий лейбл вверх на _desc_offset px (desc_zone клипует низ/верх).
func _apply_desc_offset() -> void:
	if not is_instance_valid(_desc):
		return
	_desc.offset_top = -_desc_offset
	_desc.offset_bottom = _DESC_LABEL_H - _desc_offset


## Крутить описание по наведению на ДРУГОЙ контрол (миниатюру, с которой открыт
## крупный просмотр): курсор над миниатюрой, а читают крупную копию, — вертикаль
## курсора в миниатюре и задаёт направление, тем же законом, что на самой карте.
func drive_desc_scroll_from(src: Control) -> void:
	_scroll_src = src
	set_process(true)


## Остановить прокрутку от чужого контрола и вернуть описание к началу.
func stop_desc_scroll() -> void:
	_scroll_src = null
	_on_desc_hover_end()


# Позиция курсора по вертикали в зоне (клампится к её высоте): t=0 (верх) → вверх,
# t=0.5 (центр) → стоп, t=1 (низ) → вниз. Скорость линейна по отклонению от центра.
# Высоту текста берём по числу перенесённых строк (ScrollContainer её не считал).
func _process(delta: float) -> void:
	if not is_instance_valid(_desc):
		return
	var zone: Control = _desc.get_parent()
	var zh: float = zone.size.y
	if zh <= 0.0:
		return
	# Высота текста: строки × (высота строки + межстрочный интервал) + нижний запас.
	# get_line_height() НЕ включает line_spacing — без него низ подрезался.
	var lines: int = _desc.get_line_count()
	var line_h: float = float(_desc.get_line_height())
	var spacing: float = float(_desc.get_theme_constant("line_spacing"))
	var content_h: float = float(lines) * (line_h + spacing) + _DESC_BOTTOM_PAD
	var overflow: float = content_h - zh
	if overflow <= 0.0:
		if _desc_offset != 0.0:
			_desc_offset = 0.0
			_apply_desc_offset()
		return  # текст влезает — скроллить нечего
	var t: float
	if is_instance_valid(_scroll_src) and _scroll_src.size.y > 0.0:
		t = clampf(_scroll_src.get_local_mouse_position().y / _scroll_src.size.y, 0.0, 1.0)
	else:
		t = clampf(zone.get_local_mouse_position().y / zh, 0.0, 1.0)
	var dir: float = (t - 0.5) * 2.0  # [-1..1]: <0 вверх, >0 вниз; линейно к краям
	if absf(dir) < _DESC_SCROLL_DEADZONE:
		return  # около центра — стоп
	_desc_offset = clampf(_desc_offset + dir * _DESC_SCROLL_MAX_SPEED * delta, 0.0, overflow)
	_apply_desc_offset()


# ── helpers ───────────────────────────────────────────────────────────────────


# Control, заякоренный на дробную зону рамки (доли 0..1).
func _zone(zname: String, r: Rect2) -> Control:
	var c := Control.new()
	c.name = zname
	_set_zone_rect(c, r)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(c)
	return c


# Переякорить зону на другую долю рамки (описание улики живёт в другом месте).
func _set_zone_rect(c: Control, r: Rect2) -> void:
	c.anchor_left = r.position.x
	c.anchor_top = r.position.y
	c.anchor_right = r.position.x + r.size.x
	c.anchor_bottom = r.position.y + r.size.y
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0


# Заголовок улики (имя локации) — ужать шрифт, пока не влезет в зону по ширине
# (не ниже FS_TITLE_MIN_RATIO базы). Для прочих карт — no-op.
func _fit_clue() -> void:
	if _layout != "clue" or not is_instance_valid(_clue_title) or _clue_title.text.is_empty():
		return
	var avail: float = size.x * Z_CLUE_TITLE.size.x
	if avail <= 0.0:
		return
	var font: Font = _clue_title.get_theme_font("font")
	var fs_max: int = _fs(FS_CLUE_TITLE)
	var fs_min: int = maxi(1, int(round(float(fs_max) * FS_TITLE_MIN_RATIO)))
	var fs: int = fs_max
	while (
		fs > fs_min
		and font.get_string_size(_clue_title.text, HORIZONTAL_ALIGNMENT_CENTER, -1.0, fs).x > avail
	):
		fs -= 1
	_clue_title.add_theme_font_size_override("font_size", fs)


# Длинный заголовок («Ритуал Серебряных сумерек») в плашку не влезает и клипуется —
# ужимаем шрифт, пока не влезет (не ниже FS_TITLE_MIN_RATIO базы). Меряем по ширине
# зоны заголовка от размера карты (лейбл сам ещё может быть не разложен) — зовём
# при смене текста, масштаба шрифта и размера карты.
func _fit_title() -> void:
	if not is_instance_valid(_title) or _title.text.is_empty():
		return
	var avail: float = size.x * Z_TITLE.size.x
	if avail <= 0.0:
		return
	var font: Font = _title.get_theme_font("font")
	var fs_max: int = _fs(FS_TITLE)
	var fs_min: int = maxi(1, int(round(float(fs_max) * FS_TITLE_MIN_RATIO)))
	var fs: int = fs_max
	while (
		fs > fs_min
		and font.get_string_size(tr(_title.text), HORIZONTAL_ALIGNMENT_CENTER, -1.0, fs).x > avail
	):
		fs -= 1
	_title.add_theme_font_size_override("font_size", fs)


# Размер шрифта = база × текущий масштаб контента (округлённо).
func _fs(base: int) -> int:
	return int(round(float(base) * _font_scale))


## Масштаб всех шрифтов карты (1.0 = эталон веера). Магазин рендерит карту в
## SubViewport крупнее эталона и зовёт это после new(), чтобы пропорция текста к
## карте совпала с веером. Переприменяет размеры к уже построенным лейблам.
func set_font_scale(s: float) -> void:
	if is_equal_approx(_font_scale, s):
		return
	_font_scale = s
	_cost.add_theme_font_size_override("font_size", _fs(FS_COST))
	_title.add_theme_font_size_override("font_size", _fs(FS_TITLE))
	_fit_title()
	_sub.add_theme_font_size_override("font_size", _fs(FS_SUB))
	_desc.add_theme_font_size_override(
		"font_size", _fs(FS_CLUE_DESC if _layout == "clue" else FS_DESC)
	)
	_glyph.add_theme_font_size_override("font_size", _fs(FS_GLYPH))
	_message.add_theme_font_size_override("font_size", _fs(FS_MSG))
	_clue_title.add_theme_font_size_override("font_size", _fs(FS_CLUE_TITLE))
	_clue_sub.add_theme_font_size_override("font_size", _fs(FS_CLUE_SUB))
	_fit_clue()


func _centered_label(lname: String, font_px: int, color: Color) -> Label:
	var l := Label.new()
	l.name = lname
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.add_theme_font_size_override("font_size", font_px)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
