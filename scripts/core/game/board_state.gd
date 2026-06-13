class_name BoardState
extends RefCounted

## Подсистема доски (хост-only). Вынесена из GameState:
##   • трек омена (общий для всех Древних) и дум от сдвига омена;
##   • врата (открытие/закрытие/сброс) и их цвета;
##   • монстры (спаун из «мешка», урон, снятие, возврат) и Наплыв;
##   • улики / жетоны Знамения / слухи на локациях;
##   • стартовая раскладка кампании (Icon Reference).
##
## Синкаемый стейт (gates/entities/monsters/monster_bag/monster_surge/doom/
## omens_step) ОСТАЁТСЯ полями GameState — модуль мутирует его через _gs. Доступ к
## стейту/услугам — через _gs: _gs._is_host(), _gs._load_locations(),
## _gs._current_pid(), _gs.players, _gs._campaign, _gs._fill_shop_reserve(),
## _gs._mystery.try_mystery_hook(). Создаётся в GameState (поле _board).

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


# ── Цвета омена / врат ────────────────────────────────────────────────────────

## Порядок цветов омена — ОБЩИЙ трек для всех Древних: green → blue → red → blue,
## далее по кругу. Цвет врат = знак омена; Наплыв бьёт по вратам цвета текущего омена.
const OMEN_COLORS: Array = ["green", "blue", "red", "blue"]


## Цвет текущего омена (по omens_step).
func current_omen_color() -> String:
	return String(OMEN_COLORS[_gs.omens_step % OMEN_COLORS.size()])


## Сколько открытых врат заданного цвета. Для правила «омен сдвинулся → дум +
## врата нового цвета» и для Наплыва.
func count_gates_of_color(color: String) -> int:
	var n: int = 0
	for lid_v: Variant in _gs.gates:
		if String(_gs.gates[lid_v]) == color:
			n += 1
	return n


## Дум от омена. Зовётся СРАЗУ при сдвиге омена (до открытия новых врат этой же
## картой): дум += число открытых врат текущего цвета омена. Возвращает прибавку.
func resolve_omen_doom() -> int:
	var color: String = current_omen_color()
	var matched: int = count_gates_of_color(color)
	if matched > 0:
		_gs.doom += matched
		GameConsole.log("[Омен] цвет %s · врат: %d · doom +%d" % [color, matched, matched])
	return matched


# ── Стартовая раскладка кампании (Icon Reference) ─────────────────────────────

## Базовая таблица Памятки (простые карточки): по числу сыщиков — сколько врат
## открыть и улик разложить на старте, и значение Наплыва (monster_surge) на всю
## партию. Наплыв растёт 1→3, поэтому surge-эффекты Мифа масштабируются числом
## игроков сами (см. monster_surge). NB: оверрайды Древних (карточки с символами
## в Памятке) пока НЕ применяются — это отдельная таблица per-Ancient (TODO).
const REFERENCE: Dictionary = {
	1: {"gates": 1, "clues": 1, "surge": 1},
	2: {"gates": 1, "clues": 2, "surge": 1},
	3: {"gates": 1, "clues": 2, "surge": 2},
	4: {"gates": 1, "clues": 3, "surge": 2},
	5: {"gates": 2, "clues": 3, "surge": 2},
	6: {"gates": 2, "clues": 3, "surge": 2},
	7: {"gates": 2, "clues": 4, "surge": 3},
	8: {"gates": 2, "clues": 4, "surge": 3},
}


func _reference_for(player_count: int) -> Dictionary:
	return REFERENCE.get(clampi(player_count, 1, 8), REFERENCE[1])


## Хост: начальная раскладка поля. Открыть врата (каждые → 1 монстр), разложить
## улики (≤1 на локацию), записать Наплыв. Зовётся из start_game до _broadcast_sync.
func setup_board(player_count: int) -> void:
	if not _gs._is_host():
		return
	_gs.gates = {}
	_gs.entities = {}
	_gs.monsters = {}
	_gs._fill_shop_reserve()  # стартовая витрина магазина
	# Наполняем «мешок» всеми не-эпическими монстрами (по одному id).
	_gs.monster_bag = []
	var pool: Array = MonsterCatalog.non_epic()
	for i: int in range(pool.size()):
		_gs.monster_bag.append(String(pool[i].get("id", "")))
	var ref: Dictionary = _reference_for(player_count)
	_gs.monster_surge = int(ref.get("surge", 1))
	for _i: int in int(ref.get("gates", 1)):
		open_gate()
	for _i: int in int(ref.get("clues", 1)):
		place_clue()
	GameConsole.log(
		(
			"[Старт] Раскладка: врат %d, улик %d, Наплыв %d (игроков %d)"
			% [int(ref.get("gates", 1)), int(ref.get("clues", 1)), _gs.monster_surge, player_count]
		)
	)


