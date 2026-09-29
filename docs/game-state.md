# GameState — авторитетный стейт, синк и маршрутизация

> Autoload-синглтон `/root/GameState` ([game_state.gd](../scripts/core/game/game_state.gd)).
> Держит истинное состояние стола, применяет действия, транслирует его всем. Этот
> документ — про **систему** (модель авторитетности, синк, relay-роутинг, границы
> модулей). Форма конкретных полей документирована у самих `var` в коде.

Дополняет [check-pipeline.md](check-pipeline.md) (проверки на кубах).

---

## 1. Роль

GameState совмещает четыре обязанности:

1. **Авторитетный стейт** — сериализуемые поля (раунд, фаза, игроки, врата, монстры,
   проверки, Тайны, кампания…). Единственный источник правды на **хосте**.
2. **Синк** — рассылка стейта клиентам (`broadcast_sync`) и приём (`_apply_snapshot`).
3. **Маршрутизация relay** — приём действий от клиентов, их валидация и применение
   на хосте (`_on_relay_received` → `RelayRouter`).
4. **Публичные фасады** — точка входа для UI: `perform_action`, `shop_open`,
   `reroll_die` и т.д. Тонкие обёртки, делегирующие в модули.

Бизнес-логика живёт **в модулях** (см. §5), не в GameState. GameState — фасад + стейт
+ транспорт.

---

## 2. Хост-авторитетность

Один игрок — **хост** (host-client): у него авторитетная копия стейта. Все остальные —
**клиенты** с репликой, которую они только отображают.

```
Клиент: намерение → relay → ХОСТ применяет → снапшот всем → клиенты рендерят
```

- Клиент **никогда** не мутирует стейт напрямую. Он шлёт *намерение* через relay
  (`GameState.<фасад>()` → `_nm.relay_all({action, pid, …})`).
- Хост валидирует (можно ли это действие сейчас, этому игроку) и применяет —
  через `host_apply_*` в модулях.
- После мутации хост рассылает полный снапшот; клиенты его принимают.

Хост-фасад проверяет `is_host()`: на хосте — применяет напрямую, у клиента — шлёт
намерение.

---

## 3. Синк

### 3.1 `_SYNC_FIELDS` — единый список

Синкаемые поля перечислены **один раз** в `const _SYNC_FIELDS`. И рассылка, и приём
идут циклом по нему (рефлексия `get()`/`set()`), поэтому **новое синкаемое поле
добавляется в ОДНОМ месте**:

```gdscript
func broadcast_sync() -> void:            # только хост
    var payload := {"action": RelayActions.SYNC, "mythos_index": _mythos.index}
    for f in _SYNC_FIELDS: payload[f] = get(f)
    _nm.relay_all(payload)

func _apply_snapshot(data) -> void:         # клиент (и хост при реджойне с сервера)
    for f in _SYNC_FIELDS: set(f, data.get(f, get(f)))   # set() коэрсит тип (JSON float → int)
    _mythos.index = int(data.get("mythos_index", 0))
    emit_changed(); phase_changed.emit(phase)
```

- **`set()` коэрсит** значение под тип поля — по сети JSON-числа приходят как float,
  а int-поля остаются int (проверено `test_game_sync.gd`).
- **Особый ключ** `mythos_index` (не поле GameState, а `_mythos.index`) — вручную.

### 3.2 Инварианты синка

- **Хост никогда не перезаписывает себя чужим снапшотом.** `_apply_snapshot`/приём
  `game_sync` на хосте — no-op.
- **Не-хост принимает `game_sync` только от текущего хоста** (сверка `from_id` с
  `NetworkManager.host_id()`), иначе — рассинхрон/спуфинг стейта.
- **Host-only стейт в снапшот НЕ входит** и восстанавливается отдельно при
  реджойне/промоушене хоста: колода Мифов (`_mythos.deck` → `_ensure_mythos_deck`),
  стек проверок (`CheckFlow._stack`), дедуп onEnter (`MysteryFlow._on_enter_applied_idx`).

### 3.3 Blanket-инвариант (важно для чтения кода)

> **Всё, что перечислено в `_SYNC_FIELDS`, по определению хост-авторитетно и
> синкается.** Поэтому комментарии у отдельных полей это НЕ повторяют — они
> документируют только форму словаря, смысл пустого значения и специфичные квирки.

---

## 4. Маршрутизация relay

### 4.1 Путь действия

```
Клиент:  GameState.<фасад>()  → _nm.relay_all({action:"game_…", pid, …})
                                   │  (через relay-сервер)
Хост:    _on_relay_received(from_id, data)          ← диспетчер (в GameState)
           ├─ pid-ownership guard (см. 4.2)
           ├─ _relay_actions[action].call(data)     ← адаптер RelayRouter (host-only)
           │      └─ <module>.host_apply_*(…)        ← бизнес-логика
           └─ транзиентные широковещалки (см. 4.3)
```

- **Реестр** `_relay_actions: {action → Callable}` строится из `RelayRouter`
  ([relay_router.gd](../scripts/core/game/relay_router.gd)) — ~34 тонких адаптера
  `_act_*`, каждый `(data) → module.host_apply_*`. Диспетчер (`_on_relay_received`)
  остаётся в GameState.
