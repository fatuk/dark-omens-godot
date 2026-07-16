extends CanvasLayer

## Баннер «Ваш ход»: выезжает сверху и гаснет, когда игра начинает ЖДАТЬ МОЕГО
## ввода — мой ход в фазе действий, моя встреча, адресованные лично мне проверка
## или выбор (forEach Мифов / бросок Расплаты). Срабатывает на ПЕРЕХОДЕ «не ждут
## меня» → «ждут» (не мигает на каждом синке). Транзиентно, строится кодом,
## добавляется из world_map. Отключается SettingsStore.turn_notify.

var _center: CenterContainer
var _bar: PanelContainer
var _was_awaiting: bool = false
var _tween: Tween


func _ready() -> void:
	layer = 100  # поверх всего (в т.ч. модалок выбора/проверки), чтобы был виден
	_build()
	GameState.state_changed.connect(_refresh)
	# Текущее состояние — БЕЗ показа: первый переход в «ждут меня» покажет баннер.
	_was_awaiting = _awaiting_me()


func _build() -> void:
	_center = CenterContainer.new()
	_center.name = "Center"
	_center.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_center.offset_top = 84
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)

	_bar = PanelContainer.new()
	_bar.name = "Bar"
	UIStyle.style_modal_panel(_bar)  # тёмная плашка с рамкой
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.modulate.a = 0.0
	_center.add_child(_bar)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", 48)
	margin.add_theme_constant_override("margin_right", 48)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_child(margin)

	var label := UIStyle.label(
		"TURN_BANNER_YOURS", 30, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER
	)
	label.name = "Label"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(label)


# Игра ждёт МОЕГО ввода прямо сейчас (любой из контекстов).
func _awaiting_me() -> bool:
	var me: String = String(GameState.my_player().get("user_id", ""))
	if me.is_empty():
		return false
	if GameState.is_my_turn():  # мой ход в фазе действий
		return true
	if GameState.is_my_encounter_turn():  # моя встреча
		return true
	var md: Dictionary = GameState.mythos_decision  # выбор мифа адресован мне
	if bool(md.get("active", false)) and String(md.get("pid", "")) == me:
		return true
	var pc: Dictionary = GameState.pending_check  # видимая проверка адресована мне
	if not pc.is_empty() and String(pc.get("pid", "")) == me:
		return true
	if GameState.my_player().has("reckoning_pending"):  # per-player бросок Расплаты
		return true
	return false


func _refresh() -> void:
	var now: bool = _awaiting_me()
	if now and not _was_awaiting and SettingsStore.turn_notify:
		_show_banner()
	_was_awaiting = now


func _show_banner() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_bar.modulate.a = 0.0
	_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_bar, "modulate:a", 1.0, 0.25)
	_tween.parallel().tween_property(_center, "offset_top", 84.0, 0.28).from(58.0).set_trans(
		Tween.TRANS_BACK
	)
	_tween.tween_interval(1.3)
	_tween.tween_property(_bar, "modulate:a", 0.0, 0.4)
