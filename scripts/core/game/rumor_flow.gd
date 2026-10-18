class_name RumorFlow
extends RefCounted

## Слух (Ongoing Rumor) — карта Мифов, что ОСТАЁТСЯ в игре (mythos_in_play). Реюз
## ongoing-Мифов + врат + жетонов Знамения. Гибкая схема (блок `rumor` на карте):
##   tokens        — стартовые жетоны Знамения на карте (таймер);
##   onReckoning   — DSL-программа КАЖДОЙ Расплаты (дефолт: снять 1 жетон с карты);
##   onExpire      — DSL-программа, когда жетонов на карте 0 (Рок за врата / потери / …);
##   solveOnExpire — авто-развеять Слух после onExpire (иначе onExpire бьёт каждую Расплату);
##   solve.kind    — как развеять: "gateClose" (закрыть врата-портал) | "encounter"
##                   (встреча-решение на клетке слуха) | "researchClue" (улика из
##                   исследования на клетке слуха уходит на карту; solve.progress улик —
##                   развеян) | monsterDefeated / toughnessOnCard.
##
## DSL-программы Слуха гоняются через EffectRunner на «доску» (target:each разрулит
## TargetResolver), а узел `discardEldritchToken where:"self"` ПЕРЕХВАТЫВАЕТСЯ — он снимает
## жетоны С ЭТОЙ карты (card.tokens). Счётчики (gatesOnBoard и т.п.) кладём в ctx, чтобы
## repeat считал реальную величину. Состояние Слуха живёт НА КАРТЕ в mythos_in_play
## (tokens/rumorLocation) и синкается с ней. Host-only. Owner — GameState (_gs._rumor).

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

# Дефолтная Расплата Слуха (символ ☼), если onReckoning не задан: снять 1 жетон с карты.
const _DEFAULT_ON_RECKONING: Array = [{"do": "discardEldritchToken", "where": "self", "amount": 1}]

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


## Карта Мифов — Слух (несёт блок `rumor`)?
func is_rumor(card: Dictionary) -> bool:
	return not (card.get("rumor", {}) as Dictionary).is_empty()


## Способ решения Слуха ("gateClose" по умолчанию).
func solve_kind(card: Dictionary) -> String:
	var solve: Dictionary = (card.get("rumor", {}) as Dictionary).get("solve", {})
	return String(solve.get("kind", "gateClose"))


## Вход Слуха в игру: задать счётчик жетонов; для solve=gateClose открыть врата-портал и
## запомнить его локацию. Зовётся из MythosFlow._register_in_play (host-only). Спаун из
## onReveal (улики/монстры) применяет MythosFlow ДО этого — отдельным DSL.
func on_enter(card: Dictionary) -> void:
	if not _gs.is_host():
		return
	var rumor: Dictionary = card.get("rumor", {})
	card["tokens"] = maxi(0, int(rumor.get("tokens", 0)))
	match solve_kind(card):
		"gateClose":
			var loc: String = String(_gs._board.open_gate(""))  # случайная свободная гейт-локация
			card["rumorLocation"] = loc
			if loc.is_empty():
				GameConsole.warn(
					"[Слух] «%s» — нет свободной гейт-локации для портала" % _name(card)
				)
			else:
				GameConsole.log(
					(
						"[Слух] «%s»: портал на %s, жетонов %d"
						% [_name(card), loc, int(card["tokens"])]
					)
				)
		"encounter", "researchClue":
			# Метка слуха на локации — туда идут разыгрывать встречу-решение (или
			# исследование). Явная rumor.location («нотариус в Аркхэме») важнее случайной.
			var eloc: String = String(rumor.get("location", ""))
			if eloc.is_empty():
				eloc = _pick_marked_location()
			else:
				_gs._board.place_rumor_at(eloc)
			card["rumorLocation"] = eloc
			GameConsole.log(
				"[Слух] «%s»: встреча на %s, жетонов %d" % [_name(card), eloc, int(card["tokens"])]
			)
		"monsterDefeated":
			# Спаунить монстра-цель на случайной локации; его гибель развеет Слух.
			var mloc: String = _pick_location()
			card["rumorLocation"] = mloc
			if not mloc.is_empty():
				_gs._board.spawn_monster_at(mloc)
			GameConsole.log(
				"[Слух] «%s»: монстр на %s, жетонов %d" % [_name(card), mloc, int(card["tokens"])]
			)
		_:
			# toughnessOnCard и пр. — пока без особого спауна (таймер всё равно тикает).
			GameConsole.log(
				(
					"[Слух] «%s» в игре (solve=%s), жетонов %d"
					% [_name(card), solve_kind(card), int(card["tokens"])]
				)
			)


