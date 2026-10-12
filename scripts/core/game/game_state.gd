extends Node

## Игровое состояние Dark Omens — autoload-синглтон /root/GameState.
##
## Хост-клиент авторитетный: держит стейт, применяет действия, транслирует
## изменения через relay. Не-хост — зеркало: получает game_sync и заменяет
## локальный стейт. Для своих действий не-хост шлёт game_action хосту.
##
## Фазы раунда: action → encounter → mythos → action (next round).
## В Action-фазе игроки ходят по очереди (turn_order), у каждого 2 действия.
## Доступные действия: buy_ticket, take_concentration, rest, travel, pass.
## Encounter — каждому генерится карточка, бросок проверки, эффекты.
## Mythos — хост вытягивает карту из mythosDeck, ВСЕ видят модалку, по
## кнопке «Дальше» хост применяет onDraw-эффекты и стартует новый раунд.

signal state_changed  # любое изменение стейта
signal phase_changed(new_phase: String)  # переход фазы
# Будит корутину MythosFlow; emit'ит PhaseController, а не сам GameState — движок
# считает такой сигнал неиспользованным, отсюда аннотация.
@warning_ignore("unused_signal")
signal mythos_decided(idx: int)  # сыщик выбрал ветку в forEach-проходе Мифов
signal effect_check_applied(pid: String, passed: bool)  # игрок применил видимую проверку test (корутины)
signal chat_received(pid: String, phrase_id: String, noun_ids: Array)  # транзиентный чат (Dark Souls-style)
signal action_announced(pid: String, action_id: String, params: Dictionary)  # транзиентная лента действий

const ACTIONS_PER_ROUND := 2
const MAX_TICKETS := 2  # потолок билетов на руках (ж/д + корабль суммарно), как в EH
const MAX_CONCENTRATION := 2  # потолок жетонов концентрации у сыщика
const MAX_RESOURCES := 2  # потолок жетонов-ресурсов у сыщика

# ── Глобальный стейт ──────────────────────────────────────────────────────────
var round_num: int = 0
var phase: String = ""  # "action" | "encounter" | "mythos" | ""
var current_idx: int = 0  # индекс в turn_order активного игрока
var turn_order: Array = []  # [user_id, ...] — отсортирован, стабилен
var doom: int = 0
var omens_step: int = 0
var active: bool = false  # игра запущена?

# Карта встречи активного игрока (фаза encounter). {} — ещё генерится либо
# встреч сейчас нет. Хост генерит через ContentApi и кладёт сюда, рассылает
# синком всем.
var current_encounter: Dictionary = {}

# Единая активная проверка (встреча/магазин/бой).
# Управляется CheckFlow (_check); потоки начинают проверку и читают результат.
# {} — активной проверки нет. См. check_flow.gd.
var active_check: Dictionary = {}

# Промпт «какие триггер-заклинания скастить» (напр. при отдыхе): { pid, event,
# options:[{index, id}] }. {} — промпта нет. Решает
# только владелец pid (CAST_TRIGGER_SPELLS). См. SpellFlow.prompt_trigger.
var pending_spell_cast: Dictionary = {}

# Каст «в процессе» (интерактивный бросок): {pid, item_index, spell_id, subtype,
# context, nested}. {} — каста нет. Кубы — в active_check (owner="spell"); здесь
# только метаданные. См. SpellFlow.begin_*/apply_cast.
var casting_spell: Dictionary = {}

# Ожидающая ВИДИМАЯ проверка test-узла Effect-DSL (общий движок для всех драйверов):
# {pid, driver, path, skill, modifier, subject?}. {} — нет. Кубы — в active_check
# (owner="effectCheck"); subject — payload карты-носителя для модалки (или {}). На
# «Применить» resolve_pending_check диспетчит по driver в *.resolve_*_check, тот пишет
# decisions[path]=passed и переигрывает свою программу.
var pending_check: Dictionary = {}

# Результат последнего каста для модалки расплаты: { pid, spell, back, text (flavor-
# ключ оборота), successes, outcome:{health,sanity,clues,conditions,discarded} }.
# {} — нет. Модалку показывает владелец pid и сам её
# закрывает (DISMISS_CAST_RESULT). Не привязан к ходу. См. SpellFlow.resolve_cast.
var last_cast_result: Dictionary = {}

# Результаты флипа состояний на Расплате, per-player, для модалки: {pid: {cid, back,
# name, text}}. Заполняет ConditionFlow._flip_condition; показывает владельцу pid,
# он же закрывает (DISMISS_RECKONING).
var reckoning_results: Dictionary = {}

# Идёт ли ПАРАЛЛЕЛЬНЫЙ тир сыщиков Расплаты (все резолвят одновременно). true между
# стартом и финишем всех; для оверлея «ждём других» у закончивших. Хост ставит/снимает
# в ReckoningFlow. Per-player проверки — в players[pid].reckoning_check/reckoning_pending
# (синкаются с players).
var reckoning_active: bool = false

# UI-локально: время последнего отправленного сообщения чата (анти-спам кулдаун).
const CHAT_COOLDOWN_MS := 800
var _chat_last_ms: int = 0

# Компактная сводка сгенерированной кампании: {id, doomClock, ancientOne,
# theme, mysteries}. {} — кампания ещё генерится либо не настроена. Полная
# библия хранится на сервере и тянется по id при генерации встреч.
var campaign: Dictionary = {}

# true, пока хост генерит сценарную библию — на это время игрок заблокирован
# модалкой и не допущен на карту.
var campaign_pending: bool = false

# ── По-игроку ────────────────────────────────────────────────────────────────
# Ключ — стабильный user_id аккаунта (для анонимов фолбэк на id соединения).
# Благодаря этому переподключившийся игрок находит свой слот, а не создаёт
# новый. user_id → {
#   user_id, name, investigator, location, connected,
#   actions_left, actions_used, encounter_done,
#   train_tickets, ship_tickets, concentration, hp, sanity, hp_max, sanity_max,
#   clues, conditions, items, skill_mods
# }
var players: Dictionary = {}

var _nm: Node = null

## Граф локаций поля (data/locations.json): тип/имя/врата/билеты по id — для
## подсистем (_gs.map) и UI (GameState.map). Read-only, лениво читает файл.
var map: LocationGraph = LocationGraph.new()

# Активная карта Мифов. {} — фаза не mythos или карта уже разрешена.
var current_mythos: Dictionary = {}

# Карты Мифов «в игре» (ongoing). Карта с onReckoning/whileInPlay остаётся
# здесь после разрешения; её Расплата гоняется в шаге Расплаты (ReckoningFlow), а не на
# вытягивании. Event-карты (без onReckoning/whileInPlay) сюда не попадают.
var mythos_in_play: Array = []

# Активный per-player выбор в forEach-проходе Мифов. {} — выбора нет.
# {active, pid (чей выбор), path, options:[ветки], by, picked?}. Модалку показывает
# тот клиент, у кого pid==мой; хост ждёт ответ через сигнал mythos_decided.
var mythos_decision: Dictionary = {}

# Кто из сыщиков уже нажал «Прочитал» на текущей карте мифа (список user_id).
# Карта резолвится (эффекты + новый раунд) только когда отметились ВСЕ подключённые —
# иначе один игрок закрывал бы миф всем. Сбрасывается при вытяжке новой карты.
var mythos_read: Array = []

# Последний вытянутый миф (полная карта) — для функции «перечитать». Живёт после
# резолва current_mythos; перетирается следующей картой; сбрасывается в reset().
var last_mythos: Dictionary = {}

# Открытые врата по локациям. {loc_id: "red"|"green"|"blue"}.
# Меняется через apply_board_effect("openGate"). MapLayer.set_gates рендерит
# их визуально на маркерах с вращающейся анимацией.
var gates: Dictionary = {}

# Сущности по локациям. {loc_id: [type,…]} — улики/слухи (token-ы)
# (type ∈ "clue"|"rumor"). Монстры хранятся отдельно (monsters), но на карте
# показываются тем же набором иконок (world_map склеивает вид).
var entities: Dictionary = {}

