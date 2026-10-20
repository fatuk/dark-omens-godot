class_name SpellFlow
extends RefCounted

## Подсистема заклинаний (хост-only). Двусторонняя карта: каст (тест Lore) → фронт
## onPass (если pass) → flip к рубашке → резолв её tiers по ЧИСЛУ УСПЕХОВ → discard
## (если рубашка эмитит discardCard) либо назад на фронт (заклинание многоразовое,
## остаётся в руке).
##
## Колода — как в настолке: каждое заклинание лежит в стольких копиях, сколько у
## него оборотов, у каждой копии СВОЙ оборот. Карта на руке — конкретная копия
## {id, kind:"spell", back}: рубашка закреплена, пока карта у сыщика, и при каждом
## касте переворачивается та же. Сброшенная копия возвращается в оборот при
## замешивании (сброс выводится: все копии минус руки минус колода). Число копий
## заклинания = backs.size() в контенте — дописал оборот в CMS, получил карту.
## Сам бросок каста делает cast-flow (CheckFlow); сюда приходит результат
## (successes, dice).
##
## flow.backs[item_index] — форс рубашки (детерминизм/тесты/replay); карта без back
## (легаси-снапшот) — случайная рубашка. Доступ к стейту — через _gs: _gs.players,
## _gs.spell_deck, _gs.is_host(), _gs.name_of(), _gs.apply_board_effect().
## Создаётся в GameState (поле _spell).

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

# Глаголы фронта, решающие, КАК пройдёт встреча (фаза встреч): «как будто на клетке
# нет монстров» (Туманы Релеха), «встреча с уликой на её клетке» (Ясновидение).
const _ENCOUNTER_VERBS := ["ignoreMonsters", "remoteClueEncounter"]

# front.trigger реакций «когда сыщик должен потерять …» → какой стат они бережут.
const _REACTION_STATS := {"onHealthLoss": "health", "onSanityLoss": "sanity"}

var _gs: Node
# Каст, ждущий ответа игрока (задание _make_job); пусто — нет. Хост, не синкается:
# вопрос к игроку уходит синкаемым mythos_decision.
var _run: Dictionary = {}
# Касты в очереди за _run (промпт триггер-заклинаний выбрал несколько) и что
# сделать, когда очередь опустеет (отдых — передать ход, встреча — продолжить её).
var _queue: Array = []
var _then: Callable = Callable()


func _init(gs: Node) -> void:
	_gs = gs


## Хост: разрешить каст заклинания item_index по результату теста (successes/dice).
## passed = successes ≥ 1 → фронт.onPass. Затем рубашка ЭТОЙ копии (item.back) → её
## ярус по числу успехов → discardCard в эффектах → карта сброшена.
## flow.backs[i] форсит конкретную рубашку (детерминизм/тесты).
## flow.interactive — вопросы игроку («X, иначе сбросьте карту», навык на выбор, куда
## идти, какую вещь с витрины) модалкой решения: прогон встаёт на паузу и доигрывается
## в resolve_decision. Без interactive (тихие касты, тесты) — первая ветка, сразу.
## flow.after — что сделать по итогу (apply_cast: моды в боевую проверку, отпустить
## ход, реакция на потерю). true — каст принят (с interactive может ещё идти).
func resolve_cast(
	pid: String, item_index: int, successes: int, dice: Array, flow: Dictionary = {}
) -> bool:
	var job: Dictionary = _make_job(pid, item_index, successes, dice, flow)
	if job.is_empty():
		return false
	if not bool(job.get("interactive", false)):
		_step(job)  # без вопросов — до конца сразу
		return true
	_queue.append(job)
	_pump()
	return true


## Идёт ли каст, ждущий ответа игрока (или очередь кастов за ним).
func busy() -> bool:
	return not _run.is_empty() or not _queue.is_empty()


## Хост: ответ на вопрос каста (модалка решения, driver "spell") — записать и доиграть.
func resolve_decision(pid: String, index: int) -> void:
	if not _gs.is_host() or _run.is_empty() or String(_run.get("pid", "")) != pid:
		return
	var md: Dictionary = _gs.mythos_decision
	(_run["decisions"] as Dictionary)[String(md.get("path", ""))] = (AssetActionFlow.decision_value(
		md, index
	))
	_gs.mythos_decision = {}
	if _step(_run):
		_run = {}
		_pump()
	_gs.broadcast_and_emit()


