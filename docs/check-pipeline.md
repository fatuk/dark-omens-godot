# Пайплайн проверки на кубах (CheckFlow)

> Единый механизм бросков, перебросов, модификаторов и активации карт для **всех**
> потоков игры: встречи, магазин, бой. Хост-авторитетный, синкается всем игрокам.

Документ описывает, как сейчас устроена «активная проверка»: структуру данных,
жизненный цикл, конвейер кубов, учёт перебросов, активацию карт и то, как этим
пользуются три потока (встреча / магазин / бой), сеть и UI.

---

## 1. Зачем так

Раньше каждый поток катал кубы по-своему (свои функции броска, своя логика
перебросов, своё истощение карт). Это дублировалось и расходилось. Теперь —
**один источник правды**:

- **`Dice`** (`scripts/core/dice.gd`) — чистая математика кубов (бросок, успехи,
  конвейер модификаторов). Без состояния, статические функции.
- **`CheckFlow`** (`scripts/core/check_flow.gd`) — состояние и операции одной
  активной проверки (старт / бросок / переброс / активация карты).
- **`GameState.active_check`** — само состояние проверки (синкается всем).
- **`AssetCatalog`** (`scripts/core/asset_catalog.gd`) — какие способности карт
  применимы к проверке (по контексту и навыку).

Потоки (`EncounterFlow`, магазин в `PhaseController`, бой в `EncounterFlow`) лишь
**начинают** проверку и **читают** результат — саму механику не трогают.

Три ключевых свойства:

1. **Хост-авторитетность.** Любую мутацию проверки делает только хост; клиенты
   шлют намерение через relay, получают синк.
2. **Идемпотентность.** Отображаемые кубы/успехи **всегда выводятся** из сырых
   `base` + активных модификаторов. `dice` напрямую не мутируется — поэтому
   повторный пересчёт (после переброса/активации) не накапливает бонусы дважды.
3. **Единый учёт перебросов.** Один приоритет валют для всех проверок:
   **карта (бесплатно) → концентрация → улика**.

---

## 2. Структура `active_check`

Создаётся в `CheckFlow.start()`; пустой `{}` = проверки нет.

```gdscript
active_check = {
    owner:    "encounter" | "shop" | "combat",  # кто владеет (для UI/логики потока)
    pid:      String,        # чья проверка
    skill:    String,        # навык: will/strength/influence/observation/lore
    modifier: int,           # модификатор проверки (от карты встречи и т.п.)
    context:  String,        # контекст для сопоставления карт (см. §6)

    rolled:   bool,          # катали ли уже кубы

    base:     [int],         # СЫРЫЕ значения d6 (источник правды)
    dice:     [int],         # ОТОБРАЖАЕМЫЕ значения (base + addToDie)
    successes: int,          # успехи (с учётом convertDie)
    passed:   bool,          # успехов ≥ 1

    active_mods: [Dictionary],  # ноды-эффекты применённых карт (тапом: action + пассивы)
    reroll_allowance: int,      # ПОШТУЧНЫХ бесплатных перебросов от карт (накоплено)
    rerolls_used:     int,      # сколько поштучных уже потрачено
    reroll_all_allowance: int,  # «перебросить ВСЕ кубы разом» — сколько раз доступно
    reroll_all_used:      int,  # сколько раз уже перебросили всё
    exhausted_cards:  [int],    # item_index карт, истощённых на ЭТУ проверку
    add_targets:      [int],    # кубы, на которые игрок положил +1 (addToDie) тапом (§4.5)
}
```

- `base` vs `dice`: `base` — то, что реально выпало; `dice` — что видит игрок
  после `addToDie`. Переброс меняет `base[i]`, затем `dice` пересчитывается.
- `reroll_allowance − rerolls_used` = сколько **бесплатных** (карточных)
  перебросов ещё доступно.
- `exhausted_cards` живёт ровно столько, сколько живёт проверка (пассивы вроде
  Lucky Ring истощаются «на проверку», а не на раунд).

---

## 3. Жизненный цикл

