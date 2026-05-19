extends CanvasLayer

## Левый сайдбар с текущей Мистерией кампании. Открывается кликом по орбу
## раунда в game_panel. Слайд-ин слева, по образцу location_sidebar.

const PANEL_WIDTH: float = 380.0
const ANIM_TIME:   float = 0.22

@onready var _panel:     PanelContainer = %Panel
@onready var _title:     Label  = %Title
@onready var _status:    Label  = %Status
@onready var _flavor:    Label  = %Flavor
@onready var _text:      Label  = %Text
@onready var _solve:     Label  = %Solve
@onready var _close_btn: Button = %CloseBtn

var _is_open: bool  = false
var _tween:   Tween = null


func _ready() -> void:
	UIStyle.style_panel(_panel, 18)
	UIStyle.style_icon_button(_close_btn, UIColors.DANGER)
	_close_btn.add_theme_font_size_override("font_size", 18)
	_title.add_theme_color_override("font_color",  UIColors.ACCENT)
	_status.add_theme_color_override("font_color", UIColors.WARNING)
	_flavor.add_theme_color_override("font_color", UIColors.MUTED)
	_text.add_theme_color_override("font_color",   UIColors.TEXT)
	_solve.add_theme_color_override("font_color",  UIColors.ACCENT)
	_close_btn.pressed.connect(close_panel)
	_apply_offsets(true)


# ── Public ────────────────────────────────────────────────────────────────────

## Открыть, если закрыт; закрыть, если открыт.
func toggle() -> void:
	if _is_open:
		close_panel()
	else:
		_refresh()
		_is_open = true
		_animate(false)


func close_panel() -> void:
	if not _is_open:
		return
	_is_open = false
	_animate(true)


# ── Контент ───────────────────────────────────────────────────────────────────

func _refresh() -> void:
	var m: Dictionary = GameState.current_mystery()
	if m.is_empty():
		_title.text  = "MYSTERY_NONE_TITLE"
		_status.text = ""
		_flavor.text = "MYSTERY_NONE_BODY"
		_text.text   = ""
		_solve.text  = ""
		return
	_title.text  = String(m.get("title", "MYSTERY_NONE_TITLE"))
	_status.text = tr("MYSTERY_STATUS_FMT") % [
		int(m.get("act", 1)), GameState.doom,
		int(GameState.campaign.get("doomClock", 0)),
	]
	_flavor.text = String(m.get("flavorText", ""))
	_text.text   = String(m.get("text", ""))
	_solve.text  = "%s: %s" % [tr("MYSTERY_SOLVE"), _solve_text(m.get("solveCondition", {}))]


## Человекочитаемое условие закрытия из структурного solveCondition.
func _solve_text(sc: Dictionary) -> String:
	var kind: String = String(sc.get("kind", ""))
	var n: int = int(sc.get("n", sc.get("count", 0)))
	match kind:
		"cluesOnCard":     return tr("MYSTERY_SOLVE_CLUES")  % n
		"tokensOnCard":    return tr("MYSTERY_SOLVE_TOKENS") % n
		"monsterDefeated": return tr("MYSTERY_SOLVE_MONSTER")
	return tr("MYSTERY_SOLVE_UNKNOWN")


# ── Анимация выезда ───────────────────────────────────────────────────────────

func _animate(hide_panel: bool) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var off_l: float = -PANEL_WIDTH if hide_panel else 0.0
	var off_r: float = 0.0          if hide_panel else PANEL_WIDTH
	_tween.tween_property(_panel, "offset_left",  off_l, ANIM_TIME)
	_tween.tween_property(_panel, "offset_right", off_r, ANIM_TIME)


func _apply_offsets(hide_panel: bool) -> void:
	if hide_panel:
		_panel.offset_left  = -PANEL_WIDTH
		_panel.offset_right = 0.0
	else:
		_panel.offset_left  = 0.0
		_panel.offset_right = PANEL_WIDTH
