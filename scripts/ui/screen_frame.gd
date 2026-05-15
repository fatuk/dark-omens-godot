extends CanvasLayer

## Декоративная рамка вокруг всего экрана — фигурные золотые углы + тонкие
## границы. Autoload-синглтон /root/ScreenFrame, видна по умолчанию на всех
## экранах. На карте мира скрывается (см. world_map.gd).
##
## NinePatchRect рендерит углы PNG'а как «неизменные» (резкие при любом
## разрешении окна), а серединки сторон/центр растягиваются. Поверх
## применяем Control.scale = _DISPLAY_SCALE с компенсацией размера —
## визуально уголок становится мельче (display-px), но детализация
## филиграни сохраняется (рендерим в полную source-разрешуху).

const _FRAME_TEX: Texture2D = preload("res://assets/main-frame.png")

# Размер угла в source-пикселях PNG'а (3238×1944). Покрывает филигрань
# уголков main-frame.png целиком — иначе декор бы растягивался по краям.
const _CORNER_PX: int = 300

# Визуальный масштаб. 0.25 → уголки на экране ~75 px при source=300 px.
# При смене ассета — подкручивать вместе с _CORNER_PX.
const _DISPLAY_SCALE: float = 0.25

var _frame: NinePatchRect


func _ready() -> void:
	# Слой выше игровых UI (game_panel=50, picker=50), но ниже модалок
	# (encounter_modal=80, modal_dialog=90, pause_menu=100) — рамка должна
	# закрываться попапами, но окружать обычный UI.
	layer = 75
	process_mode = Node.PROCESS_MODE_ALWAYS   # видна на паузе

	_frame = NinePatchRect.new()
	_frame.name          = "Frame"
	_frame.texture       = _FRAME_TEX
	_frame.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_frame.scale         = Vector2(_DISPLAY_SCALE, _DISPLAY_SCALE)
	_frame.patch_margin_left   = _CORNER_PX
	_frame.patch_margin_right  = _CORNER_PX
	_frame.patch_margin_top    = _CORNER_PX
	_frame.patch_margin_bottom = _CORNER_PX
	add_child(_frame)

	_update_size()
	get_viewport().size_changed.connect(_update_size)


# NinePatchRect рендерится в (window / scale), затем сжимается scale'ом обратно
# до окна — углы получают целевой display-размер, края тянутся как обычно.
func _update_size() -> void:
	var win: Vector2 = get_viewport().get_visible_rect().size
	_frame.position = Vector2.ZERO
	_frame.size     = win / _DISPLAY_SCALE


## CanvasLayer не наследует show/hide от CanvasItem — заворачиваем `visible`
## в говорящий метод.
func set_enabled(on: bool) -> void:
	visible = on
