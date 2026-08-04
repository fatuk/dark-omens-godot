extends CanvasLayer

## Окно наблюдателя: показывает ОСТАЛЬНЫМ игрокам, какую встречу проходит активный
## сыщик. Только повествование — художественный текст встречи и текст исхода, когда
## проверка сыграна. Тип проверки, кубы и кнопки намеренно НЕ показываем: это не
## интерактив, а «сводка с места событий».
##
## Данные уже синкаются: current_encounter (карта) и active_check (owner=encounter).
## Ничего нового в сеть не добавляем. Код, монтируется из world_map.
##
## TODO(дизайн): оформить под срочную телеграмму (за пользователем).
## TODO(i18n): подписи литералами — как в death_save_modal/ghost_bar.

var _root: Control
var _panel: PanelContainer
var _title: Label
var _who: Label
var _text: Label
var _outcome: Label

var _sig: String = ""  # подпись состояния — чтобы не перерисовывать каждый синк


func _ready() -> void:
	layer = 79  # под модалками проверок/Порога (86/87) и оверлеями Тени
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


# ── Сборка ────────────────────────────────────────────────────────────────────


func _build() -> void:
	# Полноэкранный якорь: кликам не мешаем (ловит только сама панель), иначе
	# наблюдатель не смог бы работать с картой и чатом, пока идёт чужая встреча.
	var anchor := Control.new()
	anchor.name = "WatchAnchor"
	anchor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(anchor)
	_root = anchor

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "WatchPanel"
	UIStyle.style_modal_panel(_panel)
	_panel.custom_minimum_size = Vector2(760, 0)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP  # панель не «прокликивается» на карту
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	_panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 10)
	margin.add_child(vb)

	var ornate: HBoxContainer = UIStyle.ornate_title("", 22, UIColors.ACCENT)
	ornate.name = "OrnateTitle"
	vb.add_child(ornate)
	_title = ornate.get_node("Title")

	_who = UIStyle.label("", 14, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_who.name = "Who"
	vb.add_child(_who)

	_text = UIStyle.label("", 16, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	_text.name = "Text"
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size.x = 700
	vb.add_child(_text)

	_outcome = UIStyle.label("", 16, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	_outcome.name = "Outcome"
	_outcome.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_outcome.custom_minimum_size.x = 700
	_outcome.visible = false
	vb.add_child(_outcome)

	UIStyle.scale_modal_text(_panel)
	_root.visible = false


# ── Состояние ─────────────────────────────────────────────────────────────────


# Чужая ли сейчас встреча (я — наблюдатель). Погибшая Тень тоже наблюдатель.
func _watching_pid() -> String:
	if not GameState.active or GameState.phase != Phases.ENCOUNTER:
		return ""
	var pid: String = GameState._current_pid()
	if pid.is_empty() or pid == NetworkManager.my_user_id:
		return ""  # моя встреча — её показывает обычная модалка встречи
	return pid


# Активный узел карты: у ветвящихся (gate/mystery) — stage1 либо ветка по итогу
# первой проверки; у плоской встречи — сама карта.
func _node(card: Dictionary) -> Dictionary:
	var kind: String = String(card.get("kind", ""))
	if kind != "gate" and kind != "mystery":
		return card
	if int(card.get("stage", 0)) <= 0:
		return card.get("stage1", {})
	var branches: Dictionary = card.get("branches", {})
	return branches.get(String(card.get("branch", "success")), {})


# Проверка встречи (owner=encounter) — из неё берём только факт «сыграно» и исход.
func _check() -> Dictionary:
	var c: Dictionary = GameState.active_check
	return c if String(c.get("owner", "")) == "encounter" else {}


func _refresh() -> void:
	var pid: String = _watching_pid()
	var card: Dictionary = GameState.current_encounter
	# Прячем: моя встреча / нет карты / игрок ещё выбирает тип / бой (своя модалка).
	var show: bool = (
		not pid.is_empty()
		and not card.is_empty()
		and (GameState.encounter_choices as Array).is_empty()
		and String(card.get("kind", "")) != "combat"
	)
	if not show:
		_root.visible = false
		_sig = ""
		return

	var node: Dictionary = _node(card)
	var chk: Dictionary = _check()
	var rolled: bool = bool(chk.get("rolled", false))
	var passed: bool = bool(chk.get("passed", false))
	# Перерисовываем только при смене содержимого (синк прилетает часто).
	var sig: String = (
		"%s|%d|%s|%s|%s"
		% [pid, int(card.get("stage", 0)), String(card.get("name", "")), str(rolled), str(passed)]
	)
	_root.visible = true
	if sig == _sig:
		return
	_sig = sig

	var nm: String = String(card.get("name", "")).strip_edges()
	_title.text = nm if not nm.is_empty() else tr("ENCOUNTER_TITLE")
	_who.text = "%s — встреча" % GameState._name_of(pid)
	_text.text = String(node.get("mainText", "")).strip_edges()

	if rolled:
		var key: String = "successText" if passed else "failureText"
		_outcome.text = String(node.get(key, "")).strip_edges()
		_outcome.add_theme_color_override(
			"font_color", UIColors.SUCCESS if passed else UIColors.DANGER
		)
		_outcome.visible = not _outcome.text.is_empty()
	else:
		_outcome.visible = false
