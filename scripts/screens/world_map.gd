extends Node2D

# ── Константы ─────────────────────────────────────────────────────────────────

# Размер тайла карты — единственный источник правды в MapLayer.TILE_W/TILE_H.
# Здесь дублировать не надо: world_map двигает камеру по тем же координатам,
# что MapLayer рисует маркеры.

const ZOOM_MIN: float = 0.5
const ZOOM_MAX: float = 1.2
const ZOOM_STEP: float = 0.15
const ZOOM_SPEED: float = 12.0  # скорость интерполяции (выше = быстрее)

# ── Состояние перетаскивания ──────────────────────────────────────────────────

## Меньше этого числа экранных пикселей считаем за клик, не за драг.
const CLICK_THRESHOLD: float = 6.0

var _dragging: bool = false
var _drag_origin: Vector2 = Vector2.ZERO
var _cam_origin: Vector2 = Vector2.ZERO
var _drag_distance: float = 0.0

# ── Инерция (как в Google Maps) ──────────────────────────────────────────────

## Экспоненциальное затухание скорости. Выше = быстрее тормозит.
const INERTIA_FRICTION: float = 2.5
## Ниже этой скорости (world units/сек) — обнуляем инерцию.
const INERTIA_MIN_SPEED: float = 6.0
## Окно для расчёта flick-скорости. Берём delta между самым старым сэмплом
## в окне и последним — даже если в самом конце мышь замедлилась, флик-моментум
## сохраняется. То же делают touch UI на iOS/Android.
const FLICK_WINDOW_MS: int = 100

var _inertia_velocity: Vector2 = Vector2.ZERO  # world units/сек
# Кольцевые сэмплы (t_ms, screen_pos) последних мотион-эвентов в окне FLICK_WINDOW_MS.
var _drag_samples: Array = []

# ── Плавный зум ───────────────────────────────────────────────────────────────

var _zoom_target: float = 0.5

# Локации с вратами/уликами на прошлом синке — чтобы ловить ТОЛЬКО что
# появившиеся и панорамировать на них. *_seen: первый рефреш (старт/вход)
# не анимируем — только запоминаем. Фокус-очередь общая для врат и улик, чтобы
# панорамирования не накладывались.
var _known_gate_locs: Dictionary = {}
var _known_clue_locs: Dictionary = {}
var _gates_seen: bool = false
var _clues_seen: bool = false
var _focus_queue: Array = []  # [{ "loc": String, "sound": AudioStream|null }]
var _focus_busy: bool = false

# Анимация перемещения сыщиков: где стояли на прошлом синке + флаг проигрывания.
var _inv_locs: Dictionary = {}  # {pid: loc_id}
var _inv_seen: bool = false  # первый рефреш — без анимации
var _travelling: bool = false  # идёт анимация перемещения (гард от ре-входа рефреша)

# ── Ноды ──────────────────────────────────────────────────────────────────────

@onready var _camera: Camera2D = $Camera2D
@onready var _game_panel: CanvasLayer = $GamePanel
@onready var _sidebar: CanvasLayer = $LocationSidebar
@onready var _mystery: CanvasLayer = $MysterySidebar

var _map_layer: MapLayer

# Веер карт руки (Tab). Наполняется реальным имуществом локального игрока.
var _hand_carousel: CanvasLayer = null

# Интро-гейт: блокирующая модалка-цепочка (загрузка → Древний → первая
# Тайна → карта), строится в коде.
var _campaign_gate: CanvasLayer = null
var _gate_vbox: VBoxContainer = null
var _intro_step: int = 0  # 0=загрузка 1=Древний 2=Тайна 3=готово
var _gate_rendered: int = -1  # последний отрисованный шаг
var _revealed_mystery: int = -1  # индекс Тайны, чей ревил уже показали


