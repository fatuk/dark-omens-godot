class_name CampaignGen
extends RefCounted

## Хост-only: генерация и анализ сценарной библии. Прогрев в лобби, сброс
## перед новой игрой, актуальный акт, текущая мистерия.
##
## GameState владеет публичными полями (campaign, campaign_pending) — они
## синкаются всем игрокам через _broadcast_sync/_apply_snapshot. CampaignGen
## владеет host-only состоянием (эпоха генерации, зерно из модалки) и логикой
## генерации/сводки/анализа. Запись в _gs.campaign/_gs.campaign_pending —
## сознательная: при успехе мы обязаны попасть в синк, и удобнее писать
## напрямую, чем пересылать через сеттеры.

var _gs: Node

# Эпоха генерации: инкрементится на каждый новый цикл и на reset. Защищает
# от записи устаревшего результата (за время await начался новый цикл или
# был reset_pregame — старый результат отбрасываем).
var _epoch: int = 0

# Зерно будущей кампании из модалки создания комнаты: имя Древнего ("" —
# на выбор модели) и размер партии (0 — не задан, фолбэк на состав лобби).
# Одноразовое — после prewarm() сбрасывается.
var _seed_ancient_one: String = ""
var _seed_player_count: int = 0


func _init(gs: Node) -> void:
	_gs = gs


# ── Public API ───────────────────────────────────────────────────────────────

## Модалка создания комнаты передаёт сюда выбор хоста. Подхватится в prewarm().
func set_seed(ancient_one: String, player_count: int) -> void:
	_seed_ancient_one  = ancient_one
	_seed_player_count = maxi(1, player_count)


## Хост: запустить генерацию ЗАРАНЕЕ — из лобби, пока игроки ещё выбирают
## сыщиков. К моменту start_game библия будет готова или почти готова, и
## экран загрузки покажется меньше (или не покажется вовсе). Использует
## зерно из set_seed; без зерна (промоут в хосты) — Древний на выбор модели,
## размер партии по составу лобби.
func prewarm() -> void:
	if not _gs._is_host():
		return
	if _gs.campaign_pending or not _gs.campaign.is_empty():
		return   # генерация уже идёт либо библия уже готова
	var pc: int = _seed_player_count
	if pc <= 0:
		pc = maxi(1, _gs._nm.players.size())
	var ao: String = _seed_ancient_one
	_seed_ancient_one  = ""
	_seed_player_count = 0
	GameConsole.log("[Game] Прогрев кампании в лобби (игроков: %d)..." % pc)
	_start_generation(pc, ao)


## Хост: запустить генерацию по конкретному составу (фолбэк, если в start_game
## кампания так и не прогрелась).
func start_generation(player_count: int, ancient_one: String) -> void:
	_start_generation(player_count, ancient_one)


## Хост: сброс полей кампании перед новой игрой. Инкрементит эпоху —
## незавершённая корутина прошлой генерации отбросит свой результат.
## Зовётся из GameState.reset_pregame, который дополнительно чистит мифос,
## встречу, префетчи и active.
func reset() -> void:
	if not _gs._is_host():
		return
	_epoch += 1
	_gs.campaign         = {}
	_gs.campaign_pending = false


# ── Анализ ───────────────────────────────────────────────────────────────────

## Текущий акт (1–3) по доле заполнения doom-часов. Трекинга прогресса
## Мистерий пока нет — акт оцениваем по doom.
func current_act() -> int:
	var clock: int = int(_gs.campaign.get("doomClock", 0))
	if clock <= 0:
		return 1
	var ratio: float = float(_gs.doom) / float(clock)
	if ratio < 0.34:
		return 1
	if ratio < 0.67:
		return 2
	return 3


## Мистерия текущего акта ({} если кампания/тайны ещё не готовы) — для UI.
func current_mystery() -> Dictionary:
	var ms: Array = _gs.campaign.get("mysteries", [])
	if ms.is_empty():
		return {}
	var act: int = current_act()
	for i in range(ms.size()):
		var m: Dictionary = ms[i]
		if int(m.get("act", 0)) == act:
			return m
	return ms[0]


