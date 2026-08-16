extends CanvasLayer

## Окно карты Мифов. Видно ВСЕМ игрокам в фазе mythos после того, как хост
## вытянул карту (GameState.current_mythos непустая). Показывает имя карты,
## flavor-строчку, рулз-текст и список эффектов onDraw. По кнопке «Дальше»
## событие через relay уходит хосту, который применяет эффекты и стартует
## следующий раунд (см. MythosFlow._apply_resolve).
##
## Контент строится кодом — паттерн settings_dialog / create_room_dialog.

@onready var _root: ColorRect = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

var _title_lbl: Label
var _flavor_lbl: Label
var _text_lbl: Label
var _eff_header: Label
var _eff_box: VBoxContainer
var _next_btn: Button

# Кеш ключа текущей карты — чтобы не пересобирать UI на каждый _refresh,
# если карта не сменилась.
var _last_card_key: String = ""

# Режим «перечитать»: показываем GameState.last_mythos (последний вытянутый миф)
# только для чтения — без гейта «Прочитал», с кнопкой «Закрыть». Живая карта
# (фаза Мифов) всегда важнее и перебивает просмотр.
var _review: bool = false


func _ready() -> void:
	UIStyle.style_modal_panel(_panel)
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


# ── Сборка ────────────────────────────────────────────────────────────────────


func _build() -> void:
	_title_lbl = UIStyle.modal_title("", UIColors.DANGER)
	_vbox.add_child(_title_lbl)

	UIStyle.separator(_vbox)

	_flavor_lbl = Label.new()
	_flavor_lbl.name = "Flavor"
	_flavor_lbl.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_HINT)
	_flavor_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	_flavor_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_flavor_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_flavor_lbl)

	_text_lbl = Label.new()
	_text_lbl.name = "Text"
	_text_lbl.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_BODY)
	_text_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	_text_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_text_lbl)

	UIStyle.separator(_vbox)

	_eff_header = Label.new()
	_eff_header.name = "EffectsHeader"
	_eff_header.text = tr("MYTHOS_EFFECTS_HEADER")
	_eff_header.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_HINT)
	_eff_header.add_theme_color_override("font_color", UIColors.MUTED)
	_vbox.add_child(_eff_header)

	_eff_box = VBoxContainer.new()
	_eff_box.name = "Effects"
	_eff_box.add_theme_constant_override("separation", 4)
	_vbox.add_child(_eff_box)

	UIStyle.separator(_vbox)

	_next_btn = UIStyle.button(tr("MYTHOS_BTN_NEXT"), UIColors.DANGER)
	_next_btn.name = "NextBtn"
	_next_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_next_btn.pressed.connect(_on_next)
	_vbox.add_child(_next_btn)


# ── Отрисовка по стейту ───────────────────────────────────────────────────────


# Открыть последний вытянутый миф в режиме «перечитать» (только чтение).
# Нет last_mythos — тихо ничего не делаем. Живая карта Мифов перебьёт просмотр.
func open_review() -> void:
	if (GameState.last_mythos as Dictionary).is_empty():
		return
	_review = true
	_refresh()


func _refresh() -> void:
	# Живая карта Мифов важнее просмотра — она требует действия («Прочитал»).
	var live: bool = GameState.phase == Phases.MYTHOS and not GameState.current_mythos.is_empty()
	if live:
		_review = false
		_show_card(GameState.current_mythos)
		_update_next_btn()
		return
	if _review and not (GameState.last_mythos as Dictionary).is_empty():
		_show_card(GameState.last_mythos)
		_next_btn.disabled = false
		_next_btn.text = tr("MYTHOS_BTN_CLOSE")
		return
	# Показывать нечего.
	UIStyle.modal_set_visible(_root, _panel, false)
	_last_card_key = ""


# Отрисовать карту (живую или на перечитку). Пересобираем UI только на смене
# карты (ключ = name); первый показ проигрывает звук появления.
func _show_card(card: Dictionary) -> void:
	UIStyle.modal_set_visible(_root, _panel, true)
	var card_key: String = String(card.get("name", ""))
	if card_key == _last_card_key:
		return
	_last_card_key = card_key
	SfxManager.play(SfxManager.SFX_MYTHOS_START)  # звук появления карты мифа
	_title_lbl.text = String(card.get("name", tr("MYTHOS_TITLE_FALLBACK")))
	_flavor_lbl.text = String(card.get("flavorText", ""))
	_flavor_lbl.visible = not _flavor_lbl.text.is_empty()
	_text_lbl.text = String(card.get("text", ""))
	_text_lbl.visible = not _text_lbl.text.is_empty()
	_render_effects(card.get("onDraw", []))


# Кнопка «Прочитал»: пока я не отметился — активна. После — заблокирована и
# показывает прогресс «Ждём остальных (X/N)». Миф резолвится, когда прочитали все.
func _update_next_btn() -> void:
	var me: String = String(GameState.my_player().get("user_id", ""))
	var read: Array = GameState.mythos_read
	var i_read: bool = read.has(me)
	_next_btn.disabled = i_read
	if i_read:
		_next_btn.text = tr("MYTHOS_BTN_WAITING") % [read.size(), _connected_count()]
	else:
		_next_btn.text = tr("MYTHOS_BTN_NEXT")


func _connected_count() -> int:
	var n: int = 0
	for uid_v: Variant in GameState.players:
		if bool(GameState.players[uid_v].get("connected", true)):
			n += 1
	return n


func _render_effects(effects: Array) -> void:
	for child in _eff_box.get_children():
		child.queue_free()
	if effects.is_empty():
		var lbl := Label.new()
		lbl.text = tr("MYTHOS_NO_EFFECTS")
		lbl.add_theme_color_override("font_color", UIColors.MUTED)
		lbl.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_HINT)
		_eff_box.add_child(lbl)
		_eff_header.visible = false
		return
	_eff_header.visible = true
	for i in range(effects.size()):
		var lbl := Label.new()
		lbl.name = "Label"
		lbl.text = "• " + EffectManifest.describe(effects[i])
		lbl.add_theme_font_size_override("font_size", UIStyle.MODAL_FS_HINT)
		lbl.add_theme_color_override("font_color", UIColors.TEXT)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_eff_box.add_child(lbl)


# ── Кнопка ────────────────────────────────────────────────────────────────────


func _on_next() -> void:
	if _review:
		_review = false  # закрыть просмотр
		_refresh()
		return
	_next_btn.disabled = true  # защита от двойного клика / двойного relay
	GameState.resolve_mythos()