```
 start(owner,pid,skill,modifier,context)      ← поток открывает окно проверки (pre-roll)
   │   active_check = {…, rolled:false}
   │
   ├── activate(pid, item_index)   ← карты можно активировать ДО броска (доп.кубы в пул)
   │
 roll(pid)                          ← бросок: base = Dice.roll(pool); rolled=true
   │   reroll_allowance = Σ rerollDice среди active_mods
   │
   ├── activate(pid, item_index)   ← И ПОСЛЕ броска (доп.кубы докидываются в base)
   ├── reroll(pid, die_index)      ← переброс провального куба (карта→фокус→улика)
   │
 <поток читает active_check.passed / .successes / .dice и применяет эффекты>
   │
 clear()                            ← active_check = {} (проверка снята)
```

Окно между `roll` и `clear` — это и есть то, где игрок докручивает результат:
активирует карты, перебрасывает кубы. Эффекты результата применяются потоком
**в конце** (на «Завершить» / «Купить»), не на броске — чтобы между броском и
фиксацией оставалось окно для перебросов.

---

## 4. Конвейер кубов (`Dice`)

Правила Dark Omens: d6, **успех = 5 или 6**, проверка **пройдена при ≥1 успехе**,
перебрасывается только **провальный** куб.

### 4.1 Пул кубов — `CheckFlow.pool(c)`

```
pool = max(1,  базовый_навык_сыщика
             + skill_mods игрока (временные баффы навыка)
             + modifier проверки
             + Dice.pre_roll_bonus(active_mods, skill))   ← доп.кубы от карт
```

### 4.2 Модификаторы (ноды-эффекты карт)

Конвейер делится на **до броска** (меняют пул) и **после броска** (меняют грани/
подсчёт):

| Глагол (`do`)        | Когда      | Действие                                                       |
|----------------------|------------|----------------------------------------------------------------|
| `rollAdditionalDice` | до броска  | +`count` кубов в пул (складываются — разные источники)          |
| `improveSkill`       | до броска  | +`amount` кубов по навыку — **НЕ складываются**: берётся МАКСИМУМ (две пушки +2/+3 → +3, не +5) |
| `impairSkill`        | до броска  | −`amount` кубов, если `skill` совпал                            |
| `addToDie`           | после      | +`amount` к `count` кубам — на **выбранные игроком** тапом (любой куб < 6, см. §4.5) |
| `convertDie`         | подсчёт    | грань `on` даёт `successes` успехов (или снимает при `negate`)  |
| `rerollDice` (count < 10) | —     | +`count` к ПОШТУЧНЫМ бесплатным перебросам (`reroll_allowance`) |
| `rerollDice` (count ≥ 10) | —     | «перебросить ВСЕ кубы разом» — +1 к `reroll_all_allowance`      |

- `apply_add_to_die_at` кладёт +1 на кубы из `add_targets` (выбор игрока, §4.5) —
  без жадности. Жадный `apply_add_to_die` (наибольший провальный < 5) остался
  ТОЛЬКО для симулятора баланса (`result_with(add_targets=null)`), где нет игрока;
  в игре он не вызывается.
- `count_successes_with` считает успехи поштучно через `_die_successes` с учётом
  `convertDie`.

### 4.3 Skill-фильтрация (важно для боя)

Карты боя (контекст `combatEncounter`) несут поле `skill` (`strength`/`will`),
потому что в бою **две** проверки: Воля (ужас) и Сила (атака). Весь конвейер
учитывает навык через `Dice.mod_skill_ok(m, skill)`:

> мод подходит, если у него **нет** поля `skill`, ИЛИ целевой навык пустой,
> ИЛИ `m.skill == skill`.

Значит strength-карта, активированная на шаге **Воли**, не добавит кубы и не
забустит грани Воли (и наоборот). Фильтр применяется в двух местах:

- `pre_roll_bonus` / `apply_add_to_die` / `count_successes_with` — на уровне
  эффекта (мод не сработает);
- `CheckFlow.activate` — на уровне **права активации** (карту не дадут активировать
  на «не свой» шаг, чтобы она не истощилась впустую).

