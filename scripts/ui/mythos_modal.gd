extends CanvasLayer

## Окно карты Мифов. Видно ВСЕМ игрокам в фазе mythos после того, как хост
## вытянул карту (GameState.current_mythos непустая). Показывает имя карты,
## flavor-строчку, рулз-текст и список эффектов onDraw. По кнопке «Дальше»
## событие через relay уходит хосту, который применяет эффекты и стартует
## следующий раунд (см. GameState._apply_resolve_mythos).
##
## Контент строится кодом — паттерн settings_dialog / create_room_dialog.

@onready var _root:  ColorRect      = $Root
@onready var _panel: PanelContainer = %Panel
@onready var _vbox:  VBoxContainer  = %VBox

var _title_lbl:   Label
var _flavor_lbl:  Label
var _text_lbl:    Label
var _eff_header:  Label
var _eff_box:     VBoxContainer
var _next_btn:    Button

# Кеш ключа текущей карты — чтобы не пересобирать UI на каждый _refresh,
# если карта не сменилась.
var _last_card_key: String = ""


func _ready() -> void:
	UIStyle.style_panel(_panel, 24)
	_build()
	GameState.state_changed.connect(_refresh)
	_refresh()


# ── Сборка ────────────────────────────────────────────────────────────────────

func _build() -> void:
	_title_lbl = Label.new()
	_title_lbl.name = "Title"
	_title_lbl.add_theme_font_size_override("font_size", 22)
	_title_lbl.add_theme_color_override("font_color", UIColors.DANGER)
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_title_lbl)

	UIStyle.separator(_vbox)

	_flavor_lbl = Label.new()
	_flavor_lbl.name = "Flavor"
	_flavor_lbl.add_theme_font_size_override("font_size", 13)
	_flavor_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	_flavor_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_flavor_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_flavor_lbl)

	_text_lbl = Label.new()
	_text_lbl.name = "Text"
	_text_lbl.add_theme_font_size_override("font_size", 14)
	_text_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	_text_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_text_lbl)

	UIStyle.separator(_vbox)

	_eff_header = Label.new()
	_eff_header.name = "EffectsHeader"
	_eff_header.text = "Эффекты:"
	_eff_header.add_theme_font_size_override("font_size", 12)
	_eff_header.add_theme_color_override("font_color", UIColors.MUTED)
	_vbox.add_child(_eff_header)

	_eff_box = VBoxContainer.new()
	_eff_box.name = "Effects"
	_eff_box.add_theme_constant_override("separation", 4)
	_vbox.add_child(_eff_box)

	UIStyle.separator(_vbox)

	_next_btn = UIStyle.button("Дальше", UIColors.DANGER)
	_next_btn.name = "NextBtn"
	_next_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_next_btn.pressed.connect(_on_next)
	_vbox.add_child(_next_btn)


# ── Отрисовка по стейту ───────────────────────────────────────────────────────

func _refresh() -> void:
	var show_modal: bool = (
		GameState.phase == "mythos" and not GameState.current_mythos.is_empty()
	)
	_root.visible = show_modal
	if not show_modal:
		_last_card_key = ""
		_next_btn.disabled = false
		return
	var card: Dictionary = GameState.current_mythos
	# Уникальный ключ карты — name + index (мифос-карты от LLM без id, имени
	# хватает для разделения, плюс _mythos_index уже отражён неявно в смене).
	var card_key: String = String(card.get("name", ""))
	if card_key == _last_card_key:
		return  # ничего не сменилось — UI уже правильный
	_last_card_key = card_key
	_next_btn.disabled = false

	_title_lbl.text  = String(card.get("name", "Миф"))
	_flavor_lbl.text = String(card.get("flavorText", ""))
	_flavor_lbl.visible = not _flavor_lbl.text.is_empty()
	_text_lbl.text   = String(card.get("text", ""))
	_text_lbl.visible = not _text_lbl.text.is_empty()
	_render_effects(card.get("onDraw", []))


func _render_effects(effects: Array) -> void:
	for child in _eff_box.get_children():
		child.queue_free()
	if effects.is_empty():
		var lbl := Label.new()
		lbl.text = "(нет эффектов)"
		lbl.add_theme_color_override("font_color", UIColors.MUTED)
		lbl.add_theme_font_size_override("font_size", 12)
		_eff_box.add_child(lbl)
		_eff_header.visible = false
		return
	_eff_header.visible = true
	for i in range(effects.size()):
		var lbl := Label.new()
		lbl.text = "• " + _describe_effect(effects[i])
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", UIColors.TEXT)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_eff_box.add_child(lbl)


# Человекочитаемое описание узла Effect-DSL — для отображения, не применение.
func _describe_effect(eff: Dictionary) -> String:
	var verb: String = String(eff.get("do", ""))
	var n: int = int(eff.get("amount", eff.get("count", 1)))
	var target: String = String(eff.get("target", ""))
	var s: String
	match verb:
		"advanceDoom":         s = "Часы doom: +%d" % n
		"advanceOmen", "moveOmen": s = "Сдвиг знамения: +%d" % n
		"openGate":            s = "Открывается врат: %d" % n
		"spawnMonster":        s = "Появляется чудовищ: %d" % n
		"placeClue":           s = "Появляется улик: %d" % n
		"placeEldritchToken":  s = "Эльдричские жетоны: %d" % n
		"placeRumor":          s = "Появляется слух"
		"resolveReckoning":    s = "Срабатывает Расплата"
		"loseHealth":          s = "Потеря здоровья: %d" % n
		"loseSanity":          s = "Потеря рассудка: %d" % n
		"gainCondition":       s = "Получает состояние: %s" % String(eff.get("condition", "?"))
		"text":                s = String(eff.get("text", "(эффект)"))
		_:
			if verb.is_empty():
				s = "(комбинатор)"
			else:
				s = verb
	if not target.is_empty():
		s += "  · %s" % _describe_target(target)
	return s


func _describe_target(t: String) -> String:
	match t:
		"lead":             return "ведущий"
		"each":             return "у каждого"
		"eachOnCity":       return "в городе"
		"eachOnWilderness": return "в дикой местности"
		"eachOnSea":        return "в море"
		_:                  return t


# ── Кнопка ────────────────────────────────────────────────────────────────────

func _on_next() -> void:
	_next_btn.disabled = true   # защита от двойного клика / двойного relay
	GameState.resolve_mythos()
