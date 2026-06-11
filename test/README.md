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

Скрипт ищет Godot в `$env:GODOT`, иначе берёт дефолтный путь (правится в
`run_tests.ps1`). Конфиг прогона — `.gutconfig.json` в корне.

Напрямую:

```powershell
& $godot --headless --path . -s addons/gut/gut_cmdln.gd `
  -gdir=res://test/unit -ginclude_subdirs -gexit
```

## Что покрыто

| Файл | Модуль | Поверхность |
|------|--------|-------------|
| `test_effect_runner.gd` | `scripts/core/effect_runner.gd` | интерпретатор Effect-DSL: игровые verb'ы + кламп, `group`/`choice`/`dieRoll`/`test`, `when`, `repeat`, маршрутизация целей |
| `test_dice.gd` | `scripts/core/dice.gd` | броски d6, подсчёт успехов (≥5), переброс провала, конвейер модификаторов карт (pre/post-roll) |
| `test_condition_flow.gd` | `scripts/core/condition_flow.gd` | whileHeld-ограничения, расплата (детерминированный `onReckoning`), подавление flipped, выдача активов с `onGain` |

## Принципы

- **Детерминизм.** Броски в Effect-DSL фиксируются через `flow.rolls[path]`
  (путь верхнеуровневой ноды `i` == `String(i)`) — записанный бросок
  переигрывается без ГСЧ. Случайные ветки (`flipCard` через `test`/`dieRoll`,
  triggered-броски) пока не покрыты — для них нужен инъецируемый ГСЧ.
- **Моки.** `ConditionFlow` обращается к `GameState` только через четыре члена
  (`players`, `_is_host`, `_name_of`, `_apply_board_effect`) — в тестах это
  минимальный `MockGameState extends Node`.
- **Реальные данные.** Тесты используют боевые `data/conditions.json` и
  `data/assets.json` (например, `poisoned` → `loseHealth 1`), так что заодно
  ловят рассинхрон данных и интерпретатора.
