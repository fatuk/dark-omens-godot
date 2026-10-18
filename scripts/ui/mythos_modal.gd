extends CanvasLayer

## Окно карты Мифов. Видно ВСЕМ игрокам в фазе mythos после того, как хост
## вытянул карту (GameState.current_mythos непустая). По кнопке «Прочитал»
## событие через relay уходит хосту, который применяет эффекты и стартует
## следующий раунд (см. MythosFlow._apply_resolve).
##
## Раскладка — разворот: слева арт карты во всю высоту (с внутренней тенью, чтобы
## картинка «утопала» в рамку), справа — имя, flavor, орнаментальный разделитель,
## текст правил и кнопка внизу. Арт — res://assets/mythos/<sourceId>.png (id
## карточки в CMS); нет файла — левая часть остаётся тёмной под той же тенью.
##
## Контент строится кодом — паттерн settings_dialog / create_room_dialog.

@onready var _root: ColorRect = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

const _INNER_SHADOW := preload("res://assets/shaders/inner_shadow.gdshader")
const _ART_DIR := "res://assets/mythos/"

# Раскладка разворота — крутится в панели тюнинга (Ctrl+M, секция «МИФЫ»): static
# var, а не const, панель правит их на живой игре и зовёт apply_tuning у открытого
# окна (группа "mythos_modal"). Найденное значение запекается сюда же.
static var PANEL_W: float = 1240.0
static var PANEL_H: float = 800.0
static var ART_W: float = 710.0  # ширина арта; текст — остаток
static var ART_RADIUS: float = 46.0  # скругление углов рамки арта
static var TEXT_PAD_X: float = 40.0  # поля текстовой колонки по бокам
static var TEXT_PAD_TOP: float = 34.0
static var TEXT_PAD_BOTTOM: float = 20.0
static var TEXT_SEP: float = 22.0  # интервал между блоками колонки
static var TITLE_FS: float = UIStyle.MODAL_FS_HERO
static var FLAVOR_FS: float = UIStyle.MODAL_FS_BODY
static var TEXT_FS: float = UIStyle.MODAL_FS_BODY
# Внутренняя тень арта (uniform'ы inner_shadow.gdshader): доли стороны + плотность.
static var SHADOW_ALPHA: float = 0.2
static var SHADOW_LEFT: float = 0.08
static var SHADOW_RIGHT: float = 0.2
static var SHADOW_TOP: float = 0.1
static var SHADOW_BOTTOM: float = 0.12
static var SHADOW_CURVE: float = 1.8

var _art: TextureRect
var _art_pane: Panel
var _art_mask: StyleBoxFlat
var _shadow_mat: ShaderMaterial
var _text_margin: MarginContainer
var _text_col: VBoxContainer
var _title_lbl: Label
var _flavor_lbl: Label
var _text_lbl: Label
var _eff_header: Label
var _eff_sep: Control  # разделитель над блоком эффектов (прячется вместе с ним)
var _eff_box: VBoxContainer
var _next_btn: Button

# Кеш ключа текущей карты — чтобы не пересобирать UI на каждый _refresh,
# если карта не сменилась.
var _last_card_key: String = ""

# Режим «перечитать»: показываем GameState.last_mythos (последний вытянутый миф)
# только для чтения — без гейта «Прочитал», с кнопкой «Закрыть». Живая карта
# (фаза Мифов) всегда важнее и перебивает просмотр.
var _review: bool = false


func _ready() -> void:
	add_to_group("mythos_modal")  # панель тюнинга переприменяет раскладку на лету
	UIStyle.style_modal_panel(_panel)
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


# ── Сборка ────────────────────────────────────────────────────────────────────


