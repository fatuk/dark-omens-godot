extends GutTest

## Полнота реестра relay-действий (GameState._relay_actions). Диспетчер
## _on_relay_received заменил ~28 веток match на lookup по реестру — этот тест
## гарантирует, что для каждого действия «от лица игрока» (и служебных host-only)
## есть Callable-адаптер. Забытая регистрация после рефактора роутера — краш «тихо
## ничего не произошло», который здесь ловится статически.

# Host-only действия без pid-владения (не входят в _PID_OWNED_ACTIONS), но должны
# быть в реестре: resolve_mythos (без pid) и set_ready (поздний вход, с active-гардом).
const _EXTRA_HOST_ACTIONS := ["game_resolve_mythos", "set_ready"]


func test_registry_covers_all_pid_owned_actions() -> void:
	var missing: Array = []
	for a: Variant in GameState._PID_OWNED_ACTIONS:
		if not GameState._relay_actions.has(String(a)):
			missing.append(String(a))
	assert_eq(missing, [], "pid-действия без адаптера в реестре: %s" % str(missing))


func test_registry_covers_extra_host_actions() -> void:
	for a: String in _EXTRA_HOST_ACTIONS:
		assert_true(GameState._relay_actions.has(a), "нет адаптера для host-действия %s" % a)


func test_registry_entries_are_callable() -> void:
	for a: Variant in GameState._relay_actions:
		assert_true(
			GameState._relay_actions[a] is Callable, "%s: значение реестра не Callable" % String(a)
		)


# Реестр не должен содержать транзиентные широковещалки — у них клиентская логика
# в match (рендер у всех), а не host-only dispatch. Иначе не-хост их бы не обработал.
func test_registry_excludes_transient_broadcasts() -> void:
	for a: String in ["game_sync", "game_chat", "game_action_feed"]:
		assert_false(
			GameState._relay_actions.has(a), "%s не должен быть в реестре (клиентский)" % a
		)
