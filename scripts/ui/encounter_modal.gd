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
	UIStyle.style_modal_panel(_panel)
	UIStyle.style_button(_roll_btn)
	UIStyle.style_button(_finish_btn)
	_title.add_theme_color_override("font_color",     UIColors.ACCENT)
	_main_text.add_theme_color_override("font_color", UIColors.TEXT)
	_check.add_theme_color_override("font_color",     UIColors.MUTED)
	_dice.add_theme_color_override("font_color",      UIColors.MUTED)

	_roll_btn.pressed.connect(_on_roll_pressed)
	_finish_btn.pressed.connect(_on_finish_pressed)

	GameState.state_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var mine: bool = GameState.is_my_encounter_turn()
	# Пока активный игрок выбирает тип встречи — окно встречи скрыто
	# (его место занимает модалка выбора).
	if mine and not (GameState.encounter_choices as Array).is_empty():
		_root.visible = false
		return
	_root.visible = mine
	if not mine:
		return
	var card: Dictionary = GameState.current_encounter
	# Бой — отдельная боевая модалка; это окно скрываем.
	if String(card.get("kind", "")) == "combat":
		_root.visible = false
		return
	if card.is_empty():
		_show_loading()
	elif String(card.get("kind", "")) == "gate":
		_show_gate(card)
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
	_finish_btn.text    = "BTN_FINISH_BIG"
	_finish_btn.visible = true


# Двухстадийная встреча Иного мира (gate): показываем текущую стадию. Нет
# stage_resolution → текст стадии + бросок; есть → исход + «Дальше» (если успех
# и стадия не последняя) либо «Завершить».
func _show_gate(card: Dictionary) -> void:
	var stages: Array = card.get("stages", [])
	var stage: int = int(card.get("stage", 0))
	if stages.is_empty() or stage < 0 or stage >= stages.size():
		_show_loading()
		return
	var st: Dictionary = stages[stage]
	var total: int = stages.size()
	_title.text     = "%s  (%d/%d)" % [String(card.get("name", "ENCOUNTER_TITLE")), stage + 1, total]
	_main_text.text = String(st.get("mainText", ""))
	_check.text     = _check_label(st.get("test", {}))
	_check.visible  = true

	if not card.has("stage_resolution"):
		_roll_btn.visible   = true
		_roll_btn.disabled  = false
		_dice.visible       = false
		_outcome.visible    = false
		_finish_btn.visible = false
		return

	var res: Dictionary = card["stage_resolution"]
	var passed: bool = bool(res.get("passed", false))
	_dice.text    = _dice_label(res)
	_dice.visible = true
	_outcome.text = String(st.get("successText" if passed else "failureText", ""))
	_outcome.add_theme_color_override(
		"font_color", UIColors.SUCCESS if passed else UIColors.DANGER
	)
	_outcome.visible  = true
	_roll_btn.visible = false
	# Успех и есть следующая стадия → «Дальше»; иначе встреча окончена → «Завершить».
	var more: bool = passed and stage < total - 1
	_finish_btn.text    = "ENCOUNTER_CONTINUE" if more else "BTN_FINISH_BIG"
	_finish_btn.visible = true


func _on_roll_pressed() -> void:
	_roll_btn.disabled = true   # хост разрешит встречу и пришлёт результат синком
	GameState.resolve_encounter()


# Кнопка под исходом: для gate с успехом и следующей стадией — «Дальше»
# (переход стадии), иначе — завершение встречи.
func _on_finish_pressed() -> void:
	var card: Dictionary = GameState.current_encounter
	if String(card.get("kind", "")) == "gate":
		var stages: Array = card.get("stages", [])
		var stage: int = int(card.get("stage", 0))
		var res: Dictionary = card.get("stage_resolution", {})
		if bool(res.get("passed", false)) and stage < stages.size() - 1:
			GameState.advance_encounter_stage()
			return
	GameState.finish_encounter()


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
