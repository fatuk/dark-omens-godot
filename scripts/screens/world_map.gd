class_name WorldMap
extends Node2D

# ── Константы ─────────────────────────────────────────────────────────────────

# Размер тайла карты — единственный источник правды в MapLayer.TILE_W/TILE_H.
# Здесь дублировать не надо: world_map двигает камеру по тем же координатам,
# что MapLayer рисует маркеры.

const _CONCENTRATION_FRAME: Texture2D = preload("res://assets/cards/concentration/card-frame.png")

# Зум подобран под эталонную карту (MapLayer.REF_TILE_W). Ассет крупнее — те же
# числа показали бы во столько же раз меньший кусок мира, поэтому делим на
# art_scale(): кадр остаётся прежним, а карта просто перестаёт растягиваться.
# Рабочие пределы — _zoom_min/_zoom_max, считаются в _setup_map_tiles.
const ZOOM_MIN_REF: float = 0.5
const ZOOM_MAX_REF: float = 1.2
static var ZOOM_STEP_REF: float = 0.15
static var ZOOM_SPEED: float = 12.0  # скорость интерполяции зума (выше = быстрее)

var _zoom_min: float = ZOOM_MIN_REF
var _zoom_max: float = ZOOM_MAX_REF

# ── Состояние перетаскивания ──────────────────────────────────────────────────

## Меньше этого числа экранных пикселей считаем за клик, не за драг.
static var CLICK_THRESHOLD: float = 6.0

var _map_tiles: Array[Sprite2D] = []  # три копии карты — переключаем им фильтр по зуму
var _dragging: bool = false
var _drag_origin: Vector2 = Vector2.ZERO
var _cam_origin: Vector2 = Vector2.ZERO
var _drag_distance: float = 0.0

# ── Инерция (как в Google Maps) ──────────────────────────────────────────────

## Экспоненциальное затухание скорости. Выше = быстрее тормозит.
static var INERTIA_FRICTION: float = 6.0
## Ниже этой скорости (world units/сек) — обнуляем инерцию.
static var INERTIA_MIN_SPEED: float = 6.0
## Окно для расчёта flick-скорости. Берём delta между самым старым сэмплом
## в окне и последним — даже если в самом конце мышь замедлилась, флик-моментум
## сохраняется. То же делают touch UI на iOS/Android.
static var FLICK_WINDOW_MS: int = 100

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
@onready var _mythos_modal: CanvasLayer = $MythosModal

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
	_setup_map_tiles()
	_camera.position = Vector2(MapLayer.TILE_W / 2.0, MapLayer.TILE_H / 2.0)
	_zoom_target = _camera.zoom.x

	_map_layer = MapLayer.new()
	_map_layer.name = "MapLayer"
	add_child(_map_layer)
	_map_layer.camera = _camera
	# Лерп MARKER_SCREEN_FAR↔_NEAR в MapLayer привязан к этому диапазону.
	_map_layer.zoom_min = _zoom_min
	_map_layer.zoom_max = _zoom_max
	_map_layer.load_from_file("res://data/locations.json")

	# Привязка GamePanel к глобальному GameState
	GameState.state_changed.connect(_refresh_game_panel)
	GameState.state_changed.connect(_refresh_investigators)
	GameState.state_changed.connect(_refresh_gates)
	GameState.state_changed.connect(_refresh_entities)
	GameState.state_changed.connect(_refresh_campaign_gate)
	GameState.state_changed.connect(_refresh_reachable)
	_build_campaign_gate()
	_build_outcome_modal()
	_build_turn_banner()
	_build_check_roll_modal()
	_build_reckoning_wait_overlay()
	_build_death_save_modal()
	_build_ghost_bar()
	_build_encounter_watch_modal()
	_build_doom_runes()
	_build_gains_modal()
	_build_chat_composer()
	_build_hand_carousel()
	_refresh_game_panel()
	_refresh_investigators()
	_refresh_gates()
	_refresh_entities()
	_refresh_campaign_gate()

	# Сайдбар закрылся — снимаем подсветку с карты
	_sidebar.closed.connect(func() -> void: _map_layer.set_selected(""))
	# Кнопка «Магазин» в сайдбаре — открыть модалку магазина.
	_sidebar.shop_requested.connect(_on_shop_requested)
	# Кнопка «Обмен» в сайдбаре — открыть модалку обмена.
	_sidebar.trade_requested.connect(_on_trade_requested)
	# Клик по картинке локации в сайдбаре — открыть полноэкранную галерею.
	_sidebar.gallery_requested.connect(_on_gallery_requested)
	# Клик по орбу раунда — открыть/закрыть сайдбар текущей Мистерии.
	_game_panel.round_clicked.connect(_on_round_clicked)
	# Клик по компасу знамений — перечитать последний вытянутый миф.
	_game_panel.mythos_review_requested.connect(_mythos_modal.open_review)
	# Кнопка «Запасы» — окно колод и сбросов (общее для стола: данные синкаются).
	_game_panel.supply_requested.connect(func() -> void: SupplyModal.open(self))
	# Смена языка не требует здесь обработки: данные локаций/сыщиков содержат
	# translation keys, лейблы Godot переводит автоматически при смене локали.


