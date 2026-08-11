class_name CardPreview
extends CanvasLayer

## Крупный просмотр одной карты поверх всего: затемнение на весь экран и карта
## во всю его высоту. Нужен там, где карты показаны миниатюрами и текст на них
## не прочитать (окно «Запасы», сброс).
##
## Закрывается кликом в любом месте и по ESC. Одноразовый: показали — закрыли —
## освободили. Появление/исчезновение — общий для модалок эффект
## (UIStyle.modal_transition), поэтому просмотр не выбивается из остального UI.
##
##   CardPreview.show_card(world_map, AssetCatalog.card_payload(asset))

const GROUP: StringName = &"card_preview"  # живые слои — для панели тюнинга
const _LAYER: int = 120  # выше модалок (ModalDialog — 90) и подсказок
const _BUILD_H: float = 520.0  # строим в каноничном росте и масштабируем (как в info_bar)

# Крутится в панели тюнинга (Ctrl+M, секция «ПРОСМОТР КАРТЫ»); найденное значение
# запекается сюда же. static var, а не const — панель правит их на живой игре.
static var MARGIN_V: float = 48.0  # запас сверху и снизу
static var MAX_H: float = 900.0  # выше карту не растягиваем — станет мылом
static var BACKDROP_ALPHA: float = 0.72  # затемнение экрана под картой

var _root: ColorRect
var _wrap: Control
var _payload: Dictionary = {}  # что показываем — для пересборки при правке тюнинга


## Показать карту. parent — узел, к которому цеплять слой (обычно экран карты).
static func show_card(parent: Node, payload: Dictionary) -> CardPreview:
	var pv := CardPreview.new()
	pv.name = "CardPreview"
	parent.add_child(pv)
	pv.set_card(payload)
	return pv


func _ready() -> void:
	layer = _LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS  # просмотр работает и на паузе
	add_to_group(GROUP)

	_root = ColorRect.new()
	_root.name = "Root"
	_root.color = Color(0, 0, 0, BACKDROP_ALPHA)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP  # клик мимо карты — тоже закрытие
	_root.gui_input.connect(_on_input)
	UIStyle.keep_own_backdrop(_root)  # тут затемнение своё, глубже общего для модалок
	add_child(_root)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_wrap = Control.new()  # обёртка: её scale ведёт общий эффект появления
	_wrap.name = "Card"
	_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_wrap)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close()
			# Гасим событие: иначе тот же ESC закрыл бы и окно под просмотром.
			get_viewport().set_input_as_handled()


func set_card(payload: Dictionary) -> void:
	if not is_node_ready():
		await ready
	_payload = payload
	_rebuild()
	UIStyle.modal_transition(_root, _wrap, true)


## Перерисовать по текущим значениям тюнинга — без повторного появления: просмотр
## уже на экране. Зовёт панель тюнинга на живом слое.
func refresh_tuning() -> void:
	if not _payload.is_empty():
		_rebuild()


# Собрать карту по текущим размерам. Появление играет тот, кто зовёт.
func _rebuild() -> void:
	_root.color = Color(0, 0, 0, BACKDROP_ALPHA)
	for c in _wrap.get_children():
		_wrap.remove_child(c)
		c.queue_free()

	var view_h: float = get_viewport().get_visible_rect().size.y
	var h: float = minf(MAX_H, maxf(_BUILD_H, view_h - MARGIN_V * 2.0))
	var scale_f: float = h / _BUILD_H
	var full_w: float = _BUILD_H * GameCard.ASPECT
	_wrap.custom_minimum_size = Vector2(full_w * scale_f, h)

	var card := GameCard.new()
	card.name = "Big"
	card.custom_minimum_size = Vector2(full_w, _BUILD_H)
	card.size = Vector2(full_w, _BUILD_H)
	card.pivot_offset = Vector2.ZERO
	card.scale = Vector2(scale_f, scale_f)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Размеры шрифтов в GameCard откалиброваны под карту веера (CARD_W). Строим шире
	# эталона — значит и шрифт тянем во столько же раз, иначе текст на крупной карте
	# выйдет мельче, чем на той же карте в руке.
	card.set_font_scale(full_w / HandCarousel.CARD_W)
	card.set_card(_payload)
	_wrap.add_child(card)


func close() -> void:
	var tw: Tween = UIStyle.modal_transition(_root, _wrap, false)
	tw.chain().tween_callback(queue_free)


func _on_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		close()