func _ready() -> void:
	# Игровая музыка — основной трек, общий для всех экранов, кроме выбора
	# сыщика (там picker сам ставит TRACK_NO_CHOICE). Придя из лобби, где
	# играл NO_CHOICE, MusicManager переключит трек обратно на основной.
	MusicManager.play(MusicManager.TRACK_ELDER_SIGN)

	# На карте мира декоративная рамка лишняя (карта — основная игровая сцена,
	# UI поверх неё в виде GamePanel/LocationSidebar). Возвращаем при выходе.
	ScreenFrame.set_enabled(false)
	_camera.position = Vector2(MapLayer.TILE_W / 2.0, MapLayer.TILE_H / 2.0)
	_zoom_target = _camera.zoom.x

	_map_layer = MapLayer.new()
	_map_layer.name = "MapLayer"
	add_child(_map_layer)
	_map_layer.camera = _camera
	# Лерп MARKER_SCREEN_FAR↔_NEAR в MapLayer привязан к этому диапазону.
	_map_layer.zoom_min = ZOOM_MIN
	_map_layer.zoom_max = ZOOM_MAX
	_map_layer.load_from_file("res://data/locations.json")

	# Привязка GamePanel к глобальному GameState
	GameState.state_changed.connect(_refresh_game_panel)
	GameState.state_changed.connect(_refresh_investigators)
	GameState.state_changed.connect(_refresh_gates)
	GameState.state_changed.connect(_refresh_entities)
	GameState.state_changed.connect(_refresh_campaign_gate)
	_build_campaign_gate()
	_build_outcome_modal()
	_build_check_roll_modal()
	_build_reckoning_wait_overlay()
	_build_chat_composer()
	_build_hand_carousel()
	_refresh_game_panel()
	_refresh_investigators()
	_refresh_gates()
	_refresh_entities()
	_refresh_campaign_gate()

	# Сайдбар закрылся — снимаем подсветку с карты
	_sidebar.closed.connect(func() -> void: _map_layer.set_selected(""))
	# Клик по соседу в списке — открываем его как если бы кликнули по карте
	_sidebar.neighbor_selected.connect(_on_neighbor_selected)
	# Кнопка «Магазин» в сайдбаре — открыть модалку магазина.
	_sidebar.shop_requested.connect(_on_shop_requested)
	# Клик по орбу раунда — открыть/закрыть сайдбар текущей Мистерии.
	_game_panel.round_clicked.connect(_on_round_clicked)
	# Смена языка не требует здесь обработки: данные локаций/сыщиков содержат
	# translation keys, лейблы Godot переводит автоматически при смене локали.


func _exit_tree() -> void:
	ScreenFrame.set_enabled(true)


# Обновляем верхний HUD по текущему стейту игры.
func _refresh_game_panel() -> void:
	_game_panel.set_phase(_phase_label_for(GameState.phase))
	_game_panel.set_player(_current_player_name())
	_game_panel.set_doom(GameState.doom)
	_game_panel.set_omens_step(float(GameState.omens_step))
	_game_panel.set_info(_to_roman(GameState.round_num))


## Обновляет маркеры сыщиков на карте по позициям из GameState.
func _refresh_investigators() -> void:
	if not is_instance_valid(_map_layer) or _travelling:
		return
	var list: Array = []
	var moves: Array = []  # [{pid, inv, from, to}] — кто сменил локацию
	for pid: String in GameState.players:
		var p: Dictionary = GameState.players[pid]
		if GameState.player_has_constraint(pid, "removeFromBoard"):
			continue  # whileHeld removeFromBoard (Lost in Time) — фишка снята с поля
		var inv: String = String(p.get("investigator", ""))
		var loc: String = String(p.get("location", ""))
		list.append({"pid": pid, "investigator": inv, "location": loc})
		var prev: String = String(_inv_locs.get(pid, ""))
		if _inv_seen and not prev.is_empty() and prev != loc:
			moves.append({"pid": pid, "inv": inv, "from": prev, "to": loc})
		_inv_locs[pid] = loc

	# Первый рефреш или нет перемещений — просто расставляем пины.
	if not _inv_seen or moves.is_empty():
		_inv_seen = true
		_map_layer.set_investigators(list)
		return

	_animate_moves(moves, list)


# Последовательно проигрывает анимации перемещений, затем расставляет пины.
func _animate_moves(moves: Array, list: Array) -> void:
	_travelling = true
	for i: int in range(moves.size()):
		var m: Dictionary = moves[i]
		_map_layer.hide_investigator(String(m.pid))
		var ctype: String = _map_layer.edge_ctype(String(m.from), String(m.to))
		await _map_layer.play_travel(String(m.inv), String(m.from), String(m.to), ctype)
	_travelling = false
	_map_layer.set_investigators(list)
	_apply_bounds()


func _build_outcome_modal() -> void:
	var om: CanvasLayer = load("res://scripts/ui/outcome_modal.gd").new()
	om.name = "OutcomeModal"
	add_child(om)


# Общая модалка видимой проверки test-узла (действия состояний, вложенные test и пр.).
func _build_check_roll_modal() -> void:
	var cam: CanvasLayer = load("res://scripts/ui/check_roll_modal.gd").new()
	cam.name = "CheckRollModal"
	add_child(cam)


