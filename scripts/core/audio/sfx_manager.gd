extends Node

## Глобальный проигрыватель SFX. Пул из нескольких AudioStreamPlayer'ов
## (round-robin), чтобы быстрые подряд проигрывания не обрывали друг друга
## — например, пользователь часто кликает по стрелкам карусели.
##
## Также владеет аудио-шиной "Sfx" и подтягивает её громкость из settings.cfg.
##
## Использование:
##   SfxManager.play(SfxManager.SFX_SLIDE)
##   SfxManager.set_volume(0.5)

const SFX_SLIDE: AudioStream = preload("res://assets/audio/sfx/slide.wav")
const SFX_BTN_CLICK: AudioStream = preload("res://assets/audio/sfx/btn-click.wav")
const SFX_SIDEBAR_SLIDE: AudioStream = preload("res://assets/audio/sfx/sidebar-slide.wav")
## Наведение/уход курсора с жетонов локации (колода выезжает/прячется).
const SFX_MAP_ITEM_HOVER: AudioStream = preload("res://assets/audio/sfx/map-item-hover.wav")
const SFX_MAP_ITEM_BLUR: AudioStream = preload("res://assets/audio/sfx/map-item-blur.wav")
## Сдвиг омена (компасный диск проворачивается на новую ступень).
const SFX_OMEN_MOVE: AudioStream = preload("res://assets/audio/sfx/omen-move.wav")
## Открытие модалки карты Мифов.
const SFX_MYTHOS_START: AudioStream = preload("res://assets/audio/sfx/myth-start.wav")
## Движение дум-трека (Рок продвинулся).
const SFX_DOOM_MOVE: AudioStream = preload("res://assets/audio/sfx/doom-track-move.wav")
## Открытие врат на локации.
const SFX_OPEN_GATE: AudioStream = preload("res://assets/audio/sfx/open-gate.wav")
## Выкладывание улики на локацию.
const SFX_CLUE_OPEN: AudioStream = preload("res://assets/audio/sfx/clue-open.wav")
## Подсматривание следующего омена по наведению (peek in) и возврат (peek out).
const SFX_OMEN_PICK_IN: AudioStream = preload("res://assets/audio/sfx/omen-pick-in.wav")
const SFX_OMEN_PICK_OUT: AudioStream = preload("res://assets/audio/sfx/omen-pick-out.wav")
## Бросок кубов: клаттер в начале файла + «активация» в хвосте (после тихого участка).
## DiceTray нарезает сегментами через play_variation: клаттер под спин, активация — на оседание.
const SFX_DICE: AudioStream = preload("res://assets/audio/sfx/dice-roll.wav")

const BUS_NAME := "Sfx"
const _POOL_SIZE: int = 4

## Оживление частых повторов (клики кнопок, карусель): вместо джиттера громкости
## (плохо считывался) — полосовой фильтр на средних частотах со случайным центром
## за каждое проигрывание. Меняющийся тембр читается заметнее. Шина-вариация на
## каждый плеер пула (round-robin → перекрытия не делят один фильтр).
const FILTER_CENTER_HZ: float = 1500.0  # центр полосы (средние частоты)
const FILTER_JITTER_HZ: float = 350.0  # ± случайный сдвиг центра за проигрывание
const FILTER_RESONANCE: float = 0.5  # Q полосы (ниже — шире, мягче окрас)

var volume: float = 0.5  # 0.0..1.0, линейная шкала (default override: SettingsStore.sfx_volume)

var _pool: Array[AudioStreamPlayer] = []
var _next: int = 0
var _var_filters: Array = []  # band-pass-фильтр на каждой шине-вариации (по плееру)


func _ready() -> void:
	# SFX играет на паузе (без этого PauseMenu глушит весь звук).
	process_mode = Node.PROCESS_MODE_ALWAYS
	AudioBuses.ensure_bus(BUS_NAME)
	for i in range(_POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.name = "Player_%d" % i
		p.bus = BUS_NAME
		add_child(p)
		_pool.append(p)
	_setup_var_buses()
	# SettingsStore зарегистрирован раньше — его поля уже загружены.
	set_volume(SettingsStore.sfx_volume)


# По шине-вариации на каждый плеер пула: band-pass-фильтр, маршрут → Sfx (наследует
# громкость). Идемпотентно — шины AudioServer переживают перезагрузку сцены.
func _setup_var_buses() -> void:
	_var_filters.clear()
	for i in range(_POOL_SIZE):
		var bus_name := "SfxVar%d" % i
		var idx: int = AudioServer.get_bus_index(bus_name)
		if idx == -1:
			idx = AudioServer.bus_count
			AudioServer.add_bus(idx)
			AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, BUS_NAME)
		var filt: AudioEffectBandPassFilter
		if AudioServer.get_bus_effect_count(idx) > 0:
			filt = AudioServer.get_bus_effect(idx, 0)
		else:
			filt = AudioEffectBandPassFilter.new()
			AudioServer.add_bus_effect(idx, filt)
		filt.cutoff_hz = FILTER_CENTER_HZ
		filt.resonance = FILTER_RESONANCE
		_var_filters.append(filt)