- Адаптер зовётся **только на хосте** (`is_host()`); не-хост доходит до диспетчера,
  но Callable не выполняет.

### 4.2 Граница доверия (pid-ownership)

`from_id` проставляет relay-сервер (id соединения отправителя) — ему верим;
`data.pid` (от лица кого действие) — нет. Для действий «от лица игрока» pid **обязан**
совпасть с user_id отправителя (`_sender_uid(from_id)`), иначе действие отклоняется
(защита от спуфинга — сыграть за другого).

`_pid_owned` = все действия реестра, **кроме** безадресных (`RESOLVE_MYTHOS` — без
pid, `SET_READY` — по connection id). Выводится из реестра автоматически.

### 4.3 Транзиентные широковещалки (не host-only)

`game_sync` / `game_chat` / `game_action_feed` — рендерятся у **всех** клиентов, не
через реестр:

- **SYNC** — снапшот стейта (см. §3).
- **CHAT** — облачко над фишкой (Dark Souls-style), от лица `pid` (анти-спуфинг), не
  в снапшоте.
- **ACTION_FEED** — лента действий, рассылает хост, клиент рендерит по id локально.

Не в снапшоте, не мутируют авторитетный стейт; текст рендерится локально по id/ключу
(`ActionLog` / `Messages`), каждый клиент — в своей локали.

---

## 5. Карта модулей

GameState создаёт модули в `_ready` и делегирует им логику (`_gs` — обратная ссылка):

| Поле | Класс | Отвечает за |
|------|-------|-------------|
| `_phase` | PhaseController | фазы хода, `host_apply_action`, магазин-грант, Refresh |
| `_encounter` | EncounterFlow | встречи: генерация, проверка, эффекты, окно preventLoss |
| `_encounter.combat` | CombatFlow | бой: очередь монстров клетки, Воля → Сила, фиксация, боевые триггеры карт |
| `_check` | CheckFlow | активная проверка (пул/бросок/переброс/+1), стек вложенных |
| `_cond` | ConditionFlow | состояния, held-ограничения, выдача активов |
| `_spell` | SpellFlow | колода копий заклинаний (`spell_deck`: копия = оборот), касты (ritual/incantation/glamour), результат каста |
| `_board` | BoardState | врата, монстры, спаун, улики (жетоны + пул идентичностей), вещи павших, board-verbs эффектов (`apply_verb`) |
| `_shop` | ShopReserve | колода активов и витрина магазина (сброс выводится) |
| `_mythos` | MythosFlow | колода Мифов (host-only), розыгрыш, решения |
| `_mystery` | MysteryFlow | цикл Тайн, прогресс, onEnter, финал партии |
| `_rumor` | RumorFlow | Слухи (ongoing-Мифы с таймером) |
| `_reckoning` | ReckoningFlow | параллельная Расплата (per-player проверки) |
| `_campaign` | CampaignGen | сценарная библия (Древний, Тайны, doomClock) |
| `_target` | TargetResolver | резолв целей эффектов (chosenMonster и т.п.) |
| `_relay_router` | RelayRouter | адаптеры relay-действий (§4.1) |
| — | DebugGrant | debug-выдача из GameConsole (dev-сборка, static) |

---

## 6. Стейт как `Dictionary` — почему и как читать

Состояние (`players`, `active_check`, `current_encounter`, `last_cast_result`, …)
хранится как **нетипизированные `Dictionary`**, а не DTO. Причина: он **сериализуется
в JSON** и уходит по сети (relay) и в снапшот (relay-БД). `RefCounted`-объект в JSON
напрямую не уходит — DTO потребовал бы `to_dict/from_dict` на каждой сетевой границе.
Это осознанный размен: простой wire-формат ценой того, что форму словаря надо
документировать у объявления.

Чтобы это не было хрупким:

- **Форма — в комментарии у `var`** (рядом с объявлением, чтобы не протухала). Пример:
  `last_cast_result: { pid, spell, back, text, successes, outcome:{…} }`.
- **Ключи — константы** там, где важно от опечаток:
  [PlayerKeys](../scripts/core/game/player_keys.gd) (поля игрока),
  [GameActions](../scripts/core/game/game_actions.gd) (типы действий),
  [Phases](../scripts/core/game/phases.gd), `RelayActions` — внедряются постепенно.
- **Каноничная форма игрока** — `_make_player_dict` (одно место определяет схему).

---

## 7. Карта файлов

| Файл | Роль |
|------|------|
| `scripts/core/game/game_state.gd` | фасад + стейт + синк + диспетчер |
| `scripts/core/game/relay_router.gd` | адаптеры relay-действий |
| `scripts/core/game/relay_actions.gd` | константы relay-действий |
| `scripts/core/game/game_actions.gd` | константы типов действий сыщика |
| `scripts/core/game/player_keys.gd` | константы ключей словаря игрока |
| `scripts/core/game/phases.gd` | константы фаз |
| `scripts/core/game/*_flow.gd`, `board_state.gd`, `campaign_gen.gd` | модули-подсистемы |
| `scripts/network/network_manager.gd` | транспорт (relay_all, host_id, from_id) |
