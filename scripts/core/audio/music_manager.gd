extends Node

## Глобальный плеер фоновой музыки. Два AudioStreamPlayer: смена трека — плавный
## кроссфейд (старый уходит, новый входит), а не обрыв. Если просят сыграть уже
## играющий трек — игнорируем (так музыка переживает переход login → main_menu
## без рестарта).
##
## Также владеет аудио-шиной "Music" и persisting'ом громкости — на старте
## создаёт шину (если ещё нет) и подтягивает значение из settings.cfg.
##
## Использование:
##   MusicManager.play(MusicManager.TRACK_MAIN_THEME)
##   MusicManager.set_volume(0.7)

# Основная тема: меню и карта мира. Прежняя («Elder  sign.ogg») пока не используется.
const TRACK_MAIN_THEME: AudioStream = preload("res://assets/audio/music/dark-omens-main-theme.ogg")
const TRACK_NO_CHOICE: AudioStream = preload("res://assets/audio/music/No choice.ogg")

const BUS_NAME := "Music"
const FADE_SEC := 1.0  # кроссфейд при смене трека (и проявление из тишины)
const _SILENT := 0.0001  # «ноль» линейной громкости плеера (−80 дБ)

var volume: float = 0.5  # 0.0..1.0, линейная шкала (default override: SettingsStore.music_volume)

var _players: Array[AudioStreamPlayer] = []
var _player: AudioStreamPlayer  # активный — тот, что играет (или входит) сейчас
var _fade: Tween
var _target: AudioStream = null  # что ДОЛЖНО звучать (null — тишина, в т.ч. на затухании)
# Web autoplay policy: AudioContext suspended до первого user gesture.
# Если вызвать play() раньше — звук не пойдёт. Откладываем play() до _input
# на вебе; на нативе ставим флаг сразу в true.
var _user_activated: bool = true
var _pending_stream: AudioStream = null


func _ready() -> void:
	# Музыка играет на паузе (без этого PauseMenu глушит весь звук).
	process_mode = Node.PROCESS_MODE_ALWAYS
	AudioBuses.ensure_bus(BUS_NAME)
	for i in range(2):
		var p := AudioStreamPlayer.new()
		p.name = "PlayerA" if i == 0 else "PlayerB"
		p.bus = BUS_NAME
		add_child(p)
		_players.append(p)
	_player = _players[0]
	_ensure_loop(TRACK_MAIN_THEME)
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
	if _target == stream and _player.stream == stream and _player.playing:
		return
	_target = stream
	# Новый трек — во втором плеере с нуля громкости; текущий уходит в тишину.
	var old: AudioStreamPlayer = _player
	_player = _players[1] if old == _players[0] else _players[0]
	_player.stop()
	_player.stream = stream
	_player.volume_db = linear_to_db(_SILENT)
	_player.play()
	_crossfade(old, _player)


func stop() -> void:
	_target = null
	_crossfade(_player, null)


# Громкость каждого плеера идёт линейно (0..1 → дБ): на слух ровнее, чем твин дБ.
# Пользовательская громкость — на шине Music, плееры её не трогают.
func _crossfade(out_p: AudioStreamPlayer, in_p: AudioStreamPlayer) -> void:
	if _fade and _fade.is_valid():
		_fade.kill()
	_fade = create_tween().set_parallel(true)
	if out_p != null and out_p.playing:
		var from: float = db_to_linear(out_p.volume_db)
		_fade.tween_method(_set_linear.bind(out_p), from, _SILENT, FADE_SEC)
	if in_p != null:
		_fade.tween_method(_set_linear.bind(in_p), _SILENT, 1.0, FADE_SEC)
	_fade.chain().tween_callback(
		func() -> void:
			# Ушедший плеер глушим совсем, чтобы не крутил поток вхолостую.
			for p in _players:
				if p != in_p:
					p.stop()
					p.stream = null
	)


static func _set_linear(v: float, p: AudioStreamPlayer) -> void:
	p.volume_db = linear_to_db(maxf(v, _SILENT))


## Установить громкость (линейно 0..1). Применяется к шине мгновенно.
## Persist делает SettingsStore.save() при сохранении настроек.
func set_volume(linear: float) -> void:
	volume = clampf(linear, 0.0, 1.0)
	AudioBuses.apply_linear_volume(BUS_NAME, volume)