# Оверлей «ждём других сыщиков» в параллельной Расплате (для уже закончивших).
func _build_reckoning_wait_overlay() -> void:
	var ov: CanvasLayer = load("res://scripts/ui/reckoning_wait_overlay.gd").new()
	ov.name = "ReckoningWaitOverlay"
	add_child(ov)


# Композер чата (C): веер шаблонов → веер слов по секциям → центр-превью → Отправить.
func _build_chat_composer() -> void:
	var cc: CanvasLayer = load("res://scripts/ui/chat_composer.gd").new()
	cc.name = "ChatComposer"
	add_child(cc)


# Веер карт руки — открывается по Tab. Карты берём из реального имущества
# локального игрока (GameState), обновляем при каждом изменении стейта.
func _build_hand_carousel() -> void:
	var hc: CanvasLayer = load("res://scripts/ui/hand_carousel.gd").new()
	hc.name = "HandCarousel"
	add_child(hc)
	_hand_carousel = hc
	# Карту вытащили на проверку. Заклинание (kind:"spell") → каст; актив → активация.
	hc.card_played.connect(
		func(item_index: int, item_id: String) -> void:
			var items: Array = GameState.my_player().get("items", [])
			# item_index захвачен при сборке веера; за время анимации розыгрыша items мог
			# сместиться синком от хоста — переразрешаем по id, иначе сыграли бы соседнюю.
			var idx: int = _resolve_played_index(items, item_index, item_id)
			if idx < 0:
				return  # карта ушла из руки — розыгрыш отменяем
			var it: Variant = items[idx]
			if not (it is Dictionary) or String((it as Dictionary).get("kind", "")) != "spell":
				GameState.activate_card(idx)
				return
			# Glamour во время активной проверки → применить пассив-ауру (как актив);
			# иначе (Ritual/Incantation/glamour вне проверки) → каст.
			var sid: String = String((it as Dictionary).get("id", ""))
			if SpellCatalog.is_glamour(sid) and not GameState.active_check.is_empty():
				GameState.activate_card(idx)
			else:
				GameState.cast_spell(idx)
	)
	# Жетон закинули на проверку — заряжаем валюту переброса; куб игрок выберет тапом.
	hc.token_played.connect(func(currency: String) -> void: GameState.set_pending_reroll(currency))
	# Сыграли карту состояния — запускаем его локальное действие (хост валидирует).
	hc.condition_acted.connect(
		func(cid: String) -> void:
			GameState.perform_action(GameActions.CONDITION_ACTION, {"condition": cid})
	)
	GameState.state_changed.connect(_refresh_hand)
	_refresh_hand()


# Актуальный индекс сыгранной карты в items. item_index захвачен при сборке веера;
# если за время анимации розыгрыша items сместился (синк от хоста), сверяем по id и
# ищем ту же карту заново. Нет совпадения id ни по индексу, ни где-либо — карта ушла
# из руки, возвращаем -1 (розыгрыш отменяется). Пустой id — старый путь без валидации.
func _resolve_played_index(items: Array, item_index: int, item_id: String) -> int:
	if item_id.is_empty():
		return item_index
	if (
		item_index >= 0
		and item_index < items.size()
		and AssetCatalog.entry_id(items[item_index]) == item_id
	):
		return item_index
	for i in range(items.size()):
		if AssetCatalog.entry_id(items[i]) == item_id:
			return i
	return -1


# Перечитать веер: секции имущества и жетонов из стейта игрока. Пустые секции не
# показываем (их отбираем здесь). Видны только во время своей применимости.
func _refresh_hand() -> void:
	if not is_instance_valid(_hand_carousel):
		return
	# Три отдельных веера: активы, заклинания, жетоны. Пустые не показываем;
	# переключение между ними — стрелками (карусель сама их включает при >1 секции).
	var sections: Array = []
	var assets: Array = _hand_assets_section()
	if not assets.is_empty():
		sections.append({"title": tr("HAND_ASSETS"), "items": assets})
	var spells: Array = _hand_spells_section()
	if not spells.is_empty():
		sections.append({"title": tr("HAND_SPELLS"), "items": spells})
	var tokens: Array = _hand_tokens_section()
	if not tokens.is_empty():
		sections.append({"title": tr("HAND_TOKENS"), "items": tokens})
	var conds: Array = _hand_conditions_section()
	if not conds.is_empty():
		sections.append({"title": tr("HAND_CONDITIONS"), "items": conds})
	_hand_carousel.set_sections(sections)


