class_name MysteryFlow
extends RefCounted

## Подсистема цикла Тайн (хост-only). Вынесена из GameState:
##   • зачёт прогресса (mysteryProgress) и решение активной Тайны → следующая/победа;
##   • data-driven хуки набора жетонов (data.progress): реакции (gateClosed и др.)
##     и встречи-хуки (encounterAt*), оплата cost, применение effect;
##   • onEnter активной Тайны; финал партии (победа/поражение по doomClock).
##
## Синкаемый стейт Тайн (active_mystery/mystery_progress/mystery_claimed/
## mystery_tokens_on_card/outcome/_on_enter_applied_idx) ОСТАЁТСЯ полями GameState —
## модуль мутирует его через _gs. Источник данных Тайн — _gs._campaign.current_mystery().
## Доступ к стейту/услугам — через _gs: _gs.players, _gs._current_pid(), _gs._name_of(),
## _gs._is_host(), _gs._campaign, _gs._board.current_omen_color(), _gs.entities,
## _gs.campaign, _gs.doom, _gs._apply_board_effect(). Создаётся в GameState (поле _mystery).

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


# ── Зачёт / решение / финал ───────────────────────────────────────────────────


# Зачёт текущей локации активного игрока в активную Тайну (verb mysteryProgress).
# При достижении solveCondition.n активная Тайна решается, индекс ++; на третьей
# решённой → outcome="victory".
func apply_mystery_progress() -> void:
	var pid: String = _gs._current_pid()
	if pid.is_empty() or not _gs.players.has(pid):
		return
	var loc: String = String(_gs.players[pid].get("location", ""))
	if loc.is_empty():
		return
	if (_gs.mystery_claimed as Array).has(loc):
		return  # уже была зачтена этим же активным игроком этой же Тайны
	_gs.mystery_progress += 1
	(_gs.mystery_claimed as Array).append(loc)
	GameConsole.log(
		(
			"[Тайна] %s зачёл «%s» (%d/%d)"
			% [_gs._name_of(pid), loc, _gs.mystery_progress, _mystery_target()]
		)
	)
	if _gs.mystery_progress >= _mystery_target():
		_solve_active_mystery()


func _mystery_target() -> int:
	var m: Dictionary = _gs._campaign.current_mystery()
	var sc: Dictionary = m.get("solveCondition", {})
	return maxi(1, int(sc.get("n", 1)))


## Тип условия решения активной Тайны: "tokensOnCard" | "cluesOnCard" |
## "monsterDefeated" | "" (старый location-счётчик). Источник — solveCondition.kind.
func mystery_kind() -> String:
	var m: Dictionary = _gs._campaign.current_mystery()
	return String((m.get("solveCondition", {}) as Dictionary).get("kind", ""))


# ── Data-driven хуки набора жетонов (data.progress) ───────────────────────────
# Хук: { on, when?, test?, cost?, effect }. on — событие-триггер; when —
# условие (omenMatch/locationMarked); test — проверка (для encounter-хуков); cost —
# ресурс «можете потратить»; effect — DSL-узлы (placeEldritchToken where:self и др.).
# См. dark-omens-relay/MYSTERY-PROGRESS.md.


## Хуки набора активной Тайны. Старый формат (один объект progressHook)
## нормализуем в массив. [] — хуков нет.
func mystery_progress_hooks() -> Array:
	var m: Dictionary = _gs._campaign.current_mystery()
	var p: Variant = m.get("progress", null)
	if p is Array:
		return p
	var single: Variant = m.get("progressHook", null)
	if single is Dictionary and not (single as Dictionary).is_empty():
		return [single]
	return []


## Первый подходящий хук для события (on==event и when выполнено). {} — нет.
## Работает только для tokensOnCard-Тайн.
func mystery_hook_for(event: String, ctx: Dictionary = {}) -> Dictionary:
	if mystery_kind() != "tokensOnCard":
		return {}
	var hooks: Array = mystery_progress_hooks()
	for i: int in range(hooks.size()):
		var h: Dictionary = hooks[i]
		if String(h.get("on", h.get("trigger", ""))) != event:
			continue
		if _eval_hook_when(h.get("when", {}), ctx):
			return h
	return {}


# Предикаты when против контекста события (ctx: loc/color/...). Пусто → всегда true.
func _eval_hook_when(when_v: Variant, ctx: Dictionary) -> bool:
	if not (when_v is Dictionary) or (when_v as Dictionary).is_empty():
		return true
	var w: Dictionary = when_v
	if (
		bool(w.get("omenMatch", false))
		and String(ctx.get("color", "")) != _gs._board.current_omen_color()
	):
		return false  # врата должны быть цвета текущего омена
	if bool(w.get("locationMarked", false)):
		var locs: Array = _gs._campaign.current_mystery().get("locations", [])
		if not locs.has(String(ctx.get("loc", ""))):
			return false
	return true


