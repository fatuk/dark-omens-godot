extends CanvasLayer

## Интерактивный каст заклинания. Видна владельцу GameState.casting_spell. Показывает
## карту заклинания (фронт), кубы spell-проверки и кнопки «Бросить кубы»/«Применить».
##
## Поток (как магазин):
##   1. «Бросить кубы» — бросок навыка заклинания (хост, единая проверка CheckFlow).
##   2. Переброс провального куба — тап по кубу: бесплатные от карт → концентрация →
##      улика (общий механизм). Карты руки (веер, Tab) активируются прямо здесь.
##   3. «Применить» — резолв фронта (onPass при успехе) + случайной рубашки; расплату
##      затем показывает cast_result_modal.
##
## Бросок/перебросы — хост-авторитетны в active_check (owner="spell"); модалка лишь
## отражает синкнутое состояние (реактивно по state_changed).
##
## Вид — «лист» по арту cards/spell/spell-cast.png (рамка, магический круг, стол со
## свечами): окно в пропорциях картинки, контент по её зонам (доли листа): заголовок
## наверху, крупная карта на круге, под ней кубы, у нижнего края кнопки.

const _SHEET_TEX: Texture2D = preload("res://assets/cards/spell/spell-cast.png")
const _SHEET_H: float = 940.0  # высота листа; ширина — по аспекту картинки
const _CARD_CENTER := Vector2(0.5, 0.372)  # центр карты (доли листа): на круге, крупно
const _CARD_H_FRAC: float = 0.535  # высота карты — доля высоты листа
const _Z_TITLE := Rect2(0.12, 0.038, 0.76, 0.06)  # посередине между орнаментом рамки и картой
const _Z_DICE := Rect2(0.10, 0.665, 0.80, 0.165)  # сразу под картой
const _Z_BUTTONS := Rect2(0.14, 0.86, 0.72, 0.085)  # у нижнего края

const _FLAME_SHADER := preload("res://assets/shaders/flame_glow.gdshader")

# Живые огни поверх нарисованных свечей (как в лавке): центр/размер — доли листа,
# тёплый additive-глоу flame_glow мерцает и чуть пляшет; фазы разные — не в такт.
# Прямоугольник с запасом под пляс (sway); хвост свечения к краям гасит сам шейдер.
const _FLAMES := [
	{"cx": 0.144, "cy": 0.449, "w": 0.068, "h": 0.115, "intensity": 0.8, "speed": 7.0, "seed": 0.0},
	{
		"cx": 0.913,
		"cy": 0.392,
		"w": 0.068,
		"h": 0.115,
		"intensity": 0.8,
		"speed": 8.0,
		"seed": 11.0
	},
	{
		"cx": 0.865,
		"cy": 0.466,
		"w": 0.046,
		"h": 0.078,
		"intensity": 0.65,
		"speed": 9.5,
		"seed": 23.0
	},
]
const _FLAME_COLOR := Color(1.0, 0.68, 0.34)

# Магическая аура за картой: фиолетовые языки лижут края карты наружу (arcane_aura).
const _AURA_SHADER := preload("res://assets/shaders/arcane_aura.gdshader")
# Крутятся в панели тюнинга (Ctrl+M, секция «ОКНО КАСТА — АУРА»); найденное запекается.
static var AURA_INTENSITY: float = 0.85
static var AURA_SPEED: float = 0.55
static var AURA_RISE: float = 0.35  # тяга языков вверх
static var AURA_REACH: float = 150.0  # px: как далеко от края карты достают языки
static var AURA_DENSITY: float = 0.42  # порог языков: ниже — гуще
static var AURA_SWIRL: float = 2.2  # закрутка

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel

var _sheet: Control  # лист: фон-картинка + зоны контента (пересобираются в _build)
var _aura: ColorRect  # магическая аура за картой (параметры — static AURA_*)

var _sig: String = ""  # подпись текущего каста (перестраиваем карту только при смене)
var _last_dice: Array = []
var _last_can: bool = false
var _last_nonce: int = 0  # метка последнего отрисованного переброса (CheckFlow.reroll_nonce)

