extends Control

## Экран входа: проверка сохранённой сессии → email → OTP-код.
## Разметка в scenes/login.tscn, тут только поведение и стилизация.

# ── Узлы (через unique_name_in_owner) ──────────────────────────────────────────
@onready var _bg: ColorRect = $Bg
@onready var _subtitle: Label = $Center/Root/Subtitle

@onready var _check_panel: PanelContainer = %CheckPanel
@onready var _email_panel: PanelContainer = %EmailPanel
@onready var _code_panel: PanelContainer = %CodePanel

@onready var _email_input: LineEdit = %EmailInput
@onready var _send_btn: Button = %SendBtn

@onready var _code_label: Label = %CodeLabel
@onready var _code_input: LineEdit = %CodeInput
@onready var _verify_btn: Button = %VerifyBtn
@onready var _back_btn: Button = %BackBtn

@onready var _status_label: Label = %StatusLabel

# ── Состояние ──────────────────────────────────────────────────────────────────
var _auth: Node
var _current_email: String = ""

# ── Lifecycle ──────────────────────────────────────────────────────────────────


func _ready() -> void:
	MusicManager.play(MusicManager.TRACK_ELDER_SIGN)
	_apply_styles()
	_wire_handlers()

	_auth = get_node("/root/AuthManager")
	_auth.otp_sent.connect(_on_otp_sent)
	_auth.otp_failed.connect(_on_otp_failed)
	_auth.login_succeeded.connect(_on_login_succeeded)
	_auth.login_failed.connect(_on_login_failed)
	_auth.session_invalid.connect(_on_session_invalid)
	_auth.access_denied.connect(_on_access_denied)

	_add_offline_button()

	if not _auth.session_token.is_empty():
		_show_panel("check")
		_auth.check_session()
	else:
		_show_panel("email")


# ── Офлайн-вход ───────────────────────────────────────────────────────────────


## «Играть офлайн» — гость без аккаунта и сервера (LocalTransport + запечённый
## контент). Кнопка есть только когда контент запечён (data/offline).
func _add_offline_button() -> void:
	if not OfflineContent.available():
		return
	var root: VBoxContainer = $Center/Root
	var sep := HSeparator.new()
	sep.name = "OfflineSep"
	root.add_child(sep)
	var btn := Button.new()
	btn.name = "OfflineBtn"
	btn.text = "LOGIN_BTN_OFFLINE"
	UIStyle.style_button(btn)
	btn.pressed.connect(_on_offline_pressed)
	root.add_child(btn)


func _on_offline_pressed() -> void:
	_show_status("LOGIN_STATUS_OFFLINE", UIColors.WARNING)
	# В меню: Древний и число мест выбираются в «Создать комнату», места займут боты.
	if not OfflineSession.enter():
		_show_status("LOGIN_ERR_OFFLINE_UNAVAILABLE", UIColors.ERROR)


# ── Применение Dark Omens-стилей к нодам из .tscn ─────────────────────────────


func _apply_styles() -> void:
	# Старый ColorRect фон заменяем на тайлированную bg-pattern.png.
	_bg.queue_free()
	UIStyle.apply_main_bg(self)

	_subtitle.add_theme_color_override("font_color", UIColors.MUTED)

	UIStyle.style_panel(_check_panel)
	UIStyle.style_panel(_email_panel)
	UIStyle.style_panel(_code_panel)

	# Заголовки внутри панелей
	for hdr_path in [
		"Center/Root/EmailPanel/VBox/Header",
		"Center/Root/CodePanel/VBox/Header",
	]:
		var hdr: Label = get_node(hdr_path)
		hdr.add_theme_color_override("font_color", UIColors.ACCENT)

	(get_node("Center/Root/CheckPanel/VBox/CheckLabel") as Label).add_theme_color_override(
		"font_color", UIColors.WARNING
	)

	# Лейблы строк ввода и подпись «Код отправлен на ...»
	for label_path in [
		"Center/Root/EmailPanel/VBox/EmailRow/EmailLabel",
		"Center/Root/CodePanel/VBox/CodeRow/CodeRowLabel",
	]:
		(get_node(label_path) as Label).add_theme_color_override("font_color", UIColors.TEXT)

	_code_label.add_theme_color_override("font_color", UIColors.MUTED)

	UIStyle.style_input(_email_input)
	UIStyle.style_input(_code_input)

	UIStyle.style_button(_send_btn)
	UIStyle.style_button(_verify_btn, UIColors.DANGER)
	UIStyle.style_button(_back_btn, UIColors.MUTED)

	_status_label.add_theme_color_override("font_color", UIColors.MUTED)