# Задание каста: всё, что нужно прогону и его переигровке после каждого решения.
# Рубашка выбирается ОДИН раз здесь — переигровка обязана перевернуть ту же карту.
func _make_job(
	pid: String, item_index: int, successes: int, dice: Array, flow: Dictionary
) -> Dictionary:
	if not _gs.is_host() or not _gs.players.has(pid):
		return {}
	var items: Array = (_gs.players[pid] as Dictionary).get("items", [])
	if item_index < 0 or item_index >= items.size():
		return {}
	var sid: String = _spell_id(items[item_index])
	var spell: Dictionary = SpellCatalog.by_id(sid)
	if spell.is_empty():
		return {}
	# Рубашка — закреплённая за ЭТОЙ копией (item.back, назначена при выдаче из
	# колоды): переворачиваем ту же карту, что и в прошлый каст. flow.backs[i] —
	# форс конкретной рубашки (детерминизм/тесты), как flow.rolls для кубиков.
	# Карта без back (легаси-снапшот) → случайная рубашка.
	var forced: String = String((flow.get("backs", {}) as Dictionary).get(str(item_index), ""))
	if forced.is_empty() and items[item_index] is Dictionary:
		forced = String((items[item_index] as Dictionary).get("back", ""))
	var job: Dictionary = {
		"pid": pid,
		"item_index": item_index,
		"sid": sid,
		"back": SpellCatalog.random_back(spell, forced),
		"successes": successes,
		"dice": dice,
		"interactive": bool(flow.get("interactive", false)),
		"nested": bool(flow.get("nested", false)),
		"after": flow.get("after", {}),
		"check_mods": [],
		"prevent": {},
		"encounter": [],
		"decisions": {},
		"rolls": {},
	}
	job["program"] = _cast_program(spell, job)
	return job


# Программа каста: фронт (если тест пройден) + выпавший ярус оборота. Узлы, что
# меняют не сыщика, а обстановку каста, вынимаем сразу (один раз — прогон
# переигрывается после каждого решения):
#   • моды проверки поверх боя (nested) — во временные моды боевой проверки
#     («+3 Силы в этой встрече»), а не жетоном навсегда;
#   • preventLoss — сколько снять с потери, которую отражает каст-реакция;
#   • ignoreMonsters / remoteClueEncounter — как пройдёт встреча (фаза встреч).
# «…вместо этого» на обороте (+5 Силы вместо +3, до 4 вместо 2) — тот же узел
# сильнее: моды проверки берутся по максимуму, предотвращение тоже.
# addSuccesses яруса («+2 успеха к результату») встаёт ПЕРЕД фронтом: ярус выбран
# по броску, а фронт «по стойкости» должен увидеть уже прибавленное.
func _cast_program(spell: Dictionary, job: Dictionary) -> Array:
	var successes: int = int(job["successes"])
	var front: Array = []
	if successes >= 1:
		front = (spell.get("front", {}) as Dictionary).get("onPass", [])
	var tier: Array = _tier_effect(job["back"], successes)
	var program: Array = []
	for n_v: Variant in tier:
		if n_v is Dictionary and String((n_v as Dictionary).get("do", "")) == "addSuccesses":
			program.append(n_v)
	for n_v: Variant in front + tier:
		if not (n_v is Dictionary):
			program.append(n_v)
			continue
		var n: Dictionary = n_v
		var verb: String = String(n.get("do", ""))
		if verb == "addSuccesses" and program.has(n_v):
			continue  # ярусный — уже в начале
		if verb == "preventLoss":
			_merge_prevent(job, n)
		elif _ENCOUNTER_VERBS.has(verb):
			(job["encounter"] as Array).append(verb)
		elif bool(job["nested"]) and AssetCatalog._CHECK_MOD_VERBS.has(verb):
			(job["check_mods"] as Array).append(n.duplicate(true))
		else:
			program.append(n)
	return program


# preventLoss каста: сильнейший узел побеждает — «предотвратите до 4 вместо этого».
func _merge_prevent(job: Dictionary, n: Dictionary) -> void:
	var cur: Dictionary = job["prevent"]
	job["prevent"] = {
		"stat": String(n.get("stat", cur.get("stat", "health"))),
		"amount": maxi(int(cur.get("amount", 0)), int(n.get("amount", 1))),
	}


# Один проход программы каста на копии сыщика: пауза на вопросе (модалка решения,
# driver "spell") либо коммит. true — каст доигран.
func _step(job: Dictionary) -> bool:
	var pid: String = String(job["pid"])
	if not _gs.players.has(pid):
		return true  # сыщик ушёл — каст пропадает
	var p: Dictionary = _gs.players[pid]
	var dup: Dictionary = p.duplicate(true)
	var flow: Dictionary = {
		"interactive": bool(job["interactive"]),
		"decisions": job["decisions"],
		"rolls": job["rolls"],
		"pending": {},
		"slot": "",
	}
	var res: Dictionary = _EffectRunner.run(job["program"], dup, _cast_ctx(pid, job), flow)
	job["rolls"] = flow.get("rolls", {})
	var pending: Dictionary = res.get("pending", {})
	if not pending.is_empty():
		_ask(job, pending)
		return false
	_commit(job, p, dup, res)
	return true


