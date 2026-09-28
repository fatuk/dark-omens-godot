class_name BoardState
extends RefCounted

## Подсистема доски (хост-only). Вынесена из GameState:
##   • трек омена (общий для всех Древних) и дум от сдвига омена;
##   • врата (открытие/закрытие/сброс) и их цвета;
##   • монстры (спаун из «мешка», урон, снятие, возврат) и Наплыв;
##   • улики / жетоны Знамения / слухи на локациях;
##   • стартовая раскладка кампании (Icon Reference).
##
##   • board-verbs эффектов (apply_verb): advanceDoom, openGate, spawnMonster, …
##
## Синкаемый стейт (gates/entities/monsters/monster_bag/monster_surge/doom/
## omens_step) ОСТАЁТСЯ полями GameState — модуль мутирует его через _gs. Доступ к
## стейту/услугам — через _gs: _gs.is_host(), _gs.map,
## _gs.current_pid(), _gs.players, _gs._campaign, _gs._fill_shop_reserve(),
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
		_gs._mystery.check_defeat()  # дум от омена тоже проверяет поражение + кламп
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


## Число из «карточки баланса» (REFERENCE) для текущего РАЗМЕРА партии по полю
## ("clues"|"gates"|"surge"). Эффекты со scale:"balance" берут счётчик отсюда, чтобы
## раскладка масштабировалась по числу игроков — как стартовый setup_board.
func reference_amount(field: String) -> int:
	return int(_reference_for(_gs._campaign.balance_player_count()).get(field, 1))


## Хост: начальная раскладка поля. Открыть врата (каждые → 1 монстр), разложить
## улики (≤1 на локацию), записать Наплыв. Зовётся из start_game до broadcast_sync.
func setup_board(player_count: int) -> void:
	if not _gs.is_host():
		return
	_gs.gates = {}
	_gs.entities = {}
	_gs.monsters = {}
	_gs._fill_shop_reserve()  # стартовая витрина магазина
	# Наполняем «мешок» не-эпическими монстрами доступных столу сезонов (по id).
	_gs.monster_bag = []
	var pool: Array = SeasonGate.filter_room(MonsterCatalog.non_epic())
	for i: int in range(pool.size()):
		_gs.monster_bag.append(String(pool[i].get("id", "")))
	_reset_gate_deck()
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
## Открыть врата. Возвращает локацию, где врата открылись ("" — не удалось: не хост
## либо нет свободной гейт-локации). Возврат нужен RumorFlow (привязка портала Слуха).
func open_gate(loc_id: String = "", color: String = "") -> String:
	if not _gs.is_host():
		return ""
	var lid: String = loc_id
	if lid.is_empty():
		lid = _draw_gate()
		if lid.is_empty():
			# Ни в колоде, ни в сбросе — выкладывать нечего. Каждые невыложенные
			# врата продвигают трек Рока: давление никуда не девается.
			_gs.doom += 1
			GameConsole.warn("[Врата] жетоны кончились — Рок +1")
			_gs._mystery.check_defeat()
			return ""
	else:
		_gate_deck_take(lid)  # адресная выкладка (Слух и пр.) тоже тратит жетон
	# Цвет привязан к локации (каноничный цвет спейса EH); явный аргумент имеет
	# приоритет. Фолбэк (локация без gateColor) — зелёный.
	var col: String = color
	if col.is_empty():
		col = _gate_color_for(lid)
	_gs.gates[lid] = col
	GameConsole.log("[Врата] открылись (%s) на %s" % [col, lid])
	_spawn_monster(lid)  # каждые новые врата → 1 монстр
	return lid


# ── Колода врат ───────────────────────────────────────────────────────────────


# Наполнить колоду всеми гейт-локациями (жетон врат = гейт-спейс) и перетасовать.
func _reset_gate_deck() -> void:
	_gs.gate_deck = []
	_gs.gate_discard = []
	for did: String in _gs.map.ids():
		if not _gs.map.gate_color(did).is_empty():
			_gs.gate_deck.append(did)
	(_gs.gate_deck as Array).shuffle()


# Вытянуть жетон врат. Колода пуста → замешиваем сброс. Пусты обе → "" (вызывающий
# продвигает Рок).
func _draw_gate() -> String:
	if (_gs.gate_deck as Array).is_empty():
		if (_gs.gate_discard as Array).is_empty():
			return ""
		_gs.gate_deck = (_gs.gate_discard as Array).duplicate()
		_gs.gate_discard = []
		(_gs.gate_deck as Array).shuffle()
		GameConsole.log("[Врата] колода замешана из сброса: %d" % (_gs.gate_deck as Array).size())
	return String((_gs.gate_deck as Array).pop_back())


