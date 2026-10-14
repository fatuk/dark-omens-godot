## TradeModal одноразовая: закрытие (отмена / отправка / «не с кем меняться») освобождает
## ноду. Регрессия: окно только пряталось, нода "TradeModal" оставалась у WorldMap, и
## его has_node("TradeModal") глотал все следующие нажатия «Обмен».
extends GutTest

const _TRADE_MODAL := preload("res://scenes/ui/trade_modal.tscn")
const _TRADE_SCRIPT := preload("res://scripts/ui/trade_modal.gd")

var _saved_uid: String


func before_each() -> void:
	_saved_uid = NetworkManager.my_user_id
	NetworkManager.my_user_id = "a"
	GameState.reset_session()


func after_each() -> void:
	GameState.reset_session()
	NetworkManager.my_user_id = _saved_uid


func _player(uid: String, loc: String) -> Dictionary:
	return {"user_id": uid, "name": uid, "location": loc, "items": [], "clues": 0}


# Как WorldMap._on_trade_requested: инстанс под именем "TradeModal" + open().
func _open_modal() -> Node:
	var host: Node = add_child_autofree(Node.new())
	host.name = "Host"
	var modal: Node = _TRADE_MODAL.instantiate()
	modal.name = "TradeModal"
	host.add_child(modal)
	modal.open()
	return modal


func test_open_with_ally_shows_window() -> void:
	GameState.players = {"a": _player("a", "5"), "b": _player("b", "5")}
	var modal: Node = _open_modal()
	assert_true((modal.get_node("Root") as Control).visible, "окно обмена показано")
	assert_eq(String(modal.get("_partner")), "b", "напарник — со-локационный сыщик")


func test_cancel_frees_modal_so_next_trade_can_open() -> void:
	GameState.players = {"a": _player("a", "5"), "b": _player("b", "5")}
	var modal: Node = _open_modal()
	var host: Node = modal.get_parent()
	modal.call("_close")
	assert_false(
		host.has_node("TradeModal"), "имя освобождено сразу — повторный «Обмен» не блокирован"
	)
	await wait_seconds(1.0)
	assert_false(is_instance_valid(modal), "после анимации нода освобождена")


func test_no_ally_frees_modal() -> void:
	GameState.players = {"a": _player("a", "5"), "b": _player("b", "7")}
	var modal: Node = _open_modal()
	var host: Node = modal.get_parent()
	assert_false(host.has_node("TradeModal"), "меняться не с кем — нода-блокер не остаётся")
	await wait_process_frames(2)
	assert_false(is_instance_valid(modal), "нода освобождена")


func test_open_for_reuses_static_modal_from_scene() -> void:
	# Регрессия: world_map.tscn держит "TradeModal" статически — WorldMap видел ноду и
	# выходил, окно не открывалось никогда. open_for берёт её и открывает.
	GameState.players = {"a": _player("a", "5"), "b": _player("b", "5")}
	var host: Node = add_child_autofree(Node.new())
	host.name = "Host"
	var static_modal: Node = _TRADE_MODAL.instantiate()
	static_modal.name = "TradeModal"
	host.add_child(static_modal)
	var opened: Node = _TRADE_SCRIPT.open_for(host)
	assert_eq(opened, static_modal, "переиспользована нода из сцены")
	assert_true((opened.get_node("Root") as Control).visible, "окно открыто")


func test_open_for_creates_modal_when_none() -> void:
	GameState.players = {"a": _player("a", "5"), "b": _player("b", "5")}
	var host: Node = add_child_autofree(Node.new())
	host.name = "Host"
	var opened: Node = _TRADE_SCRIPT.open_for(host)
	assert_eq(opened.get_parent(), host)
	assert_true((opened.get_node("Root") as Control).visible, "окно открыто")