# ── Колода врат ────────────────────────────────────────────────────────────────
# Жетон врат = гейт-локация (data/locations.json → gateColor), всего 15. Выложили —
# жетон ушёл из колоды; закрыли/сбросили — лёг в сброс. Колода пуста → замешиваем
# сброс обратно. Пусты обе — выложить нечего, и за каждые невыложенные врата
# продвигается трек Рока (см. BoardState.open_gate).
# ИНВАРИАНТ: id гейт-локации всегда ровно в одном месте — колода, поле (gates) или
# сброс. Поэтому записи колоды = СВОБОДНЫЕ гейт-спейсы, отдельная проверка не нужна.
var gate_deck: Array = []
var gate_discard: Array = []

# ── Улики Древнего: колода идентичностей ───────────────────────────────────────
# Ключ улики = локация карты (текст/арт — из campaign.ancientOne.clues, нет → имя
# локации), всего 36. clue_board_ids: loc → [ключи улик на жетонах там].
# Инвариант «ровно в одном месте»: колода ⇄ поле ⇄ руки (player.clue_ids) ⇄ сброс.
# Колода улик (36 = число локаций) и сброс — СИНКАЮТСЯ: их показывает общее окно
# сбросов. Потраченная или снятая с поля улика уходит в сброс, а не сразу обратно
# в колоду: пока не пройдут все 36, ключи не повторяются.
var clue_deck: Array = []
var clue_discard: Array = []

# ── Сброс встреч: колода карточек корпуса ─────────────────────────────────────
# sourceId уже вытянутых карточек CMS. Уходит в /encounters/draw полем exclude,
# чтобы одна и та же встреча не выпадала дважды за партию. Свежих в подходящем
# пуле не осталось — реле само возвращает сброс в колоду (пулы маленькие: девять
# морских встреч, десять диких). Синкается: колода общая на партию, и подхватить
# её должен любой, кто станет хостом.
var encounter_discard: Array = []

# Колода активов (синкается). Сброс НЕ хранится, а выводится — см. asset_discard_ids.
var asset_deck: Array = []

# Колода заклинаний (синкается): копии {id, back} — по одной на каждый оборот каждого
# доступного столу заклинания, как физические карты настолки. Сброс выводится:
# все копии минус руки минус колода (см. SpellFlow._discarded_copies).
var spell_deck: Array = []

# Где лежат ключи улик, уже вышедших из колоды: на жетонах поля. Синкается вместе с
# колодой — иначе перезаход хоста терял привязку, и ключи этих жетонов пропадали из
# оборота (в колоде их уже нет, в сброс они никогда не попадут).
var clue_board_ids: Dictionary = {}

# Колода улик уже собрана. Тоже синкается: флаг — часть состояния колоды, а не
# кэш. Без этого перезашедший хост считал колоду несобранной и на ближайшей же
# сверке пересобирал её из всех 36 локаций поверх живой партии.
var clue_deck_built: bool = false

# Монстры по локациям. {loc_id: [{id, health},…]} — экземпляры из
# MonsterCatalog с текущим здоровьем (урон в бою сохраняется между встречами).
# Визуально склеиваются с entities (по количеству).
var monsters: Dictionary = {}

# «Мешок» доступных монстров — список id, ещё не выставленных на
# поле. Спаун тянет случайный id из мешка (без повторов), смерть монстра
# возвращает его id обратно. Наполняется на старте всеми не-эпиками.
var monster_bag: Array = []

# Параметр «Наплыв монстров» — сколько монстров лезет из каждых врат
# текущего омена при событии Наплыва. Задаётся по таблице Icon Reference на старте.
var monster_surge: int = 0

# Доступные типы встречи активного игрока в фазе encounter. Непусто
# → клиент показывает модалку выбора; выбор шлётся CHOOSE_ENCOUNTER, после чего
# хост генерирует встречу выбранного kind. Очищается после выбора/смены хода.
# Элементы ∈ "general" | "research" | "gate" | "combat".
var encounter_choices: Array = []

# Витрина магазина — список id выложенных «лицом» ассетов. После
# покупки купленные заменяются новыми (см. ShopReserve.refill).
const SHOP_RESERVE_SIZE: int = 4
var shop_reserve: Array = []

# ── Цикл Тайн ────────────────────────────────────────────────────
# Активная Тайна — индекс 0/1/2 в campaign.mysteries[]. Не от doom: акт = это+1.
# Партия проходит Тайны по порядку; каждая решается набором «зачётов» помеченных
# локаций через двух-фазную mystery-встречу (см. encounter_flow + effect_runner).
var active_mystery: int = 0
# 3 ближайших Мифа для оракула-Тени (host режет колоду). Наполняется ТОЛЬКО когда
# в партии есть Тень; живые клиенты его получают, но в UI не показывают (колода и
# так доступна любому через get_campaign — секрета тут нет, зато синк надёжен).
var ghost_upcoming: Array = []
# Сколько локаций активной Тайны уже зачищено (mysteryProgress). При достижении
# solveCondition.n активная Тайна решается, индекс ++ (если уже 3 → outcome).
var mystery_progress: int = 0
# id зачищенных локаций активной Тайны (чтобы они исчезли из выбора встречи).
# При решении Тайны очищается вместе с progress.
var mystery_claimed: Array = []
# Жетоны Знамения (Eldritch), перенесённые на карту активной Тайны (solveCondition
# kind=="tokensOnCard"). Растёт, когда сыщик тратит улики на клетке с жетоном;
# проверяется в конце Фазы Мифов. При решении Тайны сбрасывается.
var mystery_tokens_on_card: int = 0
# Финал партии: "" — ещё идёт; "victory" — все 3 Тайны решены; "defeat" — doom
# достиг doomClock. Клиент по этому полю показывает финальные модалки.
var outcome: String = ""

# Подсистемы. GameState — фасад и хранитель синкаемого state; подмодули —
# host-only логика и owned state (колода мифов, эпоха генерации кампании,
# префетч встреч). _phase владеет переходами и обработкой действий — без
# собственных полей, тонкий контроллер.
var _mythos: MythosFlow
var _campaign: CampaignGen
var _encounter: EncounterFlow
var _phase: PhaseController
var _check: CheckFlow

## Кубы локального игрока: кликабельность, заряженный жетон, тап по кубу — для
## модалок проверок (GameState.dice). UI-слой над CheckFlow, см. local_dice.gd.
var dice: LocalDice
var _cond: ConditionFlow
var _reckoning: ReckoningFlow
var _board: BoardState
var _mystery: MysteryFlow
var _rumor: RumorFlow
var _target: TargetResolver
var _spell: SpellFlow
var _death: DeathSaveFlow  # спас-бросок на Пороге (0 HP/SAN), см. death_save_flow.gd
var _asset_action: AssetActionFlow  # самостоятельное действие актива (тег "action")
var _shop: ShopReserve  # колода активов и витрина магазина
var _relay_router: RelayRouter  # адаптеры relay-действий (_act_*), см. relay_router.gd

# Реэнтранси-гард централизованного свипа Порога в broadcast_sync (свип открывает
# спас и катит кубик → снова зовёт broadcast_sync; без гарда — рекурсия).
var _sweeping: bool = false

# Реестр host-авторитетных relay-действий: имя → Callable(data) (адаптер RelayRouter).
# Диспетчер _on_relay_received зовёт его вместо ~28 веток match. Строится в _ready
# после создания модулей (см. _build_action_registry).
var _relay_actions: Dictionary = {}

# Подмножество _relay_actions, действующих ОТ ЛИЦА игрока data.pid — для них pid
# сверяется с отправителем (защита от спуфинга). Выводится из реестра (минус
# безадресные RESOLVE_MYTHOS/SET_READY) в _build_action_registry.
var _pid_owned: Dictionary = {}

# ── Lifecycle ────────────────────────────────────────────────────────────────


