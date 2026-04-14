extends Control

# ── Узлы ───────────────────────────────────────────────────────────────────────
var _auth: Node

var _email_panel: Control
var _code_panel:  Control
var _check_panel: Control

var _email_input: LineEdit
var _send_btn:    Button

var _code_label:  Label
var _code_input:  LineEdit
var _verify_btn:  Button
var _back_btn:    Button

var _status_label: Label

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

	if not _auth.session_token.is_empty():
		_show_panel("check")
		_auth.check_session()
	else:
		_show_panel("email")


# ── Построение UI ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	UIStyle.apply_bg(self)

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
	title.add_theme_color_override("font_color",        UIStyle.GOLD)
	title.add_theme_color_override("font_shadow_color", UIStyle.RED)
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	root.add_child(title)

	var sub := Label.new()
	sub.text = "по мотивам настольной игры «Древний Ужас»"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", UIStyle.DIM)
	root.add_child(sub)

	UIStyle.separator(root)

	# ── Панель «проверка сессии» ───────────────────────────────────────────────
	_check_panel = UIStyle.panel()
	var check_vbox := VBoxContainer.new()
	check_vbox.add_theme_constant_override("separation", 12)
	_check_panel.add_child(check_vbox)

	var check_lbl := Label.new()
	check_lbl.text = "Проверка сессии..."
	check_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	check_lbl.add_theme_font_size_override("font_size", 16)
	check_lbl.add_theme_color_override("font_color", UIStyle.WARN)
	check_vbox.add_child(check_lbl)

	root.add_child(_check_panel)

	# ── Панель email ───────────────────────────────────────────────────────────
	_email_panel = UIStyle.panel()
	var email_vbox := VBoxContainer.new()
	email_vbox.add_theme_constant_override("separation", 12)
	_email_panel.add_child(email_vbox)

	var email_hdr := Label.new()
	email_hdr.text = "  ВХОД / РЕГИСТРАЦИЯ"
	email_hdr.add_theme_font_size_override("font_size", 16)
	email_hdr.add_theme_color_override("font_color", UIStyle.GOLD)
	email_vbox.add_child(email_hdr)

	UIStyle.separator(email_vbox)

	var email_row := UIStyle.labeled_input("Email:", "your@email.com", 90)
	_email_input = email_row[1] as LineEdit
	_email_input.custom_minimum_size.x = 280
	_email_input.text_submitted.connect(_on_send_pressed.unbind(1))
	email_vbox.add_child(email_row[0])

	_send_btn = UIStyle.button("ОТПРАВИТЬ КОД")
	_send_btn.pressed.connect(_on_send_pressed)
	email_vbox.add_child(_send_btn)

	root.add_child(_email_panel)

	# ── Панель кода ────────────────────────────────────────────────────────────
	_code_panel = UIStyle.panel()
	var code_vbox := VBoxContainer.new()
	code_vbox.add_theme_constant_override("separation", 12)
	_code_panel.add_child(code_vbox)

	var code_hdr := Label.new()
	code_hdr.text = "  ВВЕДИТЕ КОД ИЗ ПИСЬМА"
	code_hdr.add_theme_font_size_override("font_size", 16)
	code_hdr.add_theme_color_override("font_color", UIStyle.GOLD)
	code_vbox.add_child(code_hdr)

	UIStyle.separator(code_vbox)

	_code_label = Label.new()
	_code_label.text = "Код отправлен на ..."
	_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_label.add_theme_font_size_override("font_size", 13)
	_code_label.add_theme_color_override("font_color", UIStyle.DIM)
	code_vbox.add_child(_code_label)

	var code_row := UIStyle.labeled_input("Код:", "123456", 90)
	_code_input = code_row[1] as LineEdit
	_code_input.max_length = 6
	_code_input.custom_minimum_size.x = 160
	_code_input.text_submitted.connect(_on_verify_pressed.unbind(1))
	code_vbox.add_child(code_row[0])

	_verify_btn = UIStyle.button("ВОЙТИ", UIStyle.RED)
	_verify_btn.pressed.connect(_on_verify_pressed)
	code_vbox.add_child(_verify_btn)

	_back_btn = UIStyle.button("← Изменить email", UIStyle.DIM)
	_back_btn.pressed.connect(_on_back_pressed)
	code_vbox.add_child(_back_btn)

	root.add_child(_code_panel)

	UIStyle.separator(root)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", UIStyle.DIM)
	_status_label.text = "Войдите через email — пароль не нужен"
	root.add_child(_status_label)


# ── Обработчики кнопок ─────────────────────────────────────────────────────────

func _on_send_pressed() -> void:
	var email: String = _email_input.text.strip_edges().to_lower()
	if email.is_empty() or not "@" in email:
		_show_status("Введите корректный email", UIStyle.ERROR)
		return
	_current_email = email
	_send_btn.disabled = true
	_show_status("Отправляем код на %s..." % email, UIStyle.WARN)
	_auth.request_otp(email)


func _on_verify_pressed() -> void:
	var code: String = _code_input.text.strip_edges()
	if code.length() != 6:
		_show_status("Код должен содержать 6 цифр", UIStyle.ERROR)
		return
	_verify_btn.disabled = true
	_show_status("Проверяем код...", UIStyle.WARN)
	_auth.verify_otp(_current_email, code)


func _on_back_pressed() -> void:
	_code_input.text = ""
	_show_panel("email")
	_show_status("Введите email, чтобы получить новый код", UIStyle.DIM)


# ── Обработчики сигналов AuthManager ──────────────────────────────────────────

func _on_otp_sent() -> void:
	_send_btn.disabled = false
	_code_label.text = "Код отправлен на %s" % _current_email
	_show_panel("code")
	_show_status("Проверьте почту — код действителен 15 минут", UIStyle.OK)
	_code_input.grab_focus()


func _on_otp_failed(error: String) -> void:
	_send_btn.disabled = false
	_show_status("Ошибка: %s" % error, UIStyle.ERROR)


func _on_login_succeeded(_user: Dictionary) -> void:
	_show_status("Вход выполнен!", UIStyle.OK)
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_login_failed(error: String) -> void:
	_verify_btn.disabled = false
	_show_status("Ошибка: %s" % error, UIStyle.ERROR)


func _on_session_invalid() -> void:
	_show_panel("email")
	_show_status("Сессия истекла — войдите снова", UIStyle.WARN)


# ── Вспомогательные ───────────────────────────────────────────────────────────

func _show_panel(which: String) -> void:
	_check_panel.visible = which == "check"
	_email_panel.visible = which == "email"
	_code_panel.visible  = which == "code"
	if which == "email":
		_send_btn.disabled = false
		_email_input.grab_focus()


func _show_status(msg: String, color: Color = UIStyle.TEXT) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = msg
		_status_label.modulate = color