func _exit_tree() -> void:
	ScreenFrame.set_enabled(true)


# Три копии карты по горизонтали дают бесшовную прокрутку через шов долготы.
# Раскладываем их ПО РАЗМЕРУ ТЕКСТУРЫ, а не по числу из сцены: замена ассета на
# более крупный не потребует править .tscn.
func _setup_map_tiles() -> void:
	var shift := {"TileLeft": -MapLayer.TILE_W, "TileCenter": 0, "TileRight": MapLayer.TILE_W}
	for tile_name: String in shift:
		var s: Sprite2D = get_node_or_null(NodePath(tile_name)) as Sprite2D
		if s == null:
			continue
		s.position.x = float(shift[tile_name])
		_map_tiles.append(s)

	# Зум живёт в мировых единицах, то есть в текселях карты: на вдвое большем
	# ассете прежние 0.5 показали бы вдвое меньший кусок мира. Делим на art_scale —
	# кадр и шаг колеса остаются те же, меняется только резкость.
	var k: float = MapLayer.art_scale()
	_zoom_min = ZOOM_MIN_REF / k
	_zoom_max = ZOOM_MAX_REF / k
	_camera.zoom = Vector2.ONE * clampf(_camera.zoom.x / k, _zoom_min, _zoom_max)
	_apply_tile_filter(_camera.zoom.x)


# Мипмапы карте нужны ТОЛЬКО когда она ужимается: на дальнем зуме без них мерцают
# тонкие линии. На приближении они, наоборот, мылят — движок подмешивает мелкий
# уровень даже при увеличении (замерено: кадр с мипмапами на 35% менее резкий).
# Поэтому переключаем фильтр по тому, ужимаем мы текстуру или растягиваем.
#
# Один тексель карты занимает на экране zoom × (реальная ширина окна / 1920):
# холст в режиме canvas_items растянут на окно, и это тоже увеличение.
func _apply_tile_filter(zoom: float) -> void:
	# Порог с запасом, а не ровно 1.0: движок и при увеличении норовит взять
	# уровень помельче, а на крупном ассете максимальный зум как раз садится на
	# 0.99 текселя в пиксель — у самой границы.
	var minifying: bool = zoom * _canvas_scale() < 0.95
	var want: CanvasItem.TextureFilter = (
		CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		if minifying
		else CanvasItem.TEXTURE_FILTER_LINEAR
	)
	for s: Sprite2D in _map_tiles:
		if is_instance_valid(s) and s.texture_filter != want:
			s.texture_filter = want


# Шаг колеса в текущих единицах зума. Не кешируем: панель тюнинга правит
# ZOOM_STEP_REF на живой игре, и следующий щелчок должен уже это учесть.
func _wheel_step() -> float:
	return ZOOM_STEP_REF / MapLayer.art_scale()


# Во сколько раз холст растянут на окно (режим canvas_items): мировая единица
# занимает на экране zoom × это число.
func _canvas_scale() -> float:
	var base_w: float = float(
		ProjectSettings.get_setting("display/window/size/viewport_width", 1920)
	)
	return float(get_window().size.x) / maxf(base_w, 1.0)