# Контекст прогона: успехи и кубы каста; в интерактивном — ещё то, из чего игрок
# выбирает (как у розыгрыша актива): граф локаций, витрина, монстры, сыщики.
func _cast_ctx(pid: String, job: Dictionary) -> Dictionary:
	var ctx: Dictionary = {}
	var aa: Variant = _gs.get("_asset_action")
	if bool(job["interactive"]) and aa != null:
		ctx = (aa as AssetActionFlow)._ctx(pid)
	ctx["successes"] = int(job["successes"])
	ctx["dice"] = job["dice"]
	return ctx


# Вопрос каста — в общий канал модалки решения; ответ вернётся в resolve_decision.
func _ask(job: Dictionary, pending: Dictionary) -> void:
	var spell: Dictionary = SpellCatalog.by_id(String(job["sid"]))
	var kind: String = String(pending.get("kind", "choice"))
	_gs.mythos_decision = {
		"active": true,
		"pid": String(job["pid"]),
		"driver": "spell",
		"kind": kind,
		"path": String(pending.get("path", "")),
		"options": pending.get("options", []),
		"title_key": String(spell.get("name", "MYTHOS_DECISION_TITLE")),
		"prompt_key": AssetActionFlow.prompt_key_for(kind, String(pending.get("verb", ""))),
		"subject": SpellCatalog.card_payload(spell),
	}


# Каст доигран: мутации копии — в сыщика (по месту: на словарь игрока держат ссылки
# зовущие), board-эффекты, окно расплаты, сброс карты, затем flow.after.
func _commit(job: Dictionary, p: Dictionary, dup: Dictionary, res: Dictionary) -> void:
	var pid: String = String(job["pid"])
	var sid: String = String(job["sid"])
	var back: Dictionary = job["back"]
	var successes: int = int(job["successes"])
	# Снимок ДО каста — diff даст итог для окна расплаты.
	var pre: Dictionary = {
		"hp": int(p.get("hp", 0)),
		"sanity": int(p.get("sanity", 0)),
		"clues": int(p.get("clues", 0)),
		"conds": (p.get("conditions", []) as Array).duplicate(),
	}
	for k: Variant in p.keys():
		if not dup.has(k):
			p.erase(k)
	p.merge(dup, true)
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[Заклинание] %s · %s" % [_gs.name_of(pid), String(l_v)])
	var consumed: bool = false
	for node_v: Variant in res.get("board", []):
		var node: Dictionary = node_v
		if String(node.get("do", "")) == "discardCard":
			consumed = true
		else:
			node["_anchor_pid"] = pid  # «на вашей клетке» — от кастующего
			_gs.apply_board_effect(node)
	_set_cast_result(pid, sid, back, successes, pre, consumed, _tier_text(back, successes))
	GameConsole.log(
		(
			"[Заклинание] %s · «%s» (рубашка %s, успехов %d)"
			% [_gs.name_of(pid), sid, String(back.get("id", "")), successes]
		)
	)
	if consumed:
		var items: Array = p.get("items", [])
		var idx: int = _item_index_of(items, job)
		if idx >= 0:
			items.remove_at(idx)
			p["items"] = items
			GameConsole.log("[Заклинание] «%s» сброшено" % sid)
	_finish(job)


# Где в руке карта задания: по индексу, если там она же; иначе — та же копия по id
# и рубашке (руку могли поменять, пока игрок думал). -1 — карты нет.
func _item_index_of(items: Array, job: Dictionary) -> int:
	var idx: int = int(job["item_index"])
	if idx >= 0 and idx < items.size() and _spell_id(items[idx]) == String(job["sid"]):
		return idx
	var back_id: String = String((job["back"] as Dictionary).get("id", ""))
	for i in range(items.size()):
		var it: Variant = items[i]
		if _spell_id(it) != String(job["sid"]):
			continue
		if not (it is Dictionary) or String((it as Dictionary).get("back", "")) == back_id:
			return i
	return -1


