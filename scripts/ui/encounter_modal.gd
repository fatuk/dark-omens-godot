extends CanvasLayer

## Окно встречи. Видно активному игроку в фазе encounter.
##
## Чистое отражение GameState.current_encounter — состояние выводится из
## синкнутых данных:
##   пусто           → карта генерится (загрузка);
##   карта           → текст встречи + кнопка броска;
##   есть resolution → кубики, исход, кнопка «Завершить».
##
## Бросок проверки и эффекты onSuccess/onFailure — авторитетно у хоста
## (act RESOLVE_ENCOUNTER); окно лишь показывает синкнутый результат.

@onready var _root: Control = $Root
@onready var _panel: Control = %Panel  # карточка ФИКС-размера (не растёт под контент)
@onready var _vbox: VBoxContainer = %VBox
var _title: Label  # заголовок с шевронами (ставится в _ready вместо плоского %Title)
var _place: Label  # где мы: имя Иного мира в верхней полосе карточки (создаётся в _ready)
@onready var _main_text: Label = %MainText
@onready var _roll_btn: Button = %RollBtn
@onready var _dice: Label = %Dice
@onready var _outcome: Label = %Outcome
@onready var _finish_btn: Button = %FinishBtn

# Ряд кубиков (DiceTray) — создаётся кодом над строкой _dice.
var _dice_holder: VBoxContainer
# Контейнер кнопок интерактивного выбора (choice в эффектах) — создаётся кодом.
var _choice_holder: VBoxContainer
var _tray: DiceTray  # единый лоток, создаётся лениво и переиспользуется
var _last_dice: Array = []  # последний показанный бросок (спин — только на свежем)
var _last_nonce: int = 0  # метка последнего отрисованного переброса (CheckFlow.reroll_nonce)
var _last_can: bool = false  # последняя кликабельность кубов (обновление без смены кубов)
var _last_add: bool = false  # последняя доступность +1 (addToDie) — тоже меняет кликабельность
var _pending_n: int = -1  # сколько рубашек показано до броска
# Пока есть перебросы (концентрация), исход ПРОВАЛА скрыт, чтобы не спойлить до
# решения перебросить/принять. true → игрок «принял» (раскрыл) текущий провал.
var _revealed: bool = false

# Анимации: карточка «выплывает» при показе; текст исхода плавно проявляется.
const _OUTCOME_FADE: float = 0.35  # проявление текста исхода
const _OUTCOME_GROW: float = 0.3  # раздвигание блока под него
var _outcome_shown: bool = false  # исход уже проявлен (фейд — только на появлении)
var _outcome_tween: Tween = null
# Обойма исхода: Label в VBox нельзя сжать ниже его содержимого, поэтому высоту
# анимируем не у него, а у клипающего контейнера вокруг. Пока её нет, появление
# исхода мгновенно раздвигало блок — текст встречи скачком уезжал вверх.
var _outcome_slot: Control

# Смена узла ветвящейся встречи (врата/Тайна): stage 0 → ветка успеха/провала.
# Узлы — разные сцены одной истории, поэтому меняем их не подменой текста, а
# перекрёстным фейдом. _stage_key — отрисованный сейчас узел, _stage_fading —
# идёт затухание старого (в это время текст НЕ трогаем, иначе гасили бы уже новый).
const _STAGE_FADE_OUT: float = 0.18
const _STAGE_FADE_IN: float = 0.3
var _stage_key: String = ""
var _stage_fading: bool = false
var _stage_tween: Tween = null

# Арт-подложка карточки встречи по типу локации (рамка/пропы запечены в ассет).
const _BG_CITY: Texture2D = preload("res://assets/encounter/city.png")
const _BG_SEA: Texture2D = preload("res://assets/encounter/sea.png")
const _BG_WILDERNESS: Texture2D = preload("res://assets/encounter/wilderness.png")
# Резной баннер-плашка под строкой проверки (9-patch: концы не растягиваются).

# Карточка встречи — центрированная, ~70% ширины экрана, аспект арта 3:2 (2048/3072).
# Контент — во внутренних отступах (доли от размера карточки), в нижней «тёмной» зоне
# арта под сценой; поэтому верхний отступ большой.
const _CARD_WIDTH_FRAC: float = 0.75
const _CARD_ASPECT: float = 2048.0 / 3072.0
const _PAD_X_FRAC: float = 0.09  # боковые отступы (доля ширины карточки)
const _PAD_TOP_FRAC: float = 0.05  # верхний инсет (текст всплывает сюда при нехватке места)
const _PAD_BOTTOM_FRAC: float = 0.07
const _BTN_MIN_WIDTH: float = 380.0  # кнопки — фикс. ширина (центр), не на всю карточку
const _TEXT_WIDTH_FRAC: float = 0.65  # ширина колонки текста (доля карточки) — читаемая, уже полной
# Высота подписи «где мы» — доля высоты карточки от её верха. Метится в полосу под
# «глазом» рамки и НАД резной гирляндой, поэтому меньше верхнего отступа контента.
const _PLACE_TOP_FRAC: float = 0.018
# Рамка запечена в арт и у миров нарисована по-своему: у Юггота «глаз» опущен, и
# на общей высоте подпись садилась прямо на него. Мир, которого тут нет, берёт
# общую высоту — новый арт достаточно положить в папку, как и раньше.
const _PLACE_TOP_BY_WORLD := {"Yuggoth": 0.055}