### 4.4 Идемпотентный пересчёт — `CheckFlow._set_roll(c, base)`

```gdscript
var r = Dice.result_with(base, active_mods, skill, threshold, add_targets)  # {dice, successes, passed}
c.base = base
c.dice = r.dice        # base + addToDie(add_targets) на копии
c.successes = r.successes
c.passed = r.passed
```

Любая операция (бросок, переброс, активация, +1) меняет **только `base`/`add_targets`**
и зовёт `_set_roll`. `dice`/`successes` всегда выводятся заново из `base` +
`active_mods` + `add_targets` — поэтому `addToDie` не накапливается, а порядок
активаций/перебросов/выборов не важен.

### 4.5 +1 на выбранный куб — `CheckFlow.add_die(pid, die_index)`

`addToDie` не раскидывается автоматически: активированная карта **заряжает** +1
(как жетон-валюта заряжает переброс, §6), а игрок сам **тапает куб**. Аналог реролла,
но со своими правилами:

```
заряды       = Dice.add_charges(active_mods, skill)   # count кубов × amount, плоским списком
add_available = len(заряды) − len(add_targets)          # ещё не положенных +1
die_can_add: rolled, pid совпал, есть свободный заряд, dice[i] < 6 (SIDES)
add_die(i):  add_targets += [i];  _set_roll(base);  reroll_nonce++ (лоток крутит куб)
```

Отличия от переброса (§5):

- **Применимо и к УСПЕШНЫМ кубам:** порог — не «< 5», а **`< 6`**. Куб на 5 можно
  довести до 6 — ради карт, которым нужны шестёрки (`convertDie on:6`, matching).
  Шестёрку улучшать некуда.
- **Приоритет тапа.** Заряженный +1 тратится ПЕРВЫМ: `GameState.reroll_die` (и
  `reckoning_reroll_die`) сначала пробуют `die_can_add` → `add_die`, и лишь потом
  переброс. Игрок зарядил карту осознанно — сперва кладём её.
- **Заряд выводится из `active_mods`,** отдельного «pending»-флага (как у жетона
  переброса) нет: активировал addToDie-карту — заряд появился, положил на куб —
  ушёл в `add_targets`.

Сеть: relay `ADD_DIE` (active_check) / `RECKONING_ADD_DIE` (слот Расплаты) →
`CheckFlow.add_die`. `add_targets` едет в снапшоте вместе с `active_check`.

---

## 5. Учёт перебросов — `CheckFlow.reroll(pid, die_index)`

```
guard: проверка брошена (rolled), pid совпал
guard: куб провальный ПО ОТОБРАЖАЕМОМУ значению (dice[i] < 5) — успех не перебросить

приоритет валют:
   used  = rerolls_used
   free  = used < reroll_allowance           # есть бесплатный от карт?
   foc   = player.concentration
   clues = player.clues
   если not free и foc<=0 и clues<=0 → отказ (нечем)

   base[die_index] = Dice.roll_one()          # новый сырой бросок ОДНОГО куба
   _set_roll(c, base)                          # пересчёт dice/успехов (addToDie заново)

   списываем по приоритету:
     free  → rerolls_used += 1                 # сначала бесплатные от карт
     иначе foc>0  → concentration -= 1         # потом концентрация
     иначе        → clues -= 1                 # потом улика
```

Ключевые моменты:

- **Перебрасывается провальный куб по ОТОБРАЖАЕМОМУ значению** (`dice`, т.е. уже с
  `addToDie`), а не по сырому `base`. Куб, доведённый картой до успеха, перебросить
  нельзя.
- **Карты имеют приоритет.** Если активирована карта-переброс (Lucky Ring и т.п.),
  первый переброс бесплатный и **не тратит** улики/концентрацию.
- `reroll_allowance` = Σ `rerollDice.count` среди `active_mods`, где `count < 10`
  (`_allowance`). Пересчитывается на броске и при активации карты-переброса.

### 5.1 «Перебросить ВСЕ кубы разом» — `CheckFlow.reroll_all(pid)`

