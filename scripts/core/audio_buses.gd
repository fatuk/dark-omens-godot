class_name AudioBuses
extends RefCounted

## Утилиты для работы с AudioServer: создание шин и применение линейной
## громкости 0..1 как dB. Идемпотентно — повторные вызовы безопасны.

## Гарантирует наличие шины с указанным именем, маршрутизированной в Master.
## Возвращает индекс шины.
static func ensure_bus(bus_name: String) -> int:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx != -1:
		return idx
	idx = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")
	return idx


## Применяет линейную громкость 0..1 к шине: 0 → mute, иначе volume_db.
## При неизвестной шине молча выходит.
static func apply_linear_volume(bus_name: String, linear: float) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	if linear <= 0.0:
		AudioServer.set_bus_mute(idx, true)
		return
	AudioServer.set_bus_mute(idx, false)
	AudioServer.set_bus_volume_db(idx, linear_to_db(clampf(linear, 0.0, 1.0)))