# Убрать конкретный жетон из колоды/сброса (адресная выкладка врат).
func _gate_deck_take(loc_id: String) -> void:
	(_gs.gate_deck as Array).erase(loc_id)
	(_gs.gate_discard as Array).erase(loc_id)


# Врата ушли с поля → жетон в сброс (инвариант «ровно в одном месте»).
func _gate_to_discard(loc_id: String) -> void:
	if loc_id.is_empty() or (_gs.gate_discard as Array).has(loc_id):
		return
	(_gs.gate_discard as Array).append(loc_id)


## Каноничный цвет врат локации (из data/locations.json → gateColor). Локация
## без поля (не гейт-спейс) → "green" как безопасный фолбэк.
func _gate_color_for(loc_id: String) -> String:
	var c: String = _gs.map.gate_color(loc_id)
	return c if not c.is_empty() else "green"


## Закрыть врата на локации активного игрока (эффект closeGate финальной стадии
## gate-встречи). Врата привязаны к месту, где сыщик прошёл Иной мир.
func close_gate_at_active_player() -> void:
	var pid: String = _gs.current_pid()
	if pid.is_empty():
		return
	close_gate_at(String(_gs.players.get(pid, {}).get("location", "")), pid)


## Закрыть врата на локации loc от имени сыщика pid (хуки Тайны/Слуха — по нему).
## Отдельно от «у активного сыщика»: встреча за вратами может сначала переместить
## сыщика (move), а закрыть надо врата, ИЗ которых он пришёл.
func close_gate_at(loc: String, pid: String) -> void:
	if not _gs.is_host():
		return
	if _gs.gates.has(loc):
		var color: String = String(_gs.gates[loc])
		_gs.gates.erase(loc)
		_gate_to_discard(loc)
		GameConsole.log("[Врата] закрыты на %s" % loc)
		# Триггер Тайны: закрытие врат (напр. «врата цвета омена → −1 улика → жетон»)
		_gs._mystery.try_mystery_hook("gateClosed", {"loc": loc, "color": color}, pid)
		# Слух: закрытие врат-портала на этой локации развеивает Слух (если он там).
		_gs._rumor.solve_on_gate_close(loc, pid)


## Заспаунить монстра на локации, ВЫТЯНУВ случайный id из «мешка» (без повторов).
## Экземпляр хранит здоровье ({id, health}); смерть вернёт id в мешок. Мешок
## пуст → спауна нет (как пустой котёл монстров в EH).
func _spawn_monster(loc_id: String) -> void:
	if not _gs.is_host() or loc_id.is_empty():
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


## Заспаунить монстра на КОНКРЕТНОЙ локации (публичная обёртка над _spawn_monster).
## Для Слуха с solve=monsterDefeated — монстр-цель, чья гибель развеет Слух.
func spawn_monster_at(loc_id: String) -> void:
	_spawn_monster(loc_id)


## Вернуть монстра в «мешок» (после гибели/снятия с поля). Культист всегда в
## мешке (его не вынимали) — не дублируем.
func return_monster_to_bag(mid: String) -> void:
	if not _gs.is_host() or mid.is_empty() or mid == "cultist":
		return
	_gs.monster_bag.append(mid)


## Список монстров на поле для интерактивного выбора (chosenMonster): [{ref:"loc#idx",
## name:<ключ перевода имени>, toughness:<с учётом размера партии>, health:<текущее>,
## loc:<id локации>, loc_name:<ключ перевода локации>}]. ref — локация и индекс
## экземпляра; модалка переведёт name/loc_name, движок найдёт монстра по ref.
##
## Локация в опции обязательна: карты-услуги бьют «монстра в ЛЮБОЙ локации», и без
## неё игрок выбирает вслепую.
func monster_choices() -> Array:
	var out: Array = []
	var pc: int = _gs._campaign.balance_player_count()
	for loc_v: Variant in (_gs.monsters as Dictionary).keys():
		var loc: String = String(loc_v)
		var arr: Array = _gs.monsters[loc]
		for i in range(arr.size()):
			var inst: Variant = arr[i]
			var mid: String = String(inst.get("id", "")) if inst is Dictionary else String(inst)
			var m: Dictionary = MonsterCatalog.by_id(mid)
			if m.is_empty():
				continue
			var tough: int = maxi(1, MonsterCatalog.toughness_for(m, pc))
			(
				out
				. append(
					{
						"ref": "%s#%d" % [loc, i],
						"name": String(m.get("nameKey", mid)),
						"epic": bool(m.get("epic", false)),
						"toughness": tough,
						"health": int(inst.get("health", tough)) if inst is Dictionary else tough,
						"loc": loc,
						"loc_name": _gs.map.name_key(loc),
					}
				)
			)
	return out


