extends Node

## Глобальный плеер фоновой музыки. Один AudioStreamPlayer, переключается
## между треками. Если просят сыграть уже играющий трек — игнорируем (так
## music переживает переход login → main_menu без рестарта).
##
## Также владеет аудио-шиной "Music" и persisting'ом громкости — на старте
## создаёт шину (если ещё нет) и подтягивает значение из settings.cfg.
##
## Использование:
##   MusicManager.play(MusicManager.TRACK_ELDER_SIGN)
##   MusicManager.set_volume(0.7)

const TRACK_ELDER_SIGN: AudioStream = preload("res://assets/audio/music/Elder  sign.ogg")
const TRACK_NO_CHOICE:  AudioStream = preload("res://assets/audio/music/No choice.ogg")

const BUS_NAME := "Music"

var volume: float = 0.5   # 0.0..1.0, линейная шкала (default override: SettingsStore.music_volume)

var _player: AudioStreamPlayer
# Web autoplay policy: AudioContext suspended до первого user gesture.
# Если вызвать play() раньше — звук не пойдёт. Откладываем play() до _input
# на вебе; на нативе ставим флаг сразу в true.
var _user_activated: bool = true
var _pending_stream:  AudioStream = null


func _ready() -> void:
	# Музыка играет на паузе (без этого PauseMenu глушит весь звук).
	process_mode = Node.PROCESS_MODE_ALWAYS
	AudioBuses.ensure_bus(BUS_NAME)
	_player = AudioStreamPlayer.new()
	_player.name = "Player"
	_player.bus  = BUS_NAME
	add_child(_player)
	_ensure_loop(TRACK_ELDER_SIGN)
	_ensure_loop(TRACK_NO_CHOICE)
	# SettingsStore зарегистрирован раньше нас в [autoload], так что его поля
	# уже загружены из cfg к моменту нашего _ready.
	set_volume(SettingsStore.music_volume)
	if OS.has_feature("web"):
		_user_activated = false


# На вебе первый клик/нажатие клавиши «открывает» AudioContext браузера —
# тогда и стартуем отложенный трек. На нативе этот путь не используется.
func _input(_event: InputEvent) -> void:
	if _user_activated:
		return
	_user_activated = true
	if _pending_stream != null:
		_play_now(_pending_stream)
		_pending_stream = null


func _ensure_loop(stream: AudioStream) -> void:
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true


## Начать играть `stream`. Если этот же поток уже играет — no-op.
## На вебе до первого user gesture откладывает запуск — браузер всё равно
## не даст звуку проиграть в suspended AudioContext.
func play(stream: AudioStream) -> void:
	if stream == null:
		return
	if not _user_activated:
		_pending_stream = stream
		return
	_play_now(stream)


func _play_now(stream: AudioStream) -> void:
	if _player.stream == stream and _player.playing:
		return
	_player.stream = stream
	_player.play()


func stop() -> void:
	_player.stop()
	_player.stream = null


## Установить громкость (линейно 0..1). Применяется к шине мгновенно.
## Persist делает SettingsStore.save() при сохранении настроек.
func set_volume(linear: float) -> void:
	volume = clampf(linear, 0.0, 1.0)
	AudioBuses.apply_linear_volume(BUS_NAME, volume)
