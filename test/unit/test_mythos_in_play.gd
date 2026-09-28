extends GutTest

## Юнит-тесты учёта ongoing-карт Мифов (MythosFlow._register_in_play / _has_ongoing):
## карта с whileInPlay/onReckoning-эффектом остаётся в игре, чистые event/триггер — нет.

var _gs: MockGS
var _m: MythosFlow


# Стаб генератора кампании: считает перезапуски сборки, ничего не собирает.
class StubCampaignGen:
	extends RefCounted
	var starts: Array = []

	func balance_player_count() -> int:
		return 2

	func start_generation(player_count: int, ancient_one: String) -> void:
		starts.append({"pc": player_count, "ao": ancient_one})


class MockGS:
	extends Node
	var mythos_in_play: Array = []
	var _rumor: RumorFlow
	# Поля/стабы для гейта «Прочитал» (mark_read/_all_read).
	var phase: String = Phases.MYTHOS
	var current_mythos: Dictionary = {"name": "Card"}
	var players: Dictionary = {}
	var mythos_read: Array = []
	var host: bool = true
	# Для enter_phase: фаза, встреча, сигнал и кампания (id — ключ восстановления
	# колоды; пусто — восстанавливать нечего).
	var current_encounter: Dictionary = {}
	var last_mythos: Dictionary = {}
	var outcome: String = ""
	var campaign: Dictionary = {}
	var campaign_pending: bool = false
	var _campaign: StubCampaignGen = StubCampaignGen.new()
	signal phase_changed(phase: String)

	func _init() -> void:
		_rumor = RumorFlow.new(self)

	func is_host() -> bool:
		return host

	func broadcast_sync() -> void:
		pass

	func emit_changed() -> void:
		pass


func before_each() -> void:
	_gs = autofree(MockGS.new())
	_m = MythosFlow.new(_gs)


func test_ongoing_reckoning_card_registered() -> void:
	_m._register_in_play({"name": "Bad Karma", "onReckoning": [{"dieRoll": []}]})
	assert_eq((_gs.mythos_in_play as Array).size(), 1, "карта с onReckoning-эффектом — в игре")


func test_while_in_play_card_registered() -> void:
	_m._register_in_play({"name": "Aura", "whileInPlay": [{"do": "cannotRecover"}]})
	assert_eq((_gs.mythos_in_play as Array).size(), 1, "карта с whileInPlay — в игре")


func test_pure_trigger_card_not_registered() -> void:
	_m._register_in_play({"name": "Trigger", "onReckoning": [{"do": "resolveReckoning"}]})
	assert_eq(
		(_gs.mythos_in_play as Array).size(), 0, "только триггер resolveReckoning — не в игре"
	)


func test_event_card_not_registered() -> void:
	_m._register_in_play({"name": "Event", "onDraw": [{"do": "gainClue", "count": 1}]})
	assert_eq((_gs.mythos_in_play as Array).size(), 0, "чистый event — не в игре")


func test_dedup_by_name() -> void:
	var c: Dictionary = {"name": "Bad Karma", "onReckoning": [{"dieRoll": []}]}
	_m._register_in_play(c)
	_m._register_in_play(c)
	assert_eq((_gs.mythos_in_play as Array).size(), 1, "повтор той же карты не дублируется")


# ── Гейт «Прочитал»: миф резолвится только когда отметились все ────────────────


func test_read_gate_partial_does_not_resolve() -> void:
	_gs.players = {"p1": {"connected": true}, "p2": {"connected": true}}
	_gs.current_mythos = {"name": "Card"}
	_gs.mythos_read = []
	_m.mark_read("p1")
	assert_eq(_gs.mythos_read, ["p1"], "p1 отмечен прочитавшим")
	assert_false(_gs.current_mythos.is_empty(), "карта НЕ резолвится — p2 ещё не прочитал")
	assert_false(_m._all_read(), "не все прочитали")