Карты вроде **Счастливого талисмана** в данных несут `rerollDice` с `count: 99` —
конвенция «перебрось сколько угодно кубов за проверку». Такой мод трактуется не как
99 поштучных перебросов, а как отдельная способность **перебросить весь пул разом**:

- `count >= 10` (`_REROLL_ALL_MIN`) → +1 к `reroll_all_allowance` (а не в поштучные).
- `reroll_all(pid)` перебрасывает **ВСЕ** кубы пула (включая успешные — это явный
  «полный переброс») за **одно** использование (`reroll_all_used += 1`). Бесплатно —
  эффект карты. Выборочно провальные перебрасывают тапом по кубу (карта/фокус/улика).
- В UI это **повторное нажатие кнопки броска** (встреча/магазин) или отдельная
  кнопка «Перебросить кубы» (бой). Несколько изменившихся кубов лоток крутит
  спином (`play_roll`), чтобы переброс был виден. После исчерпания запаса кнопка
  пропадает.

---

## 6. Применение карт — `CheckFlow.activate(pid, item_index)`

**Все карты имущества применяются ВРУЧНУЮ** — тапом по карте в вееро (Tab). Это
осознанный выбор игрока (иммерсивность): и `action`-способности «по выбору», и
пассивы `whileOwned` (.38 Revolver, Lucky Ring) вступают в проверку только когда
игрок их тапнул. Авто-применения нет. UI шлёт `item_index` (индекс в `player.items`).

```
guard: есть активная проверка, pid совпал, предмет — инстанс {id, exhausted}
guard: НЕ истощён (it.exhausted — раунд) и НЕ применён в этой проверке (exhausted_cards)
asset = AssetCatalog.by_id(entry_id(item))

ctx   = active_check.context
skill = active_check.skill

# action (по выбору) + whileOwned-пассивы — оба фильтруются по навыку:
mods = action_check_mods(asset, ctx) + passive_check_mods(asset, ctx)  ↓ filter(mod_skill_ok)
если модов нет → отказ (нечего применить под контекст/навык)

# стоимость/лимит берём из action-нод (пассивы без стоимости):
cost  = action node .cost   (напр. {spend:"sanity", amount:2})
limit = action node .limit  (напр. "oncePerRound")
если cost.spend → _can_pay/_pay  (clue/focus/health/sanity; не до смерти)

bonus_before = pre_roll_bonus(active_mods, skill)   # ← дельта (improveSkill не складывается)
active_mods += mods
если уже rolled:            # бросок сделан → докидываем ТОЛЬКО прирост доп.кубов
   add = pre_roll_bonus(active_mods, skill) − bonus_before
   base += Dice.roll_one() × add
   _set_roll(c, base);  reroll_allowance / reroll_all_allowance — пересчёт
```

> **Дельта доп.кубов.** Поскольку `improveSkill` не складывается (берётся максимум),
> при пост-бросковом применении докидывается не полный бонус карты, а **прирост**
> относительно уже активного. Тап .38 (+2) → +2 куба; следом .45 (+3) → ещё +1 куб
> (max(2,3)−2), а не +3. Иначе пул задвоился бы.

### 6.1 Контекст проверки (где какие карты применимы)

`AssetCatalog._ctx_match(eff_ctx, cur_ctx)`: подходит, если у эффекта контекст
**пустой**, либо `anyTest`, либо **точно совпал**.

| Поток / проверка       | `context`            |
|------------------------|----------------------|
| Встреча общая/тайна/знамение | `generalEncounter` |
| Встреча-исследование   | `researchEncounter`  |
| Врата (иной мир)       | `otherWorldEncounter`|
| Магазин (Влияние)      | `acquireAssets`      |
| Бой (Воля и Сила)      | `combatEncounter`    |
| Каст заклинания (Знание) | `spellEffect`      |

(Контексты карт в данных: `combatEncounter` 68, `spellEffect` 20, `anyTest` 13,
`otherWorldEncounter` 3, `researchEncounter` 2, `acquireAssets` 2 и т.д.)

### 6.2 Слоты эффектов актива

