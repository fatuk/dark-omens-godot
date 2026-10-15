## Ореол «сейчас ходит» на пине сыщика появляется и гаснет плавно, а не скачком.
extends GutTest


func test_pin_glow_fades_in_and_out() -> void:
	var pin: InvestigatorPin = add_child_autofree(InvestigatorPin.new())
	pin.set_active(true)
	var glow: Node = pin.get_node_or_null("TurnGlow")
	assert_not_null(glow, "ореол создан")
	assert_lt(pin._turn_level, 0.5, "в первый момент — почти невидим")
	await wait_seconds(InvestigatorPin.GLOW_FADE + 0.15)
	assert_almost_eq(pin._turn_level, 1.0, 0.01, "проявился полностью")
	pin.set_active(false)
	assert_true(is_instance_valid(glow), "гаснет, а не пропадает сразу")
	await wait_seconds(InvestigatorPin.GLOW_FADE + 0.15)
	assert_false(is_instance_valid(glow), "погас — нода убрана")


func test_reactivate_mid_fade_keeps_glow() -> void:
	var pin: InvestigatorPin = add_child_autofree(InvestigatorPin.new())
	pin.set_active(true)
	await wait_seconds(InvestigatorPin.GLOW_FADE + 0.15)
	pin.set_active(false)
	await wait_seconds(0.1)
	pin.set_active(true)
	await wait_seconds(InvestigatorPin.GLOW_FADE + 0.15)
	assert_not_null(pin.get_node_or_null("TurnGlow"), "снова ходит — ореол на месте")
	assert_almost_eq(pin._turn_level, 1.0, 0.01)
