extends Node

## ContentApi — клиент HTTP-контента: встречи (выборка из корпуса CMS) и
## сценарные библии через relay-API (/encounters/draw, /campaign/assemble,
## /campaign/:id). Autoload-синглтон /root/ContentApi.
##
## Контент тянет ТОЛЬКО хост; не-хосты получают готовый контент по WS-relay
## (см. GameState). Сам сервис политику host-only не навязывает — это решает
## вызывающая сторона. Запросы аутентифицируются токеном AuthManager.
##
## Все публичные методы — await-корутины. Возвращают Dictionary вида
##   { "ok": bool, "error": String, ...полезная нагрузка }
## Пример:
##   var res: Dictionary = await ContentApi.draw_encounter({ ... })
##   if res["ok"]:
##       for card in res["encounters"]: ...
##   else:
##       push_warning(res["error"])

# Таймауты: и встреча, и сценарная библия — выборка/сборка из корпуса CMS
# (детерминированно, быстро; запас — на сеть).
const TIMEOUT_ENCOUNTER: float = 60.0
const TIMEOUT_CAMPAIGN: float = 60.0

# ── Публичное API ─────────────────────────────────────────────────────────────


## Выбрать карточки встреч из корпуса CMS. `req` — тело запроса /encounters/draw
## (kind, investigator, realLocation/otherWorld, conditions, count, language,
## campaignId/act/doom — см. relay requestSchema). При успехе в ответе ключ
## `encounters` — массив карточек.
func draw_encounter(req: Dictionary) -> Dictionary:
	if is_offline():
		return OfflineContent.draw(req)
	var res: Dictionary = await _post("/encounters/draw", req, TIMEOUT_ENCOUNTER)
	if not res["ok"]:
		return res
	var json: Dictionary = res["json"]
	return {"ok": true, "error": "", "encounters": json.get("encounters", [])}


## Собрать сценарную библию (детерминированно из CMS-корпуса). `req` — тело
## /campaign/assemble (locations, ancientOne?, playerCount, themeHint?, language).
## При успехе в ответе ключ `campaign` — объект библии.
func assemble_campaign(req: Dictionary) -> Dictionary:
	if is_offline():
		return OfflineContent.assemble(req)
	var res: Dictionary = await _post("/campaign/assemble", req, TIMEOUT_CAMPAIGN)
	if not res["ok"]:
		return res
	var json: Dictionary = res["json"]
	return {"ok": true, "error": "", "campaign": json.get("campaign", {})}


## Достать ранее сохранённую кампанию по id.
func get_campaign(id: String) -> Dictionary:
	if is_offline():
		return OfflineContent.get_campaign(id)
	var res: Dictionary = await _request(
		HTTPClient.METHOD_GET, "/campaign/" + id, "", TIMEOUT_ENCOUNTER
	)
	if not res["ok"]:
		return res
	var json: Dictionary = res["json"]
	return {"ok": true, "error": "", "campaign": json.get("campaign", {})}


## Актуальный список Древних (CMS + конфиг) для дропдауна «Создать комнату».
## Возвращает Array из {id, name}; при ошибке — пустой массив.
func get_ancients(lang: String) -> Array:
	if is_offline():
		return OfflineContent.ancients(lang)
	var res: Dictionary = await _request(
		HTTPClient.METHOD_GET, "/ancients?lang=" + lang.uri_encode(), "", TIMEOUT_ENCOUNTER
	)
	if not res["ok"]:
		return []
	var json: Dictionary = res["json"]
	return json.get("ancients", [])


## Офлайн-партия (NetworkManager.local_mode): контент берём из запечённых файлов
## data/offline/ (OfflineContent), сервер не нужен. Один переключатель на сеть и
## контент — офлайн-игру нельзя случайно оставить без библии.
func is_offline() -> bool:
	var nm: Node = get_node_or_null("/root/NetworkManager")
	return nm != null and bool(nm.get("local_mode"))


# ── Транспорт ─────────────────────────────────────────────────────────────────


func _post(path: String, body: Dictionary, timeout: float) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, path, JSON.stringify(body), timeout)


## Один HTTP-запрос. Под каждый запрос — свой HTTPRequest-узел, поэтому
## несколько запросов могут идти параллельно (в отличие от единственного
## _http в AuthManager). Узел освобождается по завершении запроса.
func _request(method: int, path: String, body: String, timeout: float) -> Dictionary:
	var token: String = AuthManager.session_token
	if token.is_empty():
		return _err("Нет сессии — сначала войдите в аккаунт")

	var http := HTTPRequest.new()
	http.name = "ContentRequest"
	http.timeout = timeout
	add_child(http)

	var headers := PackedStringArray(
		[
			"Content-Type: application/json",
			"Authorization: Bearer " + token,
		]
	)
	var err: Error = http.request(AuthManager.api_base + path, headers, method, body)
	if err != OK:
		http.queue_free()
		return _err("Запрос не отправлен (err %d)" % err)

	# request_completed отдаёт (result, response_code, headers, body).
	var r: Array = await http.request_completed
	http.queue_free()

	var result: int = r[0]
	var code: int = r[1]
	var bytes: PackedByteArray = r[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		return _err("Нет связи с сервером контента (result %d)" % result)

	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	var json: Dictionary = parsed if parsed is Dictionary else {}

	if code != 200:
		# error может прийти строкой ИЛИ объектом (структурная ошибка валидации).
		# Приводим к строке, иначе _err(msg: String) падает на конвертации типа.
		var e: Variant = json.get("error", "Ошибка сервера (%d)" % code)
		return _err(e if e is String else JSON.stringify(e))

	return {"ok": true, "error": "", "json": json}


func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "json": {}}