## Локации, где ЕСТЬ монстры, — для выбора площадью (chosenSpace: «выберите локацию,
## каждый монстр там теряет N здоровья»). [{ref:<loc id>, name:<ключ перевода>, count:N}].
## Пустые локации не предлагаем: бить по ним нечего.
func space_choices() -> Array:
	var out: Array = []
	for loc_v: Variant in (_gs.monsters as Dictionary).keys():
		var loc: String = String(loc_v)
		var n: int = (_gs.monsters[loc] as Array).size()
		if n > 0:
			out.append({"ref": loc, "name": _gs.map.name_key(loc), "count": n})
	return out


## Снять КОНКРЕТНЫЙ экземпляр монстра по ref "loc#idx" (выбранный игроком, chosenMonster).
## id возвращается в мешок. Зовётся board-verb'ом discardMonster с _target_monster.
func discard_monster_ref(ref: String) -> void:
	if not _gs.is_host():
		return
	var parts: PackedStringArray = ref.split("#")
	if parts.size() != 2:
		return
	var loc: String = parts[0]
	var idx: int = int(parts[1])
	var arr: Array = _gs.monsters.get(loc, [])
	if idx < 0 or idx >= (arr as Array).size():
		return
	var inst: Variant = arr[idx]
	var mid: String = String(inst.get("id", "")) if inst is Dictionary else String(inst)
	arr.remove_at(idx)
	if (arr as Array).is_empty():
		_gs.monsters.erase(loc)
	else:
		_gs.monsters[loc] = arr
	return_monster_to_bag(mid)
	GameConsole.log("[Монстр] сброшен %s (%s)" % [mid, loc])


## Переставить КОНКРЕТНЫЙ экземпляр монстра (ref "loc#idx") в локацию dest. Здоровье и
## прочее состояние экземпляра сохраняются. Зовётся board-verb'ом moveMonster.
func move_monster_ref(ref: String, dest: String) -> void:
	if not _gs.is_host() or dest.is_empty():
		return
	var parts: PackedStringArray = ref.split("#")
	if parts.size() != 2:
		return
	var loc: String = parts[0]
	var idx: int = int(parts[1])
	var arr: Array = _gs.monsters.get(loc, [])
	if idx < 0 or idx >= (arr as Array).size() or loc == dest:
		return
	var inst: Variant = arr[idx]
	arr.remove_at(idx)
	if (arr as Array).is_empty():
		_gs.monsters.erase(loc)
	else:
		_gs.monsters[loc] = arr
	var dst: Array = _gs.monsters.get(dest, [])
	dst.append(inst)
	_gs.monsters[dest] = dst
	var mid: String = String(inst.get("id", "")) if inst is Dictionary else String(inst)
	GameConsole.log("[Монстр] %s перемещён %s → %s" % [mid, loc, dest])


## Локация активного игрока ("" — нет активного). Для board-verb'ов, бьющих «здесь».
func _active_loc() -> String:
	var pid: String = _gs.current_pid()
	if pid.is_empty() or not _gs.players.has(pid):
		return ""
	return String(_gs.players[pid].get("location", ""))


## Снять до n монстров с локации активного игрока (id → в мешок). defeated — для лога.
func remove_monster_at_active(defeated: bool, n: int) -> void:
	if not _gs.is_host():
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
	if not _gs.is_host() or max_t < 1:
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


## То же, но по ВСЕМУ полю (цель eachMonster): «сбросьте всех монстров со
## стойкостью 1 с игрового поля». Отдельно от версии «на моей клетке» —
## у карточек это две разные механики, и путать область нельзя.
func remove_monsters_by_toughness_everywhere(defeated: bool, max_t: int) -> void:
	if not _gs.is_host() or max_t < 1:
		return
	var balance_pc: int = _gs._campaign.balance_player_count()
	var removed: int = 0
	for loc_v: Variant in (_gs.monsters as Dictionary).keys():
		var loc: String = String(loc_v)
		var kept: Array = []
		for inst_v: Variant in _gs.monsters[loc]:
			var inst: Dictionary = inst_v if inst_v is Dictionary else {"id": String(inst_v)}
			var m: Dictionary = MonsterCatalog.by_id(String(inst.get("id", "")))
			@warning_ignore("unsafe_method_access")
			var t: int = maxi(
				1, MonsterCatalog.toughness_for(m, balance_pc) if not m.is_empty() else 1
			)
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
				"[Монстр] %s ×%d (стойкость ≤ %d) со всего поля"
				% ["побеждён" if defeated else "сброшен", removed, max_t]
			)
		)


