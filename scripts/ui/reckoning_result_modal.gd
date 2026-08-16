extends CanvasLayer

## Модалка результата флипа состояния на Расплате (по образу cast_result_modal).
## Показывает владельцу его запись из GameState.reckoning_results[pid]: какое
## состояние перевернулось (заголовок), имя выпавшего оборота и художественный текст
## (самоописательный — мех-эффект уже в прозе). Кнопка закрывает → хост убирает
## запись (dismiss_reckoning_result). Per-player: каждый видит свой результат.

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

var _sig: String = ""  # подпись (чтобы не перестраивать зря на каждый синк)


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	GameState.state_changed.connect(_refresh)
	_refresh()


func _my_id() -> String:
	return String(GameState.my_player().get("user_id", ""))


func _refresh() -> void:
	var r: Dictionary = GameState.reckoning_results.get(_my_id(), {})
	var should_show: bool = not r.is_empty()
	UIStyle.modal_set_visible(_root, _panel, should_show)
	if not should_show:
		_sig = ""
		return
	var sig: String = "%s|%s" % [String(r.get("cid", "")), String(r.get("back", ""))]
	if sig == _sig:
		return
	_sig = sig
	_build(r)


func _build(r: Dictionary) -> void:
	for c in _vbox.get_children():
		c.queue_free()

	# Заголовок — какое состояние перевернулось (имя состояния, авто-перевод).
	_vbox.add_child(UIStyle.modal_title(Conditions.name_key(String(r.get("cid", "")))))

	# Имя выпавшего оборота (подзаголовок).
	var oname := Label.new()
	oname.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_LEAD)
	oname.name = "OutcomeName"
	oname.text = String(r.get("name", ""))  # ключ i18n → авто-перевод
	oname.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	oname.add_theme_color_override("font_color", UIColors.ACCENT)
	_vbox.add_child(oname)

	# Художественный текст оборота (включает механический эффект).
	var flavor := Label.new()
	flavor.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_BODY)
	flavor.name = "Flavor"
	flavor.text = String(r.get("text", ""))  # ключ i18n → авто-перевод
	flavor.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	flavor.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(flavor)

	var ok := Button.new()
	ok.name = "OkButton"
	ok.text = "BTN_OK"
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_button(ok)
	ok.pressed.connect(_on_ok)
	_vbox.add_child(ok)


func _on_ok() -> void:
	UIStyle.modal_set_visible(_root, _panel, false)  # скрыть сразу, не ждать синка
	_sig = ""
	GameState.dismiss_reckoning_result()
