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

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _title: Label = %Title
@onready var _main_text: Label = %MainText
@onready var _check: Label = %Check
@onready var _roll_btn: Button = %RollBtn
@onready var _dice: Label = %Dice
@onready var _outcome: Label = %Outcome
@onready var _finish_btn: Button = %FinishBtn

# Ряд кубиков (DiceTray) — создаётся кодом над строкой _dice.
var _dice_holder: VBoxContainer
# Контейнер кнопок интерактивного выбора (choice в эффектах) — создаётся кодом.
var _choice_holder: VBoxContainer
var _tray: DiceTray  # единый лоток, создаётся лениво и переиспользуется
var _last_dice: Array = []  # последний показанный бросок (спин — только на свежем)
var _last_can: bool = false  # последняя кликабельность кубов (обновление без смены кубов)
var _pending_n: int = -1  # сколько рубашек показано до броска
# Пока есть перебросы (концентрация), исход ПРОВАЛА скрыт, чтобы не спойлить до
# решения перебросить/принять. true → игрок «принял» (раскрыл) текущий провал.
var _revealed: bool = false

# Навык → ключ перевода для подписи проверки.
const _SKILL_KEYS := {
	"lore": "SKILL_LORE",
	"influence": "SKILL_INFLUENCE",
	"observation": "SKILL_OBSERVATION",
	"strength": "SKILL_STRENGTH",
	"will": "SKILL_WILL",
}


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	UIStyle.style_button(_roll_btn)
	UIStyle.style_button(_finish_btn)
	_title.add_theme_color_override("font_color", UIColors.ACCENT)
	_main_text.add_theme_color_override("font_color", UIColors.TEXT)
	_check.add_theme_color_override("font_color", UIColors.MUTED)
	_dice.add_theme_color_override("font_color", UIColors.MUTED)

	# Контейнер ряда кубиков — над строкой _dice (успехи/концентрация).
	_dice_holder = VBoxContainer.new()
	_dice_holder.name = "DiceHolder"
	_dice_holder.alignment = BoxContainer.ALIGNMENT_CENTER
	var vbox: Node = _dice.get_parent()
	vbox.add_child(_dice_holder)
	vbox.move_child(_dice_holder, _roll_btn.get_index())  # кубы НАД кнопкой броска
	_dice_holder.visible = false

	# Контейнер кнопок интерактивного выбора — под текстом, на месте кнопки броска.
	_choice_holder = VBoxContainer.new()
	_choice_holder.name = "ChoiceHolder"
	_choice_holder.add_theme_constant_override("separation", 8)
	vbox.add_child(_choice_holder)
	vbox.move_child(_choice_holder, _roll_btn.get_index())
	_choice_holder.visible = false

	_roll_btn.pressed.connect(_on_roll_pressed)
	_finish_btn.pressed.connect(_on_finish_pressed)
	UIStyle.scale_modal_text(_panel)  # текст модалок крупнее (×1.5)

	GameState.state_changed.connect(_refresh)
	_refresh()


# Активная проверка встречи (единая, CheckFlow), если она относится к встрече.
func _chk() -> Dictionary:
	var c: Dictionary = GameState.active_check
	return c if String(c.get("owner", "")) == "encounter" else {}


func _chk_rolled() -> bool:
	return bool(_chk().get("rolled", false))


# Доступен ли «перебросить все провальные кубы разом» (Счастливый талисман):
# проверка брошена, запас есть, исход ещё не принят и встреча не зафиксирована.
func _reroll_all_available() -> bool:
	if _revealed or bool(GameState.current_encounter.get("committed", false)):
		return false
	var c: Dictionary = _chk()
	return int(c.get("reroll_all_allowance", 0)) - int(c.get("reroll_all_used", 0)) > 0


