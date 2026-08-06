class_name GameActions
extends RefCounted

## Типы действий сыщика (perform_action / host_apply_action). Раньше пробрасывались
## строковыми литералами по нескольким файлам (game_state, phase_controller, world_map,
## action_panel) — переименование ломало поиск. Теперь одна точка правды, как Phases /
## RelayActions.
##
## ВАЖНО: значения фиксированы — они же служат id ленты действий (ActionLog / announce)
## и ключами в player.actions_used. Менять строки нельзя без миграции данных.

const PASS := "pass"
const REST := "rest"
const TRAVEL := "travel"
const TRADE := "trade"
const BUY_TICKET := "buy_ticket"
const TAKE_CONCENTRATION := "take_concentration"
const TAKE_RESOURCE := "take_resource"
const ACQUIRE_ASSETS := "acquire_assets"
const CONDITION_ACTION := "condition_action"
const ASSET_ACTION := "asset_action"  # самостоятельное действие актива (тег "action")
const INVESTIGATOR_ABILITY := "investigator_ability"
const CAST_SPELL := "cast_spell"
