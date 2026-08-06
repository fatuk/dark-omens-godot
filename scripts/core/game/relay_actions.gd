class_name RelayActions
extends RefCounted

## Имена relay-действий — общий словарь протокола клиент↔хост. Одна и та же строка
## живёт в фасаде (клиент шлёт) и в реестре _relay_actions (хост принимает); ссылка
## на общую константу гарантирует, что они не разъедутся по опечатке (раньше это
## ничем не проверялось).
##
## ВАЖНО: значения менять нельзя — relay-сервер особо-кейсит SYNC/SET_READY (и
## start_game/picking на стороне лобби). Это внутренний протокол игры поверх relay.

# ── Host-авторитетные (от лица игрока data.pid) ──────────────────────────────
const ACTION := "game_action"
const FINISH_ENCOUNTER := "game_finish_encounter"
const RESOLVE_ENCOUNTER := "game_resolve_encounter"
const REROLL_ENCOUNTER := "game_reroll_encounter"
const CHOOSE_ENCOUNTER := "game_choose_encounter"
const ADVANCE_STAGE := "game_advance_stage"
const CHOOSE_EFFECT := "game_choose_effect"
const ACTIVATE_CARD := "game_activate_card"
const CAST_INCANTATION := "game_cast_incantation"
const CAST_GLAMOUR := "game_cast_glamour"
const SPELL_CAST_ROLL := "game_spell_cast_roll"
const SPELL_CAST_REROLL := "game_spell_cast_reroll"
const SPELL_CAST_APPLY := "game_spell_cast_apply"
const CHECK_ROLL := "game_check_roll"
const CHECK_REROLL := "game_check_reroll"
const ADD_DIE := "game_add_die"  # положить +1 (addToDie) на куб активной проверки
const RESOLVE_PENDING_CHECK := "game_resolve_pending_check"
const RECKONING_ROLL := "game_reckoning_roll"
const RECKONING_REROLL := "game_reckoning_reroll"
const RECKONING_REROLL_ALL := "game_reckoning_reroll_all"
const RECKONING_ADD_DIE := "game_reckoning_add_die"
const RECKONING_ACTIVATE_CARD := "game_reckoning_activate_card"  # карта на проверку Расплаты
const RECKONING_APPLY := "game_reckoning_apply"
const DEATH_SAVE_REROLL := "game_death_save_reroll"  # сосед тратит ресурс на переброс Порога
const DEATH_SAVE_APPLY := "game_death_save_apply"  # умирающий принимает свой спас-бросок
const GHOST_PLACE_CLUE := "game_ghost_place_clue"  # Тень выкладывает улику (акт раунда)
const CAST_TRIGGER_SPELLS := "game_cast_trigger_spells"
const DISMISS_CAST_RESULT := "game_dismiss_cast_result"
const DISMISS_RECKONING := "game_dismiss_reckoning"
const SHOP_GRANT := "game_shop_grant"
const SHOP_CLOSE := "game_shop_close"
const SHOP_DEBT := "game_shop_debt"
const SHOP_SPEND_RESOURCE := "game_shop_spend_resource"
const SHOP_OPEN := "game_shop_open"
const SHOP_REROLL := "game_shop_reroll"
const REROLL_ALL := "game_reroll_all"
const MYTHOS_DECIDE := "game_mythos_decide"
const TRAVEL_ARRIVED := "game_travel_arrived"  # фишка доехала — хосту можно передавать ход

# ── Host-only, но НЕ pid-владельческие ───────────────────────────────────────
const RESOLVE_MYTHOS := "game_resolve_mythos"  # без pid (любой просит хоста разрешить Миф)
const SET_READY := "set_ready"  # поздний вход по connection id (не user pid)

# ── Транзиентные широковещалки (клиентская логика, рендер у всех) ─────────────
const SYNC := "game_sync"
const CHAT := "game_chat"
const ACTION_FEED := "game_action_feed"