# Веер «Активы»: только карты-активы (без заклинаний — у них свой веер).
# Разыгранную/истощённую в текущей проверке карту убираем (item.exhausted — раунд;
# active_check.exhausted_cards — на проверку).
func _hand_assets_section() -> Array:
	var deck: Array = AssetCatalog.deck_for_items(GameState.my_player().get("items", []))
	var per_check: Array = GameState.active_check.get("exhausted_cards", [])
	var out: Array = []
	for p_v: Variant in deck:
		var pcard: Dictionary = p_v
		var spent: bool = (
			bool(pcard.get("exhausted", false))
			or (per_check as Array).has(int(pcard.get("item_index", -1)))
		)
		if spent:
			continue  # использованную в этой проверке/раунде карту прячем
		pcard["kind"] = "asset"
		# Не подходит текущей проверке (навык/тайминг/контекст) → гасим (нельзя сыграть),
		# чтобы было видно: эта карта тут бесполезна (напр. +Воля против проверки Влияния).
		if not _card_applicable_now(pcard):
			pcard["exhausted"] = true
		out.append(pcard)
	return out


# Веер «Заклинания»: карты-заклинания ({id, kind:"spell"}); фронт активируем
# (тап/вытаскивание = каст). Отдельная секция от активов.
func _hand_spells_section() -> Array:
	var out: Array = []
	var items: Array = GameState.my_player().get("items", [])
	for i in range(items.size()):
		var it: Variant = items[i]
		if not (it is Dictionary) or String((it as Dictionary).get("kind", "")) != "spell":
			continue
		var spell: Dictionary = SpellCatalog.by_id(String((it as Dictionary).get("id", "")))
		if spell.is_empty():
			continue
		var sc: Dictionary = SpellCatalog.card_payload(spell)
		sc["item_index"] = i
		sc["kind"] = "spell"
		out.append(sc)
	return out


# Применима ли карта к ТЕКУЩЕЙ активной проверке: есть ли у неё мод (action/whileOwned),
# подходящий по контексту + навыку шага + таймингу (до/после броска). Вне проверки — да.
func _card_applicable_now(pcard: Dictionary) -> bool:
	# Боевой триггер карты (on:combatEncounter, напр. Handcuffs: фокус→победа) — у неё
	# нет check-mod, но в бою она применима, если предикат/оплата проходят. Проверяем
	# первым: триггер не зависит от active_check (шага Воли/Силы).
	if GameState.combat_trigger_ready(int(pcard.get("item_index", -1))):
		return true
	var c: Dictionary = GameState.active_check
	if c.is_empty():
		return true
	var asset: Dictionary = AssetCatalog.by_id(String(pcard.get("id", "")))
	if asset.is_empty():
		return true
	var ctx: String = String(c.get("context", ""))
	var skill: String = String(c.get("skill", ""))
	var rolled: bool = bool(c.get("rolled", false))
	var mods: Array = AssetCatalog.action_check_mods(asset, ctx).duplicate()
	mods.append_array(AssetCatalog.passive_check_mods(asset, ctx))
	for m_v: Variant in mods:
		if Dice.mod_skill_ok(m_v, skill) and Dice.mod_is_pre_roll(m_v) != rolled:
			return true
	return false


# Веер «Жетоны»: по одному элементу на жетон концентрации/улики. Доступен, когда у
# игрока есть жетоны (в т.ч. в фазе действий — для просмотра). На брошенной проверке
# их перетаскивают на провальный куб как валюту переброса.
func _hand_tokens_section() -> Array:
	var me: Dictionary = GameState.my_player()
	var out: Array = []
	for _i in range(int(me.get("concentration", 0))):
		out.append(_token_payload("concentration"))
	for _i in range(int(me.get("clues", 0))):
		out.append(_token_payload("clue"))
	return out


# Payload жетона для GameCard (вариант A — в размер карты: глиф + подпись, без цены).
func _token_payload(currency: String) -> Dictionary:
	var is_focus: bool = currency == "concentration"
	return {
		"kind": "token",
		"currency": currency,
		"title": tr("TOKEN_CONCENTRATION") if is_focus else tr("TOKEN_CLUE"),
		"glyph": "✦" if is_focus else "◆",
		"desc": tr("TOKEN_REROLL_HINT"),
	}


