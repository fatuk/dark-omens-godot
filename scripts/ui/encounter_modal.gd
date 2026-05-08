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
	# Видна только если сейчас фаза encounter и я ещё не завершил свою
	var should_show: bool = GameState.active and GameState.phase == "encounter" \
		and not GameState.have_finished_encounter()
	_root.visible = should_show