# ── Корутина генерации ───────────────────────────────────────────────────────

# Один цикл генерации сценарной библии (~минуты). Корутина — вызывается без
# await. Эпоха защищает от устаревших результатов.
func _start_generation(player_count: int, ancient_one: String) -> void:
	if not _gs._is_host():
		return
	_epoch += 1
	var epoch: int = _epoch
	_gs.campaign         = {}
	_gs.campaign_pending = true
	_gs._emit_changed()

	var api: Node = _gs.get_node_or_null("/root/ContentApi")
	if api == null:
		GameConsole.warn("[Game] ContentApi недоступен — кампания не сгенерирована")
		if epoch == _epoch:
			_gs.campaign_pending = false
			if _gs.active:
				_gs._broadcast_sync()
			_gs._emit_changed()
		return

	var req: Dictionary = _build_request(player_count, ancient_one)
	GameConsole.log("[Game] Генерация сценарной библии...")
	@warning_ignore("unsafe_method_access")
	var res: Dictionary = await api.generate_campaign(req)

	if epoch != _epoch:
		return   # перебито новым циклом или reset — результат устарел
	if bool(res.get("ok", false)):
		var full: Dictionary = res.get("campaign", {})
		_gs.campaign     = _summary(full)
		_gs._mythos.deck  = full.get("mythosDeck", [])
		_gs._mythos.index = 0
		var ao: Dictionary = _gs.campaign.get("ancientOne", {})
		GameConsole.log("[Game] Кампания готова — Древний: %s, карт Мифов: %d" % [
			String(ao.get("name", "?")), _gs._mythos.deck.size()
		])
	else:
		GameConsole.warn("[Game] Генерация кампании не удалась: %s" % String(res.get("error", "")))
	_gs.campaign_pending = false
	# Броадкаст только если игра уже идёт; библию, прогретую ещё в лобби,
	# разошлёт _broadcast_sync() из start_game.
	if _gs.active:
		_gs._broadcast_sync()
	_gs._emit_changed()


# Тело запроса /campaign/generate: локации, размер партии, язык, Древний.
func _build_request(player_count: int, ancient_one: String) -> Dictionary:
	var locations: Array = _gs._load_locations()
	var locs: Array = []
	for i in range(locations.size()):
		var loc: Dictionary = locations[i]
		# В LLM отдаём локализованное игровое имя (Аркхэм / Arkham), а не
		# realWorldLocation (Уэнэм, Массачусетс) — модель будет ссылаться на
		# места по узнаваемым лавкрафтовским названиям, не по реальным.
		var name_key: String = String(loc.get("name", loc.get("id", "")))
		locs.append({
			"name": tr(name_key),
			"type": String(loc.get("type", "city")),
		})
	var req: Dictionary = {
		"locations":   locs,
		"playerCount": maxi(1, player_count),
		"language":    _gs._relay_language(),
	}
	# Древний задан в модалке создания комнаты — иначе модель придумывает сама.
	if not ancient_one.is_empty():
		req["ancientOne"] = ancient_one
	return req


# Компактная сводка библии для синка — без тяжёлой колоды Мифов и эффектов.
# Полная библия сохранена на сервере и тянется по id при генерации встреч.
func _summary(full: Dictionary) -> Dictionary:
	var mysteries: Array = []
	var src: Array = full.get("mysteries", [])
	for i in range(src.size()):
		var m: Dictionary = src[i]
		mysteries.append({
			"act":            int(m.get("act", 0)),
			"title":          String(m.get("title", "")),
			"flavorText":     String(m.get("flavorText", "")),
			"text":           String(m.get("text", "")),
			"solveCondition": m.get("solveCondition", {}),
		})
	return {
		"id":         String(full.get("id", "")),
		"doomClock":  int(full.get("doomClock", 0)),
		"ancientOne": full.get("ancientOne", {}),
		"theme":      full.get("theme", []),
		"mysteries":  mysteries,
	}