# Веер «Состояния»: карты состояний игрока. Карта играбельна (клик/вытаскивание →
# локальное действие), только если у состояния есть action, оно не на рубашке, и
# действие сейчас доступно (мой ход действий, есть действия, condition_action ещё не
# тратил в этом раунде — тот же гейт, что у action_panel). Прочие — серые (просмотр).
func _hand_conditions_section() -> Array:
	var me: Dictionary = GameState.my_player()
	var conds: Array = me.get("conditions", [])
	var flipped: Dictionary = me.get("conditions_flipped", {})
	var used: Array = me.get("actions_used", [])
	var can_act: bool = (
		GameState.is_my_turn()
		and int(me.get("actions_left", 0)) > 0
		and not (used as Array).has(GameActions.CONDITION_ACTION)
	)
	var out: Array = []
	for i in range(conds.size()):
		var cid: String = String(conds[i])
		var pcard: Dictionary = Conditions.card_payload(cid, String(flipped.get(cid, "")))
		if pcard.is_empty():
			continue
		var playable: bool = (
			bool(pcard.get("has_action", false)) and not flipped.has(cid) and can_act
		)
		pcard["exhausted"] = not playable
		out.append(pcard)
	return out


func _refresh_gates() -> void:
	if not is_instance_valid(_map_layer):
		return
	_map_layer.set_gates(GameState.gates)

	# Какие локации с вратами появились впервые.
	var new_locs: Array = []
	for lid: Variant in GameState.gates:
		if not _known_gate_locs.has(lid):
			new_locs.append(String(lid))
	_known_gate_locs = {}
	for lid: Variant in GameState.gates:
		_known_gate_locs[lid] = true

	# Первый рефреш (вход в игру/старт) не анимируем — только запоминаем.
	if not _gates_seen:
		_gates_seen = true
		return
	for i: int in range(new_locs.size()):
		_enqueue_focus(String(new_locs[i]), SfxManager.SFX_OPEN_GATE)


# Поставить локацию в очередь фокуса камеры (+опц. звук) и запустить обработку.
func _enqueue_focus(loc: String, sound: AudioStream) -> void:
	_focus_queue.append({"loc": loc, "sound": sound})
	if not _focus_busy:
		_run_focus_queue()


# Последовательно: звук + плавный пан камеры на каждую локацию из очереди.
func _run_focus_queue() -> void:
	if _focus_busy:
		return
	_focus_busy = true
	while not _focus_queue.is_empty():
		var item: Dictionary = _focus_queue.pop_front()
		var p: Vector2 = _map_layer.loc_world_pos(String(item.get("loc", "")))
		if p == Vector2.INF:
			continue
		if item.get("sound") != null:
			SfxManager.play(item.get("sound"))
		await _pan_camera_to(p)
		await get_tree().create_timer(0.4).timeout
	_focus_busy = false


# Плавно ведёт камеру к мировой точке (по кратчайшему пути с учётом wrap по X).
func _pan_camera_to(target: Vector2) -> void:
	_inertia_velocity = Vector2.ZERO
	# Ближайшая по горизонтали копия цели (карта закольцована по X).
	var tx: float = target.x
	var dx: float = tx - _camera.position.x
	if dx > MapLayer.TILE_W * 0.5:
		tx -= MapLayer.TILE_W
	elif dx < -MapLayer.TILE_W * 0.5:
		tx += MapLayer.TILE_W
	var dest := Vector2(tx, target.y)
	var tw := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_camera, "position", dest, 0.6)
	await tw.finished
	_apply_bounds()


## Обновляет иконки сущностей на локациях. Склеивает улики/слухи (GameState.
## entities) и монстров (GameState.monsters → иконки "monster") в один вид.
## Новые улики (как и врата) — последовательный пан камеры на их локации.
func _refresh_entities() -> void:
	if not is_instance_valid(_map_layer):
		return
	var view: Dictionary = {}
	for lid: Variant in GameState.entities:
		view[lid] = (GameState.entities[lid] as Array).duplicate()
	for lid: Variant in GameState.monsters:
		var cell: Array = view.get(lid, [])
		for _i: int in range((GameState.monsters[lid] as Array).size()):
			cell.append("monster")
		view[lid] = cell
	# Незачищенные локации активной Тайны — тем же жетоном Древних (map item в стопке),
	# что и раскиданные eldritch_token; отдельного «маячного» слоя над медальоном нет.
	var myst: Dictionary = GameState.current_mystery()
	var mlocs: Array = myst.get("locations", [])
	for i: int in range(mlocs.size()):
		var mlid: String = String(mlocs[i])
		if (GameState.mystery_claimed as Array).has(mlid):
			continue
		var mcell: Array = view.get(mlid, [])
		if not mcell.has("eldritch_token"):
			mcell.append("eldritch_token")
		view[mlid] = mcell
	_map_layer.set_entities(view)

	# Локации, где улика появилась впервые.
	var new_clue_locs: Array = []
	var clue_now: Dictionary = {}
	for lid: Variant in GameState.entities:
		if (GameState.entities[lid] as Array).has("clue"):
			clue_now[lid] = true
			if not _known_clue_locs.has(lid):
				new_clue_locs.append(String(lid))
	_known_clue_locs = clue_now
	if not _clues_seen:
		_clues_seen = true
		return
	for i: int in range(new_clue_locs.size()):
		_enqueue_focus(String(new_clue_locs[i]), SfxManager.SFX_CLUE_OPEN)


