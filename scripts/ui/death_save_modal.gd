extends CanvasLayer

## Модалка Порога (спас-бросок на 0 HP/SAN). Видна ВСЕМ, пока у кого-то есть слот
## players[pid].death_save_check (он синкается). Умирающий жмёт «Принять судьбу»;
## живой сосед с ресурсом перебрасывает кубик (−1 ресурс). Один кубик, порог обычный.
## Хост-авторитетно — модалка лишь отражает синк. Код, монтируется из world_map.
##
## TODO(i18n): тексты пока литералами (translations.csv занят правкой INV_SET) —
## вынести в ключи DEATH_* при чистом csv.

var _root: ColorRect
var _panel: PanelContainer
var _vbox: VBoxContainer
var _dice_box: HBoxContainer
var _tray: DiceTray
var _sub: Label
var _status: Label
var _reroll_btn: Button
var _accept_btn: Button

var _sig: String = ""  # умирающий pid — при смене пересобираем
var _last_dice: Array = []
var _last_nonce: int = 0
var _status_hidden: bool = false  # итог скрыт, пока кубик крутится


func _ready() -> void:
	layer = 87  # поверх проверок (check_roll_modal = 86) — Порог прерывает всё
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_frame()
	GameState.state_changed.connect(_refresh)
	_refresh()


func _build_frame() -> void:
	_root = ColorRect.new()
	_root.name = "Root"
	_root.color = Color(0, 0, 0, 0.62)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP  # блокируем действия, пока Порог не решён
	_root.visible = false
	add_child(_root)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	UIStyle.style_modal_panel(_panel)
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	_panel.add_child(margin)

	_vbox = VBoxContainer.new()
	_vbox.name = "VBox"
	_vbox.add_theme_constant_override("separation", 12)
	margin.add_child(_vbox)


# ── Доступ к стейту ───────────────────────────────────────────────────────────


# Первый игрок с открытым слотом Порога (обычно один). "" — Порога нет.
func _dying_pid() -> String:
	for pid_v: Variant in GameState.players:
		var pid: String = pid_v
		if not (
			(GameState.players[pid] as Dictionary).get(PlayerKeys.DEATH_SAVE_CHECK, {}).is_empty()
		):
			return pid
	return ""


func _slot(pid: String) -> Dictionary:
	return (GameState.players.get(pid, {}) as Dictionary).get(PlayerKeys.DEATH_SAVE_CHECK, {})


func _my_id() -> String:
	return GameState.local_pid()


# ── Обновление ────────────────────────────────────────────────────────────────


func _refresh() -> void:
	var dying: String = _dying_pid()
	UIStyle.modal_set_visible(_root, _panel, not dying.is_empty())
	if dying.is_empty():
		_sig = ""
		_last_dice = []
		return
	if dying != _sig:
		_sig = dying
		_last_dice = []
		_build()
	_render_dice(dying)
	_update(dying)


