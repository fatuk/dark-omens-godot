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
	var kind: String = String(d.get("kind", "choice"))  # choice | target | monster
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
	prompt.text = tr(String(d.get("prompt_key", _default_prompt_key(kind))))
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


# Подсказка по умолчанию — зависит от вида выбора (ветка эффектов / сыщик / монстр).
func _default_prompt_key(kind: String) -> String:
	match kind:
		"monster":
			return "MYTHOS_CHOOSE_MONSTER"
		"target":
			return "MYTHOS_CHOOSE_TARGET"
		_:
			return "MYTHOS_DECISION_PROMPT"


# Метка опции: монстр — имя + стойкость; цель — имя сыщика; ветка — описание эффектов.
func _option_label(opt: Dictionary, kind: String) -> String:
	match kind:
		"monster":
			var nm: String = tr(String(opt.get("name", "?")))
			return tr("MONSTER_CHOICE_LABEL") % [nm, int(opt.get("toughness", 1))]
		"target":
			return String(opt.get("name", "?"))
		_:
			return EffectManifest.describe(opt)


func _on_pick(index: int) -> void:
	_root.visible = false  # скрыть сразу, не ждать синка от хоста
	_sig = ""
	GameState.decide_mythos(index)