var _bg: TextureRect  # арт-фон карточки (меняем текстуру по типу локации)

# Сцены Иных миров лежат отдельно и подхватываются по имени мира — см. _world_texture.
const _OTHER_WORLD_DIR: String = "res://assets/other-world/"

var _world_bg_cache: Dictionary = {}  # мир → Texture2D|null, чтобы не дёргать диск
var _warned_card: String = ""  # id карты, по которой уже ругались на пустой мир
var _card_h: float = 0.0  # высота карточки из _resize_card — для высоты подписи
var _place_frac: float = _PLACE_TOP_FRAC  # доля высоты у ТЕКУЩЕГО мира

# Навык → ключ перевода для подписи проверки.


func _ready() -> void:
	_build_background()  # арт-подложка карточки + прозрачная панель контента
	_title = _install_ornate_title()  # заголовок с орнаментальными шевронами
	UIStyle.style_button(_roll_btn)
	UIStyle.style_button(_finish_btn)
	# Кнопки не тянем на всю ширину карточки — центрируем на естественной ширине.
	for b: Button in [_roll_btn, _finish_btn]:
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.custom_minimum_size.x = _BTN_MIN_WIDTH
	# Размеры — ступени лесенки UIStyle (в сцене не хардкодим): повествование и исход
	# читаются как основной текст, строка успехов — подпись. Карточка встречи — самая
	# крупная в игре (три четверти экрана) и текста на ней больше всего, поэтому вся
	# группа стоит на ступень ВЫШЕ обычной модалки: повествование и исход как LEAD,
	# строка успехов как BODY. Заголовок остаётся TITLE — над ним ещё имя мира (HERO),
	# и поднимать его некуда без слипания верхушки.
	_main_text.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_LEAD)
	_outcome.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_LEAD)
	_dice.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_BODY)
	_main_text.add_theme_color_override("font_color", UIColors.TEXT)
	# Текст (основной + исход) — узкой колонкой по центру, не на всю ширину карточки.
	# Ширина задаётся в _resize_card; SHRINK_CENTER центрирует колонку, автоперенос — по ней.
	_main_text.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_outcome.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_dice.add_theme_color_override("font_color", UIColors.MUTED)

	# Контейнер ряда кубиков — над строкой _dice (успехи/концентрация).
	_dice_holder = VBoxContainer.new()
	_dice_holder.name = "DiceHolder"
	_dice_holder.alignment = BoxContainer.ALIGNMENT_CENTER
	var vbox: Node = _dice.get_parent()
	vbox.add_child(_dice_holder)
	vbox.move_child(_dice_holder, _roll_btn.get_index())  # кубы НАД кнопкой броска
	_dice_holder.visible = false

	# Контейнер кнопок интерактивного выбора — под текстом, на месте кнопки броска.
	_choice_holder = VBoxContainer.new()
	_choice_holder.name = "ChoiceHolder"
	_choice_holder.add_theme_constant_override("separation", 8)
	vbox.add_child(_choice_holder)
	vbox.move_child(_choice_holder, _roll_btn.get_index())
	_choice_holder.visible = false

	# Исход (успех/провал) — сразу ПОД основным текстом (продолжением), своим цветом.
	vbox.move_child(_outcome, _main_text.get_index() + 1)
	_outcome_slot = Control.new()
	_outcome_slot.name = "OutcomeSlot"
	_outcome_slot.clip_contents = true  # растём от нуля — лишнее прячем, а не толкаем
	_outcome_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_outcome_slot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var out_at: int = _outcome.get_index()
	vbox.add_child(_outcome_slot)
	vbox.move_child(_outcome_slot, out_at)
	vbox.remove_child(_outcome)
	_outcome_slot.add_child(_outcome)
	_outcome.set_anchors_preset(Control.PRESET_TOP_WIDE)
	# Прячут исход из многих мест — вместо правки каждого схлопываем обойму по сигналу.
	_outcome.visibility_changed.connect(_on_outcome_visibility)
	# Верхняя распорка (EXPAND): блок «текст + нижняя группа» прижат к НИЗУ карточки.
	# Нижняя группа (проверка · кубы · кнопка) стоит у низа НЕПОДВИЖНО; при длинном
	# тексте распорка сжимается и ТЕКСТ поднимается вверх (заходя на верхний арт), а не
	# толкает кубы/кнопку вниз. Переполнение сверху клипается (_panel.clip_contents).
	var top_spacer := Control.new()
	top_spacer.name = "TopSpacer"
	top_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(top_spacer)
	vbox.move_child(top_spacer, 0)  # распорка — самой первой, над всем контентом

	# Где мы находимся — имя Иного мира в самой верхней полосе карточки, под «глазом»
	# рамки. Живёт НЕ в VBox, а прямо на карточке по якорям: у VBox свой верхний
	# отступ под контент, и внутри него подпись не поднять выше, чем он начинается.
	# Точная высота — _PLACE_TOP_FRAC в _resize_card.
	_place = UIStyle.label("", UIStyle.MODAL_FS_HERO, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_place.name = "Place"
	_place.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_place.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Верх арта у миров разный — у Страны снов там светлое небо, у Юггота тьма.
	# Приглушённый цвет там терялся, поэтому акцентный + тёмная тень под буквами
	# (тот же приём, что у подписей на карточке сыщика).
	_place.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_place.add_theme_constant_override("shadow_offset_x", 1)
	_place.add_theme_constant_override("shadow_offset_y", 1)
	_place.add_theme_constant_override("shadow_outline_size", 3)
	_place.visible = false
	_panel.add_child(_place)  # поверх арта, но вне потока VBox
	_resize_card()  # подпись только что появилась — расставим её по высоте

	_roll_btn.pressed.connect(_on_roll_pressed)
	_finish_btn.pressed.connect(_on_finish_pressed)

	GameState.state_changed.connect(_refresh)
	_refresh()


# Заменяет плоский %Title орнаментальным заголовком (шеврон · имя · шеврон).
# Возвращает внутренний Label — в него пишем текст встречи (_title.text = …).
func _install_ornate_title() -> Label:
	var placeholder: Label = %Title
	var ot: HBoxContainer = UIStyle.ornate_title("", UIStyle.MODAL_FS_TITLE, UIColors.ACCENT)
	var vbox: Node = placeholder.get_parent()
	var at: int = placeholder.get_index()
	vbox.add_child(ot)
	vbox.move_child(ot, at)
	placeholder.queue_free()
	return ot.get_node("Title") as Label


# Фон карточки = арт city.png (TextureRect позади контента): рамка/пропы запечены в
# ассет. Карточка (_panel, обычный Control) — ФИКС-размера, поэтому контент её высоту
# не меняет (лишнее клипается). VBox с контентом — по якорям full-rect с отступами
# (в _resize_card). Затемнение вокруг даёт узел Backdrop (в сцене).
func _build_background() -> void:
	_bg = TextureRect.new()
	_bg.name = "Bg"
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED  # карточка 3:2 = аспект арта
	_bg.texture = _BG_CITY
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_bg)
	_panel.move_child(_bg, 0)  # позади VBox с контентом
	get_viewport().size_changed.connect(_resize_card)
	_resize_card()


