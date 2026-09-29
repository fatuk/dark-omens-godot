class_name PlayerKeys
extends RefCounted

## Ключи словаря игрока (players[pid]). Состояние по-игроку хранится как Dictionary
## (сериализуется в JSON по сети / в снапшот), поэтому DTO из RefCounted не подходит —
## но опечатка в строковом ключе тихо ломает игру, а статанализатор молчит. Эти
## константы дают защиту от опечаток без смены формата (внедряются постепенно).
##
## Каноничная форма — в GameState._make_player_dict. Значения фиксированы (идут по сети
## и в снапшот) — менять нельзя без миграции.

const USER_ID := "user_id"
const NAME := "name"
const INVESTIGATOR := "investigator"
const LOCATION := "location"
const TRAVEL_PATH := "travel_path"  # сегменты последнего перемещения (для анимации)
const TRAVEL_ANIM := "travel_anim"  # фишка ещё летит: хост ждёт отчёта клиента, ход не передаём
const CONNECTED := "connected"
const ACTIONS_LEFT := "actions_left"
const ACTIONS_USED := "actions_used"
const ENCOUNTER_DONE := "encounter_done"
const TRAIN_TICKETS := "train_tickets"
const SHIP_TICKETS := "ship_tickets"
const CONCENTRATION := "concentration"
const CONCENTRATION_QUOTES := "concentration_quotes"  # индексы цитат стоиков, по жетону
const RESOURCES := "resources"  # токен-ресурс: +1 хил при отдыхе / +1 успех в магазине
const HP := "hp"
const SANITY := "sanity"
const HP_MAX := "hp_max"
const SANITY_MAX := "sanity_max"
const CLUES := "clues"
const CLUE_IDS := "clue_ids"  # аддитивный слой идентичности улик (ключи-локации Древнего)
const CONDITIONS := "conditions"
const CONDITIONS_FLIPPED := "conditions_flipped"
const CONDITIONS_BACKS := "conditions_backs"  # {cond_id: back_id} — закреплённая копия (оборот)
const ITEMS := "items"
const SKILL_MODS := "skill_mods"
const DEATH_SAVE_CHECK := "death_save_check"  # per-player слот спас-броска на Пороге
const DEAD := "dead"  # сыщик погиб (заглушка до перехода в Тень — см. docs/death-design.md)
const DEATH_GRACE := "death_grace"  # выжил на Пороге — иммунитет к повторному спасу до нового раунда
const GHOST_CLUE_BUDGET := "ghost_clue_budget"  # Тень: сколько улик ещё может выложить (лимит = живые на момент гибели)
const GHOST_ACTED := "ghost_acted_this_round"  # Тень: акт (сообщение/улика) уже сделан в этом раунде