func test_read_gate_no_duplicate_marks() -> void:
	_gs.players = {"p1": {"connected": true}, "p2": {"connected": true}}
	_gs.mythos_read = []
	_m.mark_read("p1")
	_m.mark_read("p1")
	assert_eq((_gs.mythos_read as Array).size(), 1, "повторное «Прочитал» не копит дубли")


func test_read_gate_ignores_disconnected() -> void:
	_gs.players = {"p1": {"connected": true}, "p2": {"connected": false}}
	_gs.mythos_read = ["p1"]
	assert_true(_m._all_read(), "отключённый p2 не блокирует — все подключённые прочитали")


func test_read_gate_ignores_unknown_pid() -> void:
	_gs.players = {"p1": {"connected": true}}
	_gs.mythos_read = []
	_m.mark_read("ghost")  # нет в players — игнор
	assert_true((_gs.mythos_read as Array).is_empty(), "чужой pid не отмечается")


# ── Пустая колода на входе в фазу ─────────────────────────────────────────────


func test_enter_phase_without_campaign_falls_back_to_placeholder() -> void:
	# Колоды нет и восстанавливать её не по чему (кампании нет) — рисуем заглушку
	# СИНХРОННО, без зависаний: этот путь идёт в тестах и в офлайне.
	_m.deck = []
	_gs.campaign = {}
	_m.enter_phase()
	assert_eq(String(_gs.current_mythos.get("name", "")), "Эхо Древних", "заглушка вытянута")
	assert_eq(_gs.phase, Phases.MYTHOS)


func test_campaign_id_read_from_game_state() -> void:
	# Ключ повторного восстановления — id кампании из GameState. Именно по нему
	# хост дотягивает колоду, если единственная попытка при реджойне упала.
	_gs.campaign = {"id": "abc-123"}
	assert_eq(_m._campaign_id(), "abc-123")
	_gs.campaign = {}
	assert_eq(_m._campaign_id(), "", "нет кампании — нечего восстанавливать")


func test_enter_phase_with_deck_draws_without_restore() -> void:
	# Колода на месте — обычная вытяжка, восстановление не трогаем (иначе каждая
	# фаза ходила бы в API).
	_m.deck = [{"name": "Первая", "onDraw": []}, {"name": "Вторая", "onDraw": []}]
	_m.index = 0
	_gs.campaign = {"id": "abc-123"}
	_m.enter_phase()
	assert_eq(String(_gs.current_mythos.get("name", "")), "Первая", "вытянута карта колоды")


# ── Нет кампании — перезапуск сборки ──────────────────────────────────────────


func test_enter_phase_without_campaign_restarts_generation() -> void:
	# Сборка при старте упала (API лежал), партия идёт без кампании: без колоды и
	# со встречами-заглушками. На входе в фазу Мифов сборку надо перезапустить.
	_m.deck = []
	_gs.campaign = {}
	_gs.campaign_pending = false
	_m.enter_phase()
	assert_eq(_gs._campaign.starts.size(), 1, "сборка перезапущена")
	assert_eq(int(_gs._campaign.starts[0]["pc"]), 2, "размер партии — от CampaignGen")
	assert_eq(String(_gs.current_mythos.get("name", "")), "Эхо Древних", "эту фазу — заглушка")


func test_enter_phase_does_not_restart_while_pending() -> void:
	# Сборка уже идёт — второй запуск породил бы гонку двух эпох.
	_m.deck = []
	_gs.campaign = {}
	_gs.campaign_pending = true
	_m.enter_phase()
	assert_eq(_gs._campaign.starts.size(), 0, "идущую сборку не перезапускаем")


func test_enter_phase_with_campaign_does_not_restart() -> void:
	# Кампания есть — генерацию не трогаем ни при какой колоде.
	_m.deck = []
	_gs.campaign = {"id": "abc-123"}
	_m.enter_phase()
	assert_eq(_gs._campaign.starts.size(), 0, "с кампанией сборку не перезапускаем")