## Расплата Слуха: прогнать onReckoning (дефолт — снять 1 жетон); если жетонов стало 0 —
## прогнать onExpire и, при solveOnExpire, развеять Слух. Иначе карта остаётся в игре.
func reckon(card: Dictionary) -> void:
	if not _gs.is_host():
		return
	var rumor: Dictionary = card.get("rumor", {})
	_run_program(card, rumor.get("onReckoning", _DEFAULT_ON_RECKONING))
	# Триггер по Року: doomTrigger {remainingAtMost: N, effect} — один раз, когда до
	# пробуждения осталось ≤ N (doomClock − doom). Нет doomClock в библии → молчит.
	var dt: Dictionary = rumor.get("doomTrigger", {})
	if not dt.is_empty() and not bool(card.get("doom_fired", false)):
		var camp_v: Variant = _gs.get("campaign")
		var clock: int = int(camp_v.get("doomClock", 0)) if camp_v is Dictionary else 0
		if clock > 0 and clock - int(_gs.doom) <= int(dt.get("remainingAtMost", 0)):
			card["doom_fired"] = true
			_run_program(card, dt.get("effect", []))
			GameConsole.log("[Слух] «%s»: Рок подошёл — сработал doomTrigger" % _name(card))
	if int(card.get("tokens", 0)) <= 0:
		_run_program(card, rumor.get("onExpire", []))
		if bool(rumor.get("solveOnExpire", false)):
			_solve(card, "таймер истёк")


## Закрытие врат на loc развеивает Слух с solve=gateClose, чей портал на этой локации.
## Зовётся из BoardState.close_gate_at_active_player (host-only).
func solve_on_gate_close(loc: String, _pid: String) -> void:
	if not _gs.is_host() or loc.is_empty():
		return
	for c_v: Variant in (_gs.mythos_in_play as Array).duplicate():
		var card: Dictionary = c_v
		if (
			is_rumor(card)
			and solve_kind(card) == "gateClose"
			and String(card.get("rumorLocation", "")) == loc
		):
			_solve(card, "портал закрыт на %s" % loc)


# ── Решение через встречу (solve=encounter) ──────────────────────────────────


## Локация encounter-Слуха, совпадающая с локацией игрока ("" — нет или нечем платить
## за попытку: solve.cost). Для EncounterFlow: предложить встречу-решение на клетке слуха.
func encounter_location_for(pid: String) -> String:
	if not _gs.players.has(pid):
		return ""
	var loc: String = String(_gs.players[pid].get("location", ""))
	var card: Dictionary = _encounter_card_at(loc)
	if card.is_empty():
		return ""
	var cost: Dictionary = _solve_of(card).get("cost", {})
	if not cost.is_empty():
		var p: Dictionary = _gs.players[pid]
		if not ResourceLedger.can_pay(p, String(cost.get("spend", "")), int(cost.get("amount", 1))):
			return ""
	return loc


## Хост: плата за ПОПЫТКУ решения (solve.cost) — списывается при любом исходе проверки.
func pay_attempt(pid: String, loc: String) -> void:
	if not _gs.is_host() or not _gs.players.has(pid):
		return
	var cost: Dictionary = _solve_of(_encounter_card_at(loc)).get("cost", {})
	if cost.is_empty():
		return
	ResourceLedger.spend(
		_gs.players[pid], String(cost.get("spend", "")), int(cost.get("amount", 1))
	)


## Хост: успех встречи-решения на loc. solve.progress (дефолт 1) — сколько успехов
## нужно суммарно; счётчик живёт на карте (card.progress, синкается). Набрали →
## Слух развеян (true), иначе карта остаётся (false).
func progress_encounter_at(loc: String) -> bool:
	if not _gs.is_host():
		return false
	var card: Dictionary = _encounter_card_at(loc)
	if card.is_empty():
		return false
	var need: int = maxi(1, int(_solve_of(card).get("progress", 1)))
	card["progress"] = int(card.get("progress", 0)) + 1
	if int(card["progress"]) < need:
		GameConsole.log("[Слух] «%s»: решение %d/%d" % [_name(card), int(card["progress"]), need])
		return false
	return solve_encounter_at(loc)


## Хост: исследование на loc принесло сыщику gained улик. Есть researchClue-Слух на
## этой клетке — улики переезжают С СЫЩИКА на карту Слуха (card.progress, не больше,
## чем нужно до solve.progress). Набрали — Слух развеян, метка снята. true — улики
## ушли на карту (сыщику они не остались).
func research_clue_to_card(pid: String, loc: String, gained: int) -> bool:
	if not _gs.is_host() or gained <= 0 or not _gs.players.has(pid):
		return false
	var card: Dictionary = _rumor_card_at(loc, "researchClue")
	if card.is_empty():
		return false
	var p: Dictionary = _gs.players[pid]
	var need: int = maxi(1, int(_solve_of(card).get("progress", 1)))
	var have: int = int(card.get("progress", 0))
	var move: int = mini(mini(gained, need - have), int(p.get("clues", 0)))
	if move <= 0:
		return false
	ResourceLedger.spend(p, "clue", move)
	card["progress"] = have + move
	GameConsole.log(
		(
			"[Слух] «%s»: %s кладёт улику на карту (%d/%d)"
			% [_name(card), _gs.name_of(pid), int(card["progress"]), need]
		)
	)
	if int(card["progress"]) >= need:
		_gs._board.remove_rumor_at(loc)
		_solve(card, "улики на карте Слуха (%d)" % need)
	return true


