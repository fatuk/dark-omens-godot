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

# Кнопка переброса за концентрацию — создаётся кодом, ставится перед FinishBtn.
var _reroll_btn: Button

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

	# Кнопка переброса — между исходом и «Завершить»/«Дальше».
	_reroll_btn = Button.new()
	_reroll_btn.name = "RerollBtn"
	UIStyle.style_button(_reroll_btn, UIColors.MUTED)
	_reroll_btn.pressed.connect(_on_reroll_pressed)
	var vbox: Node = _finish_btn.get_parent()
	vbox.add_child(_reroll_btn)
	vbox.move_child(_reroll_btn, _finish_btn.get_index())   # перед FinishBtn
	_reroll_btn.visible = false

	_roll_btn.pressed.connect(_on_roll_pressed)
	_finish_btn.pressed.connect(_on_finish_pressed)
	UIStyle.scale_modal_text(_panel)   # текст модалок крупнее (×1.5)

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
	elif _is_branching(card):
		_show_gate(card)   # gate и mystery — общая ветвящаяся структура
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
	_update_reroll_btn(false)


func _show_card(card: Dictionary) -> void:
	_title.text     = _title_text(card)
	_main_text.text = _main_or_stakes(card)
	_check.text         = _check_label(card.get("test", {}))
	_check.visible      = true
	_roll_btn.visible   = true
	_roll_btn.disabled  = false
	_dice.visible       = false
	_outcome.visible    = false
	_finish_btn.visible = false
	_update_reroll_btn(false)


func _show_outcome(card: Dictionary) -> void:
	var res: Dictionary = card["resolution"]
	var passed: bool = bool(res.get("passed", false))
	_title.text     = _title_text(card)
	_main_text.text = _main_or_stakes(card)
	_check.text     = _check_label(card.get("test", {}))
	_check.visible  = true
	_dice.text      = _dice_label(res)
	_dice.visible   = true
	_outcome.text   = _outcome_text(card, passed)
	_outcome.add_theme_color_override(
		"font_color", UIColors.SUCCESS if passed else UIColors.DANGER
	)
	_outcome.visible    = true
	_roll_btn.visible   = false
	_finish_btn.text    = "BTN_FINISH_BIG"
	_finish_btn.visible = true
	_update_reroll_btn(true)   # одиночная встреча — переброс доступен до «Завершить»


# Двухфазные врата — дерево глубины 2. Стадия 0 (stage1) маршрутизирует: бросок
# → исход выбирает ветку, после чего «Дальше» ведёт ко второй проверке ПРИ ЛЮБОМ
# исходе. Стадия 1 — вторая проверка ветки: исход + «Завершить».
func _show_gate(card: Dictionary) -> void:
	var stage: int = int(card.get("stage", 0))
	var node: Dictionary = _gate_node(card, stage)
	if node.is_empty():
		_show_loading()
		return
	_title.text     = "%s  (%d/2)" % [_title_text(card), stage + 1]
	_main_text.text = _main_or_stakes(node)
	_check.text     = _check_label(node.get("test", {}))
	_check.visible  = true

	if not card.has("stage_resolution"):
		_roll_btn.visible   = true
		_roll_btn.disabled  = false
		_dice.visible       = false
		_outcome.visible    = false
		_finish_btn.visible = false
		_update_reroll_btn(false)
		return

	var res: Dictionary = card["stage_resolution"]
	var passed: bool = bool(res.get("passed", false))
	_dice.text    = _dice_label(res)
	_dice.visible = true
	_outcome.text = _outcome_text(node, passed)
	_outcome.add_theme_color_override(
		"font_color", UIColors.SUCCESS if passed else UIColors.DANGER
	)
	_outcome.visible  = true
	_roll_btn.visible = false
	# После первой проверки (stage 0) всегда «Дальше» (обе ветви ведут ко второй
	# проверке); после второй (stage 1) — «Завершить».
	var more: bool = stage == 0
	_finish_btn.text    = "ENCOUNTER_CONTINUE" if more else "BTN_FINISH_BIG"
	_finish_btn.visible = true
	_update_reroll_btn(true)   # переброс доступен на любой фазе до перехода/финиша


# Ветвящиеся встречи (gate и mystery) — одинаковая структура card.stage1 +
# card.branches.{success,failure}. UI и резолв общие.
func _is_branching(card: Dictionary) -> bool:
	var k: String = String(card.get("kind", ""))
	return k == "gate" or k == "mystery"


# Активный узел ветвящейся встречи: стадия 0 → stage1, стадия 1 → ветка по
# результату первой проверки (success/failure).
func _gate_node(card: Dictionary, stage: int) -> Dictionary:
	if stage <= 0:
		return card.get("stage1", {})
	var branches: Dictionary = card.get("branches", {})
	var branch: String = String(card.get("branch", "success"))
	return branches.get(branch, {})


func _on_roll_pressed() -> void:
	_roll_btn.disabled = true   # хост разрешит встречу и пришлёт результат синком
	GameState.resolve_encounter()


func _on_reroll_pressed() -> void:
	_reroll_btn.disabled = true   # хост пришлёт обновлённый бросок синком
	GameState.reroll_encounter()