# Дробная позиция камеры на зернистой карте даёт «рябь»: билинейная выборка каждый
# кадр по-новому усредняет соседние тексели, и зерно ползёт. Заметнее всего на
# затухании инерции, когда сдвиг за кадр — доли пикселя. Прижимаем камеру к целому
# ЭКРАННОМУ пикселю: шум замирает, а шаг привязки меньше пикселя и незаметен.
func _snap_camera_to_pixel() -> void:
	var s: float = _camera.zoom.x * _canvas_scale()
	if s > 0.0:
		_camera.position = (_camera.position * s).round() / s


# Обновляем верхний HUD по текущему стейту игры.
func _refresh_game_panel() -> void:
	_game_panel.set_phase(_phase_label_for(GameState.phase))
	_game_panel.set_player(_current_player_name())
	# Число делений трека = порог Рока Древнего (doomClock); иначе трек 12 делений
	# показывал бы doom≥12 всегда «полным». Фолбэк 12 — пока библия не готова.
	_game_panel.set_max_doom(int(GameState.campaign.get("doomClock", 12)))
	_game_panel.set_doom(GameState.doom)
	_game_panel.set_omens_step(float(GameState.omens_step))
	_game_panel.set_info(_to_roman(GameState.round_num))


# Чей сейчас ход — для пометки на карте и плашки. Пусто, если партия не идёт или
# фаза не про конкретного игрока (Миф, Расплата): помечать тогда некого.
func _active_turn_pid() -> String:
	if not GameState.active:
		return ""
	if GameState.phase != Phases.ACTION and GameState.phase != Phases.ENCOUNTER:
		return ""
	var pid: String = GameState._current_pid()
	# Свой ход себе не подсвечиваем: игрок и так знает, что ходит — ему про это
	# говорят баннер «Ваш ход» и доступные действия. Ореол нужен ОСТАЛЬНЫМ, чтобы
	# видеть, кого ждут; на своей же карточке он был бы лишним шумом.
	return "" if pid == GameState.local_pid() else pid


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
		(
			list
			. append(
				{
					"pid": pid,
					"investigator": inv,
					"location": loc,
					"dead": bool(p.get("dead", false)),
					"connected": bool(p.get("connected", true)),
				}
			)
		)
		var prev: String = String(_inv_locs.get(pid, ""))
		if _inv_seen and not prev.is_empty() and prev != loc:
			# Многохоповое перемещение (билеты): путь сегментов из состояния игрока.
			moves.append(
				{"pid": pid, "inv": inv, "from": prev, "to": loc, "path": p.get("travel_path", [])}
			)
		_inv_locs[pid] = loc

	# Ореол «сейчас ходит» — на каждом рефреше: ход меняется без смены локаций, и
	# set_investigators по неизменной сигнатуре ничего бы не перестроил.
	_map_layer.set_active_investigator(_active_turn_pid())

	# Первый рефреш или нет перемещений — просто расставляем пины.
	if not _inv_seen or moves.is_empty():
		_inv_seen = true
		_map_layer.set_investigators(list)
		_map_layer.set_active_investigator(_active_turn_pid())
		return

	_animate_moves(moves, list)


# Последовательно проигрывает анимации перемещений, затем расставляет пины.
func _animate_moves(moves: Array, list: Array) -> void:
	_travelling = true
	var me: String = String(GameState.my_player().get("user_id", ""))
	for i: int in range(moves.size()):
		var m: Dictionary = moves[i]
		_map_layer.hide_investigator(String(m.pid))
		# Посегментно: билетный маршрут проходит через промежуточные локации.
		for seg: Array in _travel_segments(m):
			var a: String = seg[0]
			var b: String = seg[1]
			await _map_layer.play_travel(String(m.inv), a, b, _map_layer.edge_ctype(a, b))
		# Своя фишка доехала — сообщаем хосту: он держал передачу хода до этого
		# момента, чтобы следующий игрок не начинал ход поверх летящей фишки.
		if String(m.pid) == me:
			GameState.act(RelayActions.TRAVEL_ARRIVED)
	_travelling = false
	_map_layer.set_investigators(list)
	_map_layer.set_active_investigator(_active_turn_pid())
	_apply_bounds()


