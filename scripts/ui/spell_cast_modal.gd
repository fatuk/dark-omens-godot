extends CanvasLayer

## Модалка «какие из триггер-заклинаний скастить» (напр. при отдыхе). Видна
## владельцу промпта GameState.pending_spell_cast в его ход. По умолчанию все
## заклинания отмечены; снять галку — не кастить именно его. «Скастить» →
## act(CAST_TRIGGER_SPELLS, {spells: выбранные item-индексы}): хост резолвит выбранные,
## чистит промпт — модалка скрывается. Пустой выбор — ничего не кастить (отдых
## завершается, ход уходит если это было последнее действие). См.
## SpellFlow.prompt_trigger / PhaseController.host_apply_cast_trigger_spells.

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

var _sig: String = ""  # подпись набора (чтобы не перестраивать зря на каждый синк)
var _checks: Array = []  # [{ "cb": CheckBox, "index": int }]


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	GameState.state_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var prompt: Dictionary = GameState.pending_spell_cast
	var should_show: bool = GameState.is_my_turn() and not prompt.is_empty()
	UIStyle.modal_set_visible(_root, _panel, should_show)
	if not should_show:
		_sig = ""
		return
	var opts: Array = prompt.get("options", [])
	var sig: String = _signature(opts)
	if sig == _sig:
		return
	_sig = sig
	_build(opts)


# Подпись набора (index:id,…) — перестраиваем модалку только при смене набора.
func _signature(opts: Array) -> String:
	var parts: PackedStringArray = []
	for o_v: Variant in opts:
		var o: Dictionary = o_v
		parts.append("%d:%s" % [int(o.get("index", -1)), String(o.get("id", ""))])
	return ",".join(parts)


func _build(opts: Array) -> void:
	for c in _vbox.get_children():
		c.queue_free()
	_checks.clear()

	_vbox.add_child(UIStyle.modal_title("SPELL_CAST_TITLE"))

	for o_v: Variant in opts:
		var o: Dictionary = o_v
		var idx: int = int(o.get("index", -1))
		var spell: Dictionary = SpellCatalog.by_id(String(o.get("id", "")))
		var cb := CheckBox.new()
		cb.name = "SpellCheck%d" % idx
		cb.button_pressed = true  # по умолчанию все выбраны
		cb.text = String(spell.get("name", o.get("id", "")))  # ключ i18n (авто-перевод)
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_vbox.add_child(cb)
		_checks.append({"cb": cb, "index": idx})

	var confirm := Button.new()
	confirm.name = "ConfirmButton"
	confirm.text = "SPELL_CAST_CONFIRM"
	confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_button(confirm)
	confirm.pressed.connect(_on_confirm)
	_vbox.add_child(confirm)


func _on_confirm() -> void:
	var chosen: Array = []
	for entry_v: Variant in _checks:
		var entry: Dictionary = entry_v
		if bool((entry["cb"] as CheckBox).button_pressed):
			chosen.append(int(entry["index"]))
	UIStyle.modal_set_visible(_root, _panel, false)  # скрыть сразу, не ждать синка
	_sig = ""
	GameState.act(RelayActions.CAST_TRIGGER_SPELLS, {"spells": chosen})