var _dice_box: HBoxContainer
var _tray: DiceTray
var _roll_btn: Button
var _apply_btn: Button


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("cast_check_modal")  # панель тюнинга переприменяет ауру на лету
	_build_sheet()
	GameState.state_changed.connect(_refresh)
	_refresh()


# Панель без своей рамки — её место занимает лист-картинка в пропорциях арта.
func _build_sheet() -> void:
	_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var size: Vector2 = Vector2(
		_SHEET_H * _SHEET_TEX.get_width() / _SHEET_TEX.get_height(), _SHEET_H
	)
	_panel.custom_minimum_size = size
	_sheet = Control.new()
	_sheet.name = "Sheet"
	_sheet.custom_minimum_size = size
	_panel.add_child(_sheet)
	var bg := TextureRect.new()
	bg.name = "Background"
	bg.texture = _SHEET_TEX
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.clip_contents = true  # аура не вылезает за лист (на заголовок и рамку — можно)
	_sheet.add_child(bg)
	_build_flames(bg, size)
	_build_aura(bg, size)


# Аура — прямоугольник, центрированный на карте с запасом AURA_REACH; ребёнок фона —
# под картой (она закрывает середину) и переживает пересборку листа.
func _build_aura(bg: Control, _size: Vector2) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = _AURA_SHADER
	_aura = ColorRect.new()
	_aura.name = "MagicAura"
	_aura.color = Color.WHITE  # цвет считает шейдер
	_aura.material = mat
	_aura.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(_aura)
	apply_tuning()


## Переприменить параметры ауры (static AURA_*) — зовёт панель тюнинга.
func apply_tuning() -> void:
	if not is_instance_valid(_aura):
		return
	var card_size: Vector2 = _card_size()
	var rect_size: Vector2 = card_size + Vector2.ONE * AURA_REACH * 2.0
	var sheet: Vector2 = _sheet.custom_minimum_size
	_aura.size = rect_size
	_aura.position = Vector2(sheet.x * _CARD_CENTER.x, sheet.y * _CARD_CENTER.y) - rect_size * 0.5
	var mat := _aura.material as ShaderMaterial
	mat.set_shader_parameter("rect_px", rect_size)
	mat.set_shader_parameter("card_half_px", card_size * 0.5)
	mat.set_shader_parameter("reach_px", AURA_REACH)
	mat.set_shader_parameter("intensity", AURA_INTENSITY)
	mat.set_shader_parameter("speed", AURA_SPEED)
	mat.set_shader_parameter("rise", AURA_RISE)
	mat.set_shader_parameter("threshold", AURA_DENSITY)
	mat.set_shader_parameter("swirl", AURA_SWIRL)


# Размер карты заклинания в круге (общий для ауры и самой карты).
func _card_size() -> Vector2:
	var card_h: float = _SHEET_H * _CARD_H_FRAC
	return Vector2(card_h * GameCard.ASPECT, card_h)


# Мерцающий глоу над каждой свечой арта — дети фона: живут под контентом и
# переживают пересборку листа (_build чистит всё, кроме фона).
func _build_flames(bg: Control, size: Vector2) -> void:
	for f_v: Variant in _FLAMES:
		var f: Dictionary = f_v
		var mat := ShaderMaterial.new()
		mat.shader = _FLAME_SHADER
		mat.set_shader_parameter("glow_color", _FLAME_COLOR)
		mat.set_shader_parameter("intensity", f.intensity)
		mat.set_shader_parameter("flicker_speed", f.speed)
		mat.set_shader_parameter("seed", f.seed)
		var glow := ColorRect.new()
		glow.name = "Flame"
		glow.color = Color.WHITE  # цвет считает шейдер
		glow.material = mat
		glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sz := Vector2(float(f.w) * size.x, float(f.h) * size.y)
		glow.size = sz
		glow.position = Vector2(float(f.cx) * size.x, float(f.cy) * size.y) - sz * 0.5
		bg.add_child(glow)


