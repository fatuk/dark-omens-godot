## Лоток кубов подсвечивает успехи по порогу бросающего: Благословение — 4+,
## Проклятие — только 6 (как хост считает успехи в CheckFlow).
extends GutTest

var _saved: Dictionary


func before_each() -> void:
	_saved = GameState.players
	GameState.players = {
		"b": {"user_id": "b", "conditions": ["blessed"]},
		"c": {"user_id": "c", "conditions": ["cursed"]},
		"n": {"user_id": "n", "conditions": []},
	}


func after_each() -> void:
	GameState.players = _saved


func _lit(pid: String) -> Array:
	var tray: DiceTray = add_child_autofree(DiceTray.new())
	tray.set_roller(pid)
	tray.show_roll([4, 5, 6])
	var out: Array = []
	for d: Dictionary in tray._dice:
		out.append((d["glow"] as TextureRect).visible)
	return out


func test_blessed_lights_fours() -> void:
	assert_eq(_lit("b"), [true, true, true])


func test_cursed_lights_only_sixes() -> void:
	assert_eq(_lit("c"), [false, false, true])


func test_plain_lights_fives_and_sixes() -> void:
	assert_eq(_lit("n"), [false, true, true])
