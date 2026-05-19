extends Node

## ContentApi — клиент HTTP-генерации контента: встречи и сценарные библии
## через relay-API (/encounters/generate, /campaign/generate, /campaign/:id).
## Autoload-синглтон /root/ContentApi.
##
## Генерацию зовёт ТОЛЬКО хост; не-хосты получают готовый контент по WS-relay
## (см. GameState). Сам сервис политику host-only не навязывает — это решает
## вызывающая сторона. Запросы аутентифицируются токеном AuthManager.
##
## Все публичные методы — await-корутины. Возвращают Dictionary вида
##   { "ok": bool, "error": String, ...полезная нагрузка }
## Пример:
##   var res: Dictionary = await ContentApi.generate_encounter({ ... })
##   if res["ok"]:
##       for card in res["encounters"]: ...
##   else:
##       push_warning(res["error"])

# Таймауты под время генерации LLM: встреча — десятки секунд,
# сценарная библия — пара минут.
const TIMEOUT_ENCOUNTER: float = 60.0
const TIMEOUT_CAMPAIGN:  float = 240.0


# ── Публичное API ─────────────────────────────────────────────────────────────

## Сгенерировать карточки встреч. `req` — тело запроса /encounters/generate
## (kind, investigator, realLocation/otherWorld, conditions, count, language,
## campaignId/act/doom — см. relay requestSchema). При успехе в ответе ключ
## `encounters` — массив карточек.
func generate_encounter(req: Dictionary) -> Dictionary:
	var res: Dictionary = await _post("/encounters/generate", req, TIMEOUT_ENCOUNTER)
	if not res["ok"]:
		return res
	var json: Dictionary = res["json"]
	return { "ok": true, "error": "", "encounters": json.get("encounters", []) }


## Сгенерировать сценарную библию. `req` — тело /campaign/generate
## (locations, ancientOne?, playerCount, themeHint?, language). При успехе в
## ответе ключ `campaign` — объект библии.
func generate_campaign(req: Dictionary) -> Dictionary:
	var res: Dictionary = await _post("/campaign/generate", req, TIMEOUT_CAMPAIGN)
	if not res["ok"]:
		return res
	var json: Dictionary = res["json"]
	return { "ok": true, "error": "", "campaign": json.get("campaign", {}) }


## Достать ранее сохранённую кампанию по id.
func get_campaign(id: String) -> Dictionary:
	var res: Dictionary = await _request(
		HTTPClient.METHOD_GET, "/campaign/" + id, "", TIMEOUT_ENCOUNTER
	)
	if not res["ok"]:
		return res
	var json: Dictionary = res["json"]
	return { "ok": true, "error": "", "campaign": json.get("campaign", {}) }


# ── Транспорт ─────────────────────────────────────────────────────────────────

func _post(path: String, body: Dictionary, timeout: float) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, path, JSON.stringify(body), timeout)


## Один HTTP-запрос. Под каждый запрос — свой HTTPRequest-узел, поэтому
## несколько генераций могут идти параллельно (в отличие от единственного
## _http в AuthManager). Узел освобождается по завершении запроса.
func _request(method: int, path: String, body: String, timeout: float) -> Dictionary:
	var token: String = AuthManager.session_token
	if token.is_empty():
		return _err("Нет сессии — сначала войдите в аккаунт")

	var http := HTTPRequest.new()
	http.name    = "GenRequest"
	http.timeout = timeout
	add_child(http)

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + token,
	])
	var err: Error = http.request(AuthManager.api_base + path, headers, method, body)
	if err != OK:
		http.queue_free()
		return _err("Запрос не отправлен (err %d)" % err)

	# request_completed отдаёт (result, response_code, headers, body).
	var r: Array = await http.request_completed
	http.queue_free()

	var result: int = r[0]
	var code:   int = r[1]
	var bytes: PackedByteArray = r[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		return _err("Нет связи с сервером генерации (result %d)" % result)

	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	var json: Dictionary = parsed if parsed is Dictionary else {}

	if code != 200:
		return _err(json.get("error", "Ошибка сервера (%d)" % code))

	return { "ok": true, "error": "", "json": json }


func _err(msg: String) -> Dictionary:
	return { "ok": false, "error": msg, "json": {} }