## Нанести amount урона первому монстру на локации активного игрока; гибель → снять.
func damage_monster_at_active(amount: int) -> void:
	if not _gs.is_host() or amount <= 0:
		return
	_damage_at(_active_loc(), 0, amount)


## Нанести урон КАЖДОМУ монстру на локации активного игрока (Dynamite: «каждый
## монстр на вашей локации теряет 3 здоровья»).
func damage_monsters_at_active(amount: int) -> void:
	if not _gs.is_host():
		return
	damage_monsters_at(_active_loc(), amount)


## Нанести урон КОНКРЕТНОМУ монстру по ref "loc#idx" — выбранному игроком
## (damageMonster target:chosenMonster: Assassination, Monster Hunter, Enchanted Bow).
func damage_monster_ref(ref: String, amount: int) -> void:
	if not _gs.is_host() or amount <= 0:
		return
	var parts: PackedStringArray = ref.split("#")
	if parts.size() != 2:
		return
	_damage_at(parts[0], int(parts[1]), amount)


## Нанести урон КАЖДОМУ монстру выбранной локации (damageMonster target:chosenSpace:
## Agency Quarantine, Police Raid). Идём с конца — павшие удаляются по индексу.
func damage_monsters_at(loc: String, amount: int) -> void:
	if not _gs.is_host() or amount <= 0 or loc.is_empty():
		return
	var n: int = (_gs.monsters.get(loc, []) as Array).size()
	for i in range(n - 1, -1, -1):
		_damage_at(loc, i, amount)


# Урон одному экземпляру монстра (loc + индекс). Гибель → id возвращается в мешок.
# Урон эффектов — МАГИЧЕСКИЙ: монстр с magical-резистом получает вдвое меньше.
func _damage_at(loc: String, idx: int, amount: int) -> void:
	if loc.is_empty():
		return
	var arr: Array = _gs.monsters.get(loc, [])
	if idx < 0 or idx >= (arr as Array).size():
		return
	var inst_v: Variant = arr[idx]
	var inst: Dictionary = inst_v if inst_v is Dictionary else {"id": String(inst_v), "health": 1}
	var mid: String = String(inst.get("id", ""))
	var m: Dictionary = MonsterCatalog.by_id(mid)
	var dealt: int = MonsterCatalog.apply_resistance(m, amount, "magical")
	if dealt <= 0:
		GameConsole.log("[Монстр] сопротивление магии — урон поглощён на %s" % loc)
		return
	var hp: int = int(inst.get("health", 1)) - dealt
	if hp > 0:
		inst["health"] = hp
		arr[idx] = inst
		_gs.monsters[loc] = arr
		GameConsole.log("[Монстр] %s −%d урона (осталось %d) на %s" % [mid, dealt, hp, loc])
		return
	arr.remove_at(idx)
	if (arr as Array).is_empty():
		_gs.monsters.erase(loc)
	else:
		_gs.monsters[loc] = arr
	return_monster_to_bag(mid)
	GameConsole.log("[Монстр] %s побеждён уроном на %s" % [mid, loc])


## Снять врата: на локации активного игрока, иначе случайные открытые.
func discard_gate() -> void:
	if not _gs.is_host() or _gs.gates.is_empty():
		return
	var loc: String = _active_loc()
	if not _gs.gates.has(loc):
		loc = String((_gs.gates.keys() as Array)[randi() % _gs.gates.size()])
	_gs.gates.erase(loc)
	_gate_to_discard(loc)
	GameConsole.log("[Врата] сброшены на %s" % loc)


## Монстр из мифа: спаун на случайных открытых вратах; если врат нет — открыть.
func spawn_monster_from_gate() -> void:
	if not _gs.is_host():
		return
	if _gs.gates.is_empty():
		open_gate()
		return
	var keys: Array = _gs.gates.keys()
	_spawn_monster(String(keys[randi() % keys.size()]))