func _ready() -> void:
	_nm = get_node("/root/NetworkManager")
	# Подмодули создаём ДО подписки на сигналы — иначе входящий снапшот может
	# обратиться к ним раньше, чем они инициализированы.
	_mythos = MythosFlow.new(self)
	_campaign = CampaignGen.new(self)
	_encounter = EncounterFlow.new(self)
	_phase = PhaseController.new(self)
	_check = CheckFlow.new(self)
	dice = LocalDice.new(self, _check)
	_cond = ConditionFlow.new(self)
	_reckoning = ReckoningFlow.new(self)
	_shop = ShopReserve.new(self)  # до _board: setup_board наполняет витрину
	_board = BoardState.new(self)
	_mystery = MysteryFlow.new(self)
	_rumor = RumorFlow.new(self)
	_target = TargetResolver.new(self)
	_spell = SpellFlow.new(self)
	_death = DeathSaveFlow.new(self)
	_asset_action = AssetActionFlow.new(self)
	_build_action_registry()  # реестр relay-действий (модули уже созданы выше)
	_nm.relay_received.connect(_on_relay_received)
	_nm.player_left.connect(_on_player_left)
	_nm.player_connected.connect(_on_player_connected)
	_nm.game_state_received.connect(_apply_snapshot)


# ── Helpers ──────────────────────────────────────────────────────────────────


func is_host() -> bool:
	return is_instance_valid(_nm) and _nm.is_host()


# Синкаемый стейт: имена полей GameState, у которых ключ снапшота == имя переменной.
# Единый список для рассылки (broadcast_sync) и приёма (_apply_snapshot) — новое
# синкаемое поле добавляется в ОДНОМ месте. Особые (ключ ≠ поле) — mythos_index
# (_mythos.index) — обрабатываются отдельно. Host-only (колода Мифов) сюда НЕ входят.
const _SYNC_FIELDS: Array[String] = [
	"round_num",
	"phase",
	"current_idx",
	"turn_order",
	"doom",
	"omens_step",
	"players",
	"current_encounter",
	"active_check",
	"pending_spell_cast",
	"casting_spell",
	"pending_check",
	"last_cast_result",
	"reckoning_results",
	"reckoning_active",
	"current_mythos",
	"mythos_in_play",
	"mythos_decision",
	"mythos_read",
	"last_mythos",
	"gates",
	"entities",
	"monsters",
	"monster_bag",
	"gate_deck",
	"gate_discard",
	"clue_deck",
	"clue_discard",
	"clue_board_ids",
	"clue_deck_built",
	"encounter_discard",
	"asset_deck",
	"spell_deck",
	"monster_surge",
	"encounter_choices",
	"shop_reserve",
	"campaign",
	"campaign_pending",
	"active",
	"active_mystery",
	"ghost_upcoming",
	"mystery_progress",
	"mystery_claimed",
	"mystery_tokens_on_card",
	"outcome",
]


func broadcast_sync() -> void:
	if not is_host():
		return
	# Порог: централизованный триггер спас-броска. Урон приходит из многих мест
	# (эффекты/бой/Миф/Расплата) без единой точки — поэтому ловим 0 HP/SAN здесь,
	# после любой мутации. Гард _sweeping рвёт рекурсию (свип катит кубик → синк).
	if not _sweeping:
		_sweeping = true
		_death.sweep()
		_sweeping = false
	_board.reconcile_clue_identities()  # clue_ids игроков ⇄ число улик — до рассылки
	_cond.reconcile_backs()  # состояниям без копии — закрепить оборот (карта = копия)
	_reconcile_focus_quotes()  # цитаты жетонов концентрации привязаны к жетонам
	_refresh_ghost_upcoming()  # 3 ближайших Мифа для Теней (host режет host-only колоду)
	var payload: Dictionary = {"action": RelayActions.SYNC, "mythos_index": _mythos.index}
	for f: String in _SYNC_FIELDS:
		payload[f] = get(f)
	_nm.relay_all(payload)


# Один host-action проходит через несколько точек emit/broadcast, а на state_changed
# подписаны ~30 узлов UI. Схлопываем все вызовы за кадр в один сигнал (deferred):
# UI — пассивный наблюдатель, читает стейт в _refresh(), кадр задержки ему не важен.
var _emit_pending: bool = false


func emit_changed() -> void:
	if _emit_pending:
		return
	_emit_pending = true
	_flush_changed.call_deferred()


## Синхронно разослать отложенный state_changed (тесты, отладочные сценарии, где
## нужен снимок UI «прямо сейчас»). Вне очереди — no-op.
func flush_changed() -> void:
	if _emit_pending:
		_flush_changed()


func _flush_changed() -> void:
	_emit_pending = false
	state_changed.emit()


# ── Улики Древнего: сверка идентичностей — в BoardState; здесь цитаты жетонов ──


# Host: наполнить ghost_upcoming 3 ближайшими Мифами — только если есть Тень. Колода
# host-only, index указывает на след. карту → deck[index..index+3]. Кладём лишь
# name/text (для оверлея «Ближайшие Мифы»), чтобы не тащить весь эффект-DSL.
func _refresh_ghost_upcoming() -> void:
	var has_ghost: bool = false
	for pid_v: Variant in players:
		if bool((players[pid_v] as Dictionary).get(PlayerKeys.DEAD, false)):
			has_ghost = true
			break
	if not has_ghost:
		ghost_upcoming = []
		return
	var out: Array = []
	for i in range(_mythos.index, mini(_mythos.index + 3, _mythos.deck.size())):
		var card: Dictionary = _mythos.deck[i]
		out.append({"name": String(card.get("name", "")), "text": String(card.get("text", ""))})
	ghost_upcoming = out


# Сверка идентичностей с числом улик (host, каждый broadcast_sync). Сначала вернуть
# в пул ключи «мёртвых» жетонов, затем на каждого игрока: clue_ids < clues → добрать
# из пула (любую оставшуюся); clue_ids > clues (трата/потеря) → вернуть излишек в пул.
## Привязка цитат стоиков к жетонам концентрации: длина concentration_quotes = числу
## жетонов. Новый жетон → своя цитата (случайный индекс, назначается ОДИН раз); снятый
## — с конца. Так цитата не ре-рандомится на рендере и переживает трату соседних.
func _reconcile_focus_quotes() -> void:
	if not is_host():
		return
	for pid: Variant in players:
		var p: Dictionary = players[pid]
		var want: int = int(p.get(PlayerKeys.CONCENTRATION, 0))
		var q: Array = p.get(PlayerKeys.CONCENTRATION_QUOTES, [])
		while q.size() < want:
			q.append(randi())
		while q.size() > want:
			q.pop_back()
		p[PlayerKeys.CONCENTRATION_QUOTES] = q
		players[pid] = p


# Сборка свежей записи игрока — общий шаблон для старта партии и поздних
# подключений. Меняешь поле здесь — оно автоматом подхватится в обоих местах.
func _make_player_dict(
	uid: String,
	pname: String,
	investigator: String,
	location: String,
	hp_max: int,
	sanity_max: int,
) -> Dictionary:
	return {
		PlayerKeys.USER_ID: uid,
		PlayerKeys.NAME: pname,
		PlayerKeys.INVESTIGATOR: investigator,
		PlayerKeys.LOCATION: location,
		PlayerKeys.TRAVEL_PATH: [],
		PlayerKeys.CONNECTED: true,
		PlayerKeys.ACTIONS_LEFT: ACTIONS_PER_ROUND,
		PlayerKeys.ACTIONS_USED: [],
		PlayerKeys.ENCOUNTER_DONE: false,
		PlayerKeys.TRAIN_TICKETS: _starting_ticket_count(investigator, "train"),
		PlayerKeys.SHIP_TICKETS: _starting_ticket_count(investigator, "ship"),
		PlayerKeys.CONCENTRATION: 0,
		PlayerKeys.CONCENTRATION_QUOTES: [],
		PlayerKeys.RESOURCES: 0,
		PlayerKeys.HP: hp_max,
		PlayerKeys.SANITY: sanity_max,
		PlayerKeys.HP_MAX: hp_max,
		PlayerKeys.SANITY_MAX: sanity_max,
		PlayerKeys.CLUES: _starting_token_count(investigator, "clue"),
		PlayerKeys.CLUE_IDS: [],  # идентичности добираются из пула при сверке (broadcast_sync)
		PlayerKeys.CONDITIONS: [],
		PlayerKeys.CONDITIONS_FLIPPED: {},  # {cond_id: outcome_id} — перевёрнутые в расплату
		PlayerKeys.CONDITIONS_BACKS: {},  # {cond_id: back_id} — какая копия карты на руках (ConditionFlow.reconcile_backs)
		PlayerKeys.ITEMS: _starting_items(investigator),
		PlayerKeys.SKILL_MODS: {},
	}


