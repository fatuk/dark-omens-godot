class_name Profile
extends RefCounted

## Profile — изоляция per-instance состояния в user://.
##
## Проблема: все инстансы Godot на одной машине делят ОДИН user:// — значит
## один auth.cfg (токен сессии!) и один dark_omens_prefs.cfg. При локальном
## тесте нескольких клиентов это схлопывает их в одного игрока.
##
## Решение: инстансу задаётся свой профиль аргументом запуска
##     --profile=<имя>
## и его клиентские файлы уезжают в  user://profiles/<имя>/ .
##
## Где задать: Debug → Customize Run Instances… → у нужного инстанса вписать
## в его аргументы запуска  --profile=p2  (имя любое).
##
## БЕЗ аргумента файлы лежат прямо в user://, как раньше. Поэтому на проде
## (обычный запуск, профиль не задан) поведение не меняется.

static var _profile: String = ""
static var _resolved: bool = false


## Путь к клиентскому файлу с учётом профиля запуска.
##   Profile.path("auth.cfg")  →  "user://auth.cfg"             (без --profile)
##                             →  "user://profiles/p2/auth.cfg" (--profile=p2)
static func path(file_name: String) -> String:
	_ensure_resolved()
	if _profile.is_empty():
		return "user://" + file_name
	return "user://profiles/%s/%s" % [_profile, file_name]


## Имя активного профиля ("" — дефолтный, файлы прямо в user://).
static func current() -> String:
	_ensure_resolved()
	return _profile


## Разбирает --profile=NAME из аргументов запуска один раз и кеширует.
static func _ensure_resolved() -> void:
	if _resolved:
		return
	_resolved = true
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for a: String in args:
		if a.begins_with("--profile="):
			_profile = a.trim_prefix("--profile=").strip_edges().validate_filename()
			break
	if _profile.is_empty():
		return
	# Каталог профиля должен существовать до первой записи ConfigFile.
	var dir: String = "user://profiles/" + _profile
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	print("[Profile] активный профиль запуска: %s  →  %s/" % [_profile, dir])