# Сегменты перемещения [[a,b], …]. Берём из travel_path игрока, если он валиден
# (≥2 узла, концы совпадают с from/to); иначе — один прямой сегмент from→to
# (телепорты/эффекты без пути).
func _travel_segments(m: Dictionary) -> Array:
	var path: Array = m.get("path", [])
	var from: String = String(m.from)
	var to: String = String(m.to)
	if path.size() >= 2 and String(path[0]) == from and String(path[-1]) == to:
		var segs: Array = []
		for i in range(path.size() - 1):
			segs.append([String(path[i]), String(path[i + 1])])
		return segs
	return [[from, to]]


# Подсветка на карте локаций, до которых локальному игроку НУЖЕН билет — только
# в его ход в фазе action, пока есть действие и travel ещё не использован. Иначе
# снимаем. Базовые соседи (бесплатный ход) не красятся — см. set_ticket_reach.
func _refresh_reachable() -> void:
	if not is_instance_valid(_map_layer):
		return
	var me: Dictionary = GameState.my_player()
	var can: bool = (
		GameState.is_my_turn()
		and GameState.phase == Phases.ACTION
		and int(me.get("actions_left", 0)) > 0
		and not (me.get("actions_used", []) as Array).has(GameActions.TRAVEL)
	)
	if can:
		_map_layer.set_ticket_reach(
			String(me.get("location", "")),
			int(me.get("train_tickets", 0)),
			int(me.get("ship_tickets", 0))
		)
	else:
		_map_layer.set_ticket_reach("", 0, 0)


func _build_outcome_modal() -> void:
	var om: CanvasLayer = load("res://scripts/ui/outcome_modal.gd").new()
	om.name = "OutcomeModal"
	add_child(om)


func _build_turn_banner() -> void:
	var tb: CanvasLayer = load("res://scripts/ui/turn_banner.gd").new()
	tb.name = "TurnBanner"
	add_child(tb)


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


# Модалка Порога (спас-бросок на 0 HP/SAN) — видна всем, пока идёт спас.
func _build_death_save_modal() -> void:
	var m: CanvasLayer = load("res://scripts/ui/death_save_modal.gd").new()
	m.name = "DeathSaveModal"
	add_child(m)


# Панель Тени («Мир духов») — видна погибшему игроку (оставить улику / Тайны / чат).
func _build_ghost_bar() -> void:
	var g: CanvasLayer = load("res://scripts/ui/ghost_bar.gd").new()
	g.name = "GhostBar"
	add_child(g)


# Окно наблюдателя: остальным игрокам видно, какую встречу проходит активный сыщик
# (только текст и исход, без проверки и кубов).
func _build_encounter_watch_modal() -> void:
	var w: CanvasLayer = load("res://scripts/ui/encounter_watch_modal.gd").new()
	w.name = "EncounterWatchModal"
	add_child(w)


# Окно «вы получили»: сводка приобретений после мифа/Расплаты — там выдача идёт
# молча, и понять, что именно пришло, было неоткуда.
func _build_gains_modal() -> void:
	var g: CanvasLayer = load("res://scripts/ui/gains_modal.gd").new()
	g.name = "GainsModal"
	add_child(g)


