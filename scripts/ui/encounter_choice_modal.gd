extends CanvasLayer

## Модалка выбора типа встречи. Видна активному игроку в фазе encounter, пока
## GameState.encounter_choices непусто. Кнопка → GameState.choose_encounter(kind),
## после чего хост генерирует встречу выбранного вида и эта модалка скрывается
## (encounter_choices очищается), уступая место окну встречи.

@onready var _root:  Control        = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox:  VBoxContainer  = %VBox

# kind → ключ перевода подписи кнопки.
const _KIND_KEYS := {
	"general":  "ENCOUNTER_CHOICE_GENERAL",
	"research": "ENCOUNTER_CHOICE_RESEARCH",
	"gate":     "ENCOUNTER_CHOICE_GATE",
	"combat":   "ENCOUNTER_CHOICE_COMBAT",
}

var _sig: String = ""   # подпись текущего набора кнопок (чтобы не перестраивать зря)


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	GameState.state_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var mine: bool = GameState.is_my_encounter_turn()
	var choices: Array = GameState.encounter_choices
	var should_show: bool = mine and not choices.is_empty()
	_root.visible = should_show
	if not should_show:
		_sig = ""
		return
	var sig: String = ",".join(PackedStringArray(choices))
	if sig == _sig:
		return
	_sig = sig
	_build(choices)


func _build(choices: Array) -> void:
	for c in _vbox.get_children():
		c.queue_free()

	_vbox.add_child(UIStyle.modal_title("ENCOUNTER_CHOICE_TITLE"))

	for i: int in range(choices.size()):
		var kind: String = String(choices[i])
		var btn := Button.new()
		btn.text = String(_KIND_KEYS.get(kind, kind))   # ключ перевода
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIStyle.style_button(btn)
		btn.pressed.connect(func() -> void: GameState.choose_encounter(kind))
		_vbox.add_child(btn)