# ── Врата / монстры / улики (host-only мутации синкаемого state) ──────────────


## Открыть врата. loc_id пустой → случайная свободная локация; color пустой →
## по циклу цветов омена. Каждые новые врата выпускают 1 монстра.
func open_gate(loc_id: String = "", color: String = "") -> void:
	if not _gs._is_host():
		return
	var lid: String = loc_id
	if lid.is_empty():
		# Врата открываются ТОЛЬКО на гейт-спейсах (локации с gateColor), как на
		# доске EH — номерные «реальные» точки гейтов не имеют.
		var candidates: Array = []
		var locations: Array = _gs._load_locations()
		for i: int in range(locations.size()):
			var l: Dictionary = locations[i]
			var did: String = String(l.get("id", ""))
			if did.is_empty() or _gs.gates.has(did):
				continue
			if String(l.get("gateColor", "")).is_empty():
				continue  # не гейт-спейс
			candidates.append(did)
		if candidates.is_empty():
			GameConsole.warn("[Врата] нет свободных гейт-локаций")
			return
		lid = String(candidates[randi() % candidates.size()])
	# Цвет привязан к локации (каноничный цвет спейса EH); явный аргумент имеет
	# приоритет. Фолбэк (локация без gateColor) — зелёный.
	var col: String = color
	if col.is_empty():
		col = _gate_color_for(lid)
	_gs.gates[lid] = col
	GameConsole.log("[Врата] открылись (%s) на %s" % [col, lid])
	_spawn_monster(lid)  # каждые новые врата → 1 монстр


## Каноничный цвет врат локации (из data/locations.json → gateColor). Локация
## без поля (не гейт-спейс) → "green" как безопасный фолбэк.
func _gate_color_for(loc_id: String) -> String:
	var locations: Array = _gs._load_locations()
	for i: int in range(locations.size()):
		var l: Dictionary = locations[i]
		if String(l.get("id", "")) == loc_id:
			var c: String = String(l.get("gateColor", ""))
			return c if not c.is_empty() else "green"
	return "green"


## Закрыть врата на локации активного игрока (эффект closeGate финальной стадии
## gate-встречи). Врата привязаны к месту, где сыщик прошёл Иной мир.
func close_gate_at_active_player() -> void:
	if not _gs._is_host():
		return
	var pid: String = _gs._current_pid()
	if pid.is_empty():
		return
	var loc: String = String(_gs.players.get(pid, {}).get("location", ""))
	if _gs.gates.has(loc):
		var color: String = String(_gs.gates[loc])
		_gs.gates.erase(loc)
		GameConsole.log("[Врата] закрыты на %s" % loc)
		# Триггер Тайны: закрытие врат (напр. «врата цвета омена → −1 улика → жетон»)
		_gs._mystery.try_mystery_hook("gateClosed", {"loc": loc, "color": color}, pid)


## Заспаунить монстра на локации, ВЫТЯНУВ случайный id из «мешка» (без повторов).
## Экземпляр хранит здоровье ({id, health}); смерть вернёт id в мешок. Мешок
## пуст → спауна нет (как пустой котёл монстров в EH).
func _spawn_monster(loc_id: String) -> void:
	if not _gs._is_host() or loc_id.is_empty():
		return
	if _gs.monster_bag.is_empty():
		GameConsole.warn("[Спаун] мешок монстров пуст — спаун пропущен")
		return
	var idx: int = randi() % _gs.monster_bag.size()
	var mid: String = String(_gs.monster_bag[idx])
	# Культистов много (повторяются) — не вынимаем из мешка; остальные уникальны.
	if mid != "cultist":
		_gs.monster_bag.remove_at(idx)
	var m: Dictionary = MonsterCatalog.by_id(mid)
	# Стойкость монстра — от РАЗМЕРА КОМНАТЫ (как весь баланс), а не от числа
	# подключённых: соло-тест партии на N даёт монстров как на N.
	var balance_pc: int = _gs._campaign.balance_player_count()
	@warning_ignore("unsafe_method_access")
	var hp: int = maxi(1, MonsterCatalog.toughness_for(m, balance_pc) if not m.is_empty() else 1)
	var arr: Array = _gs.monsters.get(loc_id, [])
	arr.append({"id": mid, "health": hp})
	_gs.monsters[loc_id] = arr
	GameConsole.log(
		(
			"[Спаун] монстр %s (стойкость %d) на %s · в мешке %d"
			% [mid, hp, loc_id, _gs.monster_bag.size()]
		)
	)