# Итог каста для зовущего (flow.after): моды — в вернувшуюся боевую проверку,
# предотвращение — в бой, опции встречи — в ход встречи, ход ритуала — отпустить.
func _finish(job: Dictionary) -> void:
	var pid: String = String(job["pid"])
	var after: Dictionary = job["after"]
	if bool(after.get("add_mods", false)):
		_gs._check.add_mods(pid, job["check_mods"])  # «+3 Силы в этом бою»
	var prevent: Dictionary = job["prevent"]
	if bool(after.get("reaction", false)) and not prevent.is_empty():
		_gs._encounter.prevent_by_spell(
			pid, String(prevent.get("stat", "health")), int(prevent.get("amount", 0))
		)
	if not (job["encounter"] as Array).is_empty():
		_gs._encounter.grant_spell_options(pid, job["encounter"])
	if bool(after.get("release", false)):
		_gs._phase.release_cast_turn(pid)


# Очередь кастов: по одному, пока очередной не встанет на вопрос. Опустела — _then.
func _pump() -> void:
	while _run.is_empty() and not _queue.is_empty():
		var job: Dictionary = _queue.pop_front()
		if not _step(job):
			_run = job
			return
	if _run.is_empty() and _queue.is_empty() and _then.is_valid():
		var then: Callable = _then
		_then = Callable()
		then.call()


# Записать результат каста (для модалки расплаты): какой оборот выпал + flavor-ключ
# + ЧИСТЫЙ итог рубашки (diff pre→now: −здоровье/−рассудок/−улики, новые состояния,
# сброс). Пустой outcome = «обошлось» (хороший бросок). Хост-авторитетно, синкается.
func _set_cast_result(
	pid: String,
	spell_id: String,
	back: Dictionary,
	successes: int,
	pre: Dictionary,
	discarded: bool,
	text: String = ""
) -> void:
	var p: Dictionary = _gs.players[pid]
	var out: Dictionary = {}
	var dhp: int = int(p.get("hp", 0)) - int(pre.get("hp", 0))
	if dhp != 0:
		out["health"] = dhp
	var dsan: int = int(p.get("sanity", 0)) - int(pre.get("sanity", 0))
	if dsan != 0:
		out["sanity"] = dsan
	var dcl: int = int(p.get("clues", 0)) - int(pre.get("clues", 0))
	if dcl != 0:
		out["clues"] = dcl
	var newc: Array = []
	var precon: Array = pre.get("conds", [])
	for c_v: Variant in p.get("conditions", []):
		if not precon.has(c_v):
			newc.append(String(c_v))
	if not newc.is_empty():
		out["conditions"] = newc
	if discarded:
		out["discarded"] = true
	_gs.last_cast_result = {
		"pid": pid,
		"spell": spell_id,
		"back": String(back.get("id", "")),
		"text": text if not text.is_empty() else String(back.get("text", "")),
		"successes": successes,
		"outcome": out,
	}


## Хост: НАЧАТЬ каст Ritual-заклинания (действие). Валидирует (ritual + trigger:action
## + владение) и стартует spell-проверку Lore±modifier (БЕЗ броска — игрок бросит сам
## из модалки). Резолв — позже, в apply_cast. true — каст начат (действие/удержание
## хода ставит зовущая сторона: PhaseController.cast_spell).
func begin_ritual(pid: String, item_index: int) -> bool:
	var spell: Dictionary = _validate_cast(pid, item_index, "ritual")
	if spell.is_empty():
		return false
	if String((spell.get("front", {}) as Dictionary).get("trigger", "")) != "action":
		return false
	_begin_check(pid, item_index, spell, "ritual", false)
	return true


## Хост: НАЧАТЬ каст glamour (exhaust-каст, не действие). Истощает карту на старте
## (⟳ oncePerRound) и стартует spell-проверку. Резолв — в apply_cast.
func begin_glamour(pid: String, item_index: int) -> bool:
	var spell: Dictionary = _validate_cast(pid, item_index, "glamour")
	if spell.is_empty():
		return false
	var it_v: Variant = (_gs.players[pid] as Dictionary).get("items", [])[item_index]
	if not (it_v is Dictionary):
		return false
	var it: Dictionary = it_v
	if bool(it.get("exhausted", false)):
		return false  # уже истощена в этом раунде
	it["exhausted"] = true  # ⟳ — oncePerRound
	_begin_check(pid, item_index, spell, "glamour", false)
	return true