## Положить улику на случайную локацию без улики (≤1 улика на локацию).
func place_clue() -> void:
	if not _gs.is_host():
		return
	# Жетон улики привязан к своей локации (ключ = локация), поэтому выложить можно
	# только туда, чей ключ ЕЩЁ В КОЛОДЕ. Колода пуста — замешиваем сброс; пусты обе
	# — жетоны кончились, выкладывать нечего.
	if not _gs._clue_draw_ready():
		GameConsole.warn("[Улика] жетоны кончились — выкладывать нечего")
		return
	var candidates: Array = []
	for lid: String in _gs.map.ids():
		if not (_gs.clue_deck as Array).has(lid):
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
	_gs._claim_board_clue(pick)  # приклеить идентичность улики этой локации (если заведена)
	GameConsole.log("[Улика] на %s" % pick)


## Положить жетон Знамения (Eldritch) на случайную локацию без такого жетона
## (≤1 на локацию — иначе их не отличить визуально и нечего «снимать» встречей).
func place_eldritch_token() -> void:
	if not _gs.is_host():
		return
	var candidates: Array = []
	for lid: String in _gs.map.ids():
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


## Положить до n жетонов Знамения на ПОМЕЧЕННЫЕ локации активной Тайны
## (mystery.locations), по одному на локацию без жетона. Так метка Тайны и жетон
## совпадают на клетке — единый повод для встречи (encounterAtEldritchToken).
## Зовётся из placeEldritchToken с where:"marked" (обычно из onEnter Тайны).
func place_eldritch_token_on_marked(n: int) -> void:
	if not _gs.is_host():
		return
	var locs: Array = _gs._campaign.current_mystery().get("locations", [])
	var placed: int = 0
	for i: int in range(locs.size()):
		if placed >= n:
			break
		var lid: String = String(locs[i])
		if lid.is_empty():
			continue
		var arr: Array = _gs.entities.get(lid, [])
		if not (arr as Array).has("eldritch_token"):
			arr.append("eldritch_token")
			_gs.entities[lid] = arr
			placed += 1
	if placed > 0:
		GameConsole.log("[Знамение] %d жетон(ов) на помеченные локации Тайны" % placed)


## Положить жетон Знамения на КОНКРЕТНУЮ локацию по id (≤1 на клетку). Нет id /
## уже есть жетон — no-op. Зовётся из placeEldritchToken с where:"<locationId>".
func place_eldritch_token_at(loc_id: String) -> void:
	if not _gs.is_host() or loc_id.is_empty():
		return
	var arr: Array = _gs.entities.get(loc_id, [])
	if (arr as Array).has("eldritch_token"):
		return
	arr.append("eldritch_token")
	_gs.entities[loc_id] = arr
	GameConsole.log("[Знамение] жетон на %s" % loc_id)


## Снять ВСЕ жетоны Знамения со всех локаций (синкаемое entities). Зовётся при
## разгадке Тайны: доска чистится целиком, следующая Тайна раскладывает свои через
## onEnter. Возвращает число снятых жетонов.
func clear_eldritch_tokens() -> int:
	if not _gs.is_host():
		return 0
	var removed: int = 0
	for lid: String in _gs.entities.keys():
		var arr: Array = _gs.entities[lid]
		if not (arr as Array).has("eldritch_token"):
			continue
		arr.erase("eldritch_token")
		removed += 1
		if (arr as Array).is_empty():
			_gs.entities.erase(lid)
		else:
			_gs.entities[lid] = arr
	if removed > 0:
		GameConsole.log("[Знамение] снято со стола при разгадке: %d жетон(ов)" % removed)
	return removed


## Снять ВСЕ улики с поля (синкаемое entities). Возвращает число снятых. Для эффектов
## Слухов вроде «сбросить все улики на поле» (Lost Knowledge).
func discard_all_clues() -> int:
	if not _gs.is_host():
		return 0
	var removed: int = 0
	for lid: String in _gs.entities.keys():
		var arr: Array = _gs.entities[lid]
		while (arr as Array).has("clue"):
			arr.erase("clue")
			removed += 1
		if (arr as Array).is_empty():
			_gs.entities.erase(lid)
		else:
			_gs.entities[lid] = arr
	if removed > 0:
		GameConsole.log("[Эффект] сброшены все улики с поля: %d" % removed)
	return removed


