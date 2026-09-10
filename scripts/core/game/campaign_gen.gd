class_name CampaignGen
extends RefCounted

## Хост-only: сборка и анализ сценарной библии. Прогрев в лобби, сброс
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

# Имя Древнего из модалки создания комнаты ("" — на выбор модели). Одноразовое:
# расходуется на первом prewarm() (дальше Древний уже зашит в готовую библию).
var _seed_ancient_one: String = ""

# Размер КОМНАТЫ (на сколько человек создали) — авторитет всего баланса: стартовая
# раскладка, Наплыв монстров, мифос-колода, цели Тайн. НЕ расходуется (живёт пока
# хост в комнате), иначе 2-я игра/перегенерация в той же комнате потеряет размер и
# упадёт на число подключённых. 0 — не задан (промоут в хосты) → фолбэк на лобби.
var _room_player_count: int = 0


func _init(gs: Node) -> void:
	_gs = gs


# ── Public API ───────────────────────────────────────────────────────────────


## Модалка создания комнаты передаёт сюда выбор хоста. Подхватится в prewarm().
func set_seed(ancient_one: String, player_count: int) -> void:
	_seed_ancient_one = ancient_one
	_room_player_count = maxi(1, player_count)


## Авторитетное число игроков для баланса = размер комнаты; если он неизвестен
## (промоут в хосты без зерна) — фолбэк на размер лобби. Один источник правды
## для генерации кампании и стартовой раскладки.
func balance_player_count() -> int:
	if _room_player_count > 0:
		return _room_player_count
	return maxi(1, _gs._nm.players.size())


## Хост: запустить генерацию ЗАРАНЕЕ — из лобби, пока игроки ещё выбирают
## сыщиков. К моменту start_game библия будет готова или почти готова, и
## экран загрузки покажется меньше (или не покажется вовсе). Использует
## зерно из set_seed; без зерна (промоут в хосты) — Древний на выбор модели,
## размер партии по составу лобби.
func prewarm() -> void:
	if not _gs._is_host():
		return
	if _gs.campaign_pending or not _gs.campaign.is_empty():
		return  # генерация уже идёт либо библия уже готова
	var pc: int = balance_player_count()  # размер комнаты (не лобби), если задан
	var ao: String = _seed_ancient_one
	_seed_ancient_one = ""  # Древний — одноразовый, размер комнаты живёт
	GameConsole.log("[Game] Прогрев кампании в лобби (игроков комнаты: %d)..." % pc)
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
	_gs.campaign = {}
	_gs.campaign_pending = false


# ── Анализ ───────────────────────────────────────────────────────────────────


## Стадия кампании (1–3) — по числу решённых Тайн (active_mystery): решили первую
## Тайну → стадия 2 и т.д. У самих Тайн актов НЕТ (они просто последовательность);
## акты живут только в колоде Мифов (полосы byAct) и в рецепте Древнего. Эта стадия
## используется лишь как «акт» для подбора сложности встреч. doom отдельно.
func current_act() -> int:
	return clampi(_gs.active_mystery + 1, 1, 3)


## Активная Тайна — по индексу active_mystery (Тайны идут последовательностью, без
## актов). {} — кампания/тайны не готовы либо все решены (outcome=="victory").
func current_mystery() -> Dictionary:
	var ms: Array = _gs.campaign.get("mysteries", [])
	var idx: int = _gs.active_mystery
	if idx < 0 or idx >= ms.size():
		return {}
	return ms[idx]


# ── Корутина генерации ───────────────────────────────────────────────────────


# Один цикл сборки сценарной библии (детерминированно из CMS, быстро). Корутина — вызывается без
# await. Эпоха защищает от устаревших результатов.
func _start_generation(player_count: int, ancient_one: String) -> void:
	if not _gs._is_host():
		return
	_epoch += 1
	var epoch: int = _epoch
	_gs.campaign = {}
	_gs.campaign_pending = true
	# Новая кампания — сбрасываем цикл Тайн (active_mystery/прогресс/финал).
	_gs.active_mystery = 0
	_gs.mystery_progress = 0
	_gs.mystery_claimed = []
	_gs.outcome = ""
	_gs._emit_changed()

	var api: Node = _gs.get_node_or_null("/root/ContentApi")
	if api == null:
		GameConsole.warn("[Game] ContentApi недоступен — кампания не собрана")
		if epoch == _epoch:
			_gs.campaign_pending = false
			if _gs.active:
				_gs._broadcast_sync()
			_gs._emit_changed()
		return

	var req: Dictionary = _build_request(player_count, ancient_one)
	GameConsole.log("[Game] Сборка сценарной библии...")
	@warning_ignore("unsafe_method_access")
	var res: Dictionary = await api.assemble_campaign(req)

	if epoch != _epoch:
		return  # перебито новым циклом или reset — результат устарел
	if bool(res.get("ok", false)):
		var full: Dictionary = res.get("campaign", {})
		_gs.campaign = _summary(full, ancient_one)
		# Размер партии, под который сгенерена кампания (мифос-колода, цели Тайн).
		# Стартовая раскладка (_setup_board) обязана взять ИМЕННО его, а не число
		# подключённых: иначе соло-тест партии на 5–8 даст раскладку как на 1.
		_gs.campaign["playerCount"] = maxi(1, player_count)
		_gs._mythos.deck = full.get("mythosDeck", [])
		_gs._mythos.index = 0
		var ao: Dictionary = _gs.campaign.get("ancientOne", {})
		GameConsole.log(
			(
				"[Game] Кампания готова — Древний: %s, карт Мифов: %d"
				% [String(ao.get("name", "?")), _gs._mythos.deck.size()]
			)
		)
	else:
		GameConsole.warn("[Game] Сборка кампании не удалась: %s" % String(res.get("error", "")))
	_gs.campaign_pending = false
	# Броадкаст только если игра уже идёт; библию, прогретую ещё в лобби,
	# разошлёт _broadcast_sync() из start_game.
	if _gs.active:
		_gs._mystery.apply_mystery_on_enter()  # onEnter первой Тайны, если партия уже идёт (до синка)
		_gs._broadcast_sync()
	_gs._emit_changed()