# Карточка _CARD_WIDTH_FRAC ширины экрана, аспект арта 3:2 — ФИКС-размер (не растёт
# под контент). Отступы контента = доли от карточки → offsets VBox (якоря full-rect),
# чтобы контент лёг в нижнюю «тёмную» зону арта. Пересчёт при ресайзе окна.
func _resize_card() -> void:
	if _panel == null:
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var w: float = vp.x * _CARD_WIDTH_FRAC
	var h: float = w * _CARD_ASPECT
	# Кэп по высоте: при 3:2 широкая карточка выше экрана на 16:9 — ужимаем, сохраняя
	# аспект, чтобы всегда влезала.
	var max_h: float = vp.y * 0.96
	if h > max_h:
		h = max_h
		w = h / _CARD_ASPECT
	_panel.custom_minimum_size = Vector2(w, h)
	_panel.pivot_offset = Vector2(w, h) * 0.5  # масштаб интро — от центра карточки
	_vbox.offset_left = w * _PAD_X_FRAC
	_vbox.offset_right = -w * _PAD_X_FRAC
	_vbox.offset_top = h * _PAD_TOP_FRAC
	_vbox.offset_bottom = -h * _PAD_BOTTOM_FRAC
	# Узкая колонка текста (по центру) — автоперенос по этой ширине.
	var text_w: float = w * _TEXT_WIDTH_FRAC
	_main_text.custom_minimum_size.x = text_w
	_outcome.custom_minimum_size.x = text_w
	if _outcome_slot != null:
		_outcome_slot.custom_minimum_size.x = text_w
		# Колонка стала уже/шире — исход перевёрстан, обойме нужна новая высота. Но не
		# в разгар анимации: там высоту ведёт твин, и снап оборвал бы её на полпути.
		var growing: bool = _outcome_tween != null and _outcome_tween.is_valid()
		if _outcome.visible and not growing:
			_outcome_slot.custom_minimum_size.y = _outcome_height()
			_outcome.offset_bottom = _outcome_slot.custom_minimum_size.y
	# Подпись «где мы» висит на якорях карточки, а не в VBox — двигаем сами.
	_card_h = h
	_position_place()


# Плавное проявление текста исхода (успех/провал) при его добавлении.
func _play_outcome_in() -> void:
	if _outcome_tween != null and _outcome_tween.is_valid():
		_outcome_tween.kill()
	_outcome.modulate.a = 0.0
	# Блок раздвигается вместе с проявлением: обойма растёт от нуля до высоты
	# текста, поэтому текст встречи уезжает вверх плавно, а не скачком.
	var h: float = _outcome_height()
	_outcome.offset_bottom = h  # внутри обоймы Label по якорям — высоту задаём сами
	_outcome_slot.custom_minimum_size.y = 0.0
	_outcome_tween = create_tween()
	_outcome_tween.set_parallel(true)
	_outcome_tween.tween_property(_outcome, "modulate:a", 1.0, _OUTCOME_FADE).set_trans(
		Tween.TRANS_SINE
	)
	(
		_outcome_tween
		. tween_property(_outcome_slot, "custom_minimum_size:y", h, _OUTCOME_GROW)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_OUT)
	)


# Естественная высота текста исхода при текущей ширине колонки.
func _outcome_height() -> float:
	return _outcome.get_combined_minimum_size().y


# Исход спрятали — обойма схлопывается сразу: держать пустое место незачем.
func _on_outcome_visibility() -> void:
	if _outcome_slot == null:
		return
	if not _outcome.visible:
		if _outcome_tween != null and _outcome_tween.is_valid():
			_outcome_tween.kill()
		_outcome_slot.custom_minimum_size.y = 0.0