# Стартовые карты-активы сыщика из investigators.json → в инвентарь. Токены
# (clue/focus и т.п.) пропускаем — это не карты. Формат item — инстанс
# {id, exhausted}: exhausted нужен для oncePerRound-активаций (рефреш в начале
# раунда). entry_id/deck_for_items понимают и инстанс, и старую id-строку.
func _starting_items(investigator: String) -> Array:
	var out: Array = []
	var si: Array = Investigators.get_data(investigator).get("startingItems", [])
	for entry: Variant in si:
		# Стартовое заклинание: {"spell": id} → карта-заклинание {id, kind:"spell"}
		# (как gainSpell). Сыщики-маги EH начинают игру с заклинания.
		if entry is Dictionary and (entry as Dictionary).has("spell"):
			var sid: String = String((entry as Dictionary)["spell"])
			if SpellCatalog.is_spell(sid):
				out.append({"id": sid, "kind": "spell"})
			continue
		var aid: String = AssetCatalog.entry_id(entry)
		if not aid.is_empty() and not AssetCatalog.by_id(aid).is_empty():
			out.append({"id": aid, "exhausted": false})
	return out


# Стартовые ЖЕТОНЫ сыщика (напр. {"clue": 1}) из startingItems — суммой. Личные
# жетоны игрока, не карты (карты берёт _starting_items).
func _starting_token_count(investigator: String, key: String) -> int:
	var n: int = 0
	for entry: Variant in Investigators.get_data(investigator).get("startingItems", []):
		if entry is Dictionary and (entry as Dictionary).has(key):
			n += int((entry as Dictionary)[key])
	return n


# Стартовые билеты сыщика: startingTickets = {"train": N, "ship": M}.
func _starting_ticket_count(investigator: String, key: String) -> int:
	var t: Dictionary = Investigators.get_data(investigator).get("startingTickets", {})
	return int(t.get(key, 0))


# ── Хост: запуск игры ────────────────────────────────────────────────────────


## Вызывается хостом после нажатия «Начать игру».
## players_init: [{ pid, user_id, name, investigator, hp_max, sanity_max }, ...]
func start_game(players_init: Array) -> void:
	if not is_host():
		return

	players.clear()
	turn_order.clear()
	encounter_discard.clear()  # сброс встреч — на партию
	current_encounter = {}
	pending_spell_cast = {}
	last_cast_result = {}
	reckoning_results = {}
	reckoning_active = false
	# campaign / campaign_pending НЕ сбрасываем — библия могла быть прогрета
	# заранее в лобби (prewarm_campaign). Сброс прошлой игры — reset_pregame().
	for p: Dictionary in players_init:
		var pid: String = p.get("pid", "")
		if pid.is_empty():
			continue
		# Ключ слота — стабильный user_id; для анонима фолбэк на id соединения.
		var uid: String = String(p.get("user_id", ""))
		if uid.is_empty():
			uid = pid
		var start_loc: String = String(
			Investigators.get_data(String(p.get("investigator", ""))).get("startingLocation", "")
		)
		players[uid] = _make_player_dict(
			uid,
			String(p.get("name", "???")),
			String(p.get("investigator", "")),
			start_loc,
			int(p.get("hp_max", 5)),
			int(p.get("sanity_max", 5)),
		)
		turn_order.append(uid)
	turn_order.sort()

	round_num = 1
	phase = Phases.ACTION
	current_idx = 0
	doom = 0
	omens_step = 0
	active = true

	GameConsole.log(
		"[Game] Игра начата · игроков: %d · ход: %s" % [turn_order.size(), name_of(current_pid())]
	)
	# Библия: прогрета в лобби — используем готовую (или дождёмся текущей
	# генерации); не прогрета — запускаем генерацию сейчас (фолбэк).
	if campaign.is_empty() and not campaign_pending:
		_campaign.start_generation(_campaign.balance_player_count(), "")
	# Раскладку и Наплыв считаем по РАЗМЕРУ КОМНАТЫ (на сколько создали), а не по
	# числу подключённых. campaign.playerCount уже = размер комнаты; фолбэк (если
	# библия ещё не готова) — тот же авторитет из CampaignGen. Соло-тест партии на
	# N раскладывает поле и задаёт Наплыв как на N.
	var setup_pc: int = int(campaign.get("playerCount", _campaign.balance_player_count()))
	_board.reset_clue_deck()  # свежий пул улик Древнего перед раскладкой (соберётся лениво из campaign)
	_board.setup_board(maxi(1, setup_pc))  # стартовая раскладка: врата+монстры, улики, Наплыв
	_spell.reset_deck()  # колода копий заклинаний; стартовым заклинаниям сыщиков — рубашки
	_mystery.apply_mystery_on_enter()  # onEnter первой Тайны (если библия уже готова; иначе при её приходе)
	broadcast_sync()
	emit_changed()
	phase_changed.emit(phase)


# ── Хост: обработка действия (своего или чужого через game_action) ──────────


## Единая точка входа host-авторитетных команд ОТ ЛИЦА локального игрока (UI зовёт
## её напрямую: GameState.act(RelayActions.FINISH_ENCOUNTER)). Хост применяет через
## тот же реестр RelayRouter, которым принимает чужие relay-сообщения; клиент шлёт
## хосту ровно то же сообщение. Одна реализация на оба пути: раньше у каждой команды
## было по два тела (host-ветка и relay-ветка), и они разъезжались.
## payload — поля сообщения кроме action/pid (die, index, kind, …), см. адаптеры
## RelayRouter. Транзиентные широковещалки (chat/feed) сюда не ходят.
func act(action: String, payload: Dictionary = {}) -> void:
	if not _relay_actions.has(action):
		push_error("[GameState] act: неизвестное relay-действие «%s»" % action)
		return
	var msg: Dictionary = payload.duplicate()
	msg["action"] = action
	msg["pid"] = _nm.my_user_id
	if is_host():
		(_relay_actions[action] as Callable).call(msg)
	else:
		_nm.relay_all(msg)


## Игровое действие фазы действий (travel/rest/acquire_assets/…). Сахар над act().
func perform_action(action_type: String, payload: Dictionary = {}) -> void:
	act(RelayActions.ACTION, {"type": action_type, "payload": payload})


## Применим ли боевой триггер карты (on:combatEncounter, напр. Handcuffs) ПРЯМО
## СЕЙЧАС — для веера: показать карту играбельной, хотя у неё нет check-mod. Read-only.
func combat_trigger_ready(item_index: int) -> bool:
	var me: String = _nm.my_user_id
	return (
		not _encounter.combat.trigger_node_ready(me, item_index).is_empty()
		or not _encounter.prevent_loss_node_ready(me, item_index).is_empty()
	)


## Играется ли МОЯ карта как самостоятельное действие ПРЯМО СЕЙЧАС — для веера.
## Read-only, считается и на клиенте: цели (монстры на поле) синкаются.
func can_play_asset(item_index: int) -> bool:
	return _asset_action.can_play(_nm.my_user_id, item_index)


## UI: каст заклинания из веера. Ritual → действие cast_spell (тратит действие,
## обычный action-роутинг); Glamour/Incantation → контекстный каст (CAST_GLAMOUR /
## CAST_INCANTATION), без траты действия.
func cast_spell(item_index: int) -> void:
	var items: Array = my_player().get("items", [])
	if item_index < 0 or item_index >= items.size():
		return
	var spell: Dictionary = SpellCatalog.by_id(AssetCatalog.entry_id(items[item_index]))
	if spell.is_empty():
		return
	var subtype: String = String(spell.get("subtype", ""))
	if subtype == "ritual":
		perform_action(GameActions.CAST_SPELL, {"item": item_index})
		return
	# Glamour (exhaust): начинаем spell-проверку (модалка), игрок бросает и применяет.
	# Аура применяется отдельно (тап по glamour во время чужой проверки →
	# ACTIVATE_CARD, см. world_map). Incantation — вложенная проверка поверх боя.
	var relay: String = (
		RelayActions.CAST_GLAMOUR if subtype == "glamour" else RelayActions.CAST_INCANTATION
	)
	act(relay, {"index": item_index})


