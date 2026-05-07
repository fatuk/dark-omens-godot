extends Node

## Управляет аутентификацией через email OTP.
## Autoload-синглтон: /root/AuthManager

# ── Настройки ──────────────────────────────────────────────────────────────────
## ВАЖНО: 127.0.0.1, а не localhost. На Windows localhost резолвится в ::1 (IPv6),
## а Docker Desktop не пробрасывает IPv6-порты — запросы виснут до таймаута.
var api_base: String = "http://127.0.0.1:3031"
const SAVE_FILE := "user://auth.cfg"

# ── Сигналы ────────────────────────────────────────────────────────────────────
signal otp_sent                            # код отправлен на почту
signal otp_failed(error: String)           # ошибка при запросе кода
signal login_succeeded(user: Dictionary)   # успешный вход / подтверждение сессии
signal login_failed(error: String)         # неверный код или истёк
signal session_invalid                     # сохранённый токен недействителен
signal logged_out                          # пользователь вышел

# ── Состояние ──────────────────────────────────────────────────────────────────
var current_user: Dictionary = {}   # {id, email, name}
var session_token: String = ""

var _http: HTTPRequest
var _pending: String = ""   # "otp_request" | "otp_verify" | "check_session" | "logout"


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_http = HTTPRequest.new()
	# Таймаут на сетевой запрос: если сервер завис, не висим вечно
	# (Docker port-forwarding на Windows иногда «икает», TCP не закрывается).
	_http.timeout = 10.0
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_load_session()


# ── Public API ─────────────────────────────────────────────────────────────────

func is_logged_in() -> bool:
	return not session_token.is_empty() and not current_user.is_empty()


## Проверить сохранённый токен через сервер.
## Если валидный — emit login_succeeded; если нет — emit session_invalid.
func check_session() -> void:
	if session_token.is_empty():
		session_invalid.emit()
		return
	if _pending != "":
		return
	_pending = "check_session"
	var err := _http.request(api_base + "/auth/me",
		["Authorization: Bearer " + session_token], HTTPClient.METHOD_GET)
	if err != OK:
		push_warning("AuthManager: HTTPRequest.request failed (err=%d)" % err)
		_pending = ""
		session_invalid.emit()


## Запросить OTP-код на email.
func request_otp(email: String) -> void:
	if _pending != "":
		return
	_pending = "otp_request"
	var err := _http.request(api_base + "/auth/request",
		["Content-Type: application/json"], HTTPClient.METHOD_POST,
		JSON.stringify({"email": email}))
	if err != OK:
		push_warning("AuthManager: HTTPRequest.request failed (err=%d)" % err)
		_pending = ""
		otp_failed.emit("Не удалось отправить запрос (err %d)" % err)


## Подтвердить OTP-код.
func verify_otp(email: String, code: String) -> void:
	if _pending != "":
		return
	_pending = "otp_verify"
	_http.request(
		api_base + "/auth/verify",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		JSON.stringify({"email": email, "code": code})
	)


## Выйти из аккаунта.
func logout() -> void:
	if session_token.is_empty():
		return
	# Инвалидируем на сервере (best-effort, не ждём ответа)
	if _pending == "":
		_pending = "logout"
		_http.request(
			api_base + "/auth/logout",
			["Content-Type: application/json", "Authorization: Bearer " + session_token],
			HTTPClient.METHOD_POST
		)
	current_user = {}
	session_token = ""
	_save_session()
	logged_out.emit()


# ── Обработка ответа ──────────────────────────────────────────────────────────

func _on_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
) -> void:
	var pending := _pending
	_pending = ""

	if result != HTTPRequest.RESULT_SUCCESS:
		push_warning("AuthManager: %s failed — %s (http=%d)" % [
			pending, _result_name(result), response_code,
		])
		match pending:
			"otp_request":   otp_failed.emit("Нет соединения с сервером")
			"otp_verify":    login_failed.emit("Нет соединения с сервером")
			"check_session": session_invalid.emit()
		return

	var text: String = body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	var json: Dictionary = parsed if parsed is Dictionary else {}

	match pending:
		"otp_request":
			if response_code == 200:
				otp_sent.emit()
			else:
				otp_failed.emit(json.get("error", "Ошибка сервера (%d)" % response_code))

		"otp_verify":
			if response_code == 200:
				session_token = json.get("token", "")
				current_user  = json.get("user", {})
				_save_session()
				login_succeeded.emit(current_user)
			else:
				login_failed.emit(json.get("error", "Неверный код"))

		"check_session":
			if response_code == 200:
				current_user = json
				login_succeeded.emit(current_user)
			elif response_code == 401:
				# Токен явно инвалидирован сервером — стираем
				session_token = ""
				current_user  = {}
				_save_session()
				session_invalid.emit()
			else:
				# 500 / сетевая ошибка / сервер не ответил — токен НЕ трогаем,
				# чтобы следующий запуск не требовал повторного логина
				session_invalid.emit()

		"logout":
			pass   # уже обработано в logout()


func _result_name(r: int) -> String:
	match r:
		HTTPRequest.RESULT_SUCCESS:           return "SUCCESS"
		HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: return "CHUNKED_BODY_SIZE_MISMATCH"
		HTTPRequest.RESULT_CANT_CONNECT:      return "CANT_CONNECT"
		HTTPRequest.RESULT_CANT_RESOLVE:      return "CANT_RESOLVE"
		HTTPRequest.RESULT_CONNECTION_ERROR:  return "CONNECTION_ERROR"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "TLS_HANDSHAKE_ERROR"
		HTTPRequest.RESULT_NO_RESPONSE:       return "NO_RESPONSE"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: return "BODY_SIZE_LIMIT_EXCEEDED"
		HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED: return "BODY_DECOMPRESS_FAILED"
		HTTPRequest.RESULT_REQUEST_FAILED:    return "REQUEST_FAILED"
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN: return "DOWNLOAD_FILE_CANT_OPEN"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR: return "DOWNLOAD_FILE_WRITE_ERROR"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: return "REDIRECT_LIMIT_REACHED"
		HTTPRequest.RESULT_TIMEOUT:           return "TIMEOUT"
	return "UNKNOWN"


# ── Сохранение токена ─────────────────────────────────────────────────────────

func _load_session() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_FILE) == OK:
		session_token = cfg.get_value("auth", "token", "")
		# current_user заполним через check_session — не доверяем кэшированным данным


func _save_session() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("auth", "token", session_token)
	cfg.save(SAVE_FILE)