# Гаснет весь старый узел, включая уже показанный исход; проявляется — только
# заголовок с повествованием: на свежей стадии исход ещё скрыт, и появится он
# своим фейдом (_play_outcome_in), когда осядут кубы.
func _stage_out_nodes() -> Array:
	return [_title.get_parent(), _main_text, _outcome]


func _stage_in_nodes() -> Array:
	return [_title.get_parent(), _main_text]


# Затухание старого узла. По завершении снимаем флаг и просим перерисовку — там
# ключ уже не совпадёт с _stage_key, узел отрисуется заново и проявится.
func _play_stage_out() -> void:
	if _stage_tween != null and _stage_tween.is_valid():
		_stage_tween.kill()
	_stage_fading = true
	_stage_tween = create_tween()
	_stage_tween.set_parallel(true)
	for n: CanvasItem in _stage_out_nodes():
		_stage_tween.tween_property(n, "modulate:a", 0.0, _STAGE_FADE_OUT).set_trans(
			Tween.TRANS_SINE
		)
	_stage_tween.chain().tween_callback(
		func() -> void:
			_stage_fading = false
			_stage_key = ""  # следующий рендер считает узел новым и проявит его
			_refresh()
	)


# Страховка от «карточка осталась прозрачной»: затухание рассчитывает, что за ним
# придёт перерисовка ветвящегося узла, но встреча могла закончиться прямо во время
# фейда — тогда следующий рендер пошёл бы другой веткой, а альфа осталась нулевой.
func _ensure_stage_opaque() -> void:
	if _stage_fading:
		return
	for n: CanvasItem in _stage_out_nodes():
		if n.modulate.a < 1.0:
			n.modulate.a = 1.0


func _play_stage_in() -> void:
	if _stage_tween != null and _stage_tween.is_valid():
		_stage_tween.kill()
	# Исход гасили вместе со старым узлом — вернём ему непрозрачность, иначе он
	# останется невидимым, если покажется без собственного фейда.
	_outcome.modulate.a = 1.0
	for n: CanvasItem in _stage_in_nodes():
		n.modulate.a = 0.0
	_stage_tween = create_tween()
	_stage_tween.set_parallel(true)
	for n: CanvasItem in _stage_in_nodes():
		_stage_tween.tween_property(n, "modulate:a", 1.0, _STAGE_FADE_IN).set_trans(
			Tween.TRANS_SINE
		)


# Арт карточки: за вратами — сцена Иного мира, иначе по типу локации. Заодно
# подписываем верхнюю полосу именем мира — за вратами сыщик не на карте, и понять,
# куда его занесло, больше неоткуда.
func _apply_background() -> void:
	if _bg == null:
		return
	var card: Dictionary = GameState.current_encounter
	var world: String = String(card.get("otherWorld", ""))
	_apply_place(world)
	# Врата без мира — дефект контента (в админке у карточки не проставлена ось
	# world), а не отсутствие арта: молча покажется фон по типу реальной локации.
	# Ругаемся один раз на карту, а не на каждый синк.
	var card_id: String = String(card.get("id", ""))
	if world.is_empty() and String(card.get("kind", "")) == "gate" and card_id != _warned_card:
		_warned_card = card_id
		GameConsole.log("[Встреча] у врат «%s» не указан Иной мир" % _title_text(card))
	var tex: Texture2D = _world_texture(world)
	if tex == null:
		var loc: String = String(GameState.my_player().get("location", ""))
		tex = _bg_texture(GameState.map.type_of(loc))
	if _bg.texture != tex:
		_bg.texture = tex


# Подпись «где мы» в верхней полосе: имя Иного мира. Ключ перевода выводим из имени
# («City of the Great Race» → WORLD_CITY_OF_THE_GREAT_RACE), как и файл арта, чтобы
# новый мир подхватывался строкой в translations.csv без правок кода. Перевода нет —
# tr() вернёт сам ключ, поэтому в этом случае показываем исходное имя.
# Высота подписи «где мы»: общая, либо своя у мира с иначе нарисованной рамкой.
func _position_place() -> void:
	if _place == null or _card_h <= 0.0:
		return
	_place.offset_top = _card_h * _place_frac


func _apply_place(world: String) -> void:
	if _place == null:
		return
	if world.is_empty():
		_place.visible = false
		return
	var key: String = "WORLD_" + _world_slug(world).replace("-", "_").to_upper()
	var localized: String = tr(key)
	_place.text = world if localized == key else localized
	_place.visible = true
	_place_frac = float(_PLACE_TOP_BY_WORLD.get(world, _PLACE_TOP_FRAC))
	_position_place()


# Арт фона по типу локации (city.type из locations.json: city|sea|wilderness).
func _bg_texture(loc_type: String) -> Texture2D:
	match loc_type:
		"sea":
			return _BG_SEA
		"wilderness":
			return _BG_WILDERNESS
		_:
			return _BG_CITY


# Арт Иного мира по имени из карты встречи (relay кладёт его в otherWorld —
# фиксированный набор из девяти миров). Файл ищем по слагу имени, поэтому новый
# мир достаточно положить в assets/other-world/ и код править не надо. Нет
# файла — null, и вызывающий откатится на арт по типу локации.
func _world_texture(world: String) -> Texture2D:
	if world.is_empty():
		return null
	if _world_bg_cache.has(world):
		return _world_bg_cache[world]
	var path: String = _OTHER_WORLD_DIR + _world_slug(world) + ".png"
	var tex: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
	if tex == null:
		GameConsole.log("[Встреча] нет арта Иного мира «%s» (ждём %s)" % [world, path])
	_world_bg_cache[world] = tex
	return tex