## Снять ОДНУ улику с ближайшей к from_loc клетки (BFS по дорогам, свою клетку
## считаем расстоянием 0; при равном расстоянии — первая в порядке обхода).
## Возвращает id клетки, "" — улик на поле нет / from_loc не в графе. Verb
## discardBoardClue («сбросьте ближайшую улику на игровом поле», Студент-
## исследователь). Ключ улики уйдёт в сброс через _reconcile_board_clue_ids.
func discard_nearest_clue(from_loc: String) -> String:
	if not _gs.is_host() or from_loc.is_empty():
		return ""
	var queue: Array = [from_loc]
	var seen: Dictionary = {from_loc: true}
	while not queue.is_empty():
		var loc: String = String(queue.pop_front())
		var arr: Array = _gs.entities.get(loc, [])
		if (arr as Array).has("clue"):
			arr.erase("clue")
			if (arr as Array).is_empty():
				_gs.entities.erase(loc)
			else:
				_gs.entities[loc] = arr
			GameConsole.log("[Эффект] сброшена ближайшая улика: %s" % loc)
			return loc
		for nb: Variant in _gs.map.neighbors(loc):
			if not seen.has(nb):
				seen[nb] = true
				queue.append(nb)
	return ""


## Закрыть/убрать ВСЕ открытые врата (синкаемое gates). Возвращает число убранных. Для
## эффектов Слухов вроде «сбросить все врата» (Devourer of Stars, The White Ship).
func discard_all_gates() -> int:
	if not _gs.is_host():
		return 0
	var removed: int = (_gs.gates as Dictionary).size()
	for loc_v: Variant in (_gs.gates as Dictionary).keys():
		_gate_to_discard(String(loc_v))
	_gs.gates = {}
	if removed > 0:
		GameConsole.log("[Эффект] убраны все врата: %d" % removed)
	return removed


## Положить метку слуха на КОНКРЕТНУЮ локацию (для Слуха с solve=encounter — куда идти
## развеивать). Идемпотентно. Отдельная иконка "rumor" (не путать с eldritch_token Тайны).
func place_rumor_at(loc_id: String) -> void:
	if not _gs.is_host() or loc_id.is_empty():
		return
	var arr: Array = _gs.entities.get(loc_id, [])
	if not (arr as Array).has("rumor"):
		arr.append("rumor")
		_gs.entities[loc_id] = arr


## Снять метку слуха с локации (после развеивания encounter-Слуха).
func remove_rumor_at(loc_id: String) -> void:
	if not _gs.is_host() or loc_id.is_empty():
		return
	var arr: Array = _gs.entities.get(loc_id, [])
	if (arr as Array).has("rumor"):
		arr.erase("rumor")
		if (arr as Array).is_empty():
			_gs.entities.erase(loc_id)
		else:
			_gs.entities[loc_id] = arr


## Положить слух на случайную локацию.
func place_rumor() -> void:
	if not _gs.is_host():
		return
	var lid: String = _gs.map.random_id()
	if lid.is_empty():
		return
	var cell: Array = _gs.entities.get(lid, [])
	cell.append("rumor")
	_gs.entities[lid] = cell
	GameConsole.log("[Слух] на %s" % lid)


## Наплыв монстров: из каждых врат цвета текущего омена лезет monster_surge
## монстров; если таких врат нет — открываются одни новые врата (= 1 монстр).
func monster_surge() -> void:
	if not _gs.is_host():
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


# ── Board-verbs эффектов (advanceDoom, openGate, spawnMonster, …) ─────────────


# Число повторов verb'а. scale:"balance" → счётчик из карточки баланса (REFERENCE по
# размеру партии): placeClue→clues, openGate→gates. Иначе — литерал count/amount.
func _resolve_count(node: Dictionary, verb: String) -> int:
	if String(node.get("scale", "")) == "balance":
		# NB: dict-литерал в локальную переменную — иначе GDScript парсит
		# String({…}.get(…)) как String({…}) и падает на конструкторе.
		var field_of := {"placeClue": "clues", "openGate": "gates"}
		var field: String = field_of.get(verb, "")
		if not field.is_empty():
			return maxi(0, reference_amount(field))
	return int(node.get("amount", node.get("count", 1)))


# Выдать артефакт сыщику. Пустой id — случайный из доступных, `want_trait` сужает
## («Получите 1 Книгу-артефакт»).
##
## Артефакт УНИКАЛЕН: копия одна на партию. Поэтому исключаем занятые по ВСЕМУ
## столу, а не только по рукам получателя, — иначе двое сыщиков носили бы один
## «Некрономикон». Свободных не осталось → тихо ничего, как у пустой колоды.


# Порог стойкости для целей по всему полю: "testResult" — число успехов проверки,
# число — оно само, поля нет — берём всех (999).
func _max_toughness(node: Dictionary) -> int:
	var raw: Variant = node.get("maxToughness", null)
	if raw == null:
		return 999
	if String(raw) == "testResult":
		return int(node.get("_successes", 0))
	return int(raw)