# Руны Рока: слой поверх всего, проступает по мере роста безысходности.
# Пока в ручном режиме — параметры крутятся в панели тюнинга (Ctrl+M).
func _build_doom_runes() -> void:
	var r: CanvasLayer = load("res://scripts/ui/doom_runes.gd").new()
	r.name = "DoomRunes"
	add_child(r)


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
				# Карточка с тегом "action" играется как ОТДЕЛЬНОЕ действие фазы, а не
				# как модификатор проверки (у тех нет своей программы). Но если идёт
				# проверка и карта ей подходит — она играется В ПРОВЕРКУ: у «Охотника на
				# монстров» есть и действие, и пассив +2 Силы в бою, а в бою действие не
				# потратить, и клик уходил в никуда.
				var entry: Dictionary = AssetCatalog.by_id(AssetCatalog.entry_id(it as Dictionary))
				var cur: Dictionary = GameState.dice.current_check()
				var to_check: bool = not cur.is_empty() and _asset_fits_check(entry, cur)
				if not to_check and AssetCatalog.has_standalone_action(entry):
					GameState.perform_action(GameActions.ASSET_ACTION, {"item": idx})
					return
				# В параллельной Расплате проверка лежит в per-player слоте, а не в
				# active_check — там свой маршрут, иначе карта молча не сработает.
				if GameState.my_player().has("reckoning_pending"):
					GameState.act(RelayActions.RECKONING_ACTIVATE_CARD, {"index": idx})
				else:
					GameState.act(RelayActions.ACTIVATE_CARD, {"index": idx})
				return
			# Glamour во время активной проверки → применить пассив-ауру (как актив);
			# иначе (Ritual/Incantation/glamour вне проверки) → каст.
			var sid: String = String((it as Dictionary).get("id", ""))
			if SpellCatalog.is_glamour(sid) and not GameState.active_check.is_empty():
				GameState.act(RelayActions.ACTIVATE_CARD, {"index": idx})
			else:
				GameState.cast_spell(idx)
	)
	# Жетон закинули на проверку — заряжаем валюту переброса; куб игрок выберет тапом.
	hc.token_played.connect(func(currency: String) -> void: GameState.dice.charge(currency))
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
	var per_check: Array = GameState.dice.current_check().get("exhausted_cards", [])
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
# Может ли игрок потратить действие прямо сейчас (мой ход в фазе действий).
func _can_spend_action() -> bool:
	var me: Dictionary = GameState.my_player()
	return (
		GameState.is_my_turn()
		and GameState.phase == Phases.ACTION
		and int(me.get("actions_left", 0)) > 0
	)


func _card_applicable_now(pcard: Dictionary) -> bool:
	# Боевой триггер карты (on:combatEncounter, напр. Handcuffs: фокус→победа) — у неё
	# нет check-mod, но в бою она применима, если предикат/оплата проходят. Проверяем
	# первым: триггер не зависит от active_check (шага Воли/Силы).
	# То же — предотвращение потери (бинты): в окне «бросок сделан, потеря ещё не
	# списана» карта играется за раненого на моей клетке, за себя или соседа,
	# даже в ЧУЖОЙ ход. Обе реакции проверяет combat_trigger_ready.
	if GameState.combat_trigger_ready(int(pcard.get("item_index", -1))):
		return true
	# current_check, а не active_check: в Расплате проверка лежит в per-player слоте,
	# и по пустому active_check веер показывал ВСЕ карты применимыми.
	var c: Dictionary = GameState.dice.current_check()
	var asset: Dictionary = AssetCatalog.by_id(String(pcard.get("id", "")))
	# Идёт проверка и у карты есть подходящий ей мод — играется В ПРОВЕРКУ. Этот
	# случай ПЕРВЕЕ самостоятельного действия: «Охотник на монстров» умеет и то, и
	# другое (пассив +2 Силы в бою и действие «монстр теряет 1 здоровье»), и пока
	# ветка действия стояла выше, в бою карта считалась неиграбельной — действие в
	# бою не потратить, а до пассива дело не доходило.
	if not c.is_empty() and (asset.is_empty() or _asset_fits_check(asset, c)):
		return true
	# Актив с самостоятельным действием (тег "action") играется отдельным действием
	# фазы — он применим и вне проверки, лишь бы был ход и осталось действие. Плюс
	# гварды самой карты (истощена, бить некого) — тот же can_play, что у хоста.
	if AssetCatalog.has_standalone_action(asset):
		return _can_spend_action() and GameState.can_play_asset(int(pcard.get("item_index", -1)))
	# Прочие активы вне проверки сыграть НЕКУДА: activate_card ведёт либо в боевой
	# триггер (проверен выше), либо в CheckFlow.activate, которому нужна проверка.
	# Раньше тут стоял «true», и в фазе действий вся рука светилась играбельной.
	return false


# Подходит ли актив ЭТОЙ проверке — тот же фильтр, что у хоста (AssetCatalog.fits_check).
func _asset_fits_check(asset: Dictionary, c: Dictionary) -> bool:
	return AssetCatalog.fits_check(
		asset,
		String(c.get("context", "")),
		String(c.get("skill", "")),
		bool(c.get("rolled", false))
	)