## Хост: НАЧАТЬ каст Incantation (контекстный триггер в бою, не действие). Только при
## активной боевой проверке; СОХРАНЯЕТ её (push) и стартует spell-проверку поверх —
## на apply_cast боевая вернётся (pop). Резолв — в apply_cast.
func begin_incantation(pid: String, item_index: int) -> bool:
	var spell: Dictionary = _validate_cast(pid, item_index, "incantation")
	if spell.is_empty():
		return false
	var trigger: String = String((spell.get("front", {}) as Dictionary).get("trigger", ""))
	var stat: String = String(_REACTION_STATS.get(trigger, ""))
	if trigger == "combatEncounter":
		if String((_gs.active_check as Dictionary).get("context", "")) != "combatEncounter":
			return false  # вне боя не кастуется
	elif not stat.is_empty():
		# Реакция «когда сыщик должен потерять здоровье/рассудок» (Защита плоти, Вселить
		# отвагу): окно — бой, где потеря уже видна, но не списана (то же, что у бинтов).
		# Раз в раунд — карта истощается до Refresh.
		var it_v: Variant = (_gs.players[pid] as Dictionary).get("items", [])[item_index]
		if not (it_v is Dictionary) or bool((it_v as Dictionary).get("exhausted", false)):
			return false
		if not _gs._encounter.spell_loss_window(stat):
			return false
		(it_v as Dictionary)["exhausted"] = true
	else:
		return false  # onRest / encounterPhase — из своих промптов, не с руки
	_gs._check.push()  # сохранить боевую проверку под spell-проверкой
	_begin_check(pid, item_index, spell, "incantation", true)
	if not stat.is_empty():
		(_gs.casting_spell as Dictionary)["reaction"] = stat
	return true


# Старт spell-проверки + метаданные каста (casting_spell). Без броска и без резолва.
func _begin_check(
	pid: String, item_index: int, spell: Dictionary, subtype: String, nested: bool
) -> void:
	var front: Dictionary = spell.get("front", {})
	_gs._check.start(
		"spell",
		pid,
		String(front.get("test", "lore")),
		int(front.get("modifier", 0)),
		"spellEffect"
	)
	_gs.casting_spell = {
		"pid": pid,
		"item_index": item_index,
		"spell_id": _spell_id((_gs.players[pid] as Dictionary).get("items", [])[item_index]),
		"subtype": subtype,
		"context": "spellEffect",
		"nested": nested,
	}


# Общая валидация каста: владение + подтип. Возвращает spell ({} — невалидно).
func _validate_cast(pid: String, item_index: int, subtype: String) -> Dictionary:
	if not _gs.is_host() or not _gs.players.has(pid):
		return {}
	if not (_gs.casting_spell as Dictionary).is_empty() or busy():
		return {}  # другой каст ещё идёт (проверка или вопрос игроку)
	var items: Array = (_gs.players[pid] as Dictionary).get("items", [])
	if item_index < 0 or item_index >= items.size():
		return {}
	var spell: Dictionary = SpellCatalog.by_id(_spell_id(items[item_index]))
	if spell.is_empty() or String(spell.get("subtype", "")) != subtype:
		return {}
	return spell


## Хост: бросок spell-проверки текущего каста (кнопка «Бросить кубы»).
func roll_cast(pid: String) -> bool:
	if String((_gs.casting_spell as Dictionary).get("pid", "")) != pid:
		return false
	return _gs._check.roll(pid)


## Хост: ПРИМЕНИТЬ каст («Применить») — резолвит фронт+оборот по результату spell-
## проверки (бросает, если ещё не брошено), снимает проверку (pop боевой для
## incantation, иначе clear), чистит casting_spell и освобождает ход (ritual).
## flow — детерминизм/тесты (forced backs). true — применено.
func apply_cast(pid: String, flow: Dictionary = {}) -> bool:
	var cs: Dictionary = _gs.casting_spell
	if cs.is_empty() or String(cs.get("pid", "")) != pid:
		return false
	var c: Dictionary = _gs.active_check
	if String(c.get("owner", "")) != "spell":
		return false
	if not bool(c.get("rolled", false)):
		_gs._check.roll(pid)  # страховка: применили без явного броска
		c = _gs.active_check
	var item_index: int = int(cs.get("item_index", -1))
	var dice: Array = c.get("dice", c.get("base", []))
	var successes: int = int(c.get("successes", 0))
	var nested: bool = bool(cs.get("nested", false))
	# Проверку каста снимаем сразу: дальнейшие вопросы (ветка оборота, куда идти) —
	# модалкой решения поверх вернувшейся боевой проверки / карты.
	if nested:
		_gs._check.pop()  # вернуть боевую проверку
	else:
		_gs._check.clear()
	_gs.casting_spell = {}
	var f: Dictionary = flow.duplicate()
	f["nested"] = nested
	f["interactive"] = bool(flow.get("interactive", true))
	f["after"] = {
		"add_mods": nested,
		"release": String(cs.get("subtype", "")) == "ritual",
		"reaction": cs.has("reaction"),
	}
	resolve_cast(pid, item_index, successes, dice, f)
	return true


