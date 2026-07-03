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
const CONNECTED := "connected"
const ACTIONS_LEFT := "actions_left"
const ACTIONS_USED := "actions_used"
const ENCOUNTER_DONE := "encounter_done"
const TRAIN_TICKETS := "train_tickets"
const SHIP_TICKETS := "ship_tickets"
const CONCENTRATION := "concentration"
const HP := "hp"
const SANITY := "sanity"
const HP_MAX := "hp_max"
const SANITY_MAX := "sanity_max"
const CLUES := "clues"
const CONDITIONS := "conditions"
const CONDITIONS_FLIPPED := "conditions_flipped"
const ITEMS := "items"
const SKILL_MODS := "skill_mods"
