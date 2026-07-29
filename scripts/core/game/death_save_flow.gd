class_name DeathSaveFlow
extends RefCounted

## Спас-бросок на Пороге (0 HP / 0 SAN). Хост-авторитетно. Проверка живёт в
## per-player слоте players[pid].death_save_check (как reckoning_check у Расплаты),
## поэтому НЕ конфликтует с активной проверкой боя/встречи и авто-синкается (players
## в _SYNC_FIELDS). Полный дизайн — docs/death-design.md.
##
## Правила Порога:
##  - умирающий бросает РОВНО 1 кубик (fixed_pool=1), порог — обычный (_threshold);
##  - соседи тратят РЕСУРС на переброс этого кубика (reroll_by_resource);
##  - успех → выжил на 1 (hp или sanity) + шрам −1 к Силе (по hp) / Воле (по san),
##    накопительно, пол −2 (клампится как skill_mods); лечится обычным улучшением;
##  - уже на −2 по нужному навыку → новый Порог = смерть без броска;
##  - провал → смерть.
##
## Chunk 1: смерть помечается флагом players[pid].dead. Переход в Тень (оракул),
## сброс состояний, +дум, кэш вещей, бюджет шёпотов — отдельные куски (§11 доки).

const SCAR_CAP := 2  # шрам навыка клампится в [−SCAR_CAP, +SCAR_CAP] (как SKILL_MOD_CAP)

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


# Навык, страдающий от шрама: 0 HP → Сила, 0 SAN → Воля.
static func _scar_skill(stat: String) -> String:
	return "strength" if stat == PlayerKeys.HP else "will"


## Слот спас-броска игрока (players[pid].death_save_check) — {} если нет.
func slot(pid: String) -> Dictionary:
	return (_gs.players.get(pid, {}) as Dictionary).get(PlayerKeys.DEATH_SAVE_CHECK, {})


## Хост: игрок pid достиг 0 по stat ("hp"/"sanity"). Идемпотентно: слот уже есть или
## игрок мёртв → no-op. Уже на −2 по нужному навыку → сразу смерть. Иначе открыть слот
## и бросить 1 кубик. Возвращает "death" | "save" | "".
func open(pid: String, stat: String) -> String:
	var p: Dictionary = _gs.players.get(pid, {})
	if p.is_empty() or bool(p.get(PlayerKeys.DEAD, false)):
		return ""
	if not slot(pid).is_empty():
		return ""  # спас уже идёт
	var skill: String = _scar_skill(stat)
	var mods: int = int((p.get(PlayerKeys.SKILL_MODS, {}) as Dictionary).get(skill, 0))
	if mods <= -SCAR_CAP:
		_die(pid)  # больше не за что цепляться
		return "death"
	var c: Dictionary = _gs._check.make_check("deathSave", pid, skill, 0, "deathSave")
	c["fixed_pool"] = 1
	c["death_stat"] = stat
	p[PlayerKeys.DEATH_SAVE_CHECK] = c
	_gs._check.roll(pid, c)  # 1 кубик, _sync внутри
	return "save"


## Хост: открыть Порог всем игрокам на 0 HP/SAN (живым, без активного спаса).
## Централизованный триггер — зовётся из _broadcast_sync после любой мутации.
## HP приоритетнее (если оба в 0 — сперва Сила-Порог, рассудок поймает следующий свип).
## Возвращает число открытых спасов/мгновенных смертей.
func sweep() -> int:
	var n: int = 0
	for pid_v: Variant in _gs.players:
		var pid: String = pid_v
		var p: Dictionary = _gs.players[pid]
		if (
			bool(p.get(PlayerKeys.DEAD, false))
			or bool(p.get(PlayerKeys.DEATH_GRACE, false))
			or not slot(pid).is_empty()
		):
			continue
		var stat: String = ""
		if int(p.get(PlayerKeys.HP, 1)) <= 0:
			stat = PlayerKeys.HP
		elif int(p.get(PlayerKeys.SANITY, 1)) <= 0:
			stat = PlayerKeys.SANITY
		if not stat.is_empty() and not open(pid, stat).is_empty():
			n += 1
	return n


## Хост: сосед ally_pid тратит 1 ресурс на переброс куба die_index в спас-броске
## умирающего dying_pid. Куб перебрасывается только если провальный (иначе спас уже
## пройден — ресурс не тратим). true — переброшен.
func reroll_by_resource(ally_pid: String, dying_pid: String, die_index: int) -> bool:
	var c: Dictionary = slot(dying_pid)
	if c.is_empty() or not bool(c.get("rolled", false)):
		return false
	var ally: Dictionary = _gs.players.get(ally_pid, {})
	if int(ally.get(PlayerKeys.RESOURCES, 0)) <= 0:
		return false
	if not _gs._check.die_is_rerollable(dying_pid, die_index, c):
		return false  # успех / вне диапазона — ресурс не тратим
	ally[PlayerKeys.RESOURCES] = int(ally.get(PlayerKeys.RESOURCES, 0)) - 1
	_gs._check.reroll_no_cost(dying_pid, die_index, c)  # _sync внутри
	return true


## Хост: разрешить спас-бросок игрока pid (соседи закончили с перебросами). Успех →
## выжил на 1 + шрам; провал → смерть. Возвращает "survive" | "death" | "".
func apply(pid: String) -> String:
	var c: Dictionary = slot(pid)
	if c.is_empty():
		return ""
	if not bool(c.get("rolled", false)):
		_gs._check.roll(pid, c)  # страховка: применить без явного броска
		c = slot(pid)
	if bool(c.get("passed", false)):
		_survive(pid, String(c.get("death_stat", PlayerKeys.HP)))
		return "survive"
	_die(pid)
	return "death"


# Вырвали с Порога: выжил на 1 по stat + шрам −1 к соответствующему навыку (пол −2).
# Ставим grace: добор урона от ТОГО ЖЕ события (мифос/встреча) впитывается — новый
# Порог только от отдельного повторного урона в следующем раунде (clear_grace).
func _survive(pid: String, stat: String) -> void:
	var p: Dictionary = _gs.players.get(pid, {})
	p.erase(PlayerKeys.DEATH_SAVE_CHECK)
	p[stat] = 1
	var skill: String = _scar_skill(stat)
	var mods: Dictionary = p.get(PlayerKeys.SKILL_MODS, {})
	mods[skill] = clampi(int(mods.get(skill, 0)) - 1, -SCAR_CAP, SCAR_CAP)
	p[PlayerKeys.SKILL_MODS] = mods
	p[PlayerKeys.DEATH_GRACE] = true
	_gs._broadcast_sync()
	_gs._emit_changed()


## Хост: снять grace-иммунитет со всех (в начале раунда — урон уже «повторный»).
func clear_grace() -> void:
	for pid_v: Variant in _gs.players:
		(_gs.players[pid_v] as Dictionary).erase(PlayerKeys.DEATH_GRACE)


# Смерть. Chunk 1: помечаем флагом (Тень — отдельный кусок, см. docs/death-design.md).
func _die(pid: String) -> void:
	var p: Dictionary = _gs.players.get(pid, {})
	p.erase(PlayerKeys.DEATH_SAVE_CHECK)
	p[PlayerKeys.DEAD] = true
	_gs._broadcast_sync()
	_gs._emit_changed()