# Кнопка броска переиспользуется как «Перебросить кубы», пока доступен reroll-all.
func _set_reroll_all_btn() -> void:
	if _reroll_all_available():
		_roll_btn.text = "ENCOUNTER_REROLL_ALL"
		_roll_btn.disabled = false
		_roll_btn.visible = true
	else:
		_roll_btn.visible = false


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
	# Интерактивный выбор ветки эффектов (choice) — поверх любого состояния:
	# коммит встал на паузу и ждёт решения активного игрока.
	if not (card.get("pending_choice", {}) as Dictionary).is_empty():
		_show_choice(card)
		return
	_clear_choice()
	if card.is_empty():
		_show_loading()
	elif _is_branching(card):
		_show_gate(card)  # gate и mystery — общая ветвящаяся структура
	elif _chk_rolled():
		_show_outcome(card)
	else:
		_show_card(card)


# ── Состояния окна ────────────────────────────────────────────────────────────


func _show_loading() -> void:
	_title.text = "ENCOUNTER_TITLE"
	_main_text.text = "ENCOUNTER_GENERATING"
	for node: Control in [_check, _roll_btn, _dice, _outcome, _finish_btn]:
		node.visible = false
	_hide_dice()


# Интерактивный выбор: подсказка + кнопка на каждую ветку pending_choice.options.
# Клик → GameState.choose_effect(index); хост запишет выбор и доиграет коммит.
func _show_choice(card: Dictionary) -> void:
	var pending: Dictionary = card.get("pending_choice", {})
	var kind: String = String(pending.get("kind", "choice"))  # choice | target | monster
	_title.text = _title_text(card)
	_main_text.text = tr(_choose_prompt_key(kind))
	for node: Control in [_check, _roll_btn, _dice, _outcome, _finish_btn]:
		node.visible = false
	_hide_dice()
	_clear_choice()
	var options: Array = pending.get("options", [])
	for i in range(options.size()):
		var b: Variant = options[i]
		var btn := Button.new()
		btn.name = "ChoiceBtn%d" % i
		btn.text = _choice_label(b if b is Dictionary else {}, kind)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIStyle.style_button(btn)
		var idx: int = i
		btn.pressed.connect(func() -> void: _on_choice_pressed(idx))
		_choice_holder.add_child(btn)
	_choice_holder.visible = true


# Подсказка выбора по виду: монстр (сброс) / сыщик (передача) / ветка эффектов.
func _choose_prompt_key(kind: String) -> String:
	match kind:
		"monster":
			return "ENCOUNTER_CHOOSE_MONSTER"
		"target":
			return "ENCOUNTER_CHOOSE_TARGET"
		_:
			return "ENCOUNTER_CHOOSE"


# Метка опции: монстр — имя + стойкость; сыщик — имя; ветка — описание эффектов.
func _choice_label(opt: Dictionary, kind: String) -> String:
	match kind:
		"monster":
			var nm: String = tr(String(opt.get("name", "?")))
			return tr("MONSTER_CHOICE_LABEL") % [nm, int(opt.get("toughness", 1))]
		"target":
			return String(opt.get("name", "?"))
		_:
			return _branch_label(opt)


func _clear_choice() -> void:
	if not is_instance_valid(_choice_holder):
		return
	for c: Node in _choice_holder.get_children():
		c.queue_free()
	_choice_holder.visible = false


func _on_choice_pressed(index: int) -> void:
	_clear_choice()  # блокируем повторные клики до синка от хоста
	GameState.choose_effect(index)


# Метка кнопки ветки choice: художественный text → описание group/вложенного
# choice/проверки → описание одиночного эффекта (механический режим, как ставки).
func _branch_label(b: Dictionary) -> String:
	var txt: String = String(b.get("text", "")).strip_edges()
	if not txt.is_empty():
		return txt
	if b.has("group"):
		return _describe_effects(b.get("group", []))
	if b.has("choice"):
		return _describe_effects(b.get("choice", [])).replace(", ", " / ")
	if b.has("test"):
		var sk: String = String(_SKILL_KEYS.get(String(b.get("test", "will")), "SKILL_WILL"))
		return "%s: %s" % [tr("ENCOUNTER_CHECK"), tr(sk)]
	return _describe_one(b)


