class_name RumorFlow
extends RefCounted

## Слух (Ongoing Rumor) — карта Мифов, что ОСТАЁТСЯ в игре (mythos_in_play). Реюз
## ongoing-Мифов + врат + жетонов Знамения:
##   • вход в игру → открыть врата-портал на гейт-локации (Иной мир), инициализировать
##     счётчик жетонов card.tokens (таймер), запомнить card.rumorLocation;
##   • каждая Расплата → снять 1 жетон с карты; когда жетонов 0 — Рок +1 за КАЖДЫЕ
##     врата на поле (каждую Расплату, пока Слух не развеян);
##   • решение → ЗАКРЫТЬ свои врата-портал (close_gate_at_active_player) → Слух из игры.
##
## Состояние Слуха живёт НА САМОЙ карте в _gs.mythos_in_play (tokens/rumorLocation) и
## синкается вместе с ней — отдельного top-level поля не заводим. Host-only. Owner —
## GameState (_gs._rumor). Близкий «двойник» MysteryFlow, но Слух — не трек победы
## кампании, а локальная временна́я угроза-Миф.

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


## Карта Мифов — Слух (несёт блок `rumor`)?
func is_rumor(card: Dictionary) -> bool:
	return not (card.get("rumor", {}) as Dictionary).is_empty()


## Вход Слуха в игру: открыть врата-портал, задать счётчик жетонов, запомнить локацию
## портала на карте. Зовётся из MythosFlow._register_in_play (host-only).
func on_enter(card: Dictionary) -> void:
	if not _gs._is_host():
		return
	var rumor: Dictionary = card.get("rumor", {})
	card["tokens"] = maxi(0, int(rumor.get("tokens", 0)))
	var loc: String = String(_gs._board.open_gate(""))  # случайная свободная гейт-локация
	card["rumorLocation"] = loc
	if loc.is_empty():
		GameConsole.warn("[Слух] «%s» — нет свободной гейт-локации для портала" % _name(card))
	else:
		GameConsole.log(
			"[Слух] «%s» в игре: портал на %s, жетонов %d" % [_name(card), loc, int(card["tokens"])]
		)


## Расплата Слуха: есть жетоны → снять 1 (таймер ↓); жетонов 0 → Рок +1 за каждые врата
## на поле. Карта ОСТАЁТСЯ в игре (развеять можно только закрытием портала). Host-only.
func reckon(card: Dictionary) -> void:
	if not _gs._is_host():
		return
	var tokens: int = int(card.get("tokens", 0))
	if tokens > 0:
		card["tokens"] = tokens - 1
		GameConsole.log("[Слух] «%s» — снят жетон (%d→%d)" % [_name(card), tokens, tokens - 1])
		return
	# «Когда жетонов 0 — Рок +1 за каждые врата на поле.» Считаем врата напрямую (ctx
	# репутатора пуст → gatesOnBoard вернул бы 1; здесь нужна реальная величина).
	var gates: int = (_gs.gates as Dictionary).size()
	if gates <= 0:
		return
	GameConsole.log("[Слух] «%s» созрел — Рок +%d (за открытые врата)" % [_name(card), gates])
	_gs._apply_board_effect({"do": "advanceDoom", "amount": gates})


## Закрытие врат на loc развеивает Слух, чей портал на этой локации (если такой есть).
## Зовётся из BoardState.close_gate_at_active_player (host-only). Карта уходит из игры.
func solve_on_gate_close(loc: String, _pid: String) -> void:
	if not _gs._is_host() or loc.is_empty():
		return
	var keep: Array = []
	var solved: bool = false
	for c_v: Variant in _gs.mythos_in_play as Array:
		var card: Dictionary = c_v
		if is_rumor(card) and String(card.get("rumorLocation", "")) == loc:
			solved = true
			GameConsole.log("[Слух] «%s» развеян — портал закрыт на %s" % [_name(card), loc])
		else:
			keep.append(card)
	if solved:
		_gs.mythos_in_play = keep


func _name(card: Dictionary) -> String:
	return String(card.get("name", "?"))