| Слот         | Смысл                                           | Статус            |
|--------------|-------------------------------------------------|-------------------|
| `whileOwned` | пассивы (бонус навыка, бесплатные перебросы)     | ✅ тапом (§6.4)   |
| `action`     | способность «по выбору» (правит бросок)          | ✅ тапом           |
| `triggered`  | срабатывает по триггеру                          | отложено          |
| `onGain`     | при получении карты                              | отложено          |

Из `whileOwned` поддержаны **безусловные пассивы без стоимости** (любой check-mod-
глагол без `cost`/`when`): бонус навыка (`improveSkill` — «.38 Revolver» +2 Силы),
бесплатные перебросы (`rerollDice` — Lucky Ring) и т.п. Применяются **тапом** как
и `action` (см. §6.4). Платные пассивы (топор: переброс за 2 рассудка) и условные
(`when`) — **отложены**; заклинания — часть отложенной системы.

Глаголы-модификаторы броска (идут в конвейер): `rollAdditionalDice`, `addToDie`,
`convertDie`, `improveSkill`, `impairSkill`, `rerollDice`, `rerollMatching`,
`enhanceReroll`, `minDice`. Прочие action-глаголы (`damageMonster`, `preventLoss`,
`gainCondition` …) — **не** модификаторы проверки.

### 6.3 Истощение карты — три области

| Условие применения               | Что происходит                          | Снимается           |
|----------------------------------|-----------------------------------------|---------------------|
| `cost.discardSelf: true`         | карта удаляется из `items` навсегда      | никогда             |
| action `limit: "oncePerRound"`   | `item.exhausted = true`                  | в начале раунда (Refresh) |
| прочее (пассивы, action без лимита) | `active_check.exhausted_cards += idx` | при `clear()` проверки |

**Refresh-шаг** начала раунда: `GameState._refresh_items(p)` снимает `exhausted` со
всех инстансов (`PhaseController.start_new_round` → для каждого игрока). Поэтому
`oncePerRound`-карты снова доступны в новом раунде. Перечековое истощение
(`exhausted_cards`) умирает вместе с `active_check` — каждую проверку карту можно
применить заново (один раз).

### 6.4 Пассивы — применяются тапом, бонусы навыка не складываются

Пассивы `whileOwned` (без `cost`/`when`) применяются **тем же тапом**, что и
`action` (см. §6 — иммерсивно, все карты вручную). При применении мод кладётся в
`active_check.active_mods` и идёт общим конвейером (§4):

- `improveSkill strength +2` («.38 Revolver») → +2 куба в пул **Силы**. Навык
  фильтруется: на шаге **Воли** тот же мод не применяется (и не истощает карту).
- `rerollDice` («Lucky Ring») → бесплатный переброс (`reroll_allowance`).

**Бонусы навыка не складываются.** Две пушки (.38 +2, .45 +3) дают **+3**, не +5 —
`pre_roll_bonus` берёт МАКСИМУМ `improveSkill` по навыку, а не сумму (§4.2). Игрок
тапает ту, что хочет; лучший бонус и применяется. `rollAdditionalDice` (доп.кубы от
разных источников) при этом складываются как обычно.

### 6.5 Тайминг применения — до или после броска

Каждый МОД карты применим по своему таймингу (`Dice.mod_is_pre_roll`, гейт в
`activate`: `allowed = not mod_is_pre_roll(m) or not rolled`):

| Когда | Глаголы | Почему |
|-------|---------|--------|
| **только ДО броска** (pre-roll) | `improveSkill`, `impairSkill`, `rollAdditionalDice`, `minDice` | меняют ЧИСЛО кубов — в уже брошенный набор не докинуть |
| **в ЛЮБОЙ фазе** (post-roll) | `addToDie`, `convertDie`, `rerollDice`, `rerollMatching`, `enhanceReroll` | правят результат / скоринг / перебросы — моменту добавления в `active_mods` не важны, читаются при подсчёте |