func _show_card(card: Dictionary) -> void:
	_title.text = _title_text(card)
	_main_text.text = _main_or_stakes(card)
	_check.text = _check_label(card.get("test", {}))
	_check.visible = true
	_roll_btn.text = "ENCOUNTER_ROLL"
	_roll_btn.visible = true
	_roll_btn.disabled = false
	_outcome.visible = false
	_finish_btn.visible = false
	_show_dice_pending(_check_pool(card.get("test", {})))  # рубашки до броска


func _show_outcome(card: Dictionary) -> void:
	var res: Dictionary = _chk()
	var passed: bool = bool(res.get("passed", false))
	_title.text = _title_text(card)
	_main_text.text = _main_or_stakes(card)
	_check.text = _check_label(card.get("test", {}))
	_check.visible = true
	_show_dice_result(res)
	# Провал прячем, пока есть перебросы (поштучно или «всё») и игрок не «принял».
	var hide_fail: bool = (
		not passed and not _revealed and (_rerolls_available() or _reroll_all_available())
	)
	if hide_fail:
		_outcome.visible = false
	else:
		_outcome.text = _outcome_text(card, passed)
		_outcome.add_theme_color_override(
			"font_color", UIColors.SUCCESS if passed else UIColors.DANGER
		)
		_outcome.visible = true
	_set_reroll_all_btn()  # кнопка броска → «Перебросить кубы», пока доступен reroll-all
	_finish_btn.text = "ENCOUNTER_ACCEPT" if hide_fail else "BTN_FINISH_BIG"
	_finish_btn.visible = true


# Двухфазные врата — дерево глубины 2. Стадия 0 (stage1) маршрутизирует: бросок
# → исход выбирает ветку, после чего «Дальше» ведёт ко второй проверке ПРИ ЛЮБОМ
# исходе. Стадия 1 — вторая проверка ветки: исход + «Завершить».
func _show_gate(card: Dictionary) -> void:
	var stage: int = int(card.get("stage", 0))
	var node: Dictionary = _gate_node(card, stage)
	if node.is_empty():
		_show_loading()
		return
	_title.text = "%s  (%d/2)" % [_title_text(card), stage + 1]
	_main_text.text = _main_or_stakes(node)
	_check.text = _check_label(node.get("test", {}))
	_check.visible = true

	if not _chk_rolled():
		_roll_btn.text = "ENCOUNTER_ROLL"
		_roll_btn.visible = true
		_roll_btn.disabled = false
		_outcome.visible = false
		_finish_btn.visible = false
		_show_dice_pending(_check_pool(node.get("test", {})))  # рубашки до броска
		return

	var res: Dictionary = _chk()
	var passed: bool = bool(res.get("passed", false))
	_show_dice_result(res)
	# Провал прячем, пока есть перебросы (поштучно или «всё») и игрок не «принял».
	var hide_fail: bool = (
		not passed and not _revealed and (_rerolls_available() or _reroll_all_available())
	)
	if hide_fail:
		_outcome.visible = false
	else:
		_outcome.text = _outcome_text(node, passed)
		_outcome.add_theme_color_override(
			"font_color", UIColors.SUCCESS if passed else UIColors.DANGER
		)
		_outcome.visible = true
	_set_reroll_all_btn()  # кнопка броска → «Перебросить кубы», пока доступен reroll-all
	# После первой проверки (stage 0) всегда «Дальше» (обе ветви ведут ко второй
	# проверке); после второй (stage 1) — «Завершить».
	var more: bool = stage == 0
	if hide_fail:
		_finish_btn.text = "ENCOUNTER_ACCEPT"
	else:
		_finish_btn.text = "ENCOUNTER_CONTINUE" if more else "BTN_FINISH_BIG"
	_finish_btn.visible = true


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
	# Повторное нажатие после броска = «перебросить все кубы» (Счастливый талисман).
	if _chk_rolled():
		if _reroll_all_available():
			GameState.reroll_all_dice()  # хост перебросит провальные и пришлёт синком
		return
	_revealed = false  # свежая проверка — провал снова можно скрыть до решения
	_roll_btn.disabled = true  # хост разрешит встречу и пришлёт результат синком
	GameState.resolve_encounter()


