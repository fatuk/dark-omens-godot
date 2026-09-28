# Поддержка эффектов активов (`assets.json`)

> Какие verb'ы/слоты эффектов движок реально исполняет, и как карты с ещё не
> реализованными эффектами держатся вне пула выдачи до готовности.

Связано с [check-pipeline.md](check-pipeline.md) (конвейер проверок).

---

## Фильтр пула выдачи — `AssetCatalog.is_supported`

Карта попадает в **пул выдачи** (витрина магазина / случайный `gainAsset`), только
если поддержаны **ВСЕ** её эффекты. Иначе она в игре не появляется — введём, когда
допилим её эффекты. Стартовые наборы сыщиков **не фильтруются** (курируются вручную;
частично-рабочая карта там даёт свои рабочие эффекты).

`is_supported(a)` — **слото-осознанный** и **самоподдерживающийся**: реализовали verb
или событийный слот → карта включается САМА, без ручных пометок. Правило:

- `onReckoning` в активе → **не поддержана** (не диспатчится);
- `triggered` с `on != "combatEncounter"` → **не поддержана** (событийный фреймворк не
  реализован); `on:"combatEncounter"` — поддержан (`EncounterFlow.try_combat_trigger`);
- все `do`-verb'ы в поддержанных слотах (`whileOwned`/`action`/`onGain`/боевой триггер)
  — из `_SUPPORTED_VERBS` (`asset_catalog.gd`).

На момент написания: **~131 из 168** карт поддержаны, ~36 держатся в бэклоге.

---

## Поддержанные verb'ы

**Конвейер проверок:** `improveSkill` · `impairSkill` · `rollAdditionalDice` ·
`addToDie` · `convertDie` · `rerollDice` · `minDice` · `substituteSkill`

**Эффекты на сыщика:** `gainClue`/`loseClue`/`spendClue` · `gainCondition`/
`loseCondition` · `gainAsset`/`loseAsset` · `gainSpell`/`loseSpell` · `gainArtifact` ·
`gainImprovement`/`loseImprovement` · `loseAllPossessions` · `gainFocus`/`loseFocus` ·
`healHealth`/`healSanity`/`loseHealth`/`loseSanity` · `becomeDelayed` · `extraAction` ·
`move` · `addSuccesses` · `text`

**Эффекты поля:** `openGate` · `closeGate` · `spawnMonster` · `discardMonster` ·
`damageMonster` · `advanceDoom` · `advanceOmen` · `moveOmen` · `retreatDoom` ·
`placeClue` · `placeRumor` · `placeEldritchToken` · `giveAsset` · `giveClue`

**Боевая митигация / пассивы:** `reduceMonsterDamage` · `reduceMonsterHorror` ·
`protectResource` · `immuneTo` · `substituteResource` · `discardCard`

**Боевой триггер** (`on:combatEncounter`): `defeatMonster`

---

## Бэклог (пока НЕ поддержано)

| Что | Verb'ы / слоты | Тир |
|-----|----------------|-----|
| Реактивная активная способность | `preventLoss` (Bandages) | 5 |
| Фаззи-семантика переброса | `enhanceReroll`, `rerollMatching` | 3 |
| Нужна «колода врат» (дизайн) | `lookAtGates`, `reorderGates` (Divination) | 4 |
| Событийные триггеры активов | `triggered on:rest`/`defeatMonster`/`focus`/`closeGate`/… (26 карт) | 5 |
| `onReckoning` для активов | 2 карты | 5 |

Реализовал что-то из бэклога → добавь verb в `_SUPPORTED_VERBS` (или расширь
`is_supported` под новый слот) → соответствующие карты вернутся в пул автоматически.

---

## Карта файлов

| Файл | Роль |
|------|------|
| `scripts/core/data/asset_catalog.gd` | `is_supported` / `supported_ids` / `_SUPPORTED_VERBS` |
| `scripts/core/game/shop_reserve.gd` | `_draw` — фильтр витрины по `is_supported` |
| `scripts/core/game/dice.gd`, `check_flow.gd` | check-mod verb'ы |
| `scripts/core/game/effect_runner.gd` | player/board verb'ы, immuneTo/protectResource |
| `scripts/core/game/encounter_flow.gd` | боевая митигация, боевой триггер |
| `test/unit/test_asset_catalog.gd` | тесты `is_supported`/митигации |
