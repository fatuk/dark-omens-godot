## GuideHint — подсказка профессора Армитеджа: реплики по клику, после последней
## окно закрывается, шлёт finished и освобождается; пока открыто — в реестре модалок
## (карта под ним не зумится).
extends GutTest


func _host() -> Node:
	var host: Node = add_child_autofree(Node.new())
	host.name = "Host"
	return host


func test_lines_advance_then_close() -> void:
	var g: GuideHint = GuideHint.say(_host(), ["GUIDE_HELLO", "вторая"])
	var done := {"v": false}
	g.finished.connect(func() -> void: done["v"] = true)
	var text: Label = g.find_child("Text", true, false)
	assert_eq(text.text, "GUIDE_HELLO", "первая реплика")
	assert_true(UIStyle.any_modal_open(), "окно в реестре модалок")
	g.call("_advance")
	assert_eq(text.text, "вторая", "клик — следующая реплика")
	assert_eq((g.find_child("Continue", true, false) as Label).text, "GUIDE_CLOSE")
	g.call("_advance")
	await wait_seconds(0.5)
	assert_true(done["v"], "finished отправлен")
	assert_false(is_instance_valid(g), "после последней реплики окно освобождено")
	assert_false(UIStyle.any_modal_open(), "и снято из реестра")


func test_empty_lines_close_immediately() -> void:
	var g: GuideHint = GuideHint.say(_host(), [])
	await wait_seconds(0.5)
	assert_false(is_instance_valid(g))


func test_frame_fits_text() -> void:
	var g: GuideHint = GuideHint.say(_host(), ["GUIDE_HELLO"])
	await wait_process_frames(3)
	var frame: Control = g.find_child("Frame", true, false)
	var art: Control = g.find_child("Armitage", true, false)
	assert_lt(frame.size.y, 400.0, "рамка по тексту, а не до низа экрана")
	assert_lt(frame.position.x, art.position.x + 100.0, "рамка слева от профессора")