func _phase_label_for(p: String) -> String:
	match p:
		"action":
			return "PHASE_ACTION"
		"encounter":
			return "PHASE_ENCOUNTER"
		"mythos":
			return "PHASE_MYTHOS"
	return ""


func _current_player_name() -> String:
	if GameState.phase != Phases.ACTION and GameState.phase != Phases.ENCOUNTER:
		return ""
	if GameState.turn_order.is_empty():
		return ""
	var pid: String = GameState.turn_order[GameState.current_idx]
	if not GameState.players.has(pid):
		return ""
	var inv_id: String = GameState.players[pid].get("investigator", "???")
	return Investigators.display_name(inv_id)


func _process(delta: float) -> void:
	# Инерция панорамирования
	if _inertia_velocity.length_squared() > 0.0:
		_camera.position += _inertia_velocity * delta
		_apply_bounds()
		# Экспоненциальное затухание (frame-rate independent)
		_inertia_velocity *= exp(-INERTIA_FRICTION * delta)
		if _inertia_velocity.length() < INERTIA_MIN_SPEED:
			_inertia_velocity = Vector2.ZERO

	# Плавная интерполяция зума
	var current: float = _camera.zoom.x
	if not is_equal_approx(current, _zoom_target):
		var new_zoom: float = lerpf(current, _zoom_target, ZOOM_SPEED * delta)
		_camera.zoom = Vector2.ONE * new_zoom
		_apply_bounds()


# Открыт ли веер карт руки (тогда колесо/клики уходят ему, а не карте мира).
func _fan_open() -> bool:
	return is_instance_valid(_hand_carousel) and _hand_carousel.is_open()