## Хук, доступный как ВСТРЕЧА на локации, если игрок может оплатить cost. {} — нет.
## Повод — клетка с жетоном Знамения ЛИБО помеченная локация Тайны (метка = тот же
## жетон Знамения, канон «eldritch»). Триггер хука — encounterAtEldritchToken.
func mystery_encounter_hook(loc: String, pid: String) -> Dictionary:
	if mystery_kind() != "tokensOnCard":
		return {}
	var has_token: bool = (_gs.entities.get(loc, []) as Array).has("eldritch_token")
	# Помеченная локация = жетон Тайны, ПОКА не снята (mystery_claimed). Снятую локацию
	# (метка убрана, жетон ушёл на карту) встречей больше не предлагаем.
	var is_marked: bool = (
		(_gs._campaign.current_mystery().get("locations", []) as Array).has(loc)
		and not (_gs.mystery_claimed as Array).has(loc)
	)
	if not (has_token or is_marked):
		return {}
	var hook: Dictionary = mystery_hook_for("encounterAtEldritchToken", {"loc": loc})
	if hook.is_empty() or not mystery_can_pay(hook, pid):
		return {}
	return hook


## Может ли игрок оплатить cost хука (spend <resource> amount). Без cost → true.
func mystery_can_pay(hook: Dictionary, pid: String) -> bool:
	var cost: Dictionary = hook.get("cost", {})
	if cost.is_empty():
		return true
	return _player_resource(pid, String(cost.get("spend", ""))) >= int(cost.get("amount", 1))


## Хост: применить хук — списать cost, применить effect (DSL-узлы). true — применён.
func mystery_apply_hook(hook: Dictionary, pid: String) -> bool:
	if not _gs._is_host() or not mystery_can_pay(hook, pid):
		return false
	var cost: Dictionary = hook.get("cost", {})
	if not cost.is_empty():
		_spend_resource(pid, String(cost.get("spend", "")), int(cost.get("amount", 1)))
	var effect: Array = hook.get("effect", [])
	for i: int in range(effect.size()):
		var node: Dictionary = effect[i]
		if node is Dictionary:
			_gs._apply_board_effect(node)  # placeEldritchToken where:self → счётчик и т.п.
	return true


# Хост: реакция-триггеры (gateClosed/monsterDefeated). Пока БЕЗ opt-in промпта —
# применяется автоматически, если игрок может оплатить (см. MYSTERY-PROGRESS.md).
func try_mystery_hook(event: String, ctx: Dictionary, pid: String) -> void:
	var hook: Dictionary = mystery_hook_for(event, ctx)
	if hook.is_empty() or not mystery_can_pay(hook, pid):
		return
	if mystery_apply_hook(hook, pid):
		GameConsole.log("[Тайна] хук «%s» сработал у %s" % [event, _gs._name_of(pid)])


func _player_resource(pid: String, res: String) -> int:
	if not _gs.players.has(pid):
		return 0
	return ResourceLedger.amount_of(_gs.players[pid], res)


func _spend_resource(pid: String, res: String, amt: int) -> void:
	if not _gs.players.has(pid):
		return
	ResourceLedger.spend(_gs.players[pid], res, amt)


## Хост: проверка решения Тайны по жетонам на карте. Зовётся в КОНЦЕ Фазы Мифов
## (см. MythosFlow). Для прочих kind — no-op.
func check_mystery_tokens_solve() -> void:
	if not _gs._is_host() or not _gs.outcome.is_empty():
		return
	if mystery_kind() != "tokensOnCard":
		return
	if _gs.mystery_tokens_on_card >= _mystery_target():
		GameConsole.log(
			(
				"[Тайна] жетонов на карте %d/%d — решено"
				% [_gs.mystery_tokens_on_card, _mystery_target()]
			)
		)
		_solve_active_mystery()


## Хост: применить onEnter активной Тайны (board-эффекты, напр. раскладка жетонов
## Знамения). Зовётся при активации Тайны — на старте кампании и после решения
## предыдущей. onEnter протаскивается в сводку библии (CampaignGen._summary).
func apply_mystery_on_enter() -> void:
	if not _gs._is_host():
		return
	var m: Dictionary = _gs._campaign.current_mystery()
	# Библия ещё не готова → выходим без отметки гарда (повторим, когда придёт).
	if m.is_empty() or _gs._on_enter_applied_idx == _gs.active_mystery:
		return
	_gs._on_enter_applied_idx = _gs.active_mystery
	var on_enter: Array = m.get("onEnter", [])
	for i: int in range(on_enter.size()):
		var node: Dictionary = on_enter[i]
		if node is Dictionary:
			_gs._apply_board_effect(node)


# Активная Тайна решена: переходим к следующей или фиксируем победу.
func _solve_active_mystery() -> void:
	var solved_idx: int = _gs.active_mystery
	GameConsole.log("[Тайна] решена тайна акта %d" % (solved_idx + 1))
	_gs.active_mystery += 1
	_gs.mystery_progress = 0
	_gs.mystery_claimed = []
	_gs.mystery_tokens_on_card = 0
	_gs._board.clear_eldritch_tokens()  # доска чистится — следующая Тайна разложит свои
	var total: int = (_gs.campaign.get("mysteries", []) as Array).size()
	if _gs.active_mystery >= total:
		_gs.outcome = "victory"
		GameConsole.log("[Финал] все Тайны решены — победа партии")
	else:
		apply_mystery_on_enter()  # активировалась следующая Тайна


# Doom достиг doomClock → партия проиграла. Хук на advanceDoom.
func check_defeat() -> void:
	if not _gs.outcome.is_empty():
		return
	var clock: int = int(_gs.campaign.get("doomClock", 0))
	if clock > 0 and _gs.doom >= clock:
		_gs.outcome = "defeat"
		GameConsole.log("[Финал] doom достиг %d — Древний пробуждается" % clock)
