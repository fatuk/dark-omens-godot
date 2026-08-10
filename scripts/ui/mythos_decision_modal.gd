extends CanvasLayer

## Модалка выбора: заголовок, подсказка и кнопка на каждый вариант. Показывается
## сыщику, чьего ответа сейчас ждёт ход (GameState.mythos_decision.pid == мой).
## Клик → GameState.decide_mythos(index).
##
## Канал mythos_decision общий (имя историческое): вопрос задаёт и forEach-проход
## Мифов (будит корутину MythosFlow), и программа актива (AssetActionFlow) —
## разводит их driver. Виды выбора (kind): choice — ветка эффектов, target — сыщик,
## monster — монстр на поле, space — локация с монстрами.
##
## Контент строится кодом (паттерн cast_result_modal).

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

var _sig: String = ""  # подпись текущего выбора — чтобы не пересобирать UI зря


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	GameState.state_changed.connect(_refresh)
	_refresh()


func _my_id() -> String:
	return String(GameState.my_player().get("user_id", ""))


func _refresh() -> void:
	var d: Dictionary = GameState.mythos_decision
	var mine: bool = bool(d.get("active", false)) and String(d.get("pid", "")) == _my_id()
	UIStyle.modal_set_visible(_root, _panel, mine)
	if not mine:
		_sig = ""
		return
	# Подпись — по ВСЕМУ содержимому выбора. Раньше брали только path и число веток,
	# и два разных решения подряд с одинаковой формой (очередь услуг: «какого монстра»
	# → «какую локацию», у обоих path "0" и по одной опции) оставляли на экране
	# предыдущий вопрос.
	var sig: String = (
		JSON
		. stringify(
			{
				"kind": d.get("kind", ""),
				"path": d.get("path", ""),
				"title": d.get("title_key", ""),
				"prompt": d.get("prompt_key", ""),
				"options": d.get("options", []),
			}
		)
	)
	if sig == _sig:
		return  # тот же выбор — UI уже правильный
	_sig = sig
	_build(d.get("options", []))


func _build(options: Array) -> void:
	var d: Dictionary = GameState.mythos_decision
	var kind: String = String(d.get("kind", "choice"))  # choice | target | monster
	# remove_child ДО queue_free: освобождение отложено до конца кадра, и без снятия
	# с дерева новые кнопки успевают встать рядом со старыми.
	for c in _vbox.get_children():
		_vbox.remove_child(c)
		c.queue_free()
	# title_key/prompt_key — опц. (forEach Мифов vs выбор порядка Расплаты и т.п.).
	_vbox.add_child(
		UIStyle.modal_title(
			tr(String(d.get("title_key", "MYTHOS_DECISION_TITLE"))), UIColors.DANGER
		)
	)

	var prompt := Label.new()
	prompt.name = "Prompt"
	var prompt_key: String = String(d.get("prompt_key", ""))
	if prompt_key.is_empty():
		prompt_key = _default_prompt_key(kind)
	prompt.text = tr(prompt_key)
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prompt.add_theme_color_override("font_color", UIColors.MUTED)
	_vbox.add_child(prompt)

	for i in range(options.size()):
		var opt: Dictionary = options[i] if options[i] is Dictionary else {}
		var btn := Button.new()
		btn.name = "ChoiceBtn%d" % i
		btn.text = _option_label(opt, kind)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIStyle.style_button(btn)
		btn.disabled = not bool(opt.get("_affordable", true))  # ветка не по карману
		var idx: int = i
		btn.pressed.connect(func() -> void: _on_pick(idx))
		_vbox.add_child(btn)
	UIStyle.scale_modal_text(_vbox)


# Подсказка по умолчанию — зависит от вида выбора (ветка / сыщик / монстр / локация).
func _default_prompt_key(kind: String) -> String:
	match kind:
		"monster":
			return "MYTHOS_CHOOSE_MONSTER"
		"space":
			return "PICK_SPACE_DAMAGE"
		"target":
			return "MYTHOS_CHOOSE_TARGET"
		_:
			return "MYTHOS_DECISION_PROMPT"


# Метка опции: монстр — имя, локация и здоровье; локация — имя и число монстров;
# цель — имя сыщика; ветка — описание эффектов.
func _option_label(opt: Dictionary, kind: String) -> String:
	match kind:
		"monster":
			var nm: String = tr(String(opt.get("name", "?")))
			var tough: int = int(opt.get("toughness", 1))
			# Локация в опции есть не всегда (мифы зовут выбор без неё) — тогда
			# показываем короткую метку «имя · стойкость».
			if not opt.has("loc_name"):
				return tr("MONSTER_CHOICE_LABEL") % [nm, tough]
			return (
				tr("MONSTER_CHOICE_AT")
				% [nm, tr(String(opt.get("loc_name", ""))), int(opt.get("health", tough)), tough]
			)
		"space":
			return (
				tr("SPACE_CHOICE_LABEL")
				% [tr(String(opt.get("name", "?"))), int(opt.get("count", 0))]
			)
		"target":
			return String(opt.get("name", "?"))
		_:
			return EffectManifest.describe(opt)


func _on_pick(index: int) -> void:
	UIStyle.modal_set_visible(_root, _panel, false)  # скрыть сразу, не ждать синка
	_sig = ""
	GameState.decide_mythos(index)