func _build() -> void:
	for c in _vbox.get_children():
		c.queue_free()
	_tray = null
	_status_hidden = false

	_vbox.add_child(UIStyle.modal_title(tr("DEATH_TITLE"), UIColors.DANGER))

	_sub = UIStyle.label("", UIStyle.MODAL_FS_BODY, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	_sub.name = "Subtitle"
	_vbox.add_child(_sub)

	_dice_box = HBoxContainer.new()
	_dice_box.name = "DiceBox"
	_dice_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_dice_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_child(_dice_box)

	_status = UIStyle.label("", UIStyle.MODAL_FS_BODY, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_status.name = "Status"
	_vbox.add_child(_status)

	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 16)
	_vbox.add_child(btns)

	_reroll_btn = UIStyle.button(tr("DEATH_BTN_REROLL"), UIColors.WARNING)
	_reroll_btn.name = "RerollBtn"
	_reroll_btn.pressed.connect(_on_reroll)
	btns.add_child(_reroll_btn)

	_accept_btn = UIStyle.button(tr("DEATH_BTN_ACCEPT"), UIColors.ACCENT)
	_accept_btn.name = "AcceptBtn"
	_accept_btn.pressed.connect(_on_accept)
	btns.add_child(_accept_btn)


func _ensure_tray() -> void:
	if is_instance_valid(_tray):
		return
	_tray = DiceTray.new()
	_tray.name = "DiceTray"
	_dice_box.add_child(_tray)  # кубик некликабелен — переброс через кнопку соседа
	_tray.roll_settled.connect(_on_roll_settled)


# Кубик осел — проявить исход (см. _update).
func _on_roll_settled() -> void:
	if not _sig.is_empty():
		_update(_sig)


func _render_dice(dying: String) -> void:
	if not is_instance_valid(_dice_box):
		return
	_ensure_tray()
	var c: Dictionary = _slot(dying)
	var dice: Array = c.get("dice", [])
	if dice.is_empty():
		return
	var nonce: int = int(c.get("reroll_nonce", 0))
	if _last_dice.is_empty():
		_tray.play_roll(dice, false, false)  # первый показ — спин
	elif nonce != _last_nonce and not dice.is_empty():
		_tray.reroll_die(0, int(dice[0]), false, false)  # переброс соседом — крутим
	elif dice != _last_dice:
		_tray.show_roll(dice, false, false)
	_last_dice = dice.duplicate()
	_last_nonce = nonce


func _update(dying: String) -> void:
	var c: Dictionary = _slot(dying)
	var stat: String = String(c.get("death_stat", PlayerKeys.HP))
	var kind: String = tr("DEATH_KIND_BODY") if stat == PlayerKeys.HP else tr("DEATH_KIND_MIND")
	if is_instance_valid(_sub):
		_sub.text = tr("DEATH_SUBTITLE") % [GameState.name_of(dying), kind]
	var passed: bool = bool(c.get("passed", false))
	# Пока кубик крутится — исход и кнопку переброса (она выдаёт провал) не
	# показываем: иначе итог виден раньше выпавшей грани. Проявит roll_settled.
	var rolling: bool = is_instance_valid(_tray) and _tray.is_rolling()
	if is_instance_valid(_status):
		_status.text = tr("DEATH_HOLDS") if passed else tr("DEATH_PULLS")
		_status.add_theme_color_override(
			"font_color", UIColors.SUCCESS if passed else UIColors.DANGER
		)
		if rolling:
			_status.modulate.a = 0.0
			_status_hidden = true
		elif _status_hidden:
			_status_hidden = false
			_status.create_tween().tween_property(_status, "modulate:a", 1.0, 0.25)

	var am_dying: bool = _my_id() == dying
	# Сосед может перебросить: я жив, не умирающий, есть ресурс, кубик провальный.
	var me: Dictionary = GameState.my_player()
	var can_reroll: bool = (
		not am_dying
		and not bool(me.get(PlayerKeys.DEAD, false))
		and int(me.get(PlayerKeys.RESOURCES, 0)) > 0
		and not passed
		and not rolling
	)
	if is_instance_valid(_reroll_btn):
		_reroll_btn.visible = can_reroll
	if is_instance_valid(_accept_btn):
		_accept_btn.visible = am_dying  # принимает только сам умирающий


# ── Действия ───────────────────────────────────────────────────────────────────


func _on_reroll() -> void:
	var dying: String = _dying_pid()
	if not dying.is_empty():
		GameState.act(RelayActions.DEATH_SAVE_REROLL, {"dying": dying})


func _on_accept() -> void:
	# Без disabled-гарда: apply идемпотентен (пустой слот → no-op), а модалка может
	# заново открыться (мифос снова уронил стат) — тогда кнопку нельзя оставлять
	# заблокированной, иначе повторный Порог не принять.
	GameState.act(RelayActions.DEATH_SAVE_APPLY)
