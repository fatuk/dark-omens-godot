## Централизованный роутер сцен Dark Omens.
## Использование: SceneManager.go("world_map")
## Передача данных: SceneManager.go("world_map", {"room_id": "abc"})
extends Node

# ── Реестр сцен ───────────────────────────────────────────────────────────────

const SCENES: Dictionary = {
	"home":       "res://scenes/home.tscn",
	"login":      "res://scenes/login.tscn",
	"main_menu":  "res://scenes/main_menu.tscn",
	"lobby":      "res://scenes/lobby.tscn",
	"world_map":  "res://scenes/world_map.tscn",
}

# ── Данные для передачи между сценами ─────────────────────────────────────────

## Словарь, который целевая сцена может прочитать в _ready().
## Очищается после каждого перехода.
var params: Dictionary = {}


# ── API ───────────────────────────────────────────────────────────────────────

## Переход на сцену по имени. data — необязательные параметры для целевой сцены.
func go(scene_name: String, data: Dictionary = {}) -> void:
	assert(SCENES.has(scene_name), "SceneManager: unknown scene '%s'" % scene_name)
	params = data
	get_tree().change_scene_to_file(SCENES[scene_name])
