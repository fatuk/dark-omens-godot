# Юнит-тесты (GUT)

Логическое ядро игры покрыто юнит-тестами на [GUT](https://github.com/bitwes/Gut)
(Godot Unit Test). Тесты прогоняются **headless** — без открытия редактора и без
сети/релея — поэтому быстрые и детерминированные.

## Установка GUT

Аддон не вендорится в репозиторий (как и `addons/godot_mcp` — см. `.gitignore`),
ставится локально:

```bash
git clone --depth 1 https://github.com/bitwes/Gut.git /tmp/gut
cp -r /tmp/gut/addons/gut <корень проекта>/addons/gut
```

Версия, на которой писались тесты: **GUT 9.6.0**, Godot **4.6.2**. Включать
плагин в редакторе не обязательно — для headless-прогона достаточно файлов
`addons/gut/`.

## Запуск

```powershell
.\run_tests.ps1                  # весь набор test/unit/
.\run_tests.ps1 test_dice.gd     # один файл
```

Скрипт ищет Godot в `$env:GODOT`, иначе — команду `godot` в `PATH`. Задайте
`$env:GODOT` под свою сборку (например, `$env:GODOT = 'C:\path\to\Godot_console.exe'`).
Конфиг прогона — `.gutconfig.json` в корне.

Напрямую:

```powershell
& $godot --headless --path . -s addons/gut/gut_cmdln.gd `
  -gdir=res://test/unit -ginclude_subdirs -gexit
```

## Что покрыто

`test/unit/` — 27 файлов; исходники под `scripts/core/game/` и `scripts/core/data/`.
Основные области:

| Область | Файлы |
|---------|-------|
| Effect-DSL интерпретатор | `test_effect_runner.gd`, `test_effect_runner_interactive.gd`, `test_verb_manifest.gd` |
| Броски и проверки | `test_dice.gd`, `test_check_flow.gd` |
| Фазы и действия хоста | `test_phase_controller.gd`, `test_relay_action_registry.gd` |
| Встречи / бой / магазин | `test_encounter_flow.gd` |
| Состояния и Расплата | `test_condition_flow.gd`, `test_conditions.gd`, `test_reckoning_flow.gd`, `test_reckoning_data.gd` |
| Мифы и цели | `test_mythos_foreach.gd`, `test_mythos_in_play.gd`, `test_target_resolver.gd` |
| Заклинания / Тайны / Слухи | `test_spell_flow.gd`, `test_spell_catalog.gd`, `test_mystery_flow.gd`, `test_rumor_flow.gd` |
| Поле, кампания, монстры | `test_board_state.gd`, `test_campaign_gen.gd`, `test_monster_catalog.gd` |
| Данные и i18n | `test_data_integrity.gd`, `test_messages.gd`, `test_action_log.gd` |
| UI | `test_game_card.gd`, `test_ui_style.gd` |

`test_data_integrity.gd` — ссылочная целостность боевых JSON (состояния, verb'ы в
манифесте, симметрия локаций, стартовые наборы сыщиков).

## Принципы

- **Детерминизм.** Броски в Effect-DSL фиксируются через `flow.rolls[path]`
  (путь верхнеуровневой ноды `i` == `String(i)`) — записанный бросок
  переигрывается без ГСЧ. Случайные ветки (`flipCard` через `test`/`dieRoll`,
  triggered-броски) пока не покрыты — для них нужен инъецируемый ГСЧ.
- **Моки.** Общий мок `GameState` — `test/unit/helpers/mock_game_state.gd`
  (публичный контракт: `is_host`, `name_of`, `current_pid`, `emit_changed`,
  `broadcast_sync`, `apply_board_effect`, `announce_action` + общие поля стейта).
  Специфичное для модуля — наследованием в тесте:
  `class Mock extends "res://test/unit/helpers/mock_game_state.gd":`.
- **Реальные данные.** Тесты используют боевые `data/conditions.json` и
  `data/assets.json` (например, `poisoned` → `loseHealth 1`), так что заодно
  ловят рассинхрон данных и интерпретатора.
