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

const SFX_SLIDE:          AudioStream = preload("res://assets/audio/sfx/slide.wav")
const SFX_BTN_CLICK:      AudioStream = preload("res://assets/audio/sfx/btn-click.wav")
const SFX_SIDEBAR_SLIDE:  AudioStream = preload("res://assets/audio/sfx/sidebar-slide.wav")
## Наведение/уход курсора с жетонов локации (колода выезжает/прячется).
const SFX_MAP_ITEM_HOVER: AudioStream = preload("res://assets/audio/sfx/map-item-hover.wav")
const SFX_MAP_ITEM_BLUR:  AudioStream = preload("res://assets/audio/sfx/map-item-blur.wav")
## Сдвиг омена (компасный диск проворачивается на новую ступень).
const SFX_OMEN_MOVE:      AudioStream = preload("res://assets/audio/sfx/omen-move.wav")
## Открытие модалки карты Мифов.
const SFX_MYTHOS_START:   AudioStream = preload("res://assets/audio/sfx/myth-start.wav")
## Движение дум-трека (Рок продвинулся).
const SFX_DOOM_MOVE:      AudioStream = preload("res://assets/audio/sfx/doom-track-move.wav")
## Открытие врат на локации.
const SFX_OPEN_GATE:      AudioStream = preload("res://assets/audio/sfx/open-gate.wav")
## Выкладывание улики на локацию.
const SFX_CLUE_OPEN:      AudioStream = preload("res://assets/audio/sfx/clue-open.wav")
## Подсматривание следующего омена по наведению (peek in) и возврат (peek out).
const SFX_OMEN_PICK_IN:   AudioStream = preload("res://assets/audio/sfx/omen-pick-in.wav")
const SFX_OMEN_PICK_OUT:  AudioStream = preload("res://assets/audio/sfx/omen-pick-out.wav")

const BUS_NAME := "Sfx"
const _POOL_SIZE: int = 4

var volume: float = 0.5   # 0.0..1.0, линейная шкала (default override: SettingsStore.sfx_volume)

var _pool: Array[AudioStreamPlayer] = []
var _next: int = 0


func _ready() -> void:
	# SFX играет на паузе (без этого PauseMenu глушит весь звук).
	process_mode = Node.PROCESS_MODE_ALWAYS
	AudioBuses.ensure_bus(BUS_NAME)
	for i in range(_POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.name = "Player_%d" % i
		p.bus  = BUS_NAME
		add_child(p)
		_pool.append(p)
	# SettingsStore зарегистрирован раньше — его поля уже загружены.
	set_volume(SettingsStore.sfx_volume)


## Проиграть SFX. Берёт следующий плеер из пула — даже если предыдущий
## ещё играет, новый звук стартует поверх (овелап).
func play(stream: AudioStream) -> void:
	if stream == null:
		return
	var p: AudioStreamPlayer = _pool[_next]
	_next = (_next + 1) % _POOL_SIZE
	p.stream = stream
	p.play()


## Установить громкость (линейно 0..1). Применяется к шине мгновенно.
## Persist делает SettingsStore.save() при сохранении настроек.
func set_volume(linear: float) -> void:
	volume = clampf(linear, 0.0, 1.0)
	AudioBuses.apply_linear_volume(BUS_NAME, volume)
