class_name UIFonts
extends RefCounted

## Токены размеров шрифта и настройка «Размер текста» (SettingsStore.text_scale).
##
## Три класса текста:
##   • ТЕКСТ (CAPTION…LEAD) — то, что читают: тексты окон, подсказки, ленты, описания.
##     Растёт целиком по настройке (100 / 115 / 130 %);
##   • ЗАГОЛОВКИ (BUTTON, TITLE, HERO) — растут не больше чем на DISPLAY_CAP (10 %):
##     кнопки и заголовки сидят в рамках арта, им тесно;
##   • ПОДПИСИ НА АРТЕ — art(n): своя база px, растёт вполсилы (ART_GAIN): имя и
##     навыки в листе сыщика, подписи здоровья/рассудка — рамки арта тесные;
##   • ЧИСЛО вместо токена — фиксированный размер, НЕ масштабируется: HUD, цифры и
##     подписи на арте (карта монстра, плашки действий, подписи карты мира), а также
##     составные виджеты со своей типографикой (GameCard держит шрифт сам).
##
## Размер ставится явно на узел от базы токена — не рекурсивным скейлом дерева (тот
## уже был и удвоялся при повторном вызове, протекая в карты). Узел с токеном лежит
## в группе GROUP: смена настройки пересчитывает размеры открытых окон на месте.
##
##   UIStyle.label("TEXT", UIFonts.BODY)            # токен — масштабируется
##   UIFonts.apply(rich_label, UIFonts.HINT)         # уже созданный узел
##   UIFonts.apply(title, UIFonts.TITLE, 540.0)      # + вписать в 540 px (рамка)
##   UIStyle.label("STATS_HEALTH", UIFonts.art(13))  # подпись на арте — вполсилы

## Подписи мельче подсказок: сноски, теги, мелкие строки списков.
const CAPTION := &"caption"
## Мелкий текст строк: подписи полей, вторичные строки.
const SMALL := &"small"
## Обычная подпись (кнопки-ссылки, пункты списков).
const LABEL := &"label"
## Подсказки, сноски, мелкие пояснения окон.
const HINT := &"hint"
## Промежуточный: плотные списки, лента.
const NOTE := &"note"
## Основной текст окна.
const BODY := &"body"
## Акцентная строка: подзаголовок, крупное значение, шаг проверки.
const LEAD := &"lead"
## Подпись кнопки.
const BUTTON := &"button"
## Заголовок окна.
const TITLE := &"title"
## Самое крупное — где заголовок и есть всё содержимое.
const HERO := &"hero"

const _BASE := {
	CAPTION: 13,
	SMALL: 14,
	LABEL: 16,
	HINT: 18,
	NOTE: 20,
	BODY: 22,
	LEAD: 26,
	BUTTON: 16,
	TITLE: 30,
	HERO: 39,
}
const _DISPLAY := [BUTTON, TITLE, HERO]

## Ступени настройки «Размер текста».
const SCALES := [1.0, 1.15, 1.3]
## Заголовки и кнопки растут не больше этого.
const DISPLAY_CAP: float = 1.1
## Подписи на арте (art) берут эту долю прироста: 130 % → 115 %.
const ART_GAIN: float = 0.5
## Вписывание: меньше этого не ужимаем (читаемость важнее рамки).
const FIT_MIN_PX: int = 12

const GROUP := &"ui_font_token"
const _META_TOKEN := &"font_token"
const _META_FIT := &"font_fit"
const _ART_PREFIX := "art:"


## Токен подписи на арте с базой base px: растёт с настройкой вполсилы (ART_GAIN).
## gain — своя доля прироста (1.0 — как текст), где подпись важнее тесноты.
static func art(base: int, gain: float = ART_GAIN) -> StringName:
	return StringName("%s%d:%d" % [_ART_PREFIX, base, int(round(gain * 100.0))])


## Текущий множитель «Размера текста» (SettingsStore.text_scale).
static func scale() -> float:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or not tree.root.has_node("SettingsStore"):
		return 1.0
	return float(tree.root.get_node("SettingsStore").get("text_scale"))


