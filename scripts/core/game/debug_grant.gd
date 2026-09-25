class_name DebugGrant
extends RefCounted

## Debug-выдача для GameConsole (вынесено из game_state.gd — тот упирался в лимит строк).
## Хост-авторитетные мутации в обход обычного геймплея, синкают всем. Гейт (dev-сборка +
## хост) и роутинг op — в GameState.debug_exec; сюда приходит уже готовый id. gs —
## GameState (Node autoload); флоу берём типизированно (as ConditionFlow/…) — без warnings.


static func give_asset(gs: Node, pid: String, asset_id: String) -> String:
	if not (gs.get("players") as Dictionary).has(pid):
		return "нет игрока «%s»" % pid
	if AssetCatalog.by_id(asset_id).is_empty():
		return "нет актива «%s»" % asset_id
	(gs.get("_cond") as ConditionFlow).host_grant_asset(pid, asset_id)  # с onGain-эффектами
	gs.call("_broadcast_and_emit")
	return "актив «%s» → %s" % [asset_id, String(gs.call("_name_of", pid))]


static func give_spell(gs: Node, pid: String, spell_id: String) -> String:
	if not (gs.get("players") as Dictionary).has(pid):
		return "нет игрока «%s»" % pid
	if SpellCatalog.by_id(spell_id).is_empty():
		return "нет заклинания «%s»" % spell_id
	(gs.get("_spell") as SpellFlow).grant_spell(pid, spell_id)
	gs.call("_broadcast_and_emit")
	return "заклинание «%s» → %s" % [spell_id, String(gs.call("_name_of", pid))]


# Конкретный монстр на локации — в обход мешка (нужен именно этот id). Стойкость по
# размеру партии, как штатный спаун.
static func spawn_monster(gs: Node, loc_id: String, monster_id: String) -> String:
	if loc_id.is_empty():
		return "не указана локация"
	var m: Dictionary = MonsterCatalog.by_id(monster_id)
	if m.is_empty():
		return "нет монстра «%s»" % monster_id
	var pc: int = (gs.get("_campaign") as CampaignGen).balance_player_count()
	var hp: int = maxi(1, MonsterCatalog.toughness_for(m, pc))
	var monsters: Dictionary = gs.get("monsters")
	var arr: Array = monsters.get(loc_id, [])
	arr.append({"id": monster_id, "health": hp})
	monsters[loc_id] = arr
	gs.call("_broadcast_and_emit")
	return "монстр «%s» (стойк. %d) на %s" % [monster_id, hp, loc_id]


# Пустая loc → случайный свободный гейт-спейс; явная → форсит на любой локации.
static func open_gate(gs: Node, loc_id: String, color: String) -> String:
	var opened: String = (gs.get("_board") as BoardState).open_gate(loc_id, color)  # сам спаунит монстра
	if opened.is_empty():
		return "врата не открылись (нет свободных гейт-локаций?)"
	gs.call("_broadcast_and_emit")
	return "врата на %s" % opened


# Виды встреч для консоли → (kind, siteSpecific) запроса. «local» — это та же
# general, но привязанная к клетке (siteSpecific), отдельного kind у неё нет.
# combat сюда не берём: бой не генерится из корпуса, он начинается от монстра на
# клетке (см. EncounterFlow._begin_combat) — назначать его нечем.
const ENCOUNTER_KINDS := {
	"general": ["general", false],
	"local": ["general", true],
	"research": ["research", false],
	"gate": ["gate", false],
	"mystery": ["mystery", false],
}


# Назначить игроку встречу на его следующий ход встречи. Мир — только для gate:
# штатно врата ведут в случайный мир, здесь можно прицелиться.
static func assign_encounter(gs: Node, pid: String, kind: String, world: String) -> String:
	if not (gs.get("players") as Dictionary).has(pid):
		return "нет игрока «%s»" % pid
	if not ENCOUNTER_KINDS.has(kind):
		return "вид встречи: %s" % ", ".join(ENCOUNTER_KINDS.keys())
	if not world.is_empty() and kind != "gate":
		return "мир задаётся только для gate"
	var pair: Array = ENCOUNTER_KINDS[kind]
	var spec: Dictionary = {"kind": String(pair[0]), "siteSpecific": bool(pair[1])}
	if not world.is_empty():
		spec["world"] = world
	(gs.get("_encounter") as EncounterFlow).debug_assign(pid, spec)
	var where: String = " → %s" % world if not world.is_empty() else ""
	return "следующая встреча %s: %s%s" % [String(gs.call("_name_of", pid)), kind, where]


# Улики в руку. Без локации — n анонимных: идентичности сами вытянутся из колоды
# при синке (_reconcile_clue_identities). С локацией — ровно эта улика: ключ уходит
# из колоды/сброса игроку; если он уже на поле или в чьей-то руке — отказ, улики
# уникальны на партию.
static func give_clue(gs: Node, pid: String, loc: String, n: int) -> String:
	var players: Dictionary = gs.get("players")
	if not players.has(pid):
		return "нет игрока «%s»" % pid
	var p: Dictionary = players[pid]
	var who: String = String(gs.call("_name_of", pid))
	if loc.is_empty():
		var cnt: int = clampi(n, 1, 20)
		p[PlayerKeys.CLUES] = int(p.get(PlayerKeys.CLUES, 0)) + cnt
		players[pid] = p
		gs.call("_broadcast_and_emit")
		return "улик +%d → %s" % [cnt, who]
	if not (gs.get("map").call("ids") as Array).has(loc):
		return "нет локации «%s»" % loc
	gs.call("_ensure_clue_deck")
	var deck: Array = gs.get("clue_deck")
	var discard: Array = gs.get("clue_discard")
	if deck.has(loc):
		deck.erase(loc)
	elif discard.has(loc):
		discard.erase(loc)
	else:
		return "улика «%s» уже в игре — на поле или в руках" % loc
	var ids: Array = p.get(PlayerKeys.CLUE_IDS, [])
	ids.append(loc)
	p[PlayerKeys.CLUE_IDS] = ids
	p[PlayerKeys.CLUES] = int(p.get(PlayerKeys.CLUES, 0)) + 1
	players[pid] = p
	gs.call("_broadcast_and_emit")
	return "улика «%s» → %s" % [loc, who]


static func gain_condition(gs: Node, pid: String, cid: String) -> String:
	if not (gs.get("players") as Dictionary).has(pid):
		return "нет игрока «%s»" % pid
	if Conditions.get_def(cid).is_empty():
		return "нет состояния «%s»" % cid
	var p: Dictionary = (gs.get("players") as Dictionary)[pid]
	var conds: Array = p.get("conditions", [])
	if conds.has(cid):
		return "%s уже имеет «%s»" % [String(gs.call("_name_of", pid)), cid]
	conds.append(cid)
	p["conditions"] = conds
	gs.call("_broadcast_and_emit")
	return "состояние «%s» → %s" % [cid, String(gs.call("_name_of", pid))]