func _build() -> void:
	_vbox.add_theme_constant_override("separation", 0)

	var split := HBoxContainer.new()
	split.name = "Split"
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 0)
	_vbox.add_child(split)
	split.add_child(_build_art_pane())

	var seam := ColorRect.new()  # тонкий шов между артом и текстом
	seam.name = "Seam"
	seam.custom_minimum_size = Vector2(2, 0)
	seam.color = UIStyle.MODAL_LINE_COLOR
	split.add_child(seam)

	_text_margin = MarginContainer.new()
	_text_margin.name = "TextPane"
	_text_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(_text_margin)
	var col := VBoxContainer.new()
	col.name = "Column"
	_text_margin.add_child(col)
	_text_col = col

	_title_lbl = UIStyle.modal_title("", UIColors.DANGER)
	col.add_child(_title_lbl)

	_flavor_lbl = _centered_label("Flavor", UIStyle.MODAL_FS_BODY, UIColors.TEXT)
	col.add_child(_flavor_lbl)

	col.add_child(_ornament_divider())

	_text_lbl = _centered_label("Text", UIStyle.MODAL_FS_BODY, UIColors.TEXT)
	col.add_child(_text_lbl)

	# Запасной список эффектов — только у карт без текста правил (см. _show_card).
	UIStyle.separator(col)
	_eff_sep = col.get_child(col.get_child_count() - 1)

	_eff_header = Label.new()
	_eff_header.name = "EffectsHeader"
	_eff_header.text = tr("MYTHOS_EFFECTS_HEADER")
	_eff_header.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_HINT)
	_eff_header.add_theme_color_override("font_color", UIColors.MUTED)
	col.add_child(_eff_header)

	_eff_box = VBoxContainer.new()
	_eff_box.name = "Effects"
	_eff_box.add_theme_constant_override("separation", 4)
	col.add_child(_eff_box)

	var spacer := Control.new()  # кнопка прижата к низу колонки
	spacer.name = "Spacer"
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)

	_next_btn = UIStyle.button(tr("MYTHOS_BTN_NEXT"), UIColors.DANGER)
	_next_btn.name = "NextBtn"
	_next_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_next_btn.pressed.connect(_on_next)
	col.add_child(_next_btn)
	apply_tuning()


## Применить настраиваемые размеры/тень к собранному окну. Зовёт и панель тюнинга
## (группа "mythos_modal") — правка видна сразу, без пересборки.
func apply_tuning() -> void:
	if not is_instance_valid(_art_pane):
		return
	_panel.custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	_art_pane.custom_minimum_size = Vector2(ART_W, 0)
	_art_mask.set_corner_radius_all(int(ART_RADIUS))
	_text_margin.add_theme_constant_override("margin_left", int(TEXT_PAD_X))
	_text_margin.add_theme_constant_override("margin_right", int(TEXT_PAD_X))
	_text_margin.add_theme_constant_override("margin_top", int(TEXT_PAD_TOP))
	_text_margin.add_theme_constant_override("margin_bottom", int(TEXT_PAD_BOTTOM))
	_text_col.add_theme_constant_override("separation", int(TEXT_SEP))
	_title_lbl.add_theme_font_size_override("font_size", int(TITLE_FS))
	_flavor_lbl.add_theme_font_size_override("font_size", int(FLAVOR_FS))
	_text_lbl.add_theme_font_size_override("font_size", int(TEXT_FS))
	_shadow_mat.set_shader_parameter("shadow_color", Color(0, 0, 0, SHADOW_ALPHA))
	_shadow_mat.set_shader_parameter("size_left", SHADOW_LEFT)
	_shadow_mat.set_shader_parameter("size_right", SHADOW_RIGHT)
	_shadow_mat.set_shader_parameter("size_top", SHADOW_TOP)
	_shadow_mat.set_shader_parameter("size_bottom", SHADOW_BOTTOM)
	_shadow_mat.set_shader_parameter("curve", SHADOW_CURVE)


# Левая половина разворота: арт во всю высоту (обрезка «по покрытию») и поверх —
# внутренняя тень, чтобы края картинки уходили в рамку и в текстовую панель.
# Панель со скруглёнными углами — маска: арт и тень обрезаются по её форме.
func _build_art_pane() -> Control:
	var pane := Panel.new()
	pane.name = "ArtPane"
	_art_pane = pane
	var mask := StyleBoxFlat.new()
	mask.bg_color = Color(0.045, 0.045, 0.04)  # в тон фона модалки — видно, пока арта нет
	mask.anti_aliasing = true
	_art_mask = mask
	pane.add_theme_stylebox_override("panel", mask)
	pane.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	_art = TextureRect.new()
	_art.name = "Art"
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pane.add_child(_art)
	var shadow := ColorRect.new()
	shadow.name = "InnerShadow"
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var mat := ShaderMaterial.new()
	mat.shader = _INNER_SHADOW
	shadow.material = mat
	_shadow_mat = mat
	pane.add_child(shadow)
	return pane


func _centered_label(node_name: String, font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.name = node_name
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return lbl


# Разделитель flavor/правила: тонкая линия с ромбом по центру.
func _ornament_divider() -> Control:
	var row := HBoxContainer.new()
	row.name = "Divider"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	for i in range(3):
		if i == 1:
			var gem := Label.new()
			gem.name = "Gem"
			gem.text = "◇"
			gem.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_HINT)
			gem.add_theme_color_override("font_color", UIColors.ACCENT)
			row.add_child(gem)
			continue
		var line := ColorRect.new()
		line.name = "Line"
		line.color = Color(UIColors.ACCENT, 0.45)
		line.custom_minimum_size = Vector2(0, 1)
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(line)
	return row