func _unhandled_input(event: InputEvent) -> void:
	if GameConsole.is_open():
		return  # консоль открыта — не зумим/не таскаем/не кликаем карту, пока печатаешь
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_start_drag(mb.position)
				else:
					_dragging = false
					if _drag_distance < CLICK_THRESHOLD:
						_handle_click(mb.position)
					else:
						_release_with_inertia()
			MOUSE_BUTTON_MIDDLE:
				if mb.pressed:
					_start_drag(mb.position)
				else:
					_dragging = false
					_release_with_inertia()
			MOUSE_BUTTON_WHEEL_UP:
				if not _fan_open():  # при открытом вевере колесо листает карты, не зумит карту
					_zoom_target = clamp(_zoom_target + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				if not _fan_open():
					_zoom_target = clamp(_zoom_target - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)

	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		var delta: Vector2 = motion.position - _drag_origin
		_drag_distance = maxf(_drag_distance, delta.length())
		_camera.position = _cam_origin - delta / _camera.zoom
		_apply_bounds()
		_push_sample(motion.position)


# ── Драг + инерция ───────────────────────────────────────────────────────────


func _start_drag(pos: Vector2) -> void:
	_dragging = true
	_drag_origin = pos
	_cam_origin = _camera.position
	_drag_distance = 0.0
	_inertia_velocity = Vector2.ZERO  # отменяем текущий «полёт»
	_drag_samples.clear()
	_push_sample(pos)


func _push_sample(pos: Vector2) -> void:
	var now: int = Time.get_ticks_msec()
	_drag_samples.append({"t": now, "p": pos})
	# Хвост: оставляем сэмплы в пределах окна FLICK_WINDOW_MS от текущего push'а.
	while _drag_samples.size() > 1 and now - int(_drag_samples[0].t) > FLICK_WINDOW_MS:
		_drag_samples.pop_front()


func _release_with_inertia() -> void:
	var now: int = Time.get_ticks_msec()
	# Доп. трим уже от ТЕКУЩЕГО момента: если после последнего motion прошла пауза,
	# все «старые» сэмплы (из активной фазы) выкидываются — юзер замер и решил
	# отпустить, инерции быть не должно.
	while _drag_samples.size() > 0 and now - int(_drag_samples[0].t) > FLICK_WINDOW_MS:
		_drag_samples.pop_front()

	if _drag_samples.size() < 2:
		_drag_samples.clear()
		return

	var first: Dictionary = _drag_samples[0]
	var last: Dictionary = _drag_samples[-1]
	# dt считаем от первого сэмпла до МОМЕНТА RELEASE (now), а не до last.t.
	# Так короткая пауза между последним движением и отпусканием увеличивает
	# знаменатель → скорость падает пропорционально длине паузы.
	var dt: float = float(now - int(first.t)) / 1000.0
	if dt < 0.005:
		_drag_samples.clear()
		return
	var screen_v: Vector2 = (Vector2(last.p) - Vector2(first.p)) / dt
	# Камера движется в обратную сторону от мыши, в world-координатах.
	_inertia_velocity = -screen_v / _camera.zoom.x
	_drag_samples.clear()


# ── Клик по локации ──────────────────────────────────────────────────────────


func _handle_click(screen_pos: Vector2) -> void:
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var world_pos: Vector2 = _camera.position + (screen_pos - vp_size * 0.5) / _camera.zoom
	var loc_name: String = _map_layer.try_pick(world_pos)
	if loc_name.is_empty():
		return
	# Повторный клик по уже выбранной локации — закрыть сайдбар (closed → set_selected("")).
	if _sidebar.is_open() and _map_layer.get_selected_name() == loc_name:
		_sidebar.close_panel()
		return
	var data: Dictionary = _map_layer.get_location(loc_name)
	if data.is_empty():
		return
	_sidebar.show_location(data)
	_map_layer.set_selected(loc_name)


const _SHOP_MODAL := preload("res://scenes/ui/shop_modal.tscn")


func _on_shop_requested() -> void:
	# Не плодим дубликаты, если уже открыт.
	if has_node("ShopModal"):
		return
	GameState.ensure_shop_reserve()  # дотянуть витрину, если пуста (без полного сброса)
	GameState.shop_open()  # старт pre-roll проверки Влияния (карты активируются до броска)
	var modal := _SHOP_MODAL.instantiate()
	modal.name = "ShopModal"
	add_child(modal)
	modal.open()


func _on_neighbor_selected(loc_name: String) -> void:
	var data: Dictionary = _map_layer.get_location(loc_name)
	if data.is_empty():
		return
	_sidebar.show_location(data)
	_map_layer.set_selected(loc_name)


func _on_round_clicked() -> void:
	_mystery.toggle()


# ── Интро-гейт: загрузка → Древний → первая Тайна → карта ────────────────────


## Строит блокирующую модалку поверх всех слоёв. Контент шага наполняет
## _render_gate().
func _build_campaign_gate() -> void:
	var layer := CanvasLayer.new()
	layer.name = "CampaignGate"
	layer.layer = 90
	layer.visible = false
	add_child(layer)

	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.03, 0.03, 0.07, 0.96)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(backdrop)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.add_child(center)

	var panel := PanelContainer.new()
	UIStyle.style_modal_panel(panel)
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(620.0, 0.0)
	center.add_child(panel)

	_gate_vbox = VBoxContainer.new()
	_gate_vbox.name = "VBox"
	_gate_vbox.add_theme_constant_override("separation", 14)
	panel.add_child(_gate_vbox)

	_campaign_gate = layer


## Шаг 0 (загрузка) ведётся campaign_pending; дальше — кнопками интро.
func _refresh_campaign_gate() -> void:
	if not is_instance_valid(_campaign_gate):
		return
	if GameState.campaign_pending:
		_intro_step = 0
	elif _intro_step == 0:
		# кампания готова: показываем Древнего; нет кампании — сразу на карту
		_intro_step = 1 if not GameState.campaign.is_empty() else 3
	elif (
		_intro_step == 3
		and GameState.phase == Phases.ACTION
		and GameState.outcome.is_empty()
		and GameState.active_mystery != _revealed_mystery
		and not GameState.current_mystery().is_empty()
	):
		# Тайна сменилась (решена в прошлом раунде) — после мифа, в начале нового
		# раунда (фаза action), показываем ревил новой Тайны (гейт-шаг 2).
		_intro_step = 2
		_gate_rendered = -1  # форс перерисовки: шаг тот же (2), но контент новый
	_campaign_gate.visible = _intro_step < 3
	if _campaign_gate.visible and _intro_step != _gate_rendered:
		_gate_rendered = _intro_step
		_render_gate()