# Веер «Жетоны»: по одному элементу на жетон концентрации/улики. Доступен, когда у
# игрока есть жетоны (в т.ч. в фазе действий — для просмотра). На брошенной проверке
# их перетаскивают на провальный куб как валюту переброса.
func _hand_tokens_section() -> Array:
	var me: Dictionary = GameState.my_player()
	var out: Array = []
	for i in range(int(me.get("concentration", 0))):
		out.append(_token_payload("concentration", i))
	# Улики: по карте на жетон. Идентичность (тайтл/описание/арт локации) — из clue_ids
	# через ClueCatalog. Жетонов больше, чем идентичностей → лишние дженерик (без локации).
	var clue_ids: Array = me.get("clue_ids", [])
	for i in range(int(me.get("clues", 0))):
		var loc: String = String(clue_ids[i]) if i < clue_ids.size() else ""
		out.append(_clue_token_payload(loc))
	return out


# Payload карты-улики: дженерик-жетон переброса (глиф + подсказка «на куб»); при
# наличии идентичности (loc из clue_ids) накладываем контент Древнего из ClueCatalog —
# тайтл улики и описание (нет описания → имя локации), опц. арт вместо глифа.
func _clue_token_payload(loc: String) -> Dictionary:
	var p: Dictionary = {
		"kind": "token",
		"currency": "clue",
		"title": tr("TOKEN_CLUE"),
		"glyph": "◆",
		"desc": tr("TOKEN_REROLL_HINT"),
	}
	if loc.is_empty():
		return p
	var cp: Dictionary = ClueCatalog.card_payload(loc)
	var title: String = String(cp.get("title", ""))
	if not title.strip_edges().is_empty():
		p["title"] = title
	p["desc"] = String(cp.get("desc", ""))  # описание улики или имя локации
	if cp.has("art"):
		p["art"] = cp["art"]
		p.erase("glyph")  # есть арт → без глифа-заглушки
	return p