# ── Отрисовка по стейту ───────────────────────────────────────────────────────


# Открыть последний вытянутый миф в режиме «перечитать» (только чтение).
# Нет last_mythos — тихо ничего не делаем. Живая карта Мифов перебьёт просмотр.
func open_review() -> void:
	if (GameState.last_mythos as Dictionary).is_empty():
		return
	_review = true
	_refresh()


func _refresh() -> void:
	# Живая карта Мифов важнее просмотра — она требует действия («Прочитал»).
	var live: bool = GameState.phase == Phases.MYTHOS and not GameState.current_mythos.is_empty()
	if live:
		_review = false
		_show_card(GameState.current_mythos)
		_update_next_btn()
		return
	if _review and not (GameState.last_mythos as Dictionary).is_empty():
		_show_card(GameState.last_mythos)
		_next_btn.disabled = false
		_next_btn.text = tr("MYTHOS_BTN_CLOSE")
		return
	# Показывать нечего.
	UIStyle.modal_set_visible(_root, _panel, false)
	_last_card_key = ""


# Отрисовать карту (живую или на перечитку). Пересобираем UI только на смене
# карты (ключ = name); первый показ проигрывает звук появления.
func _show_card(card: Dictionary) -> void:
	UIStyle.modal_set_visible(_root, _panel, true)
	var card_key: String = String(card.get("name", ""))
	if card_key == _last_card_key:
		return
	_last_card_key = card_key
	SfxManager.play(SfxManager.SFX_MYTHOS_START)  # звук появления карты мифа
	_title_lbl.text = String(card.get("name", tr("MYTHOS_TITLE_FALLBACK")))
	_flavor_lbl.text = String(card.get("flavorText", ""))
	_flavor_lbl.visible = not _flavor_lbl.text.is_empty()
	_art.texture = _art_for(card)
	_text_lbl.text = String(card.get("text", ""))
	_text_lbl.visible = not _text_lbl.text.is_empty()
	# Есть текст правил — он и объясняет, что случится; машинный список эффектов
	# дублировал бы его. Список — запасной вариант для карт без текста (шаблонные
	# заглушки колоды, сгенерированный контент).
	var show_effects: bool = not _text_lbl.visible
	_eff_sep.visible = show_effects
	_eff_header.visible = show_effects
	_eff_box.visible = show_effects
	if show_effects:
		_render_effects(card.get("onDraw", []))


# Арт карты по её id в CMS (sourceId); нет id или файла — null (тёмная левая часть).
func _art_for(card: Dictionary) -> Texture2D:
	var sid: String = String(card.get("sourceId", ""))
	if sid.is_empty():
		return null
	var path: String = _ART_DIR + sid + ".png"
	return load(path) as Texture2D if ResourceLoader.exists(path) else null


# Кнопка «Прочитал»: пока я не отметился — активна. После — заблокирована и
# показывает прогресс «Ждём остальных (X/N)». Миф резолвится, когда прочитали все.
func _update_next_btn() -> void:
	var me: String = String(GameState.my_player().get("user_id", ""))
	var read: Array = GameState.mythos_read
	var i_read: bool = read.has(me)
	_next_btn.disabled = i_read
	if i_read:
		_next_btn.text = tr("MYTHOS_BTN_WAITING") % [read.size(), _connected_count()]
	else:
		_next_btn.text = tr("MYTHOS_BTN_NEXT")


func _connected_count() -> int:
	var n: int = 0
	for uid_v: Variant in GameState.players:
		if bool(GameState.players[uid_v].get("connected", true)):
			n += 1
	return n


func _render_effects(effects: Array) -> void:
	for child in _eff_box.get_children():
		child.queue_free()
	if effects.is_empty():
		var lbl := Label.new()
		lbl.text = tr("MYTHOS_NO_EFFECTS")
		lbl.add_theme_color_override("font_color", UIColors.MUTED)
		lbl.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_HINT)
		_eff_box.add_child(lbl)
		_eff_header.visible = false
		return
	_eff_header.visible = true
	for i in range(effects.size()):
		var lbl := Label.new()
		lbl.name = "Label"
		lbl.text = "• " + EffectManifest.describe(effects[i])
		lbl.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_HINT)
		lbl.add_theme_color_override("font_color", UIColors.TEXT)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_eff_box.add_child(lbl)


# ── Кнопка ────────────────────────────────────────────────────────────────────


func _on_next() -> void:
	if _review:
		_review = false  # закрыть просмотр
		_refresh()
		return
	_next_btn.disabled = true  # защита от двойного клика / двойного relay
	GameState.act(RelayActions.RESOLVE_MYTHOS)
