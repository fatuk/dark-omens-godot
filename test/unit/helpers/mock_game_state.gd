extends Node
## Общий мок GameState для юнит-тестов модулей ядра. Покрывает публичный контракт
## GameState (is_host / name_of / current_pid / emit_changed / broadcast_sync /
## apply_board_effect / announce_action) и общие поля стейта. Специфичное для
## модуля — наследованием прямо в тесте:
##
##   class Mock extends "res://test/unit/helpers/mock_game_state.gd":
##       var asset_deck: Array = []
##
## Без class_name намеренно: headless-прогон GUT не обновляет кэш глобальных классов,
## а путь в extends работает всегда. Файл без префикса test_ — GUT его не подбирает.

signal effect_check_applied(pid: String, passed: bool)  # будит интерактивную Расплату
signal mythos_decided(index: int)  # будит выбор в onReckoning (канал mythos_decision)

var host: bool = true
var players: Dictionary = {}
var turn_order: Array = []
var current_idx: int = 0
var active_check: Dictionary = {}
var pending_check: Dictionary = {}
var mythos_decision: Dictionary = {}
var locations: Array = []  # граф для move / выбора клетки
var spell_deck: Array = []  # колода копий заклинаний (SpellFlow)

# Что модуль «сделал» с внешним миром — тесты читают отсюда.
var board_effects: Array = []  # apply_board_effect(node)
var feed: Array = []  # announce_action → {pid, id, params}
var sync_count: int = 0
var emit_count: int = 0

# Граф локаций из тестового списка — пересобирается на каждое чтение, чтобы
# `_gs.locations = [...]` в тесте подхватывалось без setup-хуков.
var map: LocationGraph:
	get:
		return LocationGraph.new(locations)


func is_host() -> bool:
	return host


func name_of(pid: String) -> String:
	return pid


func current_pid() -> String:
	return String(turn_order[current_idx]) if current_idx < turn_order.size() else ""


func emit_changed() -> void:
	emit_count += 1


func broadcast_sync() -> void:
	sync_count += 1


func apply_board_effect(node: Dictionary) -> void:
	board_effects.append(node)


func announce_action(pid: String, action_id: String, params: Dictionary = {}) -> void:
	feed.append({"pid": pid, "id": action_id, "params": params})