Гейт **помодовый**, поэтому один тап кладёт все подходящие таймингу моды карты.
Ключевой случай — **карта со смешанными фазами**: `double_barreled_shotgun`
(`improveSkill` pre + `convertDie` post в одном `whileOwned`). Тап **до броска**
кладёт ОБА мода: `improveSkill` докидывает кубы сразу, `convertDie` ждёт подсчёта.
(Раньше гейт был `mod_is_pre_roll(m) != rolled` — строго пофазно, и такая карта за
один тап давала лишь один эффект, второй терялся; повторный тап истощён.)

Pre-roll мод после броска по-прежнему отсекается (усиление пула вслепую не
докинуть). В бою ради pre-roll окна Силы отделена кнопка «Дальше» (§7.3).

---

## 7. Три потока

Все потоки делают одно и то же: `start()` (pre-roll) → `roll()` → читают результат
→ `clear()`. Различается только **что значит результат**.

### 7.1 Встреча — `EncounterFlow`

Плоская встреча / research / врата / тайна / знамение.

- **Показ карты** (`generate` / `_begin_eldritch_move` / смена стадии врат) →
  `_start_check_for_encounter(pid)` → `_check.start("encounter", pid, test.skill,
  test.modifier, ctx)`. Контекст из `_check_context()`; навык/модификатор из
  `_active_test()` (для врат/тайны — узел текущей стадии).
- **«Бросить»** → `host_apply_resolve` → `_check.roll(pid)`.
- **Врата, переход стадии** → `host_apply_advance_stage`: ветка из
  `active_check.passed` (success/failure) → `_start_check_for_encounter` (новая
  проверка стадии 2).
- **«Завершить»** → `host_apply_finish_encounter` → `_commit_and_advance` →
  `_commit_outcome`: читает `active_check.passed`, гоняет слот эффектов
  `onSuccess`/`onFailure` (резюмируемо при интерактивном `choice`) → `_check.clear()`.
- **Переброс** → `host_apply_reroll` → `_check.reroll`.

### 7.2 Магазин — `GameState` + `PhaseController`

Бросок на **Влияние**: монеты = успехи.

- **Открытие** → `shop_open()` → `_check.start("shop", pid, "influence", 0,
  "acquireAssets")` — pre-roll **без траты действия** (чтобы активировать карты до
  броска).
- **«Бросить кубы»** → `shop_begin()` → `perform_action("acquire_assets")`:
  тратит действие, ставит `shopping=true`, `_check.roll(pid)`. Монеты = успехи
  (+2 за «Долг», только если взят в этот визит).
- **Переброс** → `shop_reroll` → `_check.reroll`.
- **«Купить»** → `shop_grant`. **«Закрыть»** → `shop_close` →
  `host_apply_shop_close` → `_check.clear()` (+ отложенная передача хода).

### 7.3 Бой — `EncounterFlow` (две последовательные проверки)

`active_check` держит **одну** проверку, а бой — это **два** шага. Решение: первый
шаг замораживается снимком в `current_encounter`, затем стартует второй.

У каждого шага — **отдельное pre-roll окно** (важно: усиливающие карты применяются
только до броска, §6.5), затем бросок, затем post-roll окно (результат/переброс).

```
_begin_combat → строит карту монстра → _start_combat_will
   _check.start("combat", pid, horror.skill, horror.modificator, "combatEncounter")   ← ВОЛЯ (pre-roll)
   (окно ДО броска: карты усиления на Волю)

«Бросить Волю»  → host_apply_resolve → _resolve_combat → _check.roll(pid)             ← бросок ВОЛИ
   (окно ПОСЛЕ: переброс Воли / результат-карты)

«Дальше»        → _resolve_combat (Воля уже rolled):
   enc.will       = {dice, successes}   ← ЗАМОРОЗКА снимка Воли
   enc.sanity_loss= max(0, horror.damage − воля.успехи)
   _check.start("combat", pid, combat.skill, combat.modificator, "combatEncounter")   ← СИЛА (pre-roll)
   (окно ДО броска: ОРУЖИЕ +Сила применяется здесь)

«Бросить Силу»  → _resolve_combat (Сила pre-roll) → _check.roll(pid)                  ← бросок СИЛЫ
   (окно ПОСЛЕ: переброс Силы / результат-карты)

«Завершить»     → finish_encounter → _commit_outcome → _commit_combat:
   списать sanity_loss
   resolution = _combat_resolution(enc, active_check)   ← из активной СИЛЫ:
       hits         = сила.успехи
       health_after = max(0, enc.health − hits)
       won          = health_after <= 0
       hp_loss      = max(0, combat.damage − hits)
   применить hp_loss; победа → снять монстра + вернуть в мешок; иначе → записать здоровье
   _check.clear()
```