# Тело запроса /campaign/assemble: локации, размер партии, язык, Древний.
func _build_request(player_count: int, ancient_one: String) -> Dictionary:
	var locations: Array = _gs.map.all()
	var locs: Array = []
	for i in range(locations.size()):
		var loc: Dictionary = locations[i]
		# В LLM отдаём локализованное игровое имя (Аркхэм / Arkham), а не
		# realWorldLocation (Уэнэм, Массачусетс) — модель будет ссылаться на
		# места по узнаваемым лавкрафтовским названиям, не по реальным.
		var name_key: String = String(loc.get("name", loc.get("id", "")))
		# id шлём отдельно — relay сопоставляет с config/ancients.json по нему
		# (стабильный ключ, не зависит от языка).
		(
			locs
			. append(
				{
					"id": String(loc.get("id", "")),
					"name": tr(name_key),
					"type": String(loc.get("type", "city")),
				}
			)
		)
	var req: Dictionary = {
		"locations": locs,
		"playerCount": maxi(1, player_count),
		"language": _gs._relay_language(),
	}
	# Древний задан в модалке создания комнаты — иначе модель придумывает сама.
	if not ancient_one.is_empty():
		req["ancientOne"] = ancient_one
	return req


# Компактная сводка библии для синка — без тяжёлой колоды Мифов и эффектов.
# Полная библия сохранена на сервере и тянется по id при генерации встреч.
# ancient_id (id Древнего из сида комнаты) штампуем в ancientOne для идентичности —
# relay шлёт {name, epithet, onReckoning, …} без id. Расплату Древнего ReckoningFlow
# берёт из ancientOne.onReckoning (из CMS), а не адресует по id.
func _summary(full: Dictionary, ancient_id: String = "") -> Dictionary:
	var mysteries: Array = []
	var src: Array = full.get("mysteries", [])
	for i in range(src.size()):
		var m: Dictionary = src[i]
		var msum: Dictionary = {
			"title": String(m.get("title", "")),
			"flavorText": String(m.get("flavorText", "")),
			"text": String(m.get("text", "")),
			"solveCondition": m.get("solveCondition", {}),
			# Помеченные локации Тайны — без них нет маркеров и mystery-встреч.
			"locations": m.get("locations", []),
			# onEnter — board-эффекты при активации Тайны (напр. раскладка
			# жетонов Знамения для tokensOnCard). Лёгкий, синкаем.
			"onEnter": m.get("onEnter", []),
		}
		# progress-хуки набора жетонов (реакции gateClosed/... + встречи-хуки
		# encounterAtEldritchToken) — БЕЗ них tokensOnCard-Тайна не продвигается и
		# не предлагает встречу. Лёгкие, синкаем как есть. Копируем только если есть
		# (иначе пустой progress затенил бы легаси-progressHook в mystery_progress_hooks).
		if m.has("progress"):
			msum["progress"] = m.get("progress", [])
		if m.has("progressHook"):
			msum["progressHook"] = m.get("progressHook", {})
		mysteries.append(msum)
	return {
		"id": String(full.get("id", "")),
		"doomClock": int(full.get("doomClock", 0)),
		"ancientOne": _stamp_ancient_id(full.get("ancientOne", {}), ancient_id),
		"mysteries": mysteries,
		# Локации с авторской site-встречей — на них предлагаем выбор «общая/локационная».
		"siteEncounterLocations": full.get("siteEncounterLocations", []),
	}


# Проштамповать id Древнего (из сида комнаты) в объект ancientOne, если relay его
# не прислал. Копию — чтобы не мутировать исходный full. Существующий id не трогаем.
func _stamp_ancient_id(ao: Dictionary, ancient_id: String) -> Dictionary:
	if ancient_id.is_empty() or String(ao.get("id", "")) != "":
		return ao
	var out: Dictionary = ao.duplicate(true)
	out["id"] = ancient_id
	return out