# «City of the Great Race» → «city-of-the-great-race»: латиница и цифры как есть,
# всё прочее — дефис, повторы схлопываем.
static func _world_slug(world: String) -> String:
	var out: String = ""
	for ch: String in world.to_lower():
		var ok: bool = (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9")
		if ok:
			out += ch
		elif not out.ends_with("-"):
			out += "-"
	return out.trim_prefix("-").trim_suffix("-")


# Активная проверка встречи (единая, CheckFlow), если она относится к встрече.
func _chk() -> Dictionary:
	var c: Dictionary = GameState.active_check
	return c if String(c.get("owner", "")) == "encounter" else {}


func _chk_rolled() -> bool:
	return bool(_chk().get("rolled", false))


# Доступен ли «перебросить все провальные кубы разом» (Счастливый талисман):
# проверка брошена, запас есть, исход ещё не принят и встреча не зафиксирована.
func _reroll_all_available() -> bool:
	if _revealed or bool(GameState.current_encounter.get("committed", false)):
		return false
	var c: Dictionary = _chk()
	return int(c.get("reroll_all_allowance", 0)) - int(c.get("reroll_all_used", 0)) > 0


# Кнопка броска переиспользуется как «Перебросить кубы», пока доступен reroll-all.
func _set_reroll_all_btn() -> void:
	if _reroll_all_available():
		_roll_btn.text = "ENCOUNTER_REROLL_ALL"
		_roll_btn.disabled = false
		_roll_btn.visible = true
	else:
		_roll_btn.visible = false


func _refresh() -> void:
	var mine: bool = GameState.is_my_encounter_turn()
	# Не мой ход / встреча кончилась — сброс, чтобы следующая встреча снова «выплыла».
	if not mine:
		UIStyle.modal_set_visible(_root, _panel, false)
		return
	# Пока активный игрок выбирает тип встречи — окно встречи скрыто
	# (его место занимает модалка выбора). Флаг показа НЕ сбрасываем — это та же встреча.
	if not (GameState.encounter_choices as Array).is_empty():
		UIStyle.modal_set_visible(_root, _panel, false)
		return
	var card: Dictionary = GameState.current_encounter
	# Бой — отдельная боевая модалка; это окно скрываем (та же встреча — флаг держим).
	if String(card.get("kind", "")) == "combat":
		UIStyle.modal_set_visible(_root, _panel, false)
		return
	UIStyle.modal_set_visible(_root, _panel, true)
	_apply_background()  # подложка по типу локации встречи
	# Интерактивный выбор ветки эффектов (choice) — поверх любого состояния:
	# коммит встал на паузу и ждёт решения активного игрока.
	if not (card.get("pending_choice", {}) as Dictionary).is_empty():
		_show_choice(card)
		return
	_clear_choice()
	if card.is_empty():
		_show_loading()
	elif _is_branching(card):
		_show_gate(card)  # gate и mystery — общая ветвящаяся структура
	elif _chk_rolled():
		_show_outcome(card)
	else:
		_show_card(card)


# ── Состояния окна ────────────────────────────────────────────────────────────


func _show_loading() -> void:
	_ensure_stage_opaque()
	_stage_key = ""  # встреча кончилась — следующая ветвящаяся начнётся с проявления
	_title.text = "ENCOUNTER_TITLE"
	_main_text.text = "ENCOUNTER_GENERATING"
	for node: Control in [_roll_btn, _dice, _outcome, _finish_btn]:
		node.visible = false
	_outcome_shown = false  # исход ещё не показан — сброс фейд-флага
	_hide_dice()


# Интерактивный выбор: подсказка + кнопка на каждую ветку pending_choice.options.
# Клик → act(CHOOSE_EFFECT, {index}); хост запишет выбор и доиграет коммит.
func _show_choice(card: Dictionary) -> void:
	_ensure_stage_opaque()
	var pending: Dictionary = card.get("pending_choice", {})
	var kind: String = String(pending.get("kind", "choice"))  # choice | target | monster
	_title.text = _title_text(card)
	_main_text.text = tr(_choose_prompt_key(kind))
	for node: Control in [_roll_btn, _dice, _outcome, _finish_btn]:
		node.visible = false
	_hide_dice()
	_clear_choice()
	var options: Array = pending.get("options", [])
	for i in range(options.size()):
		var b: Variant = options[i]
		var btn := Button.new()
		btn.name = "ChoiceBtn%d" % i
		btn.text = _choice_label(b if b is Dictionary else {}, kind)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIStyle.style_button(btn)
		var idx: int = i
		btn.pressed.connect(func() -> void: _on_choice_pressed(idx))
		_choice_holder.add_child(btn)
	_choice_holder.visible = true


# Подсказка выбора по виду: монстр (сброс) / сыщик (передача) / ветка эффектов.
func _choose_prompt_key(kind: String) -> String:
	match kind:
		"monster":
			return "ENCOUNTER_CHOOSE_MONSTER"
		"target":
			return "ENCOUNTER_CHOOSE_TARGET"
		_:
			return "ENCOUNTER_CHOOSE"


# Метка опции: монстр — имя + стойкость; сыщик — имя; ветка — описание эффектов.
func _choice_label(opt: Dictionary, kind: String) -> String:
	match kind:
		"monster":
			var nm: String = tr(String(opt.get("name", "?")))
			return tr("MONSTER_CHOICE_LABEL") % [nm, int(opt.get("toughness", 1))]
		"target":
			return String(opt.get("name", "?"))
		_:
			return EffectManifest.describe(opt)


func _clear_choice() -> void:
	if not is_instance_valid(_choice_holder):
		return
	for c: Node in _choice_holder.get_children():
		c.queue_free()
	_choice_holder.visible = false


func _on_choice_pressed(index: int) -> void:
	_clear_choice()  # блокируем повторные клики до синка от хоста
	GameState.act(RelayActions.CHOOSE_EFFECT, {"index": index})


func _show_card(card: Dictionary) -> void:
	_ensure_stage_opaque()
	_title.text = _title_text(card)
	_main_text.text = _main_or_stakes(card)
	_roll_btn.text = "ENCOUNTER_ROLL"
	_roll_btn.visible = true
	_roll_btn.disabled = false
	_outcome.visible = false
	_outcome_shown = false  # исход ещё не показан — сброс фейд-флага
	_finish_btn.visible = false
	var test_c: Dictionary = card.get("test", {})
	_show_dice_pending(test_c)


# Кубы осели — проявляем исход (см. _show_outcome: пока крутится, он скрыт).
func _on_roll_settled() -> void:
	if _outcome_shown or _outcome.text.is_empty():
		return
	_outcome.visible = true
	_play_outcome_in()
	_outcome_shown = true


func _show_outcome(card: Dictionary) -> void:
	_ensure_stage_opaque()
	var res: Dictionary = _chk()
	var passed: bool = bool(res.get("passed", false))
	_title.text = _title_text(card)
	_main_text.text = _main_or_stakes(card)
	_show_dice_result(res)
	# Провал прячем, пока есть перебросы (поштучно или «всё») и игрок не «принял».
	var hide_fail: bool = (
		not passed and not _revealed and (_rerolls_available() or _reroll_all_available())
	)
	# Исход — продолжением под основным текстом (см. раскладку в _ready), но своим
	# цветом: зелёный успех / красный провал. Появление — плавным фейдом.
	if hide_fail:
		_outcome.visible = false
		_outcome_shown = false
	else:
		_outcome.text = _outcome_text(card, passed)
		_outcome.add_theme_color_override(
			"font_color", UIColors.SUCCESS if passed else UIColors.DANGER
		)
		# Пока кубы крутятся — исход держим скрытым: иначе «успех» проявляется
		# раньше, чем игрок увидел выпавшие грани. Покажет _on_roll_settled.
		if _tray != null and _tray.is_rolling():
			_outcome.visible = false
			_outcome_shown = false
		else:
			_outcome.visible = true
			if not _outcome_shown:
				_play_outcome_in()
				_outcome_shown = true
	_set_reroll_all_btn()  # кнопка броска → «Перебросить кубы», пока доступен reroll-all
	_finish_btn.text = "ENCOUNTER_ACCEPT" if hide_fail else "BTN_FINISH_BIG"
	_finish_btn.visible = true


# Двухфазные врата — дерево глубины 2. Стадия 0 (stage1) маршрутизирует: бросок
# → исход выбирает ветку, после чего «Дальше» ведёт ко второй проверке ПРИ ЛЮБОМ
# исходе. Стадия 1 — вторая проверка ветки: исход + «Завершить».
func _show_gate(card: Dictionary) -> void:
	var stage: int = int(card.get("stage", 0))
	var node: Dictionary = _gate_node(card, stage)
	if node.is_empty():
		_show_loading()
		return
	# Узел сменился (первая проверка → ветка) — гасим старый и выходим: текст
	# перерисуется в колбэке затухания, оттуда же начнётся проявление нового.
	var key: String = "%d|%s" % [stage, String(card.get("branch", ""))]
	if _stage_fading:
		return
	if not _stage_key.is_empty() and key != _stage_key:
		_play_stage_out()
		return
	var fresh: bool = _stage_key != key
	_stage_key = key
	_title.text = "%s  (%d/2)" % [_title_text(card), stage + 1]
	_main_text.text = _main_or_stakes(node)
	if fresh:
		_play_stage_in()

	if not _chk_rolled():
		_roll_btn.text = "ENCOUNTER_ROLL"
		_roll_btn.visible = true
		_roll_btn.disabled = false
		_outcome.visible = false
		_outcome_shown = false  # исход ещё не показан — сброс фейд-флага
		_finish_btn.visible = false
		var test_n: Dictionary = node.get("test", {})
		_show_dice_pending(test_n)
		return

	var res: Dictionary = _chk()
	var passed: bool = bool(res.get("passed", false))
	_show_dice_result(res)
	# Провал прячем, пока есть перебросы (поштучно или «всё») и игрок не «принял».
	var hide_fail: bool = (
		not passed and not _revealed and (_rerolls_available() or _reroll_all_available())
	)
	# Исход — продолжением под основным текстом узла, своим цветом (как _show_outcome).
	if hide_fail:
		_outcome.visible = false
		_outcome_shown = false
	else:
		_outcome.text = _outcome_text(node, passed)
		_outcome.add_theme_color_override(
			"font_color", UIColors.SUCCESS if passed else UIColors.DANGER
		)
		_outcome.visible = true
		if not _outcome_shown:
			_play_outcome_in()
			_outcome_shown = true
	_set_reroll_all_btn()  # кнопка броска → «Перебросить кубы», пока доступен reroll-all
	# После первой проверки (stage 0) всегда «Дальше» (обе ветви ведут ко второй
	# проверке); после второй (stage 1) — «Завершить».
	var more: bool = stage == 0
	if hide_fail:
		_finish_btn.text = "ENCOUNTER_ACCEPT"
	else:
		_finish_btn.text = "ENCOUNTER_CONTINUE" if more else "BTN_FINISH_BIG"
	_finish_btn.visible = true


# Ветвящиеся встречи (gate и mystery) — одинаковая структура card.stage1 +
# card.branches.{success,failure}. UI и резолв общие.
func _is_branching(card: Dictionary) -> bool:
	var k: String = String(card.get("kind", ""))
	return k == "gate" or k == "mystery"


# Активный узел ветвящейся встречи: стадия 0 → stage1, стадия 1 → ветка по
# результату первой проверки (success/failure).
func _gate_node(card: Dictionary, stage: int) -> Dictionary:
	if stage <= 0:
		return card.get("stage1", {})
	var branches: Dictionary = card.get("branches", {})
	var branch: String = String(card.get("branch", "success"))
	return branches.get(branch, {})


func _on_roll_pressed() -> void:
	# Повторное нажатие после броска = «перебросить все кубы» (Счастливый талисман).
	if _chk_rolled():
		if _reroll_all_available():
			GameState.act(RelayActions.REROLL_ALL)  # хост перебросит провальные и пришлёт синком
		return
	_revealed = false  # свежая проверка — провал снова можно скрыть до решения
	_roll_btn.disabled = true  # хост разрешит встречу и пришлёт результат синком
	GameState.act(RelayActions.RESOLVE_ENCOUNTER)


func _on_die_clicked(index: int) -> void:
	# После «принятия» встречи кубы не трогаем. Иначе делегируем reroll_die: он сам
	# приоритезирует +1 (addToDie) над перебросом — гард can_reroll_now() глушил «+1».
	if _revealed:
		return
	GameState.reroll_die(index)


# Единый лоток — создаётся лениво и переиспользуется, чтобы спин не рвался при
# ре-рендере на синке.
func _ensure_tray() -> void:
	if is_instance_valid(_tray):
		return
	_tray = DiceTray.new()
	_tray.name = "DiceTray"
	_tray.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_tray.die_selected.connect(_on_die_clicked)
	_tray.roll_settled.connect(_on_roll_settled)
	_dice_holder.add_child(_tray)


# До броска — полный пул сыщика: бросаемые кубы плюс помеченные добавленные/отнятые.
func _show_dice_pending(test: Dictionary) -> void:
	if not is_instance_valid(_dice_holder):
		return
	_ensure_tray()
	var pb: Dictionary = _pool(test)
	var pool: int = int(pb["pool"])
	if _pending_n != pool or not _last_dice.is_empty():
		_tray.set_pool_marks(int(pb["bonus"]), int(pb["blocked"]))
		_tray.show_pending(pool, String(test.get("skill", "")))
		_pending_n = pool
		_last_dice = []
	_dice_holder.visible = true
	_dice.visible = false


# Результат: свежий бросок → спин всех; переброс одного куба → крутится только он;
# повторный синк того же броска → не трогаем (не рвём анимацию).
func _show_dice_result(res: Dictionary) -> void:
	if not is_instance_valid(_dice_holder):
		return
	_ensure_tray()
	var dice: Array = res.get("dice", [])
	var committed: bool = bool(GameState.current_encounter.get("committed", false))
	# Тапом перебросить можно ТОЛЬКО бесплатно (карта) или заряженным жетоном.
	# Концентрация/улика — лишь через розыгрыш жетона. После «принятия» (_revealed) — нет.
	var can: bool = GameState.can_reroll_now() and not committed and not _revealed
	var add: bool = GameState.can_add_die_now() and not committed and not _revealed
	var nonce: int = int(res.get("reroll_nonce", 0))
	if dice != _last_dice:
		var prev: Array = _last_dice
		var diff: int = _single_diff(prev, dice)
		_last_dice = dice.duplicate()
		_pending_n = -1
		if prev.is_empty():
			_tray.play_roll(dice, can, add)  # первый бросок — спин всех
		elif diff >= 0:
			_tray.reroll_die(diff, int(dice[diff]), can, add)  # переброс одного — крутится он
		elif prev.size() == dice.size():
			_tray.play_roll(dice, can, add)  # тот же размер, изменилось несколько → reroll-all (спин)
		else:
			_tray.show_roll(dice, can, add)  # размер изменился (докинули кубы) → статикой
		_last_can = can
		_last_add = add
		_last_nonce = nonce
	elif nonce != _last_nonce:
		# Переброс в ТО ЖЕ значение: массив не изменился, но nonce вырос — крутим
		# затронутый куб, иначе клик «съеденный» (фокус ушёл, куб не дёрнулся).
		var ri: int = int(res.get("reroll_index", -1))
		if ri >= 0 and ri < dice.size():
			_tray.reroll_die(ri, int(dice[ri]), can, add)
		_last_can = can
		_last_add = add
		_last_nonce = nonce
	elif can != _last_can or add != _last_add:
		# Кубы те же, но кликабельность изменилась (активировали карту-переброс/+1
		# после броска) — обновляем лоток, иначе кубик не нажать.
		_tray.show_roll(dice, can, add)
		_last_can = can
		_last_add = add
	_dice_holder.visible = true
	# Строку-итог «успехов: N · перетащите жетон…» убрали — кубы говорят сами за себя.
	_dice.visible = false


func _hide_dice() -> void:
	_last_dice = []
	_pending_n = -1
	if is_instance_valid(_dice_holder):
		_dice_holder.visible = false
	_dice.visible = false


# Индекс единственного отличия наборов (спин только переброшенного куба); -1 если
# отличий нет или больше одного / разные размеры.
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


# Пул d6 проверки = навык + модификаторы навыка + модификатор карты (как у хоста
# в CheckFlow.pool). Для показа рубашек до броска.
# Разбор пула: {pool, bonus, blocked} — ряд показывает полный пул сыщика,
# добавленные/отнятые кубы помечены цветом (см. DiceTray.set_pool_marks).
func _pool(test: Dictionary) -> Dictionary:
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var skill: String = String(test.get("skill", "will"))
	var base: int = int((inv.get("skills", {}) as Dictionary).get(skill, 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get(skill, 0))
	# Доп. кубы от активированных карт до броска (Фаза 5) — рубашки растут заранее.
	var amods: Array = _chk().get("active_mods", [])
	var extra: int = Dice.pre_roll_bonus(amods, skill)
	return Dice.pool_breakdown(base, mods, int(test.get("modifier", 0)), extra)


# Кнопка под исходом: после первой проверки врат (stage 0) — «Дальше» ко второй
# проверке при ЛЮБОМ исходе (ветка выбирается по успеху/провалу); иначе — конец.
func _on_finish_pressed() -> void:
	var card: Dictionary = GameState.current_encounter
	# Если провал скрыт (есть перебросы) — первый клик РАСКРЫВАЕТ исход и блокирует
	# перебросы; завершение/переход — следующим кликом.
	if not _revealed and _current_failed(card) and _rerolls_available():
		_revealed = true
		_refresh()
		return
	if _is_branching(card):
		if int(card.get("stage", 0)) == 0 and _chk_rolled():
			GameState.act(RelayActions.ADVANCE_STAGE)
			return
	GameState.act(RelayActions.FINISH_ENCOUNTER)


# Доступны ли перебросы: есть фокус ИЛИ бесплатные перебросы от карт, и проверка
# ещё не закоммичена.
# Можно ли ВООБЩЕ перебросить (для скрытия исхода): бесплатно / концентрация / улика
# (последние — через розыгрыш жетона). Пока ресурс есть — провал не показываем.
func _rerolls_available() -> bool:
	if bool(GameState.current_encounter.get("committed", false)):
		return false
	return GameState.has_reroll_resource()


# Текущий показанный результат — провал? (из активной проверки встречи).
func _current_failed(_card: Dictionary) -> bool:
	var res: Dictionary = _chk()
	if not bool(res.get("rolled", false)):
		return false
	return not bool(res.get("passed", false))


# ── Хелперы текста ────────────────────────────────────────────────────────────


# Заголовок: имя карты (от LLM) либо локализованный фолбэк (механический режим).
func _title_text(card: Dictionary) -> String:
	var n: String = String(card.get("name", "")).strip_edges()
	return n if not n.is_empty() else tr("ENCOUNTER_TITLE")


# Основной текст: художественный mainText, а если пуст (механический режим без
# LLM) — ставки проверки: что даёт успех и чем карает провал.
func _main_or_stakes(src: Dictionary) -> String:
	var main: String = String(src.get("mainText", "")).strip_edges()
	if not main.is_empty():
		return main
	var succ: Array = src.get("onSuccess", [])
	var fail: Array = src.get("onFailure", [])
	# Маршрутизирующая стадия (без эффектов на любом исходе) — нейтрально, текст
	# по виду встречи: врата — Иной мир, Тайна — расследование на месте.
	if succ.is_empty() and fail.is_empty():
		var kind: String = String(GameState.current_encounter.get("kind", ""))
		return tr("ENCOUNTER_MYSTERY_TRIAL" if kind == "mystery" else "ENCOUNTER_GATE_TRIAL")
	return (
		"%s: %s\n%s: %s"
		% [
			tr("ENC_REWARD"),
			_eff(succ),
			tr("ENC_PENALTY"),
			_eff(fail),
		]
	)


# Текст исхода: художественный success/failureText, либо описание применённых
# эффектов, если текста нет (механический режим); пустой исход → «идём дальше».
func _outcome_text(src: Dictionary, passed: bool) -> String:
	var txt: String = String(src.get("successText" if passed else "failureText", "")).strip_edges()
	var arr: Array = src.get("onSuccess" if passed else "onFailure", [])
	var out: String
	# Механический режим (без флейвора) — только описание эффектов / «идём дальше».
	if txt.is_empty():
		out = _eff(arr) if not arr.is_empty() else tr("ENCOUNTER_PROCEED")
	elif not arr.is_empty():
		# Есть флейвор: под ним отдельной строкой — что именно получил/потерял.
		out = "%s\n\n%s" % [txt, _eff(arr)]
	else:
		out = txt
	return out


# ── Описание эффектов (механический режим) — через единый verb-манифест ─────────


# Список эффектов человекочитаемо (EffectManifest), пусто → «—».
func _eff(arr: Variant) -> String:
	var s: String = EffectManifest.describe_list(arr)
	return s if not s.is_empty() else tr("ENC_EFF_NONE")
