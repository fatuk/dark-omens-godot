extends GutTest

## Полнота и целостность реестра relay-действий (GameState._relay_actions) и
## выведенного из него набора pid-владельческих (_pid_owned). Диспетчер
## _on_relay_received заменил ~28 веток match на lookup — этот тест гарантирует,
## что каждое действие зарегистрировано, значения — Callable, а pid-набор выведен
## верно (все действия реестра, кроме безадресных). Ловит забытую регистрацию и
## рассинхрон _pid_owned после рефактора роутера.

# Host-only действия, НЕ действующие от лица pid (исключены из _pid_owned):
# resolve_mythos (без pid) и set_ready (поздний вход по connection id).
const _NON_PID_ACTIONS := [RelayActions.RESOLVE_MYTHOS, RelayActions.SET_READY]

# Транзиентные широковещалки — у них клиентская логика (рендер у всех), в реестре
# их быть НЕ должно (иначе не-хост их бы не обработал).
const _TRANSIENT := [RelayActions.SYNC, RelayActions.CHAT, RelayActions.ACTION_FEED]


func test_registry_entries_are_callable() -> void:
	for a: Variant in GameState._relay_actions:
		assert_true(
			GameState._relay_actions[a] is Callable, "%s: значение реестра не Callable" % String(a)
		)


func test_pid_owned_is_subset_of_registry() -> void:
	var missing: Array = []
	for a: Variant in GameState._pid_owned:
		if not GameState._relay_actions.has(String(a)):
			missing.append(String(a))
	assert_eq(missing, [], "pid-действия без адаптера в реестре: %s" % str(missing))


func test_pid_owned_excludes_non_pid_actions() -> void:
	# resolve_mythos/set_ready есть в реестре, но НЕ должны требовать сверки pid.
	for a: String in _NON_PID_ACTIONS:
		assert_true(GameState._relay_actions.has(a), "нет адаптера для host-действия %s" % a)
		assert_false(GameState._pid_owned.has(a), "%s не должен быть pid-владельческим" % a)


func test_pid_owned_covers_registry_minus_non_pid() -> void:
	# Полный вывод: _pid_owned = ключи реестра минус безадресные. Гарантирует, что
	# новое pid-действие в реестре автоматически попадает под сверку отправителя.
	var expected: int = GameState._relay_actions.size() - _NON_PID_ACTIONS.size()
	assert_eq(
		GameState._pid_owned.size(), expected, "число pid-действий = реестр минус безадресные"
	)


func test_registry_excludes_transient_broadcasts() -> void:
	for a: String in _TRANSIENT:
		assert_false(
			GameState._relay_actions.has(a), "%s не должен быть в реестре (клиентский)" % a
		)
