extends CanvasLayer

## Заглушка встречи — выезжает когда фаза encounter и я её ещё не завершил.
## Кнопка «Завершить» вызывает GameState.finish_encounter().

@onready var _root:        Control        = $Root
@onready var _backdrop:    ColorRect      = $Root/Backdrop
@onready var _panel:       PanelContainer = %Panel
@onready var _title:       Label          = %Title
@onready var _body:        Label          = %Body
@onready var _finish_btn:  Button         = %FinishBtn


func _ready() -> void:
	UIStyle.style_panel(_panel, 24)
	UIStyle.style_button(_finish_btn, UIColors.ACCENT)
	_title.add_theme_color_override("font_color", UIColors.ACCENT)
	_body.add_theme_color_override("font_color", UIColors.TEXT)

	_finish_btn.pressed.connect(func() -> void: GameState.finish_encounter())

	GameState.state_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	# Модалка видна только когда наступила МОЯ очередь на встречу
	# (встречи проходят последовательно по turn_order).
	_root.visible = GameState.is_my_encounter_turn()