# Видимость кнопки переброса: показываем при показанном результате броска, если
# есть концентрация, встреча не зафиксирована и это не бой.
func _update_reroll_btn(roll_shown: bool) -> void:
	if not is_instance_valid(_reroll_btn):
		return
	var enc: Dictionary = GameState.current_encounter
	var foc: int = int(GameState.my_player().get("concentration", 0))
	var committed: bool = bool(enc.get("committed", false))
	var combat: bool = String(enc.get("kind", "")) == "combat"
	if roll_shown and foc > 0 and not committed and not combat:
		_reroll_btn.text     = tr("ENCOUNTER_REROLL") % foc
		_reroll_btn.disabled = false
		_reroll_btn.visible  = true
	else:
		_reroll_btn.visible = false


# Кнопка под исходом: после первой проверки врат (stage 0) — «Дальше» ко второй
# проверке при ЛЮБОМ исходе (ветка выбирается по успеху/провалу); иначе — конец.
func _on_finish_pressed() -> void:
	var card: Dictionary = GameState.current_encounter
	if _is_branching(card):
		if int(card.get("stage", 0)) == 0 and card.has("stage_resolution"):
			GameState.advance_encounter_stage()
			return
	GameState.finish_encounter()


# ── Хелперы текста ────────────────────────────────────────────────────────────

# Заголовок: имя карты (от LLM) либо локализованный фолбэк (механический режим).
func _title_text(card: Dictionary) -> String:
	var n: String = String(card.get("name", "")).strip_edges()
	return n if not n.is_empty() else tr("ENCOUNTER_TITLE")


# Основной текст: художественный mainText, а если пуст (механический режим без
# LLM) — ставки проверки: что даёт успех и чем карает провал.
func _main_or_stakes(src: Dictionary) -> String:
	var main: String = String(src.get("mainText", "")).strip_edges()
	if not main.is_empty():
		return main
	var succ: Array = src.get("onSuccess", [])
	var fail: Array = src.get("onFailure", [])
	# Маршрутизирующая стадия (без эффектов на любом исходе) — нейтрально, текст
	# по виду встречи: врата — Иной мир, Тайна — расследование на месте.
	if succ.is_empty() and fail.is_empty():
		var kind: String = String(GameState.current_encounter.get("kind", ""))
		return tr("ENCOUNTER_MYSTERY_TRIAL" if kind == "mystery" else "ENCOUNTER_GATE_TRIAL")
	return "%s: %s\n%s: %s" % [
		tr("ENC_REWARD"),  _describe_effects(succ),
		tr("ENC_PENALTY"), _describe_effects(fail),
	]


# Текст исхода: художественный success/failureText, либо описание применённых
# эффектов, если текста нет (механический режим); пустой исход → «идём дальше».
func _outcome_text(src: Dictionary, passed: bool) -> String:
	var txt: String = String(src.get("successText" if passed else "failureText", "")).strip_edges()
	if not txt.is_empty():
		return txt
	var arr: Array = src.get("onSuccess" if passed else "onFailure", [])
	if arr.is_empty():
		return tr("ENCOUNTER_PROCEED")
	return _describe_effects(arr)


# ── Описание эффектов (для механического режима) ───────────────────────────────

func _describe_effects(arr: Variant) -> String:
	if not (arr is Array) or (arr as Array).is_empty():
		return tr("ENC_EFF_NONE")
	var parts := PackedStringArray()
	for i in range((arr as Array).size()):
		var e: Variant = (arr as Array)[i]
		if e is Dictionary:
			parts.append(_describe_one(e))
	return ", ".join(parts) if parts.size() > 0 else tr("ENC_EFF_NONE")


func _describe_one(eff: Dictionary) -> String:
	var verb: String = String(eff.get("do", ""))
	var amount: int = int(eff.get("amount", eff.get("count", 1)))
	match verb:
		"gainClue":      return tr("ENC_EFF_CLUE") % amount
		"loseClue":      return tr("ENC_EFF_CLUE") % -amount
		"healHealth":    return tr("ENC_EFF_HP")  % amount
		"loseHealth":    return tr("ENC_EFF_HP")  % -amount
		"healSanity":    return tr("ENC_EFF_SAN") % amount
		"loseSanity":    return tr("ENC_EFF_SAN") % -amount
		"gainSpell":     return tr("ENC_EFF_SPELL")
		"gainArtifact":  return tr("ENC_EFF_ARTIFACT")
		"gainAsset":     return tr("ENC_EFF_ASSET")
		"improveSkill":  return tr("ENC_EFF_IMPROVE") % amount
		"gainCondition": return tr("ENC_EFF_COND_GAIN") % tr(Conditions.name_key(String(eff.get("condition", ""))))
		"loseCondition": return tr("ENC_EFF_COND_LOSE") % tr(Conditions.name_key(String(eff.get("condition", ""))))
		"move":          return tr("ENC_EFF_MOVE")
		"closeGate":     return tr("ENC_EFF_CLOSE_GATE")
		"":
			# Комбинатор: choice → ветви через «/», group → перечисление.
			if eff.has("choice"):
				return _describe_effects(eff.get("choice", [])).replace(", ", " / ")
			if eff.has("group"):
				return _describe_effects(eff.get("group", []))
			return verb
		_:
			return verb


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