func _on_die_clicked(index: int) -> void:
	# Тапом — только бесплатно или заряженным жетоном; после «принятия» — нет.
	if _revealed or not GameState.can_reroll_now():
		return
	GameState.reroll_die(index)


# Единый лоток — создаётся лениво и переиспользуется, чтобы спин не рвался при
# ре-рендере на синке.
func _ensure_tray() -> void:
	if is_instance_valid(_tray):
		return
	_tray = DiceTray.new()
	_tray.name = "DiceTray"
	_tray.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_tray.die_selected.connect(_on_die_clicked)
	_dice_holder.add_child(_tray)


# До броска — рубашки по числу кубов проверки (как в магазине).
func _show_dice_pending(pool: int) -> void:
	if not is_instance_valid(_dice_holder):
		return
	_ensure_tray()
	if _pending_n != pool or not _last_dice.is_empty():
		_tray.show_pending(pool)
		_pending_n = pool
		_last_dice = []
	_dice_holder.visible = true
	_dice.visible = false


# Результат: свежий бросок → спин всех; переброс одного куба → крутится только он;
# повторный синк того же броска → не трогаем (не рвём анимацию).
func _show_dice_result(res: Dictionary) -> void:
	if not is_instance_valid(_dice_holder):
		return
	_ensure_tray()
	var dice: Array = res.get("dice", [])
	var committed: bool = bool(GameState.current_encounter.get("committed", false))
	# Тапом перебросить можно ТОЛЬКО бесплатно (карта) или заряженным жетоном.
	# Концентрация/улика — лишь через розыгрыш жетона. После «принятия» (_revealed) — нет.
	var can: bool = GameState.can_reroll_now() and not committed and not _revealed
	if dice != _last_dice:
		var prev: Array = _last_dice
		var diff: int = _single_diff(prev, dice)
		_last_dice = dice.duplicate()
		_pending_n = -1
		if prev.is_empty():
			_tray.play_roll(dice, can)  # первый бросок — спин всех
		elif diff >= 0:
			_tray.reroll_die(diff, int(dice[diff]), can)  # переброс одного — крутится он
		elif prev.size() == dice.size():
			_tray.play_roll(dice, can)  # тот же размер, изменилось несколько → reroll-all (спин всех)
		else:
			_tray.show_roll(dice, can)  # размер изменился (докинули кубы) → статикой
		_last_can = can
	elif can != _last_can:
		# Кубы те же, но кликабельность изменилась (активировали карту-переброс
		# после броска) — обновляем лоток, иначе кубик не нажать.
		_tray.show_roll(dice, can)
		_last_can = can
	_dice_holder.visible = true
	# Строку-итог «успехов: N · перетащите жетон…» убрали — кубы говорят сами за себя.
	_dice.visible = false


func _hide_dice() -> void:
	_last_dice = []
	_pending_n = -1
	if is_instance_valid(_dice_holder):
		_dice_holder.visible = false
	_dice.visible = false


# Индекс единственного отличия наборов (спин только переброшенного куба); -1 если
# отличий нет или больше одного / разные размеры.
func _single_diff(a: Array, b: Array) -> int:
	if a.size() != b.size():
		return -1
	var idx: int = -1
	for i in range(a.size()):
		if int(a[i]) != int(b[i]):
			if idx >= 0:
				return -1
			idx = i
	return idx


# Пул d6 проверки = навык + модификаторы навыка + модификатор карты (как у хоста
# в CheckFlow.pool). Для показа рубашек до броска.
func _check_pool(test: Dictionary) -> int:
	var me: Dictionary = GameState.my_player()
	var inv: Dictionary = Investigators.get_data(String(me.get("investigator", "")))
	var skill: String = String(test.get("skill", "will"))
	var base: int = int((inv.get("skills", {}) as Dictionary).get(skill, 1))
	var mods: int = int((me.get("skill_mods", {}) as Dictionary).get(skill, 0))
	# Доп. кубы от активированных карт до броска (Фаза 5) — рубашки растут заранее.
	var amods: Array = _chk().get("active_mods", [])
	return maxi(1, base + mods + int(test.get("modifier", 0)) + Dice.pre_roll_bonus(amods, skill))