- **Переброс** (любой шаг) → `host_apply_reroll` → `_check.reroll` (активна — текущая
  проверка: Воля до заморозки, Сила после).
- Если монстр повержен и на клетке остались монстры → `continue_encounter_turn`
  стартует следующий бой (свежая Воля). Если выжил — ход сыщика завершается.
- **Skill-фильтр обязателен:** strength-карта инертна на шаге Воли, will-карта —
  на шаге Силы (см. §4.3).

- **4 нажатия:** «Бросить Волю» → «Дальше» (заморозка Воли + старт Силы в pre-roll) →
  «Бросить Силу» → «Завершить». Шаг «Дальше» нужен ради pre-roll окна Силы: оружие
  (`improveSkill`) применяется ТОЛЬКО до броска (§6.5), поэтому бросок Силы отделён.

---

## 8. Сеть (хост-авторитетность)

Каждый фасад в `GameState` проверяет `_is_host()`:

```
Игрок-клиент:  GameState.<facade>()  → _nm.relay_all({action:"game_…", pid, …})
                                         │ (через relay)
Хост:          relay-router (_handle_relay) ──┐
Хост напрямую: GameState.<facade>() ──────────┴→ host_apply_* / _check.*  → мутация
                                                  → _check._sync():
                                                       _broadcast_sync()  (рассылка снапшота)
                                                       _emit_changed()    (локальный сигнал)
Клиенты:       _apply_snapshot(data)  → active_check = data.active_check
               → state_changed → UI перерисовывается
```

Соответствие действий релея и обработчиков:

| Relay action              | Хост-обработчик                        |
|---------------------------|----------------------------------------|
| `game_resolve_encounter`  | `EncounterFlow.host_apply_resolve`     |
| `game_reroll_encounter`   | `EncounterFlow.host_apply_reroll` → `_check.reroll` |
| `game_activate_card`      | `CheckFlow.activate`                    |
| `game_advance_stage`      | `EncounterFlow.host_apply_advance_stage`|
| `game_finish_encounter`   | `PhaseController.host_apply_finish_encounter` |
| `game_shop_open`          | `_check.start("shop", …)`               |
| `game_shop_reroll`        | `_check.reroll`                         |

`active_check` входит в снапшот (`_broadcast_sync`, поле `"active_check"`) и
восстанавливается в `_apply_snapshot`.

---

## 9. UI

Модалки читают `active_check` (реактивно, на `state_changed`) и не держат своего
состояния броска.

### Общий хелпер каждой модалки

```gdscript
func _chk() -> Dictionary:
    var c = GameState.active_check
    return c if String(c.get("owner","")) == "<owner>" else {}

func _free_rerolls() -> int:
    var c = _chk()
    return max(0, c.reroll_allowance - c.rerolls_used)
```

### Кликабельность куба (одинаково везде)

Куб провального значения становится кликабельным, когда есть чем перебросить:

```gdscript
can = (free > 0 or concentration > 0 or clues > 0) and not committed and not revealed
```

> Это должно **зеркалить** хостовое условие `CheckFlow.reroll`. Если UI забудет
> какую-то валюту (как было с уликами), хост бы переброс разрешил, но игрок не
> сможет нажать кубик. Подсказка под кубами показывает источник по приоритету:
> карта (бесплатно) → концентрация → улика.

**+1 (addToDie) расширяет кликабельность.** Помимо переброса, куб кликабелен под
`+1`, если заряд свободен (§4.5) — тут порог **`< 6`**, а не `< 5`. `DiceTray`:
`clickable = (can_reroll и dice[i] < 5) ИЛИ (can_add и dice[i] < 6)`, где
`can_add = GameState.can_add_die_now(reckoning?)`. Модалки следят за доступностью
+1 (`_last_add`) и перерисовывают лоток при её смене — иначе куб-5 не станет
нажимаемым сразу после розыгрыша карты. Тап приоритетно кладёт +1 (§4.5), затем
переброс.

