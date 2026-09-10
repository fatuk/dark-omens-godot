extends CanvasLayer

## Модалка выбора типа встречи. Видна активному игроку в фазе encounter, пока
## GameState.encounter_choices непусто. Кнопка → act(CHOOSE_ENCOUNTER, {kind}),
## после чего хост генерирует встречу выбранного вида и эта модалка скрывается
## (encounter_choices очищается), уступая место окну встречи.

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

# kind → ключ перевода подписи кнопки.
const _KIND_KEYS := {
	"general": "ENCOUNTER_CHOICE_GENERAL",
	"research": "ENCOUNTER_CHOICE_RESEARCH",
	"gate": "ENCOUNTER_CHOICE_GATE",
	"combat": "ENCOUNTER_CHOICE_COMBAT",
	"mystery": "ENCOUNTER_CHOICE_MYSTERY",
	"eldritch": "ENCOUNTER_CHOICE_ELDRITCH",
	"local": "ENCOUNTER_CHOICE_LOCAL",
	"rumor": "ENCOUNTER_CHOICE_RUMOR",
	"belongings": "ENCOUNTER_CHOICE_BELONGINGS",
}

var _sig: String = ""  # подпись текущего набора кнопок (чтобы не перестраивать зря)


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	GameState.state_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var mine: bool = GameState.is_my_encounter_turn()
	var choices: Array = GameState.encounter_choices
	var should_show: bool = mine and not choices.is_empty()
	UIStyle.modal_set_visible(_root, _panel, should_show)
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

	# Порядок боёв: варианты "combat:<idx>" — это монстры на клетке, а не типы
	# встреч. Заголовок и подписи другие: сыщик выбирает, с КЕМ драться первым.
	var combat_order: bool = not choices.is_empty() and String(choices[0]).begins_with("combat:")
	_vbox.add_child(
		UIStyle.modal_title(
			"ENCOUNTER_CHOICE_COMBAT_ORDER" if combat_order else "ENCOUNTER_CHOICE_TITLE"
		)
	)

	for i: int in range(choices.size()):
		var kind: String = String(choices[i])
		var btn := Button.new()
		btn.name = "Button"
		btn.text = _monster_label(kind) if combat_order else String(_KIND_KEYS.get(kind, kind))
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIStyle.style_button(btn)
		btn.pressed.connect(
			func() -> void: GameState.act(RelayActions.CHOOSE_ENCOUNTER, {"kind": kind})
		)
		_vbox.add_child(btn)


# Подпись кнопки порядка боя: имя монстра и здоровье («Гуль · 2/3»). Экземпляр
# берём из синкнутых monsters по индексу на клетке сыщика; здоровье без поля —
# полное (легаси-строка).
func _monster_label(choice: String) -> String:
	var idx: int = int(choice.substr(7))
	var loc: String = String(GameState.my_player().get("location", ""))
	var mons: Array = GameState.monsters.get(loc, [])
	if idx < 0 or idx >= mons.size():
		return choice
	var inst_v: Variant = mons[idx]
	var mid: String = String(inst_v.get("id", "")) if inst_v is Dictionary else String(inst_v)
	var m: Dictionary = MonsterCatalog.by_id(mid)
	if m.is_empty():
		return mid
	var tough: int = MonsterCatalog.toughness_for(m, GameState.campaign.get("playerCount", 1))
	var hp: int = (
		int((inst_v as Dictionary).get("health", tough)) if inst_v is Dictionary else tough
	)
	return "%s  ·  %d/%d" % [tr(String(m.get("nameKey", mid))), hp, tough]