# Кнопка под исходом: после первой проверки врат (stage 0) — «Дальше» ко второй
# проверке при ЛЮБОМ исходе (ветка выбирается по успеху/провалу); иначе — конец.
func _on_finish_pressed() -> void:
	var card: Dictionary = GameState.current_encounter
	# Если провал скрыт (есть перебросы) — первый клик РАСКРЫВАЕТ исход и блокирует
	# перебросы; завершение/переход — следующим кликом.
	if not _revealed and _current_failed(card) and _rerolls_available():
		_revealed = true
		_refresh()
		return
	if _is_branching(card):
		if int(card.get("stage", 0)) == 0 and _chk_rolled():
			GameState.advance_encounter_stage()
			return
	GameState.finish_encounter()


# Доступны ли перебросы: есть фокус ИЛИ бесплатные перебросы от карт, и проверка
# ещё не закоммичена.
# Можно ли ВООБЩЕ перебросить (для скрытия исхода): бесплатно / концентрация / улика
# (последние — через розыгрыш жетона). Пока ресурс есть — провал не показываем.
func _rerolls_available() -> bool:
	if bool(GameState.current_encounter.get("committed", false)):
		return false
	return GameState.has_reroll_resource()


# Текущий показанный результат — провал? (из активной проверки встречи).
func _current_failed(_card: Dictionary) -> bool:
	var res: Dictionary = _chk()
	if not bool(res.get("rolled", false)):
		return false
	return not bool(res.get("passed", false))


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
	return (
		"%s: %s\n%s: %s"
		% [
			tr("ENC_REWARD"),
			_describe_effects(succ),
			tr("ENC_PENALTY"),
			_describe_effects(fail),
		]
	)


# Текст исхода: художественный success/failureText, либо описание применённых
# эффектов, если текста нет (механический режим); пустой исход → «идём дальше».
func _outcome_text(src: Dictionary, passed: bool) -> String:
	var txt: String = String(src.get("successText" if passed else "failureText", "")).strip_edges()
	var arr: Array = src.get("onSuccess" if passed else "onFailure", [])
	var out: String
	# Механический режим (без флейвора) — только описание эффектов / «идём дальше».
	if txt.is_empty():
		out = _describe_effects(arr) if not arr.is_empty() else tr("ENCOUNTER_PROCEED")
	elif not arr.is_empty():
		# Есть флейвор: под ним отдельной строкой — что именно получил/потерял.
		out = "%s\n\n%s" % [txt, _describe_effects(arr)]
	else:
		out = txt
	return out


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
		"gainClue":
			return tr("ENC_EFF_CLUE") % amount
		"loseClue":
			return tr("ENC_EFF_CLUE") % -amount
		"healHealth":
			return tr("ENC_EFF_HP") % amount
		"loseHealth":
			return tr("ENC_EFF_HP") % -amount
		"healSanity":
			return tr("ENC_EFF_SAN") % amount
		"loseSanity":
			return tr("ENC_EFF_SAN") % -amount
		"gainSpell":
			return tr("ENC_EFF_SPELL")
		"gainArtifact":
			return tr("ENC_EFF_ARTIFACT")
		"gainAsset":
			return tr("ENC_EFF_ASSET")
		"improveSkill":
			return tr("ENC_EFF_IMPROVE") % amount
		"gainCondition":
			return (
				tr("ENC_EFF_COND_GAIN") % tr(Conditions.name_key(String(eff.get("condition", ""))))
			)
		"loseCondition":
			return (
				tr("ENC_EFF_COND_LOSE") % tr(Conditions.name_key(String(eff.get("condition", ""))))
			)
		"move":
			return tr("ENC_EFF_MOVE")
		"closeGate":
			return tr("ENC_EFF_CLOSE_GATE")
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
		# Модификатор монстра/карты — как в бою: «… +1» / «… −3» (юникод-минус).
		line += "  %s%d" % ["+" if modifier > 0 else "−", absi(modifier)]
	return line