func _solve_of(card: Dictionary) -> Dictionary:
	return (card.get("rumor", {}) as Dictionary).get("solve", {})


## Карта encounter-Слуха на локации loc ({} — нет).
func _encounter_card_at(loc: String) -> Dictionary:
	return _rumor_card_at(loc, "encounter")


## Карта Слуха со способом решения kind на локации loc ({} — нет).
func _rumor_card_at(loc: String, kind: String) -> Dictionary:
	if loc.is_empty():
		return {}
	for c_v: Variant in _gs.mythos_in_play as Array:
		var card: Dictionary = c_v
		if (
			is_rumor(card)
			and solve_kind(card) == kind
			and String(card.get("rumorLocation", "")) == loc
		):
			return card
	return {}


## Имя/текст карты encounter-Слуха на локации (для модалки встречи). {} — нет.
func encounter_card_for(loc: String) -> Dictionary:
	return _encounter_card_at(loc)


## Тест-узел встречи-решения (solve.test), дефолт — Знание.
func encounter_test(loc: String) -> Dictionary:
	var card: Dictionary = _encounter_card_at(loc)
	var solve: Dictionary = (card.get("rumor", {}) as Dictionary).get("solve", {})
	return solve.get("test", {"skill": "lore", "modifier": 0})


## Развеять encounter-Слух на loc (после УСПЕХА встречи). true — развеян. Снимает метку.
func solve_encounter_at(loc: String) -> bool:
	if not _gs.is_host():
		return false
	var card: Dictionary = _encounter_card_at(loc)
	if card.is_empty():
		return false
	_gs._board.remove_rumor_at(loc)
	_solve(card, "встреча у Слуха на %s" % loc)
	return true


# Случайная локация (id) или "" — нет локаций.
func _pick_location() -> String:
	return _gs.map.random_id()


# Случайная локация + метка слуха на ней (для encounter-Слуха).
func _pick_marked_location() -> String:
	var loc: String = _pick_location()
	if not loc.is_empty():
		_gs._board.place_rumor_at(loc)
	return loc


# ── Решение через гибель монстра (solve=monsterDefeated) ──────────────────────


## Гибель монстра на loc развеивает monsterDefeated-Слух, чья локация == loc. Зовётся из
## EncounterFlow._commit_combat при победе сыщика. true — Слух развеян.
func notify_monster_defeated(loc: String) -> bool:
	if not _gs.is_host() or loc.is_empty():
		return false
	for c_v: Variant in (_gs.mythos_in_play as Array).duplicate():
		var card: Dictionary = c_v
		if (
			is_rumor(card)
			and solve_kind(card) == "monsterDefeated"
			and String(card.get("rumorLocation", "")) == loc
		):
			_solve(card, "монстр повержен на %s" % loc)
			return true
	return false


# ── Внутреннее ────────────────────────────────────────────────────────────────


# Прогнать DSL-программу Слуха на «доску». discardEldritchToken where:"self" → снять жетоны
# С ЭТОЙ карты (card.tokens); прочие board-узлы — через apply_board_effect (target:each
# разрулит TargetResolver, _times учитывает repeat). interactive:true — чтобы target:each
# уходили в board; choice в Расплату Слуха не поддержан (некому выбирать).
func _run_program(card: Dictionary, prog: Array) -> void:
	if (prog as Array).is_empty():
		return
	var ctx: Dictionary = {"gates_on_board": (_gs.gates as Dictionary).size()}
	var flow: Dictionary = {
		"interactive": true, "decisions": {}, "rolls": {}, "pending": {}, "slot": ""
	}
	var res: Dictionary = _EffectRunner.run(prog, {}, ctx, flow)
	for node_v: Variant in res.get("board", []):
		var node: Dictionary = node_v
		var times: int = int(node.get("_times", 1))  # repeat-кол-во (0 — эффекта нет)
		if (
			String(node.get("do", "")) == "discardEldritchToken"
			and String(node.get("where", "")) == "self"
		):
			var amt: int = int(node.get("amount", 1)) * times  # repeat:gatesOnBoard → снять = врат
			var before: int = int(card.get("tokens", 0))
			card["tokens"] = maxi(0, before - amt)
			GameConsole.log(
				"[Слух:%s] снят жетон (%d→%d)" % [_name(card), before, int(card["tokens"])]
			)
		elif times > 0:  # apply_board_effect форсит min 1, поэтому 0-повтор гасим тут
			_gs.apply_board_effect(node)
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[Слух:%s] %s" % [_name(card), String(l_v)])


# Развеять Слух: убрать карту из mythos_in_play.
func _solve(card: Dictionary, reason: String) -> void:
	var stack: Array = _gs.mythos_in_play as Array
	if stack.has(card):
		stack.erase(card)
		_gs.mythos_in_play = stack
	GameConsole.log("[Слух] «%s» развеян (%s)" % [_name(card), reason])


func _name(card: Dictionary) -> String:
	return String(card.get("name", "?"))