## Вернуть монстра в «мешок» (после гибели/снятия с поля). Культист всегда в
## мешке (его не вынимали) — не дублируем.
func return_monster_to_bag(mid: String) -> void:
	if not _gs._is_host() or mid.is_empty() or mid == "cultist":
		return
	_gs.monster_bag.append(mid)


## Локация активного игрока ("" — нет активного). Для board-verb'ов, бьющих «здесь».
func _active_loc() -> String:
	var pid: String = _gs._current_pid()
	if pid.is_empty() or not _gs.players.has(pid):
		return ""
	return String(_gs.players[pid].get("location", ""))


## Снять до n монстров с локации активного игрока (id → в мешок). defeated — для лога.
func remove_monster_at_active(defeated: bool, n: int) -> void:
	if not _gs._is_host():
		return
	var loc: String = _active_loc()
	if loc.is_empty():
		return
	var arr: Array = _gs.monsters.get(loc, [])
	var removed: int = 0
	while removed < maxi(1, n) and not (arr as Array).is_empty():
		var inst: Variant = arr[0]
		var mid: String = String(inst.get("id", "")) if inst is Dictionary else String(inst)
		arr.remove_at(0)
		return_monster_to_bag(mid)
		removed += 1
	if (arr as Array).is_empty():
		_gs.monsters.erase(loc)
	else:
		_gs.monsters[loc] = arr
	if removed > 0:
		GameConsole.log(
			"[Монстр] %s ×%d на %s" % ["побеждён" if defeated else "сброшен", removed, loc]
		)


## Снять с локации активного игрока всех монстров со стойкостью ≤ max_t (id → в
## мешок). Для эффектов «по стойкости» (Poison Mist/Banishment/Binding). defeated — лог.
func remove_monsters_by_toughness(defeated: bool, max_t: int) -> void:
	if not _gs._is_host() or max_t < 1:
		return
	var loc: String = _active_loc()
	if loc.is_empty():
		return
	var balance_pc: int = _gs._campaign.balance_player_count()
	var kept: Array = []
	var removed: int = 0
	for inst_v: Variant in _gs.monsters.get(loc, []):
		var inst: Dictionary = inst_v if inst_v is Dictionary else {"id": String(inst_v)}
		var m: Dictionary = MonsterCatalog.by_id(String(inst.get("id", "")))
		@warning_ignore("unsafe_method_access")
		var t: int = maxi(1, MonsterCatalog.toughness_for(m, balance_pc) if not m.is_empty() else 1)
		if t <= max_t:
			return_monster_to_bag(String(inst.get("id", "")))
			removed += 1
		else:
			kept.append(inst)
	if kept.is_empty():
		_gs.monsters.erase(loc)
	else:
		_gs.monsters[loc] = kept
	if removed > 0:
		GameConsole.log(
			(
				"[Монстр] %s ×%d (стойкость ≤ %d) на %s"
				% ["побеждён" if defeated else "сброшен", removed, max_t, loc]
			)
		)


## Нанести amount урона первому монстру на локации активного игрока; гибель → снять.
func damage_monster_at_active(amount: int) -> void:
	if not _gs._is_host() or amount <= 0:
		return
	var loc: String = _active_loc()
	var arr: Array = _gs.monsters.get(loc, [])
	if (arr as Array).is_empty():
		return
	var inst_v: Variant = arr[0]
	var inst: Dictionary = inst_v if inst_v is Dictionary else {"id": String(inst_v), "health": 1}
	# Урон заклинаний — МАГИЧЕСКИЙ: монстр с magical-резистом получает вдвое меньше.
	var m: Dictionary = MonsterCatalog.by_id(String(inst.get("id", "")))
	var dealt: int = MonsterCatalog.apply_resistance(m, amount, "magical")
	if dealt <= 0:
		GameConsole.log("[Монстр] сопротивление магии — урон поглощён на %s" % loc)
		return
	var hp: int = int(inst.get("health", 1)) - dealt
	if hp <= 0:
		remove_monster_at_active(true, 1)
	else:
		inst["health"] = hp
		arr[0] = inst
		_gs.monsters[loc] = arr
		GameConsole.log("[Монстр] −%d урона (осталось %d) на %s" % [dealt, hp, loc])


