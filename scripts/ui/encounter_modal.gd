extends CanvasLayer

## Окно встречи. Видно активному игроку в фазе encounter.
##
## Чистое отражение GameState.current_encounter — состояние выводится из
## синкнутых данных:
##   пусто           → карта генерится (загрузка);
##   карта           → текст встречи + кнопка броска;
##   есть resolution → кубики, исход, кнопка «Завершить».
##
## Бросок проверки и эффекты onSuccess/onFailure — авторитетно у хоста
## (GameState.resolve_encounter); окно лишь показывает синкнутый результат.

@onready var _root:       Control        = $Root
@onready var _panel:      PanelContainer = %Panel
@onready var _title:      Label          = %Title
@onready var _main_text:  Label          = %MainText
@onready var _check:      Label          = %Check
@onready var _roll_btn:   Button         = %RollBtn
@onready var _dice:       Label          = %Dice
@onready var _outcome:    Label          = %Outcome
@onready var _finish_btn: Button         = %FinishBtn

# Навык → ключ перевода для подписи проверки.
const _SKILL_KEYS := {
	"lore":        "SKILL_LORE",
	"influence":   "SKILL_INFLUENCE",
	"observation": "SKILL_OBSERVATION",
	"strength":    "SKILL_STRENGTH",
	"will":        "SKILL_WILL",
}


func _ready() -> void:
	UIStyle.style_panel(_panel, 24)
	UIStyle.style_button(_roll_btn)
	UIStyle.style_button(_finish_btn)
	_title.add_theme_color_override("font_color",     UIColors.ACCENT)
	_main_text.add_theme_color_override("font_color", UIColors.TEXT)
	_check.add_theme_color_override("font_color",     UIColors.MUTED)
	_dice.add_theme_color_override("font_color",      UIColors.MUTED)

	_roll_btn.pressed.connect(_on_roll_pressed)
	_finish_btn.pressed.connect(func() -> void: GameState.finish_encounter())

	GameState.state_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var mine: bool = GameState.is_my_encounter_turn()
	_root.visible = mine
	if not mine:
		return
	var card: Dictionary = GameState.current_encounter
	if card.is_empty():
		_show_loading()
	elif card.has("resolution"):
		_show_outcome(card)
	else:
		_show_card(card)


# ── Состояния окна ────────────────────────────────────────────────────────────

func _show_loading() -> void:
	_title.text     = "ENCOUNTER_TITLE"
	_main_text.text = "ENCOUNTER_GENERATING"
	for node: Control in [_check, _roll_btn, _dice, _outcome, _finish_btn]:
		node.visible = false


func _show_card(card: Dictionary) -> void:
	_title.text     = String(card.get("name", "ENCOUNTER_TITLE"))
	_main_text.text = String(card.get("mainText", ""))
	_check.text         = _check_label(card.get("test", {}))
	_check.visible      = true
	_roll_btn.visible   = true
	_roll_btn.disabled  = false
	_dice.visible       = false
	_outcome.visible    = false
	_finish_btn.visible = false


func _show_outcome(card: Dictionary) -> void:
	var res: Dictionary = card["resolution"]
	var passed: bool = bool(res.get("passed", false))
	_title.text     = String(card.get("name", "ENCOUNTER_TITLE"))
	_main_text.text = String(card.get("mainText", ""))
	_check.text     = _check_label(card.get("test", {}))
	_check.visible  = true
	_dice.text      = _dice_label(res)
	_dice.visible   = true
	_outcome.text   = String(card.get("successText" if passed else "failureText", ""))
	_outcome.add_theme_color_override(
		"font_color", UIColors.SUCCESS if passed else UIColors.DANGER
	)
	_outcome.visible    = true
	_roll_btn.visible   = false
	_finish_btn.visible = true


func _on_roll_pressed() -> void:
	_roll_btn.disabled = true   # хост разрешит встречу и пришлёт результат синком
	GameState.resolve_encounter()


# ── Хелперы текста ────────────────────────────────────────────────────────────

func _check_label(test: Dictionary) -> String:
	var skill: String = String(test.get("skill", "will"))
	var modifier: int = int(test.get("modifier", 0))
	var skill_name: String = tr(String(_SKILL_KEYS.get(skill, "SKILL_WILL")))
	var line: String = "%s: %s" % [tr("ENCOUNTER_CHECK"), skill_name]
	if modifier != 0:
		line += " %+d" % modifier
	return line


func _dice_label(res: Dictionary) -> String:
	return "%s: %s · %s: %d" % [
		tr("ENCOUNTER_DICE"),
		", ".join(_to_strings(res.get("dice", []))),
		tr("ENCOUNTER_SUCCESSES"),
		int(res.get("successes", 0)),
	]


func _to_strings(nums: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(nums.size()):
		out.append(str(nums[i]))
	return out