## Хост: разрешить ожидающую проверку — прочитать passed и диспетчить в драйвер по
## pending_check.driver. Драйвер сам пишет decisions[path]=passed и ПЕРЕИГРЫВАЕТ свою
## программу: если та снова пендит чек — драйвер выставит новые pending_check/active_check;
## если завершилась — драйвер их очистит и освободит ход. Поэтому здесь НЕ чистим стейт.
func resolve_pending_check_host(pid: String) -> bool:
	var pc: Dictionary = pending_check
	if pc.is_empty() or String(pc.get("pid", "")) != pid:
		return false
	var c: Dictionary = active_check
	if String(c.get("owner", "")) != "effectCheck":
		return false
	if not bool(c.get("rolled", false)):
		_check.roll(pid)  # страховка: применить без явного броска
		c = active_check
	var passed: bool = bool(c.get("passed", false))
	var path: String = String(pc.get("path", ""))
	match String(pc.get("driver", "")):
		"condition":
			_cond.resolve_action_check(pid, path, passed)
		"asset":
			_asset_action.resolve_check(pid, path, passed)
		"encounter":
			_encounter.resolve_encounter_check(pid, path, passed)
		"mythos":
			# Корутина forEach-Мифов: будим ожидающую её результатом; она сама чистит
			# pending_check/active_check и переигрывает свою программу.
			effect_check_applied.emit(pid, passed)
		_:
			push_warning("[GameState] resolve_pending_check: неизвестный driver %s" % pc)
			pending_check = {}
			_check.clear()
	return true


# ── Параллельная Расплата: per-player проверка в players[pid].reckoning_check ──


# Слот проверки Расплаты игрока (players[pid].reckoning_check) — {} если нет.
func reckoning_slot(pid: String) -> Dictionary:
	return (players.get(pid, {}) as Dictionary).get("reckoning_check", {})


## Хост: применить проверку Расплаты игрока — прочитать passed и разбудить его корутину
## (она чистит per-player слоты и переигрывает программу состояния).
func reckoning_apply_host(pid: String) -> bool:
	var c: Dictionary = reckoning_slot(pid)
	if c.is_empty():
		return false
	if not bool(c.get("rolled", false)):
		_check.roll(pid, c)  # страховка: применить без явного броска
		c = reckoning_slot(pid)
	effect_check_applied.emit(pid, bool(c.get("passed", false)))
	return true


# ── Чат (Dark Souls-style): транзиентный broadcast, НЕ часть snapshot ──────────


## Отправить сообщение чата (шаблон + выбранные слова). Реле шлёт всем КРОМЕ отправителя
## (обычный relay исключает self), поэтому СВОЁ облачко просто рисуем локально тут же
## (chat_received → map_layer). Текст не шлём: каждый клиент рендерит по id на своём языке.
func send_chat(phrase_id: String, noun_ids: Array) -> void:
	var now: int = Time.get_ticks_msec()
	if now - _chat_last_ms < CHAT_COOLDOWN_MS:
		return
	_chat_last_ms = now
	var nouns: Array = (noun_ids as Array).slice(0, 2)
	var my_pid: String = _nm.my_user_id
	_nm.relay_all(
		{"action": RelayActions.CHAT, "pid": my_pid, "phrase_id": phrase_id, "noun_ids": nouns}
	)
	chat_received.emit(my_pid, phrase_id, nouns)  # своё — рисуем локально (реле его не вернёт)


## Транзиентная «лента действий»: над фишкой действующего игрока (pid) у ВСЕХ всплывает
## облачко с литературным описанием действия (ActionLog). НЕ часть snapshot. Зовётся ТОЛЬКО
## хостом после коммита действия (host_apply_action / encounter_flow). Реле шлёт всем КРОМЕ
## хоста-отправителя, поэтому хост ещё и локально эмитит (как send_chat). params —
## {placeholder: i18n-ключ}; каждый клиент сам tr() в своей локали.
func announce_action(pid: String, action_id: String, params: Dictionary = {}) -> void:
	if not is_host() or pid.is_empty() or action_id.is_empty():
		return
	_nm.relay_all(
		{"action": RelayActions.ACTION_FEED, "pid": pid, "id": action_id, "params": params}
	)
	action_announced.emit(pid, action_id, params)  # своё — рисуем локально (реле его не вернёт)


# Лента исходов эффектов (урон/лечение/состояния/жетоны) вынесена в ActionFeed
# (static), чтобы не раздувать публичный API GameState. Flow зовут её напрямую:
# ActionFeed.announce_deltas(self, pid, before, after).


# Хост: очистить результат каста, если его закрыл владелец (pid совпал).
func host_dismiss_cast_result(pid: String) -> void:
	if String(last_cast_result.get("pid", "")) != pid:
		return
	last_cast_result = {}
	broadcast_sync()
	emit_changed()


# Хост: стереть сводку приобретений игрока (по закрытию модалки).
func host_dismiss_gains(pid: String) -> void:
	if not players.has(pid):
		return
	var p: Dictionary = players[pid]
	if not p.has("gains"):
		return
	p.erase("gains")
	broadcast_and_emit()


# Хост: убрать запись результата флипа игрока (по закрытию модалки).
func host_dismiss_reckoning(pid: String) -> void:
	if not reckoning_results.has(pid):
		return
	reckoning_results.erase(pid)
	broadcast_sync()
	emit_changed()


## Доступно ли спец-действие сыщика: мой ход, есть действие, в раунде ещё не
## использовал, и у сыщика вообще есть способность (data/investigators.json).
func can_use_ability() -> bool:
	if not is_my_turn():
		return false
	var me: Dictionary = my_player()
	if int(me.get(PlayerKeys.ACTIONS_LEFT, 0)) <= 0:
		return false
	if (me.get(PlayerKeys.ACTIONS_USED, []) as Array).has(GameActions.INVESTIGATOR_ABILITY):
		return false
	var inv: String = String(me.get("investigator", ""))
	if not Investigators.has_ability(inv):
		return false
	# Встроенные виды могут быть неприменимы прямо сейчас — иначе кнопка активна,
	# а нажатие молча ничего не делает (полное здоровье И рассудок у Мэй Линь).
	match Investigators.ability_kind(inv):
		"convertVitality":
			return _convert_vitality_max(me) > 0
	return true


## Максимум, который сейчас можно перелить в ЛЮБУЮ сторону (0 — способность
## неприменима). Источник не опускаем ниже 1, приёмник — не выше максимума.
func _convert_vitality_max(me: Dictionary) -> int:
	var hp: int = int(me.get(PlayerKeys.HP, 0))
	var san: int = int(me.get(PlayerKeys.SANITY, 0))
	var hp_room: int = maxi(0, int(me.get("hp_max", 0)) - hp)
	var san_room: int = maxi(0, int(me.get("sanity_max", 0)) - san)
	return maxi(mini(maxi(0, hp - 1), san_room), mini(maxi(0, san - 1), hp_room))


# Может ли локальный игрок переместиться в dest прямо сейчас: мой ход в action-фазе,
# есть действие, travel в этом раунде не израсходован, дорога есть (PhaseController).
func _can_travel_to(dest: String) -> bool:
	if not is_my_turn():
		return false
	var me: Dictionary = my_player()
	if int(me.get("actions_left", 0)) <= 0:
		return false
	var used: Array = me.get("actions_used", [])
	if used.has(GameActions.TRAVEL):
		return false
	return _phase.can_travel(_nm.my_user_id, dest)