## Проиграть SFX. Берёт следующий плеер из пула — даже если предыдущий ещё играет,
## новый звук стартует поверх (овелап). filtered=true — играть через шину-вариацию
## со случайным центром band-pass (оживляет частые повторы: клики, карусель).
func play(stream: AudioStream, filtered: bool = false) -> void:
	if stream == null:
		return
	var i: int = _next
	_next = (_next + 1) % _POOL_SIZE
	var p: AudioStreamPlayer = _pool[i]
	# Сбрасываем питч — пул переиспользуется.
	p.pitch_scale = 1.0
	if filtered and i < _var_filters.size():
		(_var_filters[i] as AudioEffectBandPassFilter).cutoff_hz = (
			FILTER_CENTER_HZ + randf_range(-FILTER_JITTER_HZ, FILTER_JITTER_HZ)
		)
		p.bus = "SfxVar%d" % i
	else:
		p.bus = BUS_NAME
	p.stream = stream
	p.play()


## Проиграть СЛУЧАЙНУЮ ВАРИАЦИЮ из одного файла, нарезанного по времени на
## `variations` равных кусков. Берёт кусок k = randi() % variations, играет с его
## позиции и обрывает в конце сегмента (иначе звук поехал бы в следующую вариацию).
## pitch_jitter (0..1) — случайный сдвиг высоты ±jitter для доп. разнообразия.
##
## variations <= 1 → файл играется целиком через общий пул (только питч-джиттер).
## Лучше всего, если между вариациями в файле есть короткая тишина — тогда обрыв
## сегмента приходится на паузу и не щёлкает.
## `segments` (опционально) — список [start_sec, end_sec] для точной нарезки под
## реальный файл (например, вариации разной длины с паузами). Если задан — играет
## случайный из них; иначе работает равная нарезка по `variations`.
func play_variation(
	stream: AudioStream,
	variations: int = 1,
	pitch_jitter: float = 0.0,
	segments: Array = [],
) -> void:
	if stream == null:
		return
	var jitter: float = 1.0
	if pitch_jitter > 0.0:
		jitter = 1.0 + randf_range(-pitch_jitter, pitch_jitter)

	var total: float = stream.get_length()

	# Явные сегменты — приоритет.
	if not segments.is_empty():
		var s: Array = segments[randi() % segments.size()]
		var start: float = float(s[0])
		var dur: float = maxf(0.0, float(s[1]) - start)
		_play_segment(stream, start, dur, jitter)
		return

	# Один кусок (нет нарезки) — целиком через пул, только питч.
	if variations <= 1 or total <= 0.0:
		var p: AudioStreamPlayer = _pool[_next]
		_next = (_next + 1) % _POOL_SIZE
		p.pitch_scale = jitter
		p.bus = BUS_NAME  # пул мог остаться на шине-вариации от play(filtered)
		p.stream = stream
		p.play()
		return

	# Равная нарезка на N кусков по времени.
	var seg: float = total / float(variations)
	var k: int = randi() % variations
	_play_segment(stream, seg * float(k), seg, jitter)


# Отдельный плеер на сегмент [start, start+dur]: играем с позиции и глушим в
# конце (пул переиспользуется round-robin'ом — отложенный stop оборвал бы чужое).
func _play_segment(stream: AudioStream, start: float, dur: float, pitch: float) -> void:
	var tp := AudioStreamPlayer.new()
	tp.name = "Player"
	tp.bus = BUS_NAME
	tp.pitch_scale = pitch
	tp.stream = stream
	add_child(tp)
	tp.play(start)
	# Длительность на экране = dur / pitch (питч ускоряет/замедляет). Если dur не
	# задан — доигрываем до конца файла.
	var wait: float = (dur / pitch) if dur > 0.0 else maxf(0.05, stream.get_length() - start)
	await get_tree().create_timer(maxf(0.02, wait)).timeout
	if is_instance_valid(tp):
		tp.stop()
		tp.queue_free()


## Установить громкость (линейно 0..1). Применяется к шине мгновенно.
## Persist делает SettingsStore.save() при сохранении настроек.
func set_volume(linear: float) -> void:
	volume = clampf(linear, 0.0, 1.0)
	AudioBuses.apply_linear_volume(BUS_NAME, volume)