# Зона листа по долям (x, y, w, h ∈ 0..1).
func _zone(zname: String, r: Rect2) -> Control:
	var c := Control.new()
	c.name = zname
	c.anchor_left = r.position.x
	c.anchor_top = r.position.y
	c.anchor_right = r.position.x + r.size.x
	c.anchor_bottom = r.position.y + r.size.y
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_child(c)
	return c


# ── Доступ к стейту ───────────────────────────────────────────────────────────


# Активный каст этого игрока (иначе {}).
func _cast() -> Dictionary:
	var cs: Dictionary = GameState.casting_spell
	return cs if String(cs.get("pid", "")) == _my_id() else {}


# Активная проверка, если она spell-проверка (иначе {}).
func _chk() -> Dictionary:
	var c: Dictionary = GameState.active_check
	return c if String(c.get("owner", "")) == "spell" else {}


func _my_id() -> String:
	return String(GameState.my_player().get("user_id", ""))


func _rolled() -> bool:
	return bool(_chk().get("rolled", false))


# Доступен ли «перебросить все провальные кубы разом» (Счастливый талисман).
func _reroll_all_available() -> bool:
	if not _rolled():
		return false
	var c: Dictionary = _chk()
	return int(c.get("reroll_all_allowance", 0)) - int(c.get("reroll_all_used", 0)) > 0


# ── Обновление ────────────────────────────────────────────────────────────────


func _refresh() -> void:
	var cs: Dictionary = _cast()
	var casting: bool = not cs.is_empty()
	UIStyle.modal_set_visible(_root, _panel, casting)
	if not casting:
		_sig = ""
		_last_dice = []
		return
	var sig: String = "%s|%d" % [String(cs.get("spell_id", "")), int(cs.get("item_index", -1))]
	if sig != _sig:
		_sig = sig
		_last_dice = []
		_build(cs)
	_render_dice()
	_update_buttons()


func _build(cs: Dictionary) -> void:
	for c in _sheet.get_children():
		if c.name != "Background":
			_sheet.remove_child(c)
			c.queue_free()
	_tray = null

	var spell: Dictionary = SpellCatalog.by_id(String(cs.get("spell_id", "")))
	var title_zone := _zone("TitleZone", _Z_TITLE)
	# Стандартный орнаментальный заголовок: шеврон · «Чтение заклинания» · шеврон.
	var title := UIStyle.ornate_title("CAST_TITLE", UIStyle.MODAL_FS_TITLE, UIColors.ACCENT)
	title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title_zone.add_child(title)

	# Карта заклинания (фронт) — в центре магического круга.
	var card_size: Vector2 = _card_size()
	var card := GameCard.new()
	card.name = "SpellCard"
	card.custom_minimum_size = card_size
	card.size = card_size
	card.position = (
		Vector2(_sheet.custom_minimum_size.x * _CARD_CENTER.x, _SHEET_H * _CARD_CENTER.y)
		- card_size * 0.5
	)
	card.set_font_scale(card_size.x / HandCarousel.CARD_W)  # текст в пропорции, как в веере
	var spell_payload: Dictionary = SpellCatalog.card_payload(spell)
	card.set_card(spell_payload)
	_sheet.add_child(card)
	CardPreview.attach_click(card, spell_payload)

	# Кубы spell-проверки — на столе под кругом.
	var dice_zone := _zone("DiceZone", _Z_DICE)
	_dice_box = HBoxContainer.new()
	_dice_box.name = "DiceBox"
	_dice_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_dice_box.add_theme_constant_override("separation", 6)
	_dice_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dice_zone.add_child(_dice_box)

	# Кнопки: бросок · применить.
	var btn_zone := _zone("ButtonsZone", _Z_BUTTONS)
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 16)
	btns.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn_zone.add_child(btns)

	_roll_btn = UIStyle.button("CAST_ROLL", UIColors.ACCENT)
	_roll_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roll_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER  # родная высота: зона выше кнопки
	_roll_btn.pressed.connect(_on_roll)
	btns.add_child(_roll_btn)

	_apply_btn = UIStyle.button("CAST_APPLY", UIColors.ACCENT)
	_apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER  # родная высота: зона выше кнопки
	_apply_btn.pressed.connect(_on_apply)
	btns.add_child(_apply_btn)


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
	_tray.set_roller(_my_id())  # Благословение/Проклятие сдвигают порог подсветки
	if not _rolled():
		if not _last_dice.is_empty():
			_last_dice = []
		var pb: Dictionary = _pool()
		_tray.set_pool_marks(int(pb["bonus"]), int(pb["blocked"]))
		_tray.show_pending(int(pb["pool"]), String(_chk().get("skill", "")))
		return
	var dice: Array = _chk().get("dice", [])
	var can: bool = GameState.dice.can_reroll()
	var nonce: int = int(_chk().get("reroll_nonce", 0))
	if dice != _last_dice:
		var prev: Array = _last_dice
		var diff: int = _single_diff(prev, dice)
		_last_dice = dice.duplicate()
		if prev.is_empty():
			_tray.play_roll(dice, can)  # свежий бросок — спин
		elif diff >= 0:
			_tray.reroll_die(diff, int(dice[diff]), can)  # переброс одного — крутится он
		elif prev.size() == dice.size():
			_tray.play_roll(dice, can)  # несколько изменилось (reroll-all) — спин всех
		else:
			_tray.show_roll(dice, can)  # размер изменился (докинули кубы) — статикой
		_last_can = can
		_last_nonce = nonce
	elif nonce != _last_nonce:
		# Переброс в ТО ЖЕ значение: массив не изменился, но nonce вырос — крутим
		# затронутый куб, иначе клик «съеденный» (фокус ушёл, куб не дёрнулся).
		var ri: int = int(_chk().get("reroll_index", -1))
		if ri >= 0 and ri < dice.size():
			_tray.reroll_die(ri, int(dice[ri]), can)
		_last_can = can
		_last_nonce = nonce
	elif can != _last_can:
		_tray.show_roll(dice, can)  # та же раскладка, сменилась кликабельность
		_last_can = can


