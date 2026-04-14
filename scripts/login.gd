extends Control

# ── Цвета ──────────────────────────────────────────────────────────────────────
const COLOR_BG           := Color(0.05, 0.04, 0.10)
const COLOR_PANEL        := Color(0.08, 0.07, 0.15)
const COLOR_PANEL_BORDER := Color(0.35, 0.25, 0.10)
const COLOR_GOLD         := Color(0.78, 0.66, 0.29)
const COLOR_RED          := Color(0.55, 0.10, 0.10)
const COLOR_TEXT         := Color(0.85, 0.82, 0.75)
const COLOR_DIM          := Color(0.55, 0.52, 0.45)
const COLOR_ERROR        := Color(0.90, 0.25, 0.20)
const COLOR_OK           := Color(0.30, 0.80, 0.40)
const COLOR_WARN         := Color(0.90, 0.75, 0.20)

# ── Узлы ───────────────────────────────────────────────────────────────────────
var _auth: Node

var _email_panel:   Control
var _code_panel:    Control
var _check_panel:   Control    # "Проверка сессии..."

var _email_input:   LineEdit
var _send_btn:      Button

var _code_label:    Label      # "Код отправлен на {email}"
var _code_input:    LineEdit
var _verify_btn:    Button
var _back_btn:      Button

var _status_label:  Label

var _current_email: String = ""


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_auth = get_node("/root/AuthManager")
	_auth.otp_sent.connect(_on_otp_sent)
	_auth.otp_failed.connect(_on_otp_failed)
	_auth.login_succeeded.connect(_on_login_succeeded)
	_auth.login_failed.connect(_on_login_failed)
	_auth.session_invalid.connect(_on_session_invalid)

	_build_ui()

	# Если токен есть — проверяем на сервере
	if not _auth.session_token.is_empty():
		_show_panel("check")
		_auth.check_session()
	else:
		_show_panel("email")


# ── Построение UI ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(480, 0)
	root.add_theme_constant_override("separation", 16)
	center.add_child(root)

	# Заголовок
	var title := Label.new()
	title.text = "DARK OMENS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", COLOR_GOLD)
	title.add_theme_color_override("font_shadow_color", COLOR_RED)
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	root.add_child(title)

	var sub := Label.new()
	sub.text = "по мотивам настольной игры «Древний Ужас»"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", COLOR_DIM)
	root.add_child(sub)

	_add_separator(root)

	# ── Панель "проверка сессии" ───────────────────────────────────────────────
	_check_panel = _make_panel()
	var check_vbox := VBoxContainer.new()
	check_vbox.add_theme_constant_override("separation", 12)
	_check_panel.add_child(check_vbox)

	var check_lbl := Label.new()
	check_lbl.text = "Проверка сессии..."
	check_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	check_lbl.add_theme_font_size_override("font_size", 16)
	check_lbl.add_theme_color_override("font_color", COLOR_WARN)
	check_vbox.add_child(check_lbl)

	root.add_child(_check_panel)

	# ── Панель email ───────────────────────────────────────────────────────────
	_email_panel = _make_panel()
	var email_vbox := VBoxContainer.new()
	email_vbox.add_theme_constant_override("separation", 12)
	_email_panel.add_child(email_vbox)

	var email_hdr := Label.new()
	email_hdr.text = "  ВХОД / РЕГИСТРАЦИЯ"
	email_hdr.add_theme_font_size_override("font_size", 16)
	email_hdr.add_theme_color_override("font_color", COLOR_GOLD)
	email_vbox.add_child(email_hdr)

	_add_separator(email_vbox)

	var email_row := _make_labeled_input("Email:", "your@email.com", 90)
	_email_input = email_row[1] as LineEdit
	_email_input.custom_minimum_size.x = 280
	_email_input.text_submitted.connect(_on_send_pressed.unbind(1))
	email_vbox.add_child(email_row[0])

	_send_btn = _make_button("ОТПРАВИТЬ КОД", COLOR_PANEL_BORDER)
	_send_btn.pressed.connect(_on_send_pressed)
	email_vbox.add_child(_send_btn)

	root.add_child(_email_panel)

	# ── Панель кода ────────────────────────────────────────────────────────────
	_code_panel = _make_panel()
	var code_vbox := VBoxContainer.new()
	code_vbox.add_theme_constant_override("separation", 12)
	_code_panel.add_child(code_vbox)

	var code_hdr := Label.new()
	code_hdr.text = "  ВВЕДИТЕ КОД ИЗ ПИСЬМА"
	code_hdr.add_theme_font_size_override("font_size", 16)
	code_hdr.add_theme_color_override("font_color", COLOR_GOLD)
	code_vbox.add_child(code_hdr)

	_add_separator(code_vbox)

	_code_label = Label.new()
	_code_label.text = "Код отправлен на ..."
	_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_label.add_theme_font_size_override("font_size", 13)
	_code_label.add_theme_color_override("font_color", COLOR_DIM)
	code_vbox.add_child(_code_label)

	var code_row := _make_labeled_input("Код:", "123456", 90)
	_code_input = code_row[1] as LineEdit
	_code_input.max_length = 6
	_code_input.custom_minimum_size.x = 160
	_code_input.text_submitted.connect(_on_verify_pressed.unbind(1))
	code_vbox.add_child(code_row[0])

	_verify_btn = _make_button("ВОЙТИ", COLOR_RED)
	_verify_btn.pressed.connect(_on_verify_pressed)
	code_vbox.add_child(_verify_btn)

	_back_btn = _make_button("← Изменить email", COLOR_DIM)
	_back_btn.pressed.connect(_on_back_pressed)
	code_vbox.add_child(_back_btn)

	root.add_child(_code_panel)

	_add_separator(root)

	# Статус
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", COLOR_DIM)
	_status_label.text = "Войдите через email — пароль не нужен"
	root.add_child(_status_label)