## Снять врата: на локации активного игрока, иначе случайные открытые.
func discard_gate() -> void:
	if not _gs._is_host() or _gs.gates.is_empty():
		return
	var loc: String = _active_loc()
	if not _gs.gates.has(loc):
		loc = String((_gs.gates.keys() as Array)[randi() % _gs.gates.size()])
	_gs.gates.erase(loc)
	GameConsole.log("[Врата] сброшены на %s" % loc)


## Монстр из мифа: спаун на случайных открытых вратах; если врат нет — открыть.
func spawn_monster_from_gate() -> void:
	if not _gs._is_host():
		return
	if _gs.gates.is_empty():
		open_gate()
		return
	var keys: Array = _gs.gates.keys()
	_spawn_monster(String(keys[randi() % keys.size()]))


## Положить улику на случайную локацию без улики (≤1 улика на локацию).
func place_clue() -> void:
	if not _gs._is_host():
		return
	var candidates: Array = []
	var locations: Array = _gs._load_locations()
	for i: int in range(locations.size()):
		var lid: String = String(locations[i].get("id", ""))
		if lid.is_empty():
			continue
		var arr: Array = _gs.entities.get(lid, [])
		if not (arr as Array).has("clue"):
			candidates.append(lid)
	if candidates.is_empty():
		return
	var pick: String = String(candidates[randi() % candidates.size()])
	var cell: Array = _gs.entities.get(pick, [])
	cell.append("clue")
	_gs.entities[pick] = cell
	GameConsole.log("[Улика] на %s" % pick)


## Положить жетон Знамения (Eldritch) на случайную локацию без такого жетона
## (≤1 на локацию — иначе их не отличить визуально и нечего «снимать» встречей).
func place_eldritch_token() -> void:
	if not _gs._is_host():
		return
	var candidates: Array = []
	var locations: Array = _gs._load_locations()
	for i: int in range(locations.size()):
		var lid: String = String(locations[i].get("id", ""))
		if lid.is_empty():
			continue
		var arr: Array = _gs.entities.get(lid, [])
		if not (arr as Array).has("eldritch_token"):
			candidates.append(lid)
	if candidates.is_empty():
		return
	var pick: String = String(candidates[randi() % candidates.size()])
	var cell: Array = _gs.entities.get(pick, [])
	cell.append("eldritch_token")
	_gs.entities[pick] = cell
	GameConsole.log("[Знамение] жетон на %s" % pick)


## Положить слух на случайную локацию.
func place_rumor() -> void:
	if not _gs._is_host():
		return
	var locations: Array = _gs._load_locations()
	if locations.is_empty():
		return
	var lid: String = String(locations[randi() % locations.size()].get("id", ""))
	if lid.is_empty():
		return
	var cell: Array = _gs.entities.get(lid, [])
	cell.append("rumor")
	_gs.entities[lid] = cell
	GameConsole.log("[Слух] на %s" % lid)


## Наплыв монстров: из каждых врат цвета текущего омена лезет monster_surge
## монстров; если таких врат нет — открываются одни новые врата (= 1 монстр).
func monster_surge() -> void:
	if not _gs._is_host():
		return
	var color: String = current_omen_color()
	var matched: Array = []
	for lid_v: Variant in _gs.gates:
		if String(_gs.gates[lid_v]) == color:
			matched.append(String(lid_v))
	if matched.is_empty():
		GameConsole.log("[Наплыв] нет врат цвета %s — открываются новые" % color)
		open_gate()
		return
	for i: int in range(matched.size()):
		for _j: int in _gs.monster_surge:
			_spawn_monster(matched[i])
	GameConsole.log(
		"[Наплыв] из %d врат (%s) по %d монстров" % [matched.size(), color, _gs.monster_surge]
	)