## Размер токена в пикселях с учётом настройки.
static func px(token: StringName) -> int:
	var k: float = scale()
	if String(token).begins_with(_ART_PREFIX):
		var parts: PackedStringArray = String(token).substr(_ART_PREFIX.length()).split(":")
		var gain: float = parts[1].to_int() / 100.0 if parts.size() > 1 else ART_GAIN
		return int(round(parts[0].to_int() * (1.0 + (k - 1.0) * gain)))
	var base: int = int(_BASE.get(token, 22))
	if token in _DISPLAY:
		k = minf(k, DISPLAY_CAP)
	return int(round(base * k))


## Произвольная база px (тюнинг-панель) по настройке: display — как заголовок (≤ 10 %).
## Для узлов, чей размер пересчитывает свой владелец (не живёт в группе).
static func scaled(base: float, display: bool = false) -> int:
	var k: float = scale()
	if display:
		k = minf(k, DISPLAY_CAP)
	return int(round(base * k))


## Базовый размер токена (100 %), без настройки.
static func base_px(token: StringName) -> int:
	return int(_BASE.get(token, 22))


## Поставить узлу размер шрифта: токен (масштабируется, узел запоминается для живого
## пересчёта) или число (фиксированный). max_w > 0 — вписать однострочный текст в эту
## ширину (рамка фиксированного размера): крупная настройка не вылезет за неё.
static func apply(ctrl: Control, size: Variant, max_w: float = 0.0) -> void:
	if size is StringName or size is String:
		var token := StringName(size)
		ctrl.set_meta(_META_TOKEN, token)
		if not ctrl.is_in_group(GROUP):
			ctrl.add_to_group(GROUP)
		if max_w > 0.0:
			ctrl.set_meta(_META_FIT, max_w)
		_set_px(ctrl, px(token))
		if max_w > 0.0:
			_refit(ctrl)
	else:
		_set_px(ctrl, int(size))


## Пересчитать все узлы с токенами (смена настройки) — окна обновляются на месте.
static func refresh_all(tree: SceneTree) -> void:
	for n: Node in tree.get_nodes_in_group(GROUP):
		var c := n as Control
		if c == null or not c.has_meta(_META_TOKEN):
			continue
		_set_px(c, px(StringName(c.get_meta(_META_TOKEN))))
		if c.has_meta(_META_FIT):
			_refit(c)


static func _set_px(ctrl: Control, n: int) -> void:
	if ctrl is RichTextLabel:
		ctrl.add_theme_font_size_override("normal_font_size", n)
		ctrl.add_theme_font_size_override("bold_font_size", n)
		ctrl.add_theme_font_size_override("italics_font_size", n)
	else:
		ctrl.add_theme_font_size_override("font_size", n)


## Вписать уже вписываемый узел заново (текст сменился после apply).
static func refit(ctrl: Control) -> void:
	if ctrl.has_meta(_META_FIT):
		_refit(ctrl)


# Вписать: размер токена, но если однострочный текст шире рамки (мета _META_FIT) —
# уменьшить до неё, не меньше FIT_MIN_PX.
static func _refit(ctrl: Control) -> void:
	if not is_instance_valid(ctrl) or not ctrl.has_meta(_META_TOKEN):
		return
	var want: int = px(StringName(ctrl.get_meta(_META_TOKEN)))
	var width: float = float(ctrl.get_meta(_META_FIT, 0.0))
	var text: String = String(ctrl.get("text")) if "text" in ctrl else ""
	if text.is_empty() or width <= 1.0:
		_set_px(ctrl, want)
		return
	var font: Font = ctrl.get_theme_font("font")
	var n: int = fit_px(font, ctrl.tr(text), want, width)
	_set_px(ctrl, n)


## Наибольший размер ≤ want, при котором строка text влезает в width (не меньше
## FIT_MIN_PX). Чистая функция — для тестов.
static func fit_px(font: Font, text: String, want: int, width: float) -> int:
	var n: int = want
	while n > FIT_MIN_PX and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, n).x > width:
		n -= 1
	return n