## Наполняет панель гейта содержимым текущего шага.
func _render_gate() -> void:
	for child in _gate_vbox.get_children():
		child.queue_free()
	match _intro_step:
		0:
			_gate_title("CAMPAIGN_GATE_TITLE")
			_gate_body("CAMPAIGN_GATE_BODY")
		1:
			var ao: Dictionary = GameState.campaign.get("ancientOne", {})
			_gate_eyebrow("INTRO_ANCIENT_EYEBROW")
			_gate_title(String(ao.get("name", "")))
			var epithet: String = String(ao.get("epithet", ""))
			if not epithet.is_empty():
				_gate_subtitle(epithet)
			_gate_body(String(ao.get("description", "")))
			_gate_button("INTRO_NEXT", _on_gate_next)
		2:
			var m: Dictionary = GameState.current_mystery()
			# Запоминаем, чей ревил показан — чтобы не повторять и ловить смену.
			_revealed_mystery = GameState.active_mystery
			# Eyebrow по порядковому номеру Тайны в последовательности (Первая/Вторая/
			# Третья), а не по «акту» — актов у Тайн нет.
			var seq: int = clampi(GameState.active_mystery + 1, 1, 3)
			_gate_eyebrow("INTRO_MYSTERY_EYEBROW_%d" % seq)
			_gate_title(String(m.get("title", "")))
			var flavor: String = String(m.get("flavorText", ""))
			if not flavor.is_empty():
				_gate_body(flavor)
			_gate_body(String(m.get("text", "")))
			_gate_button("INTRO_START", _on_gate_start)
	UIStyle.scale_modal_text(_gate_vbox)  # текст модалок крупнее (×1.5)


func _on_gate_next() -> void:
	_intro_step = 2
	_refresh_campaign_gate()


func _on_gate_start() -> void:
	_intro_step = 3
	_refresh_campaign_gate()


# ── Хелперы наполнения гейта ──────────────────────────────────────────────────


func _gate_eyebrow(text: String) -> void:
	var lbl := UIStyle.label(text, 12, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Eyebrow"
	_gate_vbox.add_child(lbl)


func _gate_title(text: String) -> void:
	var lbl := UIStyle.label(text, 26, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Title"
	_gate_vbox.add_child(lbl)


func _gate_subtitle(text: String) -> void:
	var lbl := UIStyle.label(text, 15, UIColors.WARNING, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Subtitle"
	_gate_vbox.add_child(lbl)


func _gate_body(text: String) -> void:
	var lbl := UIStyle.label(text, 15, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Body"
	lbl.custom_minimum_size = Vector2(540.0, 0.0)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_gate_vbox.add_child(lbl)


func _gate_button(text: String, handler: Callable) -> void:
	var btn := UIStyle.button(text)
	btn.name = "GateButton"
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.pressed.connect(handler)
	_gate_vbox.add_child(btn)


# ── Утилиты ───────────────────────────────────────────────────────────────────


## Целое 1..3999 → римские цифры. Для номера раунда хватит с большим запасом.
func _to_roman(n: int) -> String:
	if n <= 0:
		return "0"
	const VALS := [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
	const SYMS := ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
	var result := ""
	var v: int = n
	for i in VALS.size():
		while v >= VALS[i]:
			result += SYMS[i]
			v -= VALS[i]
	return result


# ── Зум ───────────────────────────────────────────────────────────────────────


# Устарело — оставлено для совместимости, используй _zoom_target напрямую
func _set_zoom(value: float) -> void:
	_zoom_target = clamp(value, ZOOM_MIN, ZOOM_MAX)


# ── Границы и горизонтальная бесконечность ────────────────────────────────────


func _apply_bounds() -> void:
	# Горизонтальный wrap: камера всегда остаётся в [0, TILE_W)
	# Три тайла рядом делают переход незаметным
	_camera.position.x = fmod(_camera.position.x, float(MapLayer.TILE_W))
	if _camera.position.x < 0.0:
		_camera.position.x += MapLayer.TILE_W

	# Вертикальный clamp: не выходим за верх/низ карты
	var vp_half_h: float = get_viewport().get_visible_rect().size.y * 0.5 / _camera.zoom.y
	_camera.position.y = clamp(_camera.position.y, vp_half_h, MapLayer.TILE_H - vp_half_h)