# Транзиентный тест Lore (для триггер-кастов onRest/onTravel/…, когда CheckFlow занят).
# flow.cast={successes,dice} переопределяет бросок (тесты/replay).
func _lore_roll(p: Dictionary, modifier: int, flow: Dictionary) -> Dictionary:
	var roll: Dictionary = flow.get("cast", {})
	if roll.has("successes"):
		return {"successes": int(roll["successes"]), "dice": roll.get("dice", [])}
	var inv: Dictionary = Investigators.get_data(String(p.get("investigator", "")))
	var lore: int = int((inv.get("skills", {}) as Dictionary).get("lore", 1))
	var mods: int = int((p.get("skill_mods", {}) as Dictionary).get("lore", 0))
	var dice: Array = Dice.roll(maxi(1, lore + mods + modifier))
	# Порог Blessed/Cursed действует и в тихих кастах (как в видимом CheckFlow).
	var threshold: int = Conditions.success_threshold(
		p.get("conditions", []), p.get("conditions_flipped", {})
	)
	return {"successes": int(Dice.result(dice, threshold).get("successes", 0)), "dice": dice}


## Хост: сработавший spell-триггер по игровому событию (onRest/onTravel/…). Кастует
## ВСЕ заклинания сыщика с front.trigger == event (а не только первое — игрок может
## держать несколько, напр. три onRest-лечилки). Для каждого: тест Lore → фронт
## onPass к себе → рубашка. true — сработало хотя бы одно. Зовётся из игровых хуков
## (phase_controller.rest и т.п.). flow.cast/backs — детерминизм/тесты.
func fire_trigger(pid: String, event: String, flow: Dictionary = {}) -> bool:
	if not _gs.is_host() or not _gs.players.has(pid):
		return false
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	# Собираем индексы ВСЕХ совпавших заклинаний, потом кастуем.
	var matches: Array[int] = []
	for i in range(items.size()):
		var it: Variant = items[i]
		if not (it is Dictionary):
			continue
		var spell: Dictionary = SpellCatalog.by_id(_spell_id(it))
		if spell.is_empty():
			continue
		if String((spell.get("front", {}) as Dictionary).get("trigger", "")) == event:
			matches.append(i)
	if matches.is_empty():
		return false
	# Кастуем по УБЫВАНИЮ индекса: если рубашка сбросит карту (resolve_cast удалит
	# элемент), индексы НИЖЕ не сдвинутся — обработка остальных не поедет.
	matches.reverse()
	for idx: int in matches:
		var front: Dictionary = SpellCatalog.by_id(_spell_id(items[idx])).get("front", {})
		var r: Dictionary = _lore_roll(p, int(front.get("modifier", 0)), flow)
		resolve_cast(pid, idx, int(r["successes"]), r["dice"], flow)
	return true


## Хост: выставить ПРОМПТ выбора триггер-заклинаний (НЕ кастуя). Собирает все
## заклинания сыщика с front.trigger == event в _gs.pending_spell_cast =
## {pid, event, options:[{index, id}]} и синкается. Игрок выберет подмножество →
## host_apply_trigger_spells. true — есть что предлагать (промпт выставлен); иначе
## false (зовущая сторона ничего не делает). Опциональная замена fire_trigger для
## событий, где каст должен быть на усмотрение игрока (напр. onRest).
func prompt_trigger(pid: String, event: String) -> bool:
	if not _gs.is_host() or not _gs.players.has(pid):
		return false
	var items: Array = (_gs.players[pid] as Dictionary).get("items", [])
	var options: Array = []
	for i in range(items.size()):
		var it: Variant = items[i]
		if not (it is Dictionary):
			continue
		var spell: Dictionary = SpellCatalog.by_id(_spell_id(it))
		if spell.is_empty():
			continue
		if String((spell.get("front", {}) as Dictionary).get("trigger", "")) == event:
			options.append({"index": i, "id": _spell_id(it)})
	if options.is_empty():
		return false
	_gs.pending_spell_cast = {"pid": pid, "event": event, "options": options}
	return true