## Стоимость перемещения локального игрока в dest: {train, ship, path} либо {},
## если недостижим / не мой ход. Для сайдбара — показать маршрут и «потратить …».
func travel_cost_to(dest: String) -> Dictionary:
	if not _can_travel_to(dest):
		return {}
	var me: Dictionary = my_player()
	return TravelPlanner.cost_to(
		map.all(),
		String(me.get("location", "")),
		dest,
		int(me.get("train_tickets", 0)),
		int(me.get("ship_tickets", 0))
	)


# ── Магазин (фасады) ──────────────────────────────────────────────────────────


## Доступен ли магазин: мой ход, город, мой сыщик там, есть действие и покупка
## («acquire_assets») ещё не сделана в этом раунде (уникальное действие — раз за раунд).
func can_shop(loc_id: String) -> bool:
	if loc_id.is_empty() or not is_my_turn():
		return false
	var me: Dictionary = my_player()
	if int(me.get("actions_left", 0)) <= 0:
		return false
	if (me.get("actions_used", []) as Array).has(GameActions.ACQUIRE_ASSETS):
		return false
	if not map.is_city(loc_id):
		return false
	return String(me.get("location", "")) == loc_id


## Можно ли купить билет в loc_id прямо сейчас (для кнопок сайдбара). Условия как у
## магазина: мой ход, мой текущий город, есть действие, buy_ticket ещё не сделан в
## этом раунде. Конкретные типы билетов — map.ticket_types(loc_id).
func can_buy_ticket(loc_id: String) -> bool:
	if loc_id.is_empty() or not is_my_turn():
		return false
	var me: Dictionary = my_player()
	if int(me.get("actions_left", 0)) <= 0:
		return false
	if (me.get("actions_used", []) as Array).has(GameActions.BUY_TICKET):
		return false
	if String(me.get("location", "")) != loc_id:
		return false
	# Потолок: на руках максимум MAX_TICKETS билетов (ж/д + корабль).
	if int(me.get("train_tickets", 0)) + int(me.get("ship_tickets", 0)) >= MAX_TICKETS:
		return false
	return not map.ticket_types(loc_id).is_empty()


## Сброс активов для UI запаса (выводится, не хранится). Делегат ShopReserve.
func asset_discard_ids() -> Array:
	return _shop.discard_ids()


## Дотянуть витрину магазина, если она пуста (партии до появления резерва). Делегат.
func ensure_shop_reserve() -> void:
	_shop.ensure()


## Карты-Слухи (Ongoing Rumor), что сейчас в игре — для UI (сайдбар Тайны). Каждая
## несёт tokens (таймер) и rumorLocation (портал). [] — слухов нет.
func rumors_in_play() -> Array:
	var out: Array = []
	for c_v: Variant in mythos_in_play:
		if _rumor.is_rumor(c_v as Dictionary):
			out.append(c_v)
	return out


# ── Уход игрока ──────────────────────────────────────────────────────────────


# Игрок отключился (закрыл клиент, потерял связь, вышел кнопкой).
# Слот НЕ удаляется и НЕ выбывает из turn_order — игрок помечается
# отключённым и при повторном входе возвращается в тот же слот. Только хост
# двигает стейт и рассылает sync.
func _on_player_left(player_id: String, _new_host_id: String, user_id: String) -> void:
	if not active or not is_host():
		return
	# Мог только что стать хостом (старый хост вышел): host-only колода Мифов у
	# нас пуста — восстанавливаем, иначе следующая вытяжка Мифов выпадет в заглушку.
	_ensure_mythos_deck()
	# Ключ слота — стабильный user_id; аноним → фолбэк на id соединения.
	var uid: String = user_id
	if uid.is_empty():
		uid = player_id
	if not players.has(uid):
		return

	players[uid]["connected"] = false
	GameConsole.log("[Game] %s отключился — слот сохранён до возвращения" % name_of(uid))

	# Если отвалился сыщик, чьего выбора ждёт модалка решения (миф или программа
	# актива) — выбираем за него сами, иначе фаза зависнет навсегда. Случайно, а не
	# первой опцией: см. host_apply_absent_decision.
	if bool(mythos_decision.get("active", false)) and String(mythos_decision.get("pid", "")) == uid:
		_phase.host_apply_absent_decision(uid)

	# Если ждали «Прочитал» этого сыщика на открытой карте мифа, а остальные уже
	# отметились — резолвим карту (иначе миф зависнет в ожидании ушедшего).
	_mythos.on_player_left()

	# Если отвалился сыщик, чьей видимой проверки ждёт корутина (Расплата или
	# mythos-driver test) — будим её «провалом». Сама парковка после пробуждения
	# видит connected=false и мгновенно дренирует остаток карт, не зависая.
	# Именно провал, а не бросок за него: решение по игре — партия должна быть
	# тяжёлой, и уход не даёт шанса выкрутиться. Выбор из вариантов — другое дело,
	# там берём случайный (host_apply_absent_decision).
	var awaiting_check: bool = (
		String(pending_check.get("pid", "")) == uid
		or players[uid].has("reckoning_pending")
		or players[uid].has("reckoning_check")
	)
	if awaiting_check:
		effect_check_applied.emit(uid, false)

	# Если отключился игрок, чей сейчас ход — пропускаем его, иначе партия
	# застрянет на «ходит несуществующий игрок».
	if current_pid() == uid:
		if phase == Phases.ACTION:
			_phase.advance_action_turn()
		elif phase == Phases.ENCOUNTER:
			_phase.advance_encounter_turn()

	broadcast_sync()
	emit_changed()


# Игрок (пере)подключился к комнате. Хост возвращает прежнего участника в его
# слот, а нового игрока с уже выбранным сыщиком — подключает к идущей партии.
func _on_player_connected(pid: String, info: Dictionary) -> void:
	if not active or not is_host():
		return
	var uid: String = String(info.get("user_id", ""))
	if uid.is_empty():
		uid = pid
	if players.has(uid):
		if not bool(players[uid].get("connected", true)):
			players[uid]["connected"] = true
			GameConsole.log("[Game] %s вернулся в игру" % name_of(uid))
			broadcast_sync()
			emit_changed()
		return
	# Новый участник: сыщик уже выбран (relay восстановил из БД) — подключаем
	# сразу; иначе ждём set_ready после выбора в лобби (handle_late_join).
	var inv: String = String(info.get("investigator", ""))
	if not inv.is_empty():
		_add_player_mid_game(uid, String(info.get("name", "???")), inv)


## Хост: подключить позднего игрока по его set_ready (выбор сыщика в лобби
## уже идущей партии). user_id и имя берём из живого списка NetworkManager.
func handle_late_join(data: Dictionary) -> void:
	var conn_id: String = String(data.get("player_id", ""))
	var inv: String = String(data.get("investigator", ""))
	if conn_id.is_empty() or inv.is_empty():
		return
	var uid: String = conn_id
	var pname: String = conn_id
	var lobby: Dictionary = _nm.players
	if lobby.has(conn_id):
		var rec: Dictionary = lobby[conn_id]
		var u: String = String(rec.get("user_id", ""))
		if not u.is_empty():
			uid = u
		pname = String(rec.get("name", conn_id))
	if players.has(uid):
		return  # уже участник — обычный set_ready, не поздний вход
	_add_player_mid_game(uid, pname, inv)


## Хост: добавить нового игрока в идущую партию. Слот ставится в конец
## turn_order — поздний игрок получает ход в текущем же раунде после остальных.
func _add_player_mid_game(uid: String, pname: String, investigator: String) -> void:
	if uid.is_empty() or investigator.is_empty() or players.has(uid):
		return
	# Страховка от дубликата сыщика на позднем входе (клиентский пикер уже не даёт
	# выбрать занятого — это защита от гонки/обхода): второго с тем же сыщиком не
	# заводим. Игрок остаётся в лобби-пикере и выберет свободного.
	for other_uid: String in players:
		if String(players[other_uid].get("investigator", "")) == investigator:
			GameConsole.warn(
				"[Game] Сыщик %s занят — поздний вход %s отклонён" % [investigator, pname]
			)
			return
	var inv: Dictionary = Investigators.get_data(investigator)
	var hp_max: int = int(inv.get("health", 5))
	var san_max: int = int(inv.get("sanity", 5))
	players[uid] = _make_player_dict(
		uid,
		pname,
		investigator,
		String(inv.get("startingLocation", "")),
		hp_max,
		san_max,
	)
	turn_order.append(uid)
	_spell.assign_backs(uid)  # стартовому заклинанию — копия из колоды
	GameConsole.log("[Game] %s присоединился к партии (игроков: %d)" % [pname, turn_order.size()])
	broadcast_sync()
	emit_changed()


