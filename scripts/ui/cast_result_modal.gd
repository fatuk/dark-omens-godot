extends CanvasLayer

## Модалка расплаты заклинания. Показывает владельцу GameState.last_cast_result,
## какой оборот выпал: название заклинания (заголовок), художественный текст
## расплаты (flavor-ключ оборота) и ЧИСТЫЙ итог рубашки (−здоровье/−рассудок/−улики,
## новые состояния, сброс — либо «обошлось», если итог пуст). Кнопка закрывает и
## чистит результат (GameState.dismiss_cast_result). Не привязана к ходу — видна и
## после того, как каст завершил ход игрока. См. SpellFlow.resolve_cast.

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

var _sig: String = ""  # подпись результата (чтобы не перестраивать зря на каждый синк)


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	GameState.state_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var r: Dictionary = GameState.last_cast_result
	var mine: bool = not r.is_empty() and String(r.get("pid", "")) == _my_id()
	_root.visible = mine
	if not mine:
		_sig = ""
		return
	var sig: String = "%s|%d" % [String(r.get("back", "")), int(r.get("successes", 0))]
	if sig == _sig:
		return
	_sig = sig
	_build(r)


func _my_id() -> String:
	return String(GameState.my_player().get("user_id", ""))


func _build(r: Dictionary) -> void:
	for c in _vbox.get_children():
		c.queue_free()

	var spell: Dictionary = SpellCatalog.by_id(String(r.get("spell", "")))
	_vbox.add_child(UIStyle.modal_title(String(spell.get("name", ""))))

	var flavor := Label.new()
	flavor.name = "Flavor"
	flavor.text = String(r.get("text", ""))  # ключ RECK_<id> (авто-перевод)
	flavor.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	flavor.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(flavor)

	for ln_v: Variant in _outcome_lines(r.get("outcome", {})):
		var lbl := Label.new()
		lbl.name = "Outcome"
		lbl.text = String(ln_v)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_vbox.add_child(lbl)

	var ok := Button.new()
	ok.name = "OkButton"
	ok.text = "BTN_OK"
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_button(ok)
	ok.pressed.connect(_on_ok)
	_vbox.add_child(ok)
	UIStyle.scale_modal_text(_vbox)


# Локализованные строки итога из outcome-словаря (пусто → «обошлось»). %+d — со
# знаком: −1 / +1. Состояния — по локализованному имени (Conditions.name_key).
func _outcome_lines(outcome: Dictionary) -> Array:
	var out: Array = []
	if outcome.is_empty():
		out.append(tr("RECK_OUT_NONE"))
		return out
	if outcome.has("health"):
		out.append(tr("RECK_OUT_HEALTH") % int(outcome["health"]))
	if outcome.has("sanity"):
		out.append(tr("RECK_OUT_SANITY") % int(outcome["sanity"]))
	if outcome.has("clues"):
		out.append(tr("RECK_OUT_CLUES") % int(outcome["clues"]))
	for c_v: Variant in outcome.get("conditions", []):
		out.append(tr("RECK_OUT_CONDITION") % tr(Conditions.name_key(String(c_v))))
	if bool(outcome.get("discarded", false)):
		out.append(tr("RECK_OUT_DISCARDED"))
	return out


func _on_ok() -> void:
	_root.visible = false  # скрыть сразу, не ждать синка
	_sig = ""
	GameState.dismiss_cast_result()
