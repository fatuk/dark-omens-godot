class_name MapPickPrompt
extends CanvasLayer

## Подсказка выбора на карте: «Чартерный рейс — выберите подсвеченную локацию».
## Выбор «куда переместиться» (mythos_decision kind destination) делается кликом по
## карте, а не списком в модалке: игрок видит, куда летит. Плашка сверху — только
## текст, клики не ловит (карта под ней должна работать). Показ/скрытие — show_for.

## Мета-метка окна, которое выбор на карте заменяет (модалка решения): при проверке
## «свободна ли карта» его не считаем.
const REPLACED_META: StringName = &"map_pick_replaced"

## Решение, которое СЕЙЧАС выбирается на карте ({} — нет). Пересчитывается каждый
## кадр в _process: карта должна быть свободна от прочих окон (под встречей/Мифом
## по ней не кликнуть — тогда остаётся список в модалке). Окна закрываются и без
## смены состояния (магазин освобождается после покупки), поэтому опрос, а не сигнал.
static var _active: Dictionary = {}

signal changed

var _sig: String = ""
var _root: Control
var _panel: PanelContainer
var _title: Label
var _prompt: Label


func _ready() -> void:
	layer = 70  # над картой и HUD, под модалками (80+)
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_TOP_WIDE)
	center.offset_top = 150.0  # под верхней панелью
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.style_modal_panel(_panel, 24)
	center.add_child(_panel)
	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(box)
	_title = UIStyle.label("", UIStyle.MODAL_FS_LEAD, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_title.name = "Title"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_title)
	_prompt = UIStyle.label(
		"PICK_ON_MAP", UIStyle.MODAL_FS_BODY, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	_prompt.name = "Prompt"
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_prompt)


## Моё решение «куда переместиться», которое выбирается на карте ({} — нет такого).
## Единая точка для модалки решения (она такой выбор не показывает) и карты.
static func decision() -> Dictionary:
	return _active


# Моё решение «куда переместиться» по состоянию, без учёта окон.
static func _pending() -> Dictionary:
	var d: Dictionary = GameState.mythos_decision
	if not bool(d.get("active", false)) or String(d.get("kind", "")) != "destination":
		return {}
	if String(d.get("pid", "")) != String(GameState.my_player().get("user_id", "")):
		return {}
	return d


## Индекс варианта решения d для локации loc_id (-1 — не цель).
static func option_index(d: Dictionary, loc_id: String) -> int:
	var opts: Array = d.get("options", [])
	for i in range(opts.size()):
		if String((opts[i] as Dictionary).get("ref", "")) == loc_id:
			return i
	return -1


func _process(_delta: float) -> void:
	var d: Dictionary = _pending()
	var free: bool = not UIStyle.any_modal_open(REPLACED_META)
	var next: Dictionary = d if not d.is_empty() and free else {}
	var sig: String = JSON.stringify(next)
	if sig == _sig:
		return
	_sig = sig
	_active = next
	show_for(next)
	changed.emit()
	# Модалка решения пересобирается: карта освободилась → спрятаться, и наоборот.
	get_tree().call_group("mythos_decision_modal", "refresh")


func _exit_tree() -> void:
	_active = {}


## Показать для решения d (mythos_decision) или скрыть ({}).
func show_for(d: Dictionary) -> void:
	if not is_instance_valid(_root):
		return
	if d.is_empty():
		_root.visible = false
		return
	_title.text = String(d.get("title_key", "MYTHOS_DECISION_TITLE"))
	_root.visible = true


func is_shown() -> bool:
	return is_instance_valid(_root) and _root.visible
