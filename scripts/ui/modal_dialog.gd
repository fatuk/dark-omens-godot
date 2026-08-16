extends CanvasLayer
class_name ModalDialog

## Переиспользуемая модалка: затемнение фона + центрированная панель с
## заголовком и крестиком закрытия. Контент — любой Control, передаётся через
## set_content() или add_content_child().
##
## Закрывается: крестиком, клавишей ESC, кликом по затемнению.
## Открытие/закрытие — общий для всех модалок эффект (UIStyle.modal_transition).
## Работает во время паузы (process_mode=ALWAYS).
##
## Использование:
##   var modal := preload("res://scenes/ui/modal_dialog.tscn").instantiate()
##   add_child(modal)
##   modal.set_title("Заголовок")
##   modal.set_content(my_control)        # либо
##   modal.add_content_child(my_control)  # для добавления нескольких
##   modal.closed.connect(modal.queue_free)
##   modal.open()

signal closed

# Затемнение под панелью — общее для всех окон (UIStyle.MODAL_BACKDROP_ALPHA,
# крутится в панели тюнинга); проставляет его modal_transition при открытии.

@export var close_on_backdrop_click: bool = true
@export var close_on_esc: bool = true
@export var auto_free_on_close: bool = true  # после анимации закрытия — queue_free
@export var panel_min_width: int = 440

@onready var _root: Control = %Root
@onready var _backdrop: ColorRect = %Backdrop
@onready var _panel: PanelContainer = %Panel
@onready var _title: Label = %Title
@onready var _content: VBoxContainer = %Content
@onready var _close_btn: Button = %CloseBtn
@onready var _header_sep: HSeparator = %HeaderSep
@onready var _shield: TextureRect = %Shield

var _is_open: bool = false
var _tween: Tween = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_panel.custom_minimum_size.x = float(panel_min_width)
	UIStyle.style_modal_panel(_panel)
	UIStyle.style_modal_close_button(_close_btn)
	UIStyle.style_separator(_header_sep)
	_title.add_theme_color_override("font_color", UIColors.ACCENT)
	_close_btn.pressed.connect(close)
	_backdrop.gui_input.connect(_on_backdrop_input)
	UIStyle.apply_backdrop_alpha(_root)
	_root.visible = false
	_root.modulate.a = 0.0  # эффект ведёт весь слой целиком (UIStyle.modal_transition)


func _input(event: InputEvent) -> void:
	if not _is_open or not close_on_esc:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()


# ── Public API ────────────────────────────────────────────────────────────────


func set_title(text: String) -> void:
	if not is_node_ready():
		await ready
	_title.text = text
	var has_title := not text.is_empty()
	_title.visible = has_title
	_shield.visible = has_title
	_header_sep.visible = has_title


## Заменяет всё содержимое слота на единственный node. Если нужно несколько
## контролов — оборачивай во VBox/HBox или используй add_content_child().
func set_content(node: Control) -> void:
	if not is_node_ready():
		await ready
	_clear_content()
	if node:
		_content.add_child(node)


func add_content_child(node: Control) -> void:
	if not is_node_ready():
		await ready
	_content.add_child(node)


## Прямой доступ к VBoxContainer контента — для тонкой настройки порядка/спейсинга.
func get_content_box() -> VBoxContainer:
	return _content


func open() -> void:
	if _is_open:
		return
	_is_open = true
	_root.visible = true
	_animate(true)


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	_animate(false)
	closed.emit()


func is_open() -> bool:
	return _is_open


# ── Внутренние ───────────────────────────────────────────────────────────────


func _on_backdrop_input(event: InputEvent) -> void:
	if not close_on_backdrop_click:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			close()


func _animate(showing: bool) -> void:
	# Общий для всех модалок эффект (UIStyle.modal_transition): проявление слоя
	# целиком + «выплывание» панели.
	_tween = UIStyle.modal_transition(_root, _panel, showing)
	if not showing:
		_tween.chain().tween_callback(func() -> void: _root.visible = false)
		if auto_free_on_close:
			# queue_free серийно ПОСЛЕ скрытия. Если в окно анимации позвали
			# open() — новый tween убъёт этот, и queue_free не выполнится.
			_tween.tween_callback(queue_free)


func _clear_content() -> void:
	for child in _content.get_children():
		child.queue_free()