# Индекс единственного отличия наборов (-1 если 0 или >1 отличий / разные размеры).
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


# Пул кубов навыка каста до броска (для рубашек): навык + skill_mods + modifier + доп.кубы.
# Разбор пула: {pool, bonus, blocked} — см. DiceTray.set_pool_marks.
func _pool() -> Dictionary:
	var c: Dictionary = _chk()
	var skill: String = String(c.get("skill", "lore"))
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get(skill, 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get(skill, 0))
	var extra: int = Dice.pre_roll_bonus(c.get("active_mods", []), skill)
	return Dice.pool_breakdown(base, mods, int(c.get("modifier", 0)), extra)


# ── Действия ───────────────────────────────────────────────────────────────────


func _on_roll() -> void:
	if _rolled():
		# Повторное нажатие после броска = «перебросить все кубы» (Талисман).
		if _reroll_all_available():
			GameState.act(RelayActions.REROLL_ALL)
		return
	_roll_btn.disabled = true  # хост катит и пришлёт active_check синком
	GameState.act(RelayActions.SPELL_CAST_ROLL)


func _on_die_clicked(index: int) -> void:
	if not GameState.dice.can_reroll():
		return
	GameState.dice.tap(index)  # маршрутится по owner="spell" → SPELL_CAST_REROLL


func _on_apply() -> void:
	_apply_btn.disabled = true
	GameState.act(RelayActions.SPELL_CAST_APPLY)  # резолв; расплату покажет cast_result_modal


func _update_buttons() -> void:
	if is_instance_valid(_roll_btn):
		if _rolled() and _reroll_all_available():
			_roll_btn.text = "ENCOUNTER_REROLL_ALL"
			_roll_btn.disabled = false
		else:
			_roll_btn.text = "CAST_ROLL"
			_roll_btn.disabled = _rolled()
	if is_instance_valid(_apply_btn):
		_apply_btn.disabled = not _rolled()  # применить можно только после броска