func _wire_handlers() -> void:
	_email_input.text_submitted.connect(_on_send_pressed.unbind(1))
	_code_input.text_submitted.connect(_on_verify_pressed.unbind(1))
	_send_btn.pressed.connect(_on_send_pressed)
	_verify_btn.pressed.connect(_on_verify_pressed)
	_back_btn.pressed.connect(_on_back_pressed)


# ── Обработчики кнопок ─────────────────────────────────────────────────────────


func _on_send_pressed() -> void:
	var email: String = _email_input.text.strip_edges().to_lower()
	if email.is_empty() or not "@" in email:
		_show_status("LOGIN_ERR_INVALID_EMAIL", UIColors.ERROR)
		return
	_current_email = email
	_send_btn.disabled = true
	_show_status(tr("LOGIN_STATUS_SENDING") % email, UIColors.WARNING)
	_auth.request_otp(email)


func _on_verify_pressed() -> void:
	var code: String = _code_input.text.strip_edges()
	if code.length() != 6:
		_show_status("LOGIN_ERR_CODE_LENGTH", UIColors.ERROR)
		return
	_verify_btn.disabled = true
	_show_status("LOGIN_STATUS_CHECKING_CODE", UIColors.WARNING)
	_auth.verify_otp(_current_email, code)


func _on_back_pressed() -> void:
	_code_input.text = ""
	_show_panel("email")
	_show_status("LOGIN_ERR_NEED_EMAIL", UIColors.MUTED)


# ── Обработчики сигналов AuthManager ──────────────────────────────────────────


func _on_otp_sent() -> void:
	_send_btn.disabled = false
	_code_label.text = tr("LOGIN_STATUS_CODE_SENT") % _current_email
	_show_panel("code")
	_show_status("LOGIN_STATUS_CHECK_MAIL", UIColors.SUCCESS)
	_code_input.grab_focus()


func _on_otp_failed(error: String) -> void:
	_send_btn.disabled = false
	_show_status(tr("LOGIN_STATUS_ERROR") % error, UIColors.ERROR)


func _on_login_succeeded(_user: Dictionary) -> void:
	_show_status("LOGIN_STATUS_SUCCESS", UIColors.SUCCESS)
	SceneManager.go("main_menu")


func _on_login_failed(error: String) -> void:
	_verify_btn.disabled = false
	_show_status(tr("LOGIN_STATUS_ERROR") % error, UIColors.ERROR)


func _on_session_invalid() -> void:
	_show_panel("email")
	_show_status("LOGIN_SESSION_EXPIRED", UIColors.WARNING)


# Играть нельзя. Форму входа показываем, но предупреждаем: новый код ничего не
# изменит, сервер откажет снова — иначе игрок будет слать себе письма по кругу.
# Слова разные: отозванному — в поддержку, не купившему — купить.
func _on_access_denied(code: String, reason: String) -> void:
	_show_panel("email")
	var key: String = (
		"LOGIN_LICENSE_REVOKED" if code == "license_revoked" else "LOGIN_LICENSE_REQUIRED"
	)
	var text: String = tr(key)
	if not reason.strip_edges().is_empty():
		text += " (%s)" % reason
	_show_status(text, UIColors.ERROR)


# ── Вспомогательные ───────────────────────────────────────────────────────────


func _show_panel(which: String) -> void:
	_check_panel.visible = which == "check"
	_email_panel.visible = which == "email"
	_code_panel.visible = which == "code"
	if which == "email":
		_send_btn.disabled = false
		_email_input.grab_focus()


func _show_status(msg: String, color: Color = UIColors.TEXT) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = msg
		_status_label.modulate = color