# Payload жетона концентрации для GameCard — полно-артовая карта (своя рамка) с
# цитатой стоика (автор/источник/текст). Индекс цитаты хранится на жетоне
# (player.concentration_quotes[slot], назначается хостом при выдаче) — цитата
# привязана к выданному жетону и переживает синки/трату соседних. Фолбэк slot —
# если реконсиляция ещё не прошла.
func _token_payload(currency: String, slot: int) -> Dictionary:
	var quotes: Array = GameState.my_player().get("concentration_quotes", [])
	var idx: int = int(quotes[slot]) if slot < quotes.size() else slot
	var q: Dictionary = StoicQuotes.at(idx)
	return {
		"kind": "token",
		"currency": currency,
		"frame": _CONCENTRATION_FRAME,
		"title": String(q.get("author", tr("TOKEN_CONCENTRATION"))),
		"subtitle": String(q.get("source", "")),
		"desc": String(q.get("text", tr("TOKEN_REROLL_HINT"))),
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
	# Вертикаль клампим ДО твина, а не после: у полярной локации центр кадра лежит
	# за краем карты, твин уводил камеру туда, и _apply_bounds в конце дёргал её
	# обратно. На дальнем зуме рывок доходил до 1080 px.
	var dest := Vector2(tx, _clamp_cam_y(target.y))
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
	# _current_pid() bounds-safe: при гибели всех / переходе фаз current_idx может
	# оказаться за пределами turn_order — раньше был out-of-bounds краш.
	var pid: String = GameState._current_pid()
	if pid.is_empty() or not GameState.players.has(pid):
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
		_apply_tile_filter(new_zoom)


# Открыт ли ЛЮБОЙ веер — руки/имущества ИЛИ чата (отдельный инстанс, монтируется
# chat_composer). Оба в группе "hand_carousel". Если открыт — колесо/клики уходят
# ему, а не карте мира (иначе скролл проваливается в зум карты).
func _fan_open() -> bool:
	for fan: Node in get_tree().get_nodes_in_group("hand_carousel"):
		if fan.has_method("is_open") and fan.call("is_open"):
			return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if GameConsole.is_open():
		return  # консоль открыта — не зумим/не таскаем/не кликаем карту, пока печатаешь
	# Открыта любая модалка — карта не реагирует. Полагаться на затемнение модалки
	# нельзя: Control с MOUSE_FILTER_STOP съедает клик, но КОЛЕСО пропускает сквозь
	# себя, и карта зумилась прямо под окном. Реестр ведёт UIStyle.modal_transition,
	# через который проходят все модалки.
	if UIStyle.any_modal_open():
		return
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
					_zoom_target = clamp(_zoom_target + _wheel_step(), _zoom_min, _zoom_max)
			MOUSE_BUTTON_WHEEL_DOWN:
				if not _fan_open():
					_zoom_target = clamp(_zoom_target - _wheel_step(), _zoom_min, _zoom_max)

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
	GameState.act(RelayActions.SHOP_OPEN)  # старт pre-roll проверки Влияния (карты активируются до броска)
	var modal := _SHOP_MODAL.instantiate()
	modal.name = "ShopModal"
	add_child(modal)
	modal.open()


const _TRADE_MODAL := preload("res://scenes/ui/trade_modal.tscn")


func _on_trade_requested() -> void:
	# Не плодим дубликаты, если уже открыт. open() сам no-op, если менять не с кем.
	if has_node("TradeModal"):
		return
	var modal := _TRADE_MODAL.instantiate()
	modal.name = "TradeModal"
	add_child(modal)
	modal.open()


const _GALLERY_MODAL := preload("res://scenes/ui/gallery_modal.tscn")


func _on_gallery_requested(loc_data: Dictionary) -> void:
	if has_node("GalleryModal"):
		return
	var modal := _GALLERY_MODAL.instantiate()
	modal.name = "GalleryModal"
	add_child(modal)
	modal.open(loc_data)


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


func _on_gate_next() -> void:
	_intro_step = 2
	_refresh_campaign_gate()


func _on_gate_start() -> void:
	_intro_step = 3
	_refresh_campaign_gate()


# ── Хелперы наполнения гейта ──────────────────────────────────────────────────


func _gate_eyebrow(text: String) -> void:
	var lbl := UIStyle.label(
		text, UIStyle.MODAL_FS_HINT, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER
	)
	lbl.name = "Eyebrow"
	_gate_vbox.add_child(lbl)


func _gate_title(text: String) -> void:
	var lbl := UIStyle.label(
		text, UIStyle.MODAL_FS_HERO, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER
	)
	lbl.name = "Title"
	_gate_vbox.add_child(lbl)


func _gate_subtitle(text: String) -> void:
	var lbl := UIStyle.label(
		text, UIStyle.MODAL_FS_BODY, UIColors.WARNING, HORIZONTAL_ALIGNMENT_CENTER
	)
	lbl.name = "Subtitle"
	_gate_vbox.add_child(lbl)


func _gate_body(text: String) -> void:
	var lbl := UIStyle.label(
		text, UIStyle.MODAL_FS_BODY, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
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
	_zoom_target = clamp(value, _zoom_min, _zoom_max)


# ── Границы и горизонтальная бесконечность ────────────────────────────────────


# Допустимая высота центра камеры: полкадра от края карты сверху и снизу. Полоса
# зависит от зума, поэтому считается каждый раз. Карта уже TILE_H в высоту — на
# самом дальнем зуме полоса схлопывается, clamp тогда просто ставит центр.
func _clamp_cam_y(y: float) -> float:
	var half: float = get_viewport().get_visible_rect().size.y * 0.5 / _camera.zoom.y
	if half * 2.0 >= float(MapLayer.TILE_H):
		return float(MapLayer.TILE_H) * 0.5
	return clampf(y, half, float(MapLayer.TILE_H) - half)


func _apply_bounds() -> void:
	# Горизонтальный wrap: камера всегда остаётся в [0, TILE_W)
	# Три тайла рядом делают переход незаметным
	_camera.position.x = fmod(_camera.position.x, float(MapLayer.TILE_W))
	if _camera.position.x < 0.0:
		_camera.position.x += MapLayer.TILE_W

	# Вертикальный clamp: не выходим за верх/низ карты
	_camera.position.y = _clamp_cam_y(_camera.position.y)

	_snap_camera_to_pixel()