# ── Применить снапшот (от хоста через relay ИЛИ от сервера через joined_room) ─


func _apply_snapshot(data: Dictionary) -> void:
	# Восстанавливаем поля из _SYNC_FIELDS: set() коэрсит под тип переменной
	# (JSON-число float → int-поле и т.п.); отсутствующий ключ → оставляем текущее.
	for f: String in _SYNC_FIELDS:
		set(f, data.get(f, get(f)))
	_mythos.index = int(data.get("mythos_index", 0))
	emit_changed()
	phase_changed.emit(phase)

	# Хост реджойнулся в фазу встреч, а карта в снапшоте — пустая (хост ушёл
	# в момент await api.draw_encounter, снапшот сохранился в loading-
	# состоянии). Без перезапуска генерации модалка зависнет на «загрузке».
	# call_deferred — чтобы не дёргать сеть из коллбэка снапшота.
	if is_host() and active and phase == Phases.ENCOUNTER and current_encounter.is_empty():
		GameConsole.log("[Game] Реджойн в фазу встреч с пустой картой — перегенерируем")
		_encounter.generate.call_deferred()

	# Реджойн хоста: колода Мифов — host-only, в снапшот не попадает. При
	# перезапуске процесса колода теряется → следующая вытяжка выпала бы в
	# заглушку. Индекс уже подтянулся из snapshot выше; колоду восстанавливаем.
	_ensure_mythos_deck()


# Host-only колода Мифов не входит в снапшот. Восстанавливаем её по campaign.id из
# relay-API, когда мы хост, партия активна, а колода пуста. Срабатывает и при
# реджойне хоста (перезапуск процесса, см. _apply_snapshot), и при промоушене
# не-хоста в хосты (старый хост вышел, см. _on_player_left) — у свежего хоста
# колоды никогда не было. Гард по пустой колоде делает вызов идемпотентным.
func _ensure_mythos_deck() -> void:
	if not (is_host() and active and _mythos.deck.is_empty() and not campaign.is_empty()):
		return
	var camp_id: String = String(campaign.get("id", ""))
	if not camp_id.is_empty():
		_mythos.restore_deck.call_deferred(camp_id)


# ── Не-хост: приём от relay ──────────────────────────────────────────────────


# user_id отправителя по его id соединения (from_id, проставлен relay-сервером).
# Аноним → сам from_id (тот же фолбэк, что при заведении слота игрока).
func _sender_uid(from_id: String) -> String:
	if is_instance_valid(_nm) and _nm.players.has(from_id):
		var u: String = String(_nm.players[from_id].get("user_id", ""))
		if not u.is_empty():
			return u
	return from_id


# ── Реестр host-авторитетных relay-действий ───────────────────────────────────
# Каждый _act_* — адаптер (data) → host-логика, перенесённая дословно из ветки
# match. Диспетчер (_on_relay_received) зовёт _relay_actions[action].call(data) под
# гардом is_host(). Транзиентные широковещалки (game_sync/game_chat/game_action_
# feed) — НЕ здесь: у них клиентская логика (рендер у всех), см. match.


func broadcast_and_emit() -> void:
	broadcast_sync()
	emit_changed()


func _build_action_registry() -> void:
	_relay_router = RelayRouter.new()
	_relay_router.setup(self, _phase, _encounter, _spell, _check, _mythos, _death)
	_relay_actions = _relay_router.build_registry()

	# pid-владельческие = все действия реестра, КРОМЕ безадресных: RESOLVE_MYTHOS
	# (без pid) и SET_READY (по connection id). Для остальных _on_relay_received сверяет
	# pid с отправителем. Выводим из реестра — отдельный список не нужен.
	for a: Variant in _relay_actions:
		if a != RelayActions.RESOLVE_MYTHOS and a != RelayActions.SET_READY:
			_pid_owned[String(a)] = true


func _on_relay_received(from_id: String, data: Dictionary) -> void:
	var action: String = String(data.get("action", ""))

	# Граница доверия. from_id проставляет relay-сервер (id соединения отправителя)
	# — ему верим, содержимому data.pid — нет. Для действий «от лица игрока» pid
	# обязан совпасть с user_id отправителя. Проверяем только когда from_id известен
	# (сервер его проставил) — иначе не ломаем игру на старом relay без from_id.
	if not from_id.is_empty() and _pid_owned.has(action):
		var claimed: String = String(data.get("pid", ""))
		var sender: String = _sender_uid(from_id)
		if claimed != sender:
			GameConsole.warn(
				"[Game] Отклонено %s: pid=%s ≠ отправитель=%s" % [action, claimed, sender]
			)
			return

	# Host-авторитетные действия — через реестр (host-only): диспетчер вместо ~28
	# веток match. Логика — в модулях (host_apply_*), не менялась. Не-хост сюда
	# доходит, но Callable не зовётся (валидирует и применяет только хост).
	if _relay_actions.has(action):
		if is_host():
			(_relay_actions[action] as Callable).call(data)
		return

	# Транзиентные широковещалки — рендерятся у ВСЕХ клиентов (не host-only).
	match action:
		RelayActions.SYNC:
			# Хост прислал полный стейт — применяем тем же путём, что снапшот
			# с сервера (joined_room.game_state). Хост авторитетен и НИКОГДА не
			# перезаписывает себя чужим снапшотом; не-хост принимает sync только
			# от текущего хоста (если его id известен — см. NetworkManager._host_id).
			if is_host():
				return
			var host_id: String = _nm.host_id() if is_instance_valid(_nm) else ""
			if not host_id.is_empty() and not from_id.is_empty() and from_id != host_id:
				GameConsole.warn("[Game] Отклонён game_sync не от хоста (%s)" % from_id)
				return
			_apply_snapshot(data)

		RelayActions.CHAT:
			# Транзиентный чат: каждый клиент (вкл. отправителя) рендерит локально. Не
			# host-only, не в snapshot — просто эмитим сигнал для облачка над фишкой.
			var c_pid: String = String(data.get("pid", ""))
			var c_phrase: String = String(data.get("phrase_id", ""))
			# Чат идёт от лица c_pid — не даём писать за другого (спуфинг облачка).
			if not from_id.is_empty() and c_pid != _sender_uid(from_id):
				return
			if not c_pid.is_empty() and not Messages.phrase(c_phrase).is_empty():
				chat_received.emit(c_pid, c_phrase, (data.get("noun_ids", []) as Array).slice(0, 2))

		RelayActions.ACTION_FEED:
			# Транзиентная лента действий: рассылает хост, рендерим локально по id (как
			# game_chat). Не в snapshot. params — плейсхолдер→i18n-ключ (клиент сам tr()).
			var f_pid: String = String(data.get("pid", ""))
			var f_id: String = String(data.get("id", ""))
			if not f_pid.is_empty() and not ActionLog.entry(f_id).is_empty():
				var f_params: Variant = data.get("params", {})
				action_announced.emit(f_pid, f_id, f_params if f_params is Dictionary else {})


# ── Сервисное ────────────────────────────────────────────────────────────────


func current_pid() -> String:
	if current_idx < 0 or current_idx >= turn_order.size():
		return ""
	return turn_order[current_idx]


func name_of(pid: String) -> String:
	if players.has(pid):
		return players[pid].get("name", pid)
	return pid


## Узнать, мой ли ход сейчас (только для phase=action).
func is_my_turn() -> bool:
	if bool(my_player().get(PlayerKeys.DEAD, false)):
		return false  # Тень обычный ход не берёт (страховка к пропуску в phase_controller)
	return active and phase == Phases.ACTION and current_pid() == _nm.my_user_id