## Хост: игрок подтвердил, КАКИЕ из предложенных триггер-заклинаний скастить
## (indices — item-индексы из pending_spell_cast.options). Кастует только ВАЛИДНЫЕ
## выбранные (входящие в options — защита от произвольного ввода клиента) по
## убыванию индекса (сброс рубашкой не сдвинет необработанные нижние) и чистит
## промпт. flow — детерминизм/тесты. true — промпт был для pid и закрыт.
func host_apply_trigger_spells(
	pid: String, indices: Array, flow: Dictionary = {}, then: Callable = Callable()
) -> bool:
	if not _gs.is_host():
		return false
	var prompt: Dictionary = _gs.pending_spell_cast
	if prompt.is_empty() or String(prompt.get("pid", "")) != pid:
		return false
	var allowed: Dictionary = {}
	for o_v: Variant in prompt.get("options", []):
		allowed[int((o_v as Dictionary).get("index", -1))] = true
	var chosen: Array[int] = []
	for v: Variant in indices:
		var idx: int = int(v)
		if allowed.has(idx) and not chosen.has(idx):
			chosen.append(idx)
	chosen.sort()
	chosen.reverse()  # по убыванию
	var p: Dictionary = _gs.players[pid]
	var f: Dictionary = flow.duplicate()
	f["interactive"] = bool(flow.get("interactive", true))
	# Касты встают в очередь (каждый может спросить игрока); then — когда доиграют все.
	for idx: int in chosen:
		var items: Array = p.get("items", [])
		if idx < 0 or idx >= items.size():
			continue
		var front: Dictionary = SpellCatalog.by_id(_spell_id(items[idx])).get("front", {})
		var r: Dictionary = _lore_roll(p, int(front.get("modifier", 0)), flow)
		var job: Dictionary = _make_job(pid, idx, int(r["successes"]), r["dice"], f)
		if not job.is_empty():
			_queue.append(job)
	_gs.pending_spell_cast = {}
	if then.is_valid():
		var prev: Callable = _then
		_then = then if not prev.is_valid() else _chain(prev, then)
	_pump()
	return true


# Два продолжения подряд (очередь кастов опустеет одна на оба промпта).
static func _chain(first: Callable, second: Callable) -> Callable:
	return func() -> void:
		first.call()
		second.call()


## Хост: выдать заклинание сыщику (board-verb gainSpell). spell_id пустой →
## случайная копия из колоды; иначе — копия ИМЕННО этого заклинания (любой из его
## оборотов). Копий не осталось (все в руках) — карта не выдаётся, как в настолке.
func grant_spell(pid: String, spell_id: String = "", want_type: String = "") -> void:
	if not _gs.is_host() or not _gs.players.has(pid):
		return
	if not spell_id.is_empty() and SpellCatalog.by_id(spell_id).is_empty():
		return
	var copy: Dictionary = _take_copy(spell_id, want_type)
	if copy.is_empty():
		GameConsole.log("[Заклинание] копий «%s» не осталось" % (spell_id if spell_id else "?"))
		return
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	items.append({"id": String(copy["id"]), "kind": "spell", "back": String(copy["back"])})
	p["items"] = items
	GameConsole.log(
		"[Заклинание] %s получил «%s» (%s)" % [_gs.name_of(pid), copy["id"], copy["back"]]
	)


# ── Колода копий ─────────────────────────────────────────────────────────────


## Хост: собрать колоду партии — по копии на каждый оборот каждого доступного столу
## заклинания. Стартовые заклинания сыщиков уже лежат в руках без рубашки: каждому
## назначается своя копия (и вычитается из колоды). Зовётся из start_game.
func reset_deck() -> void:
	if not _gs.is_host():
		return
	_gs.spell_deck = _all_copies()
	for pid: String in _gs.players:
		assign_backs(pid)
	(_gs.spell_deck as Array).shuffle()
	GameConsole.log("[Заклинания] колода собрана: %d копий" % (_gs.spell_deck as Array).size())


## Хост: закрепить копии за заклинаниями на руках сыщика: карте без back — своя копия
## из колоды (стартовые карты, поздний вход, легаси-снапшот); карта с back — её копия
## из колоды убирается (одна копия — один владелец). Копий нет → карта остаётся без
## рубашки (каст возьмёт случайную).
func assign_backs(pid: String) -> void:
	if not _gs.is_host() or not _gs.players.has(pid):
		return
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	for i in range(items.size()):
		var it_v: Variant = items[i]
		if not (it_v is Dictionary) or String((it_v as Dictionary).get("kind", "")) != "spell":
			continue
		var it: Dictionary = it_v
		var sid: String = String(it.get("id", ""))
		var own: String = String(it.get("back", ""))
		if own.is_empty():
			var copy: Dictionary = _take_copy(sid)
			if copy.is_empty():
				continue
			it["back"] = String(copy["back"])
			items[i] = it
		else:
			_remove_copy(sid, own)
	p["items"] = items


