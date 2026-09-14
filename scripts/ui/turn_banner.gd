extends CanvasLayer

## Баннер «Ваш ход»: выезжает сверху и гаснет, когда игра начинает ЖДАТЬ МОЕГО
## ввода — мой ход в фазе действий, моя встреча, адресованные лично мне проверка
## или выбор (forEach Мифов / бросок Расплаты). Срабатывает на ПЕРЕХОДЕ «не ждут
## меня» → «ждут» (не мигает на каждом синке). Транзиентно, строится кодом,
## добавляется из world_map. Отключается SettingsStore.turn_notify.

const _TOP_RATIO: float = 0.3  # отступ сверху — доля высоты экрана
const _SLIDE: float = 26.0  # с какой высоты выезжает

var _anchor: Control
var _bar: PanelContainer
var _label: Label
var _was_awaiting: bool = false
var _pending: bool = false  # ход мой, но экран занят модалкой — ждём её закрытия
var _pending_text: String = ""  # что показать, когда экран освободится
var _intro_done: bool = false  # стартовый баннер «чей ход» показан
var _tween: Tween


func _ready() -> void:
	layer = 100  # поверх всего (в т.ч. модалок выбора/проверки), чтобы был виден
	_build()
	GameState.state_changed.connect(_refresh)
	get_viewport().size_changed.connect(_reposition)
	set_process(false)  # включаем только на время ожидания закрытия модалок
	# Текущее состояние — БЕЗ показа: первый переход в «ждут меня» покажет баннер.
	_was_awaiting = _awaiting_me()
	# Кроме старта партии / входа в комнату: тут сразу говорим, чей ход, — иначе
	# первый игрок не видит «Ваш ход», а остальные не знают, кого ждут.
	_show_intro()


func _build() -> void:
	# Позиционируем вручную (CenterContainer не умеет центрировать по УМЕНЬШЕННОЙ
	# ширине масштабированного ребёнка).
	_anchor = Control.new()
	_anchor.name = "Anchor"
	_anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	_anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_anchor)

	_bar = PanelContainer.new()
	_bar.name = "Bar"
	# Ассеты @2×: строим баннер в НАТУРАЛЬНОМ 2× и ужимаем вдвое. Иначе орнамент
	# рамки (углы ~80px) на маленькой плашке выглядит вдвое крупнее нужного.
	_bar.scale = Vector2(0.5, 0.5)
	UIStyle.style_modal_panel(_bar, 44)  # тёмная плашка с рамкой
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.modulate.a = 0.0
	_bar.resized.connect(_reposition)
	_anchor.add_child(_bar)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", 96)
	margin.add_theme_constant_override("margin_right", 96)
	margin.add_theme_constant_override("margin_top", 32)
	margin.add_theme_constant_override("margin_bottom", 32)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_child(margin)

	_label = UIStyle.label("TURN_BANNER_YOURS", 60, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_label.name = "Label"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(_label)

	_reposition()


# По центру экрана по горизонтали — с учётом того, что видимая ширина вдвое
# меньше размера в раскладке. Вертикаль не трогаем: её ведёт тween выезда.
func _reposition() -> void:
	if not is_instance_valid(_bar):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_bar.position.x = (vp.x - _bar.size.x * _bar.scale.x) * 0.5


# Целевая высота баннера — доля высоты экрана (не фикс. пиксели: иначе на разных
# разрешениях плашка висит по-разному).
func _top_y() -> float:
	return get_viewport().get_visible_rect().size.y * _TOP_RATIO


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
	if not _intro_done:
		# Состояние могло прийти позже _ready (реконнект) — стартовый баннер отсюда.
		_show_intro()
	elif now and not _was_awaiting and SettingsStore.turn_notify:
		_queue_banner(tr("TURN_BANNER_YOURS"))
	if not now and _pending_text == tr("TURN_BANNER_YOURS"):
		_pending = false  # ждать больше нечего: ход уже не мой
		set_process(false)
	_was_awaiting = now


# Старт партии / вход в комнату: «Ваш ход» или «Ходит <имя>» — один раз, как только
# известно, чей ход (фаза действий/встреч и текущий сыщик есть).
func _show_intro() -> void:
	if _intro_done or not GameState.active:
		return
	if GameState.phase != Phases.ACTION and GameState.phase != Phases.ENCOUNTER:
		return
	var pid: String = GameState._current_pid()
	if pid.is_empty() or not GameState.players.has(pid):
		return
	_intro_done = true
	if not SettingsStore.turn_notify:
		return
	if pid == GameState.local_pid():
		_queue_banner(tr("TURN_BANNER_YOURS"))
	else:
		var inv_id: String = String(GameState.players[pid].get("investigator", ""))
		_queue_banner(tr("TURN_BANNER_OTHER") % Investigators.display_name(inv_id))


# Показать сейчас или, если экран занят окном (миф, встреча, «вы получили»…),
# после его закрытия — игрок сначала закрывает модалку, баннер ждёт.
func _queue_banner(text: String) -> void:
	_pending_text = text
	if UIStyle.any_modal_open():
		_pending = true
		set_process(true)
	else:
		_show_banner()


# Крутится ТОЛЬКО пока баннер ждёт закрытия модалок (см. _refresh): закрытие окна
# не сопровождается синком состояния, поймать его иначе нечем.
func _process(_delta: float) -> void:
	if not _pending:
		set_process(false)
		return
	if UIStyle.any_modal_open():
		return
	_pending = false
	set_process(false)
	if SettingsStore.turn_notify and (_pending_text != tr("TURN_BANNER_YOURS") or _awaiting_me()):
		_show_banner()


func _show_banner() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_label.text = _pending_text if not _pending_text.is_empty() else tr("TURN_BANNER_YOURS")
	_reposition()
	var top: float = _top_y()
	_bar.modulate.a = 0.0
	_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_bar, "modulate:a", 1.0, 0.25)
	_tween.parallel().tween_property(_bar, "position:y", top, 0.28).from(top - _SLIDE).set_trans(
		Tween.TRANS_BACK
	)
	_tween.tween_interval(1.3)
	_tween.tween_property(_bar, "modulate:a", 0.0, 0.4)