# ── Обработчики кнопок ─────────────────────────────────────────────────────────

func _on_send_pressed() -> void:
	var email: String = _email_input.text.strip_edges().to_lower()
	if email.is_empty() or not "@" in email:
		_show_status("Введите корректный email", COLOR_ERROR)
		return
	_current_email = email
	_send_btn.disabled = true
	_show_status("Отправляем код на %s..." % email, COLOR_WARN)
	_auth.request_otp(email)


func _on_verify_pressed() -> void:
	var code: String = _code_input.text.strip_edges()
	if code.length() != 6:
		_show_status("Код должен содержать 6 цифр", COLOR_ERROR)
		return
	_verify_btn.disabled = true
	_show_status("Проверяем код...", COLOR_WARN)
	_auth.verify_otp(_current_email, code)


func _on_back_pressed() -> void:
	_code_input.text = ""
	_show_panel("email")
	_show_status("Введите email, чтобы получить новый код", COLOR_DIM)


# ── Обработчики сигналов AuthManager ──────────────────────────────────────────

func _on_otp_sent() -> void:
	_send_btn.disabled = false
	_code_label.text = "Код отправлен на %s" % _current_email
	_show_panel("code")
	_show_status("Проверьте почту — код действителен 15 минут", COLOR_OK)
	_code_input.grab_focus()


func _on_otp_failed(error: String) -> void:
	_send_btn.disabled = false
	_show_status("Ошибка: %s" % error, COLOR_ERROR)


func _on_login_succeeded(_user: Dictionary) -> void:
	_show_status("Вход выполнен!", COLOR_OK)
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_login_failed(error: String) -> void:
	_verify_btn.disabled = false
	_show_status("Ошибка: %s" % error, COLOR_ERROR)


func _on_session_invalid() -> void:
	_show_panel("email")
	_show_status("Сессия истекла — войдите снова", COLOR_WARN)


# ── Вспомогательные ───────────────────────────────────────────────────────────

func _show_panel(which: String) -> void:
	_check_panel.visible = which == "check"
	_email_panel.visible = which == "email"
	_code_panel.visible  = which == "code"
	if which == "email":
		_send_btn.disabled = false
		_email_input.grab_focus()


func _show_status(msg: String, color: Color = COLOR_TEXT) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = msg
		_status_label.modulate = color


func _make_panel() -> PanelContainer:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_PANEL
	style.border_color = COLOR_PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(16)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _make_labeled_input(label_text: String, placeholder: String, label_w: int = 100) -> Array:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = label_w
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", COLOR_TEXT)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(lbl)

	var style_n := StyleBoxFlat.new()
	style_n.bg_color = Color(0.10, 0.09, 0.18)
	style_n.border_color = COLOR_PANEL_BORDER
	style_n.set_border_width_all(1)
	style_n.set_corner_radius_all(4)
	style_n.set_content_margin_all(8)

	var style_f := StyleBoxFlat.new()
	style_f.bg_color = Color(0.12, 0.11, 0.22)
	style_f.border_color = COLOR_GOLD
	style_f.set_border_width_all(1)
	style_f.set_corner_radius_all(4)
	style_f.set_content_margin_all(8)

	var input := LineEdit.new()
	input.placeholder_text = placeholder
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.add_theme_stylebox_override("normal", style_n)
	input.add_theme_stylebox_override("focus", style_f)
	input.add_theme_color_override("font_color", COLOR_TEXT)
	input.add_theme_color_override("font_placeholder_color", COLOR_DIM)
	input.add_theme_font_size_override("font_size", 14)
	hbox.add_child(input)

	return [hbox, input]


func _make_button(text: String, border_color: Color) -> Button:
	var style_n := StyleBoxFlat.new()
	style_n.bg_color = Color(0.12, 0.10, 0.20)
	style_n.border_color = border_color
	style_n.set_border_width_all(1)
	style_n.set_corner_radius_all(5)
	style_n.set_content_margin_all(10)

	var style_h := StyleBoxFlat.new()
	style_h.bg_color = Color(0.20, 0.16, 0.30)
	style_h.border_color = COLOR_GOLD
	style_h.set_border_width_all(1)
	style_h.set_corner_radius_all(5)
	style_h.set_content_margin_all(10)

	var style_p := StyleBoxFlat.new()
	style_p.bg_color = Color(0.08, 0.06, 0.14)
	style_p.border_color = COLOR_RED
	style_p.set_border_width_all(1)
	style_p.set_corner_radius_all(5)
	style_p.set_content_margin_all(10)

	var style_d := StyleBoxFlat.new()
	style_d.bg_color = Color(0.08, 0.07, 0.12)
	style_d.border_color = COLOR_DIM
	style_d.set_border_width_all(1)
	style_d.set_corner_radius_all(5)
	style_d.set_content_margin_all(10)

	var btn := Button.new()
	btn.text = text
	btn.add_theme_stylebox_override("normal", style_n)
	btn.add_theme_stylebox_override("hover", style_h)
	btn.add_theme_stylebox_override("pressed", style_p)
	btn.add_theme_stylebox_override("disabled", style_d)
	btn.add_theme_color_override("font_color", COLOR_GOLD)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", COLOR_DIM)
	btn.add_theme_font_size_override("font_size", 15)
	return btn


func _add_separator(parent: Control, color: Color = COLOR_PANEL_BORDER) -> void:
	var sep := HSeparator.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_content_margin_all(0)
	sep.add_theme_stylebox_override("separator", style)
	parent.add_child(sep)
