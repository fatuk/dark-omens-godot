class_name GuideDirector
extends Node

## Кто и когда показывает подсказки профессора Армитеджа (GuideHint).
##
## Что сказать — данные (data/guide_hints.json: id, on, lines, show, priority),
## когда — события игры, которые здесь распознаются по GameState (trigger_active).
## Каждая подсказка — один раз на профиль (SettingsStore.guide_seen); выключаются
## в настройках (SettingsStore.guide_hints, по умолчанию включены у всех).
##
## Очередь: по одной подсказке за раз, по приоритету.
##   show "free" — ждём, пока экран свободен от окон (как баннер «Ваш ход»),
##                 и ещё _SETTLE секунд, чтобы не выскакивать посреди анимации;
##   show "over" — подсказка ПРО открытое окно (встреча, бой, магазин) — сразу,
##                 поверх него.
## Событие прошло, пока подсказка ждала (ход кончился) — снимаем её из очереди,
## покажется при следующем таком событии.
##
## Только локально: ничего не синхронизируется, у каждого игрока своя память.
## Монтируется из WorldMap.

const DATA_PATH := "res://data/guide_hints.json"
const _SETTLE: float = 0.6  # сколько экран должен быть свободен перед «free»

## Сохранять ли «показано» в профиль (тесты выключают, чтобы не трогать user://).
var persist: bool = true

var _hints: Array = []  # записи из DATA_PATH
var _queue: Array = []  # id ожидающих показа
var _seen: Array = []  # показанные (persist → SettingsStore.guide_seen)
var _current: GuideHint = null
var _free_for: float = 0.0


func _ready() -> void:
	_hints = DataLoader.load_dict(DATA_PATH).get("hints", [])
	_seen = SettingsStore.guide_seen if persist else []
	GameState.state_changed.connect(_refresh)
	_refresh()


## Поставить в очередь подсказки, чьё событие идёт прямо сейчас.
func _refresh() -> void:
	if not _enabled():
		_queue.clear()
		return
	for h_v: Variant in _hints:
		var h: Dictionary = h_v
		var id: String = String(h.get("id", ""))
		if id.is_empty() or _seen.has(id) or _queue.has(id):
			continue
		if trigger_active(String(h.get("on", ""))):
			_queue.append(id)
	_queue.sort_custom(func(a: String, b: String) -> bool: return _priority(a) > _priority(b))


func _process(delta: float) -> void:
	if is_instance_valid(_current) or _queue.is_empty():
		_free_for = 0.0
		return
	if not _enabled():
		_queue.clear()
		return
	# Момент упущен (ход кончился, окно закрылось) — снимаем, покажем при следующем
	# таком событии. Все разом: иначе устаревшие голова очереди держала бы свежую.
	_queue = _queue.filter(
		func(id: Variant) -> bool: return trigger_active(String(hint(String(id)).get("on", "")))
	)
	if _queue.is_empty():
		return
	var h: Dictionary = hint(String(_queue[0]))
	if String(h.get("show", "free")) != "over":
		if UIStyle.any_modal_open():
			_free_for = 0.0
			return
		_free_for += delta
		if _free_for < _SETTLE:
			return
	_queue.pop_front()
	_show(h)


func _show(h: Dictionary) -> void:
	var id: String = String(h.get("id", ""))
	if persist:
		SettingsStore.mark_guide_seen(id)  # тот же массив, что _seen
	elif not _seen.has(id):
		_seen.append(id)
	_free_for = 0.0
	_current = GuideHint.say(self, h.get("lines", []), String(h.get("show", "free")) == "over")


## Запись подсказки по id ({} — нет такой).
func hint(id: String) -> Dictionary:
	for h_v: Variant in _hints:
		if String((h_v as Dictionary).get("id", "")) == id:
			return h_v
	return {}


## Идёт ли сейчас событие on — для МЕНЯ (локальный игрок). Тень подсказок не видит.
func trigger_active(on: String) -> bool:
	if not GameState.active:
		return false
	var me: Dictionary = GameState.my_player()
	if me.is_empty() or bool(me.get(PlayerKeys.DEAD, false)):
		return false
	var enc: Dictionary = GameState.current_encounter
	match on:
		"actionPhase":
			return (
				GameState.is_my_turn()
				and int(me.get(PlayerKeys.ACTIONS_LEFT, 0)) > 0
				and not bool(me.get(PlayerKeys.TRAVEL_ANIM, false))
			)
		"monsterHere":
			return (
				GameState.is_my_turn()
				and GameState.has_monster_at(String(me.get(PlayerKeys.LOCATION, "")))
			)
		"lowVitality":
			var hp: int = int(me.get(PlayerKeys.HP, 0))
			var san: int = int(me.get(PlayerKeys.SANITY, 0))
			return GameState.is_my_turn() and hp > 0 and san > 0 and (hp <= 2 or san <= 2)
		"encounter":
			return (
				GameState.is_my_encounter_turn()
				and (GameState.encounter_choices as Array).is_empty()
				and not enc.is_empty()
				and String(enc.get("kind", "")) != "combat"
			)
		"combat":
			return GameState.is_my_encounter_turn() and String(enc.get("kind", "")) == "combat"
		"shop":
			for n: Node in get_tree().get_nodes_in_group("shop_modal"):
				if bool(n.get("visible")):
					return true
			return false
		"mythos":
			return (
				GameState.phase == Phases.MYTHOS
				and not (GameState.current_mythos as Dictionary).is_empty()
				and not (GameState.mythos_read as Array).has(String(me.get(PlayerKeys.USER_ID, "")))
			)
		"reckoning":
			return me.has("reckoning_check")
	return false


func _enabled() -> bool:
	return SettingsStore.guide_hints and GameState.active


func _priority(id: String) -> int:
	return int(hint(id).get("priority", 0))
