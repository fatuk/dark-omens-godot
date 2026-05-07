## RelayTransport — чистый транспортный слой (WebSocket).
## Не знает ничего о лобби, игроках или игровой логике.
## NetworkManager подписывается на его сигналы и использует send_raw().
extends Node

# ── Сигналы ────────────────────────────────────────────────────────────────────
signal ws_opened                    # соединение установлено
signal ws_closed                    # соединение закрыто
signal raw_received(text: String)   # пришёл текстовый пакет (JSON-строка)
signal reconnecting(attempt: int)   # начинаем попытку переподключения
signal connection_lost              # исчерпали все попытки

# ── Настройки ──────────────────────────────────────────────────────────────────
const RECONNECT_BASE      := 3.0    # начальная задержка (секунд)
const RECONNECT_MAX_DELAY := 60.0   # максимальная задержка
const RECONNECT_MAX       := 10     # количество попыток перед сдачей
const KEEPALIVE_INTERVAL  := 20.0   # интервал app-level ping

# ── Внутреннее состояние ───────────────────────────────────────────────────────
var _ws              := WebSocketPeer.new()
var _prev_state      : int  = WebSocketPeer.STATE_CLOSED
var _url             : String = ""

var _reconnect_enabled  : bool  = false
var _reconnect_attempts : int   = 0
var _reconnect_timer    : float = 0.0
var _keepalive_timer    : float = KEEPALIVE_INTERVAL


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	# WebSocket polling должен продолжаться, даже когда дерево на паузе
	process_mode = Node.PROCESS_MODE_ALWAYS


# ── Публичный API ──────────────────────────────────────────────────────────────

## Установить соединение. Включает автопереподключение.
func connect_to_server(url: String) -> Error:
	_url = url
	_reconnect_enabled  = true
	_reconnect_attempts = 0
	_reconnect_timer    = 0.0
	_prev_state         = WebSocketPeer.STATE_CLOSED
	return _do_connect()


## Закрыть соединение и отключить автопереподключение.
func disconnect_from_server() -> void:
	_reconnect_enabled = false
	_ws.close()
	_prev_state = WebSocketPeer.STATE_CLOSED


## Отправить словарь как JSON. Молча игнорирует, если сокет не открыт.
func send_raw(data: Dictionary) -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_ws.send_text(JSON.stringify(data))


func is_open() -> bool:
	return _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


func is_connecting_or_open() -> bool:
	var s := _ws.get_ready_state()
	return s == WebSocketPeer.STATE_OPEN or s == WebSocketPeer.STATE_CONNECTING


# ── Godot lifecycle ────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	# Ожидание перед следующей попыткой реконнекта
	if _reconnect_timer > 0.0:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0.0:
			_attempt_reconnect()
		return

	# Нет смысла поллить, если оба состояния CLOSED
	if _prev_state == WebSocketPeer.STATE_CLOSED and _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		return

	_ws.poll()
	var cur_state: int = _ws.get_ready_state()

	# Обнаружение смены состояния — _prev_state обновляется ДО вызова хендлера
	if cur_state != _prev_state:
		_prev_state = cur_state
		match cur_state:
			WebSocketPeer.STATE_OPEN:
				_reconnect_attempts = 0
				_keepalive_timer    = KEEPALIVE_INTERVAL
				ws_opened.emit()
			WebSocketPeer.STATE_CLOSED:
				ws_closed.emit()
				if _reconnect_enabled and _reconnect_attempts < RECONNECT_MAX:
					_schedule_reconnect()
				elif _reconnect_enabled:
					_reconnect_enabled = false
					print("[Transport] Gave up reconnecting after %d attempts" % RECONNECT_MAX)
					connection_lost.emit()

	# Keepalive ping
	if cur_state == WebSocketPeer.STATE_OPEN:
		_keepalive_timer -= delta
		if _keepalive_timer <= 0.0:
			_keepalive_timer = KEEPALIVE_INTERVAL
			send_raw({"type": "ping"})

	# Чтение входящих пакетов
	while _ws.get_available_packet_count() > 0:
		var text: String = _ws.get_packet().get_string_from_utf8()
		raw_received.emit(text)


# ── Reconnect internals ───────────────────────────────────────────────────────

func _schedule_reconnect() -> void:
	_reconnect_attempts += 1
	# Exponential backoff: base * 1.5^(n-1) + jitter ±0.5s
	var delay: float = minf(
		RECONNECT_BASE * pow(1.5, _reconnect_attempts - 1),
		RECONNECT_MAX_DELAY
	)
	delay += randf_range(-0.5, 0.5)
	_reconnect_timer = maxf(delay, 1.0)
	reconnecting.emit(_reconnect_attempts)
	print("[Transport] Reconnect attempt %d in %.1fs..." % [_reconnect_attempts, _reconnect_timer])


func _attempt_reconnect() -> void:
	if not _reconnect_enabled:
		return
	_prev_state = WebSocketPeer.STATE_CLOSED
	var err: Error = _do_connect()
	if err != OK:
		if _reconnect_attempts < RECONNECT_MAX:
			_schedule_reconnect()
		else:
			_reconnect_enabled = false
			print("[Transport] Gave up reconnecting after %d attempts" % RECONNECT_MAX)
			connection_lost.emit()


func _do_connect() -> Error:
	_ws.close()
	_ws = WebSocketPeer.new()
	var err: int = _ws.connect_to_url(_url)
	if err == OK:
		_prev_state = WebSocketPeer.STATE_CONNECTING
	return err as Error
