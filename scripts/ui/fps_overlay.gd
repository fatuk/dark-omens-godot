extends CanvasLayer

## Счётчик FPS поверх игры. Autoload /root/FpsOverlay.
##
## Включается в настройках (`SettingsStore.show_fps`). Намеренно НЕ спрятан за
## `OS.is_debug_build()`, в отличие от консоли и тюнинг-панели: он нужен на
## живых плейтестах, а те идут на релизной сборке.
##
## Слой 300 — выше плёночного PostFx (200), чтобы зерно не мылило цифры, но
## ниже курсора (1024).

## Как часто обновляем надпись. Каждый кадр — мельтешение, цифру не прочесть.
const UPDATE_INTERVAL: float = 0.25

const MARGIN: int = 10

var _label: Label
var _elapsed: float = 0.0


func _ready() -> void:
	layer = 300
	# Считаем и на паузе: просадки часто ловятся именно на открытой модалке.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	set_shown(SettingsStore.show_fps)


## Показать/скрыть счётчик. Зовётся из диалога настроек при сохранении.
func set_shown(on: bool) -> void:
	visible = on
	# Без счётчика не тикаем вовсе — незачем будить _process ради невидимого узла.
	set_process(on)
	if on:
		_refresh()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < UPDATE_INTERVAL:
		return
	_elapsed = 0.0
	_refresh()


func _refresh() -> void:
	_label.text = "%d FPS" % Engine.get_frames_per_second()


func _build() -> void:
	_label = Label.new()
	_label.name = "FpsCounter"
	# Прижимаем к правому верхнему углу: там свободно на всех экранах, а левый
	# верхний занят рамкой и заголовками.
	_label.anchor_left = 1.0
	_label.anchor_right = 1.0
	_label.offset_left = -96 - MARGIN
	_label.offset_right = -MARGIN
	_label.offset_top = MARGIN
	_label.offset_bottom = MARGIN + 26
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Иначе счётчик перехватывал бы клики по тому, что под ним.
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_color_override("font_color", UIColors.ACCENT)
	_label.add_theme_font_size_override("font_size", 14)

	var box := StyleBoxFlat.new()
	box.bg_color = Color(UIColors.BG, 0.65)
	box.set_content_margin_all(4)
	box.set_corner_radius_all(3)
	_label.add_theme_stylebox_override("normal", box)

	add_child(_label)