**«Перебросить кубы».** Когда `reroll_all_allowance − reroll_all_used > 0`, модалки
встречи/магазина **переиспользуют кнопку броска** (текст → «Перебросить кубы»,
обработчик → `GameState.reroll_all_dice()`); боевая модалка показывает отдельную
кнопку. Один клик перебрасывает все провальные кубы текущей проверки.

| Модалка          | owner       | Особенности                                                |
|------------------|-------------|------------------------------------------------------------|
| `encounter_modal`| `encounter` | `_show_dice_result` рендерит лоток; ре-рендер при смене `can` |
| `shop_modal`     | `shop`      | монеты = успехи; рендер из `active_check`                   |
| `combat_modal`   | `combat`    | два лотка: Воля (снимок из `enc.will`) + Сила (живой `active_check`) |

### Веер руки — `HandCarousel` (`hand_carousel.gd`)

- Слой **95** — поверх всех игровых/диалоговых модалок; открывается **Tab** в любой
  момент проверки.
- Клик по карте → `card_played(item_index)` → `GameState.activate_card` →
  `_check.activate`. Работает в любом потоке (хост сам валидирует контекст/навык).
- Истощённые карты приглушены. `WorldMap._refresh_hand` собирает руку через
  `AssetCatalog.deck_for_items(items)` (тянет `item.exhausted` — раунд) и
  домешивает `active_check.exhausted_cards` (перечековые пассивы).

---

## 10. Инварианты и подводные камни

- **Никогда не мутируй `dice` напрямую.** Меняй `base` и зови `_set_roll` — иначе
  `addToDie` задвоится. Бросок/переброс/активация именно так и делают.
- **Переброс смотрит на отображаемое значение** (`dice`, с `addToDie`), не на сырой
  `base`. Куб, доведённый картой до успеха, перебросить нельзя.
- **Skill-фильтр в двух местах:** право активации (`CheckFlow.activate`) и сам
  эффект (`Dice.*`). Карта «не своего» навыка не активируется и не тратится.
- **Приоритет перебросов хост-авторитетен:** карта → концентрация → улика. UI обязан
  повторять то же условие кликабельности.
- **Одна `active_check` за раз.** Двухшаговый бой делает снимок Воли в
  `current_encounter.will` и стартует отдельную проверку Силы.
- **Эффекты результата — на «Завершить»/«Купить», не на броске.** Это сохраняет
  окно для перебросов между броском и фиксацией.
- **Области истощения** не путать: `oncePerRound` (инстанс, снимается в начале
  раунда) ≠ перечековый пассив (`exhausted_cards`, умирает с проверкой) ≠
  `discardSelf` (карта удаляется навсегда).

---

## 11. Карта файлов

| Файл                                 | Роль                                                  |
|--------------------------------------|-------------------------------------------------------|
| `scripts/core/dice.gd`               | чистая математика кубов + конвейер модификаторов      |
| `scripts/core/check_flow.gd`         | состояние и операции активной проверки                |
| `scripts/core/asset_catalog.gd`      | применимость карт (контекст/навык), payload'ы для веера|
| `scripts/core/encounter_flow.gd`     | поток встреч + бой (две проверки)                     |
| `scripts/core/phase_controller.gd`   | магазин (`acquire_assets`), Refresh, завершение встречи|
| `scripts/core/game_state.gd`         | `active_check`, фасады, синк, relay-router             |
| `scripts/ui/encounter_modal.gd`      | UI встречи                                             |
| `scripts/ui/shop_modal.gd`           | UI магазина                                            |
| `scripts/ui/combat_modal.gd`         | UI боя (два лотка)                                     |
| `scripts/ui/hand_carousel.gd`        | веер руки (активация карт)                             |
| `scripts/screens/world_map.gd`       | сборка руки, проводка `card_played → activate_card`    |
