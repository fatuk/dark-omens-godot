extends CanvasLayer

## Модалка выбора в forEach-проходе фазы Мифов. Показывается сыщику, чьего выбора
## сейчас ждёт ход (GameState.mythos_decision.pid == мой): заголовок, подсказка и
## кнопка на каждую ветку. Клик → GameState.decide_mythos(index); хост разблокирует
## ожидающую корутину MythosFlow и применит выбранную ветку. Контент строится кодом
## (паттерн cast_result_modal). См. MythosFlow._run_player_subprogram.

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
	_root.visible = mine
	if not mine:
		_sig = ""
		return
	var sig: String = "%s|%d" % [String(d.get("path", "")), (d.get("options", []) as Array).size()]
	if sig == _sig:
		return  # тот же выбор — UI уже правильный
	_sig = sig
	_build(d.get("options", []))


func _build(options: Array) -> void:
	var d: Dictionary = GameState.mythos_decision
	for c in _vbox.get_children():
		c.queue_free()
	# title_key/prompt_key — опц. (forEach Мифов vs выбор порядка Расплаты и т.п.).
	_vbox.add_child(
		UIStyle.modal_title(
			tr(String(d.get("title_key", "MYTHOS_DECISION_TITLE"))), UIColors.DANGER
		)
	)

	var prompt := Label.new()
	prompt.name = "Prompt"
	prompt.text = tr(String(d.get("prompt_key", "MYTHOS_DECISION_PROMPT")))
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prompt.add_theme_color_override("font_color", UIColors.MUTED)
	_vbox.add_child(prompt)

	for i in range(options.size()):
		var opt: Dictionary = options[i] if options[i] is Dictionary else {}
		var btn := Button.new()
		btn.name = "ChoiceBtn%d" % i
		btn.text = _branch_label(opt)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIStyle.style_button(btn)
		btn.disabled = not bool(opt.get("_affordable", true))  # ветка не по карману
		var idx: int = i
		btn.pressed.connect(func() -> void: _on_pick(idx))
		_vbox.add_child(btn)
	UIStyle.scale_modal_text(_vbox)


func _on_pick(index: int) -> void:
	_root.visible = false  # скрыть сразу, не ждать синка от хоста
	_sig = ""
	GameState.decide_mythos(index)


# Метка кнопки ветки: художественный text → описание group/choice → одиночный эффект.
func _branch_label(b: Dictionary) -> String:
	var txt: String = String(b.get("text", "")).strip_edges()
	if not txt.is_empty():
		return txt
	if b.has("group"):
		return _describe_list(b.get("group", []))
	if b.has("choice"):
		return _describe_list(b.get("choice", []))
	return _describe_one(b)


func _describe_list(effs: Array) -> String:
	var parts: Array = []
	for i in range(effs.size()):
		if effs[i] is Dictionary:
			parts.append(_describe_one(effs[i]))
	return ", ".join(parts)


# Компактное описание одного эффекта — для метки кнопки.
func _describe_one(eff: Dictionary) -> String:
	var verb: String = String(eff.get("do", ""))
	var n: int = int(eff.get("amount", eff.get("count", 1)))
	var target: String = String(eff.get("target", ""))
	var s: String
	match verb:
		"loseHealth":
			s = tr("MYTHOS_EFF_LOSE_HEALTH") % n
		"loseSanity":
			s = tr("MYTHOS_EFF_LOSE_SANITY") % n
		"gainCondition":
			s = (
				tr("MYTHOS_EFF_GAIN_CONDITION")
				% tr(Conditions.name_key(String(eff.get("condition", "?"))))
			)
		"loseAllPossessions":
			s = tr("MYTHOS_EFF_LOSE_ALL")
		_:
			s = verb
	if not target.is_empty() and target != "self":
		s += " · %s" % _describe_target(target)
	return s


func _describe_target(t: String) -> String:
	match t:
		"rightNeighbor":
			return tr("MYTHOS_TGT_RIGHT")
		"leftNeighbor":
			return tr("MYTHOS_TGT_LEFT")
		"lead":
			return tr("MYTHOS_TGT_LEAD")
		"each":
			return tr("MYTHOS_TGT_EACH")
		_:
			return t