# Один проход board-verb'а (без учёта _times — его разворачивает apply_board_effect).
func apply_verb(node: Dictionary, verb: String) -> void:
	var n: int = _resolve_count(node, verb)
	match verb:
		"advanceDoom":
			_gs.doom += n
			GameConsole.log("[Эффект] doom +%d" % n)
			_gs._mystery.check_defeat()
		"advanceOmen", "moveOmen":
			# На каждый шаг омена: сдвигаем, затем СРАЗУ считаем дум по вратам
			# нового цвета омена — ДО того как карта откроет новые врата, чтобы
			# только что открытые врата не влияли на дум этого сдвига.
			for _i: int in maxi(1, n):
				_gs.omens_step += 1
				resolve_omen_doom()
			GameConsole.log("[Эффект] омен +%d" % maxi(1, n))
		"openGate":
			# where: "self" — врата в локации активного/якорного сыщика (встреча/forEach);
			# "<locId>" — в конкретной локации; пусто — движок сам берёт гейт-спейс (как было).
			var gate_where: String = String(node.get("where", ""))
			var gate_loc: String = ""
			if gate_where == "self":
				var apid: String = String(node.get("_anchor_pid", _gs.current_pid()))
				gate_loc = String((_gs.players.get(apid, {}) as Dictionary).get("location", ""))
			elif not gate_where.is_empty():
				gate_loc = gate_where
			for _i: int in n:
				open_gate(gate_loc)
		"closeGate":
			# _origin_loc — где сыщик стоял до эффектов ветки: если та же ветка его
			# переместила (move), закрываются врата исходной клетки, а не новой.
			if node.has("_origin_loc"):
				close_gate_at(
					String(node["_origin_loc"]), String(node.get("_anchor_pid", _gs.current_pid()))
				)
			else:
				close_gate_at_active_player()
		"spawnMonster":
			# where: "self" — монстр в локации активного/якорного сыщика (встреча «появляется
			# монстр»); "<locId>" — в конкретной; пусто — из случайных врат (как было).
			var mon_where: String = String(node.get("where", ""))
			var mon_loc: String = ""
			if mon_where == "self":
				var apid: String = String(node.get("_anchor_pid", _gs.current_pid()))
				mon_loc = String((_gs.players.get(apid, {}) as Dictionary).get("location", ""))
			elif not mon_where.is_empty():
				mon_loc = mon_where
			for _i: int in n:
				if mon_where.is_empty():
					spawn_monster_from_gate()
				elif not mon_loc.is_empty():
					spawn_monster_at(mon_loc)
		"placeClue":
			for _i: int in n:
				place_clue()
		"placeRumor":
			for _i: int in n:
				place_rumor()
		"placeEldritchToken":
			# Единый жетон поля Знамения.
			#   where=="self"   → жетон(ы) на карту активной Тайны (счётчик решения);
			#   where=="marked" → на помеченные локации Тайны (метка и жетон совпадают);
			#   where==""       → N жетонов на случайные поля (как у Мифов);
			#   where=="<id>"   → на конкретную локацию по id (data/locations.json).
			match String(node.get("where", "")):
				"self":
					_gs.mystery_tokens_on_card += n
					GameConsole.log(
						"[Тайна] жетонов на карте Тайны: %d" % _gs.mystery_tokens_on_card
					)
				"marked":
					place_eldritch_token_on_marked(n)
				"":
					for _i: int in n:
						place_eldritch_token()
				var loc_id:
					place_eldritch_token_at(loc_id)
		"monsterSurge":
			monster_surge()
		"mysteryProgress":
			# Зачёт текущей локации активного игрока в активную Тайну. Выдаётся
			# только из mystery-встреч (см. relay encounter-tables). За пределами
			# фазы encounter — тихо игнорируем.
			if _gs.phase != Phases.ENCOUNTER:
				GameConsole.log("[Эффект] mysteryProgress вне фазы encounter — игнор")
			else:
				_gs._mystery.apply_mystery_progress()
		"retreatDoom":
			_gs.doom = maxi(0, _gs.doom - n)
			GameConsole.log("[Эффект] doom −%d (откат) → %d" % [n, _gs.doom])
		"setDoom":
			_gs.doom = maxi(0, int(node.get("amount", node.get("count", 0))))
			GameConsole.log("[Эффект] doom = %d" % _gs.doom)
			_gs._mystery.check_defeat()
		"loseGame":
			# Партия проигрывает (эффект Слуха «investigators lose the game»).
			if _gs.outcome.is_empty():
				_gs.outcome = "defeat"
				GameConsole.log("[Финал] поражение партии (эффект)")
		"discardAllClues":
			discard_all_clues()
		"discardBoardClue":  # ближайшая к действующему сыщику улика на поле
			var apid: String = String(node.get("_anchor_pid", _gs.current_pid()))
			var lost: String = discard_nearest_clue(
				String(_gs.players.get(apid, {}).get("location", ""))
			)
			if not lost.is_empty():
				var ev := {"id": "board_clue_lost", "params": {"place": _gs.map.name_key(lost)}}
				_gs.announce_action(apid, ev["id"], ev["params"])
				# Исход — и в узел: прогон актива соберёт его в окно результата.
				var evs: Array = node.get("_events", [])
				evs.append(ev)
				node["_events"] = evs
		"discardAllGates":
			discard_all_gates()
		"discardGate":
			discard_gate()
		"moveMonster":
			# Выбранный монстр → к якорному сыщику (where:self; бой — на следующей фазе
			# встреч, как с любым монстром на клетке) либо в выбранную клетку (_target_space).
			if node.has("_target_monster"):
				var dest: String = String(node.get("_target_space", ""))
				if dest.is_empty():
					var apid: String = String(node.get("_anchor_pid", _gs.current_pid()))
					dest = String((_gs.players.get(apid, {}) as Dictionary).get("location", ""))
				move_monster_ref(String(node.get("_target_monster", "")), dest)
		"discardMonster":
			if node.has("_target_monster"):
				discard_monster_ref(String(node.get("_target_monster", "")))  # выбранный
			elif String(node.get("target", "")) == "eachMonster":
				remove_monsters_by_toughness_everywhere(false, _max_toughness(node))
			elif String(node.get("maxToughness", "")) == "testResult":
				remove_monsters_by_toughness(false, int(node.get("_successes", 0)))
			else:
				remove_monster_at_active(false, n)  # снять без боя
		"defeatMonster":
			if String(node.get("target", "")) == "eachMonster":
				remove_monsters_by_toughness_everywhere(true, _max_toughness(node))
			elif String(node.get("maxToughness", "")) == "testResult":
				remove_monsters_by_toughness(true, int(node.get("_successes", 0)))
			else:
				remove_monster_at_active(true, n)  # победить (вернуть id в мешок)
		"damageMonster":
			# Цель разрешает интерпретатор: _target_monster — выбранный игроком монстр
			# (chosenMonster), _target_space — выбранная локация (chosenSpace, бьём всех
			# там). Без выбора: eachMonsterOnSpace — все на локации активного игрока,
			# иначе первый монстр под ногами (легаси-цель заклинаний).
			if node.has("_target_monster"):
				damage_monster_ref(String(node.get("_target_monster", "")), n)
			elif node.has("_target_space"):
				damage_monsters_at(String(node.get("_target_space", "")), n)
			elif String(node.get("target", "")) == "eachMonsterOnSpace":
				damage_monsters_at_active(n)
			else:
				damage_monster_at_active(n)
		"resolveReckoning":
			_gs._cond.host_resolve_reckoning()
		"gainSpell":
			# Заклинание тянет ТОТ сыщик, от которого идёт эффект (_anchor_pid ставит
			# forEach-подпрограмма мифа), иначе — активный игрок хода. Раньше здесь
			# всегда стоял current_pid(): в фазе мифов это последний ходивший, и
			# карта уходила не тому, кто её выбрал.
			var spell_pid: String = String(node.get("_anchor_pid", ""))
			if spell_pid.is_empty() or not _gs.players.has(spell_pid):
				spell_pid = _gs.current_pid()
			# count — «возьмите 2 заклинания» (Некрономикон). Пустой spell — случайное
			# из доступного пула, это уже умеет grant_spell.
			for _s in range(maxi(1, n)):
				_gs._spell.grant_spell(spell_pid, String(node.get("spell", "")))
		"gainArtifact":
			# Как и заклинание, артефакт получает ЯКОРНЫЙ сыщик (тот, от которого
			# идёт эффект), а не «текущий по ходу»: в фазе Мифов это разные люди.
			var art_pid: String = String(node.get("_anchor_pid", ""))
			if art_pid.is_empty() or not _gs.players.has(art_pid):
				art_pid = _gs.current_pid()
			for _a in range(maxi(1, n)):
				_gs.grant_artifact(
					art_pid, String(node.get("artifact", "")), String(node.get("trait", ""))
				)
		_:
			GameConsole.log("[Эффект] %s — пока не поддержано движком" % verb)