## Публичный доступ к held-ограничению игрока (whileHeld: removeFromBoard/cannotAct/…).
## Для UI — вместо лазанья в приватный _cond.
func player_has_constraint(pid: String, verb: String) -> bool:
	return _cond.player_has_constraint(pid, verb)


# ── Debug (только dev-сборка + хост) ──────────────────────────────────────────
# Единая точка для GameConsole. Разбор команд/резолв id — на стороне консоли, сюда
# приходит op + готовые id. Мутации (DebugGrant) идут ТЕМ ЖЕ хост-путём, что геймплей,
# и синкают всем; гейт двойной (релиз ИЛИ не-хост → no-op). op: mypid | give_asset |
# give_spell | clue | spawn | gate | condition | encounter.
func debug_exec(op: String, a: String = "", b: String = "", c: String = "") -> String:
	if op == "mypid":
		return _nm.my_user_id
	if not (OS.is_debug_build() and is_host()):
		return "debug-выдача только на хосте (dev-сборка)"
	match op:
		"give_asset":
			return DebugGrant.give_asset(self, a, b)
		"give_spell":
			return DebugGrant.give_spell(self, a, b)
		"spawn":  # a=локация, b=монстр
			return DebugGrant.spawn_monster(self, a, b)
		"gate":  # a=локация, b=цвет
			return DebugGrant.open_gate(self, a, b)
		"condition":
			return DebugGrant.gain_condition(self, a, b)
		"clue":  # a=игрок, b=локация ("" — анонимные), c=число
			return DebugGrant.give_clue(self, a, b, maxi(1, int(c)))
		"encounter":  # a=игрок, b=вид, c=мир (для gate)
			return DebugGrant.assign_encounter(self, a, b, c)
		_:
			return "неизвестная debug-операция «%s»" % op


## Узнать, моя ли очередь на встречу (только для phase=encounter).
## Встречи проходят последовательно по turn_order.
func is_my_encounter_turn() -> bool:
	return (
		active
		and phase == Phases.ENCOUNTER
		and current_pid() == _nm.my_user_id
		and not _have_finished_encounter()
	)


# Я ли уже завершил встречу (только для phase=encounter).
func _have_finished_encounter() -> bool:
	if not players.has(_nm.my_user_id):
		return false
	return bool(players[_nm.my_user_id].get("encounter_done", false))


## Мой собственный user_id ("" если сеть ещё не готова). Имя local_pid, а не my_pid:
## в классе уже куча локальных `var my_pid` — одноимённый метод их затенял (ворнинг).
func local_pid() -> String:
	return _nm.my_user_id if is_instance_valid(_nm) else ""


## Получить мои собственные данные (или пустой словарь, если не в игре).
func my_player() -> Dictionary:
	return players.get(_nm.my_user_id, {})


# ── Helpers, общие для подмодулей ─────────────────────────────────────────────


## Определение монстра с учётом листа Древнего партии: культист (useAncientOne)
## берёт статы и Расплату из campaign.ancientOne.cultist. Единая точка для боя,
## спауна, списка целей, Расплаты монстров и UI — иначе шкалы разъезжаются.
func monster_def(mid: String) -> Dictionary:
	return MonsterCatalog.resolve(MonsterCatalog.by_id(mid), campaign.get("ancientOne", {}))


## Текущий язык игры названием для relay ("Russian" / "English"). Используется
## EncounterFlow и CampaignGen в теле запроса к ContentApi.
func relay_language() -> String:
	if I18n.get_locale() == "en":
		return "English"
	return "Russian"


## Эффекты уровня поля (advanceDoom и т.п.) — интерпретатор их не трогает,
## применяются здесь, потому что меняют синкаемые поля GameState (doom,
## omens_step). Зовётся из EncounterFlow и MythosFlow.
func apply_board_effect(node: Dictionary) -> void:
	var verb: String = String(node.get("do", ""))
	# Адресные эффекты (target lead/each/eachOn*/chosenInvestigator) и передачи
	# активов/улик — применяются к разрешённым сыщикам, а не к доске.
	if _target.is_targeted_effect(node):
		_target.apply_targeted_effect(node)
		return
	# Повтор уровня поля (repeat по источнику разрешён интерпретатором в _times).
	var times: int = maxi(1, int(node.get("_times", 1)))
	for _t in range(times):
		_board.apply_verb(node, verb)


## Выдать артефакт сыщику. Пустой id — случайный из доступных, `want_trait` сужает
## («Получите 1 Книгу-артефакт»).
##
## Артефакт УНИКАЛЕН: копия одна на партию. Поэтому исключаем занятые по ВСЕМУ
## столу, а не только по рукам получателя, — иначе двое сыщиков носили бы один
## «Некрономикон». Свободных не осталось → тихо ничего, как у пустой колоды.
func grant_artifact(pid: String, artifact_id: String = "", want_trait: String = "") -> void:
	if not is_host() or not players.has(pid):
		return
	var taken: Dictionary = {}
	for p_v: Variant in players.values():
		for it_v: Variant in (p_v as Dictionary).get("items", []):
			taken[AssetCatalog.entry_id(it_v)] = true
	var aid: String = artifact_id
	if aid.is_empty():
		aid = ArtifactCatalog.pick_free(taken, want_trait)
		if aid.is_empty():
			GameConsole.log("[Артефакт] свободных не осталось")
			return
	elif taken.has(aid) or not ArtifactCatalog.has(aid):
		GameConsole.log("[Артефакт] «%s» недоступен" % aid)
		return
	var p: Dictionary = players[pid]
	var items: Array = p.get("items", [])
	items.append({"id": aid, "kind": "artifact", "exhausted": false})
	p["items"] = items
	GameConsole.log("[Артефакт] %s получил «%s»" % [name_of(pid), aid])


# ── Сценарная библия (фасады в CampaignGen) ───────────────────────────────────


## Модалка создания комнаты задаёт «зерно» будущей кампании. Делегат.
func set_campaign_seed(ancient_one: String, player_count: int) -> void:
	_campaign.set_seed(ancient_one, player_count)


## Хост: прогрев библии в лобби. Делегат.
func prewarm_campaign() -> void:
	_campaign.prewarm()


## Мистерия текущего акта ({} если кампания/тайны ещё не готовы) — для UI.
func current_mystery() -> Dictionary:
	return _campaign.current_mystery()


## Хост: сброс перед новой игрой. Зовётся из lobby при входе в свежее лобби —
## чтобы prewarm следующей игры не наткнулся на библию предыдущей и зависшую
## генерацию. Чистит собственный state GameState; campaign и мифос — через
## модули (там живут их «приватные» поля типа epoch/seed).
func reset_pregame() -> void:
	if not is_host():
		return
	_clear_pregame_fields()


## Полный сброс стейта при выходе из комнаты (ВСЕ клиенты, не host-only). В отличие
## от reset_pregame (готовит хост к сборке новой библии) чистит и players/turn_order/
## campaign — иначе рудимент прошлой партии всплывает в новом лобби (сыщик «занято»,
## стейл-Тень). Зовётся из main_menu._ready при возврате в меню.
func reset_session() -> void:
	_clear_pregame_fields()
	players.clear()
	turn_order.clear()
	current_idx = 0
	round_num = 0
	doom = 0
	omens_step = 0
	active_mystery = 0
	phase = ""
	campaign = {}
	campaign_pending = false
	_board.reset_clue_deck()  # чистит пул улик и вещи павших (наследство Теней)
	emit_changed()


# Общая часть reset_pregame/reset_session — обнуление игровых полей (без players).
func _clear_pregame_fields() -> void:
	_campaign.reset()
	current_encounter = {}
	active_check = {}
	_check.reset_stack()
	pending_spell_cast = {}
	casting_spell = {}
	pending_check = {}
	last_cast_result = {}
	reckoning_results = {}
	reckoning_active = false
	current_mythos = {}
	mythos_in_play = []
	mythos_decision = {}
	mythos_read = []
	last_mythos = {}
	_mythos.deck = []
	_mythos.index = 0
	gates = {}
	entities = {}
	monsters = {}
	monster_bag = []
	monster_surge = 0
	encounter_choices = []
	active = false