# Все копии доступных столу заклинаний: {id, back} на каждый оборот; заклинание без
# оборотов — одна копия с пустым back.
func _all_copies() -> Array:
	var out: Array = []
	for s_v: Variant in SeasonGate.filter_room(SpellCatalog.all()):
		var s: Dictionary = s_v
		var sid: String = String(s.get("id", ""))
		var backs: Array = s.get("backs", [])
		if backs.is_empty():
			out.append({"id": sid, "back": ""})
		for b_v: Variant in backs:
			out.append({"id": sid, "back": String((b_v as Dictionary).get("id", ""))})
	return out


# Снять копию из колоды: заклинания spell_id (случайный из его оборотов) или любую
# ("" — случайная карта). Нужной копии в колоде нет → замешиваем сброс (все копии
# минус руки минус колода). {} — копий не осталось вовсе.
# want_type — вид заклинания («получите Ритуал»: ritual / incantation / glamour). Такого
# в колоде нет — любое: пустая награда хуже неточной (то же правило, что у gainAsset).
func _take_copy(spell_id: String, want_type: String = "") -> Dictionary:
	var deck: Array = _gs.spell_deck
	var idx: int = _find_copy(deck, spell_id, want_type)
	if idx < 0:
		var discard: Array = _discarded_copies()
		if not discard.is_empty():
			discard.shuffle()
			deck.append_array(discard)
			GameConsole.log("[Заклинания] колода замешана из сброса: %d копий" % discard.size())
			idx = _find_copy(deck, spell_id, want_type)
	if idx < 0:
		return {}
	var copy: Dictionary = deck[idx]
	deck.remove_at(idx)
	_gs.spell_deck = deck
	return copy


func _find_copy(deck: Array, spell_id: String, want_type: String = "") -> int:
	if deck.is_empty():
		return -1
	if spell_id.is_empty() and not want_type.is_empty():
		var typed: Array = []
		for i in range(deck.size()):
			var sid: String = String((deck[i] as Dictionary).get("id", ""))
			if String(SpellCatalog.by_id(sid).get("subtype", "")) == want_type:
				typed.append(i)
		if not typed.is_empty():
			return int(typed[randi() % typed.size()])
	if spell_id.is_empty():
		return randi() % deck.size()
	var cands: Array = []
	for i in range(deck.size()):
		if String((deck[i] as Dictionary).get("id", "")) == spell_id:
			cands.append(i)
	return -1 if cands.is_empty() else int(cands[randi() % cands.size()])


func _remove_copy(spell_id: String, back: String) -> void:
	var deck: Array = _gs.spell_deck
	for i in range(deck.size()):
		var c: Dictionary = deck[i]
		if String(c.get("id", "")) == spell_id and String(c.get("back", "")) == back:
			deck.remove_at(i)
			_gs.spell_deck = deck
			return


# Сброс выводится: копии, которых нет ни в руках, ни в колоде.
func _discarded_copies() -> Array:
	var taken: Dictionary = {}
	for p_v: Variant in _gs.players.values():
		for it_v: Variant in (p_v as Dictionary).get("items", []):
			if it_v is Dictionary and String((it_v as Dictionary).get("kind", "")) == "spell":
				var it: Dictionary = it_v
				taken["%s|%s" % [String(it.get("id", "")), String(it.get("back", ""))]] = true
	for c_v: Variant in _gs.spell_deck:
		var c: Dictionary = c_v
		taken["%s|%s" % [String(c.get("id", "")), String(c.get("back", ""))]] = true
	var out: Array = []
	for c_v: Variant in _all_copies():
		var c: Dictionary = c_v
		if not taken.has("%s|%s" % [String(c.get("id", "")), String(c.get("back", ""))]):
			out.append(c)
	return out


# Выпавший ярус оборота по числу успехов ({} — ни один не подошёл).
static func _tier_of(back: Dictionary, successes: int) -> Dictionary:
	for t_v: Variant in back.get("tiers", []):
		var t: Dictionary = t_v
		if _EffectRunner._tier_match(successes, String(t.get("on", ""))):
			return t
	return {}


# Эффекты выпавшего яруса.
static func _tier_effect(back: Dictionary, successes: int) -> Array:
	var t: Dictionary = _tier_of(back, successes)
	return t.get("effect", t.get("then", []))


# Текст выпавшего яруса оборота (у каждого яруса свой флейвор в EH); нет — "".
static func _tier_text(back: Dictionary, successes: int) -> String:
	return String(_tier_of(back, successes).get("text", ""))


# id заклинания из элемента инвентаря ({id} | {id, kind} | строка).
func _spell_id(entry: Variant) -> String:
	if entry is Dictionary:
		return String((entry as Dictionary).get("id", ""))
	return String(entry)
