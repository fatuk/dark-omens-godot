class_name GameOutcome
extends RefCounted

## Финал партии: GameState.outcome (victory | defeat) + outcome_reason — почему.
## Причина выбирает концовку Древнего (поля карточки CMS, см. text_keys) и заголовок
## модалки. Финал ставится один раз: первая сработавшая проверка побеждает.

const VICTORY := "victory"
const DEFEAT := "defeat"

## Причины. victory — только MYSTERIES; остальные — поражение.
const MYSTERIES := "mysteries"  # все Тайны кампании решены
const DOOM := "doom"  # Рок дошёл до Часов Рока — Древний пробуждается
const MYTHOS := "mythos"  # колода Мифов исчерпана — время вышло
const DEAD := "dead"  # все сыщики погибли
const EFFECT := "effect"  # карта велела проиграть (loseGame)

const DEFEAT_REASONS := [DOOM, MYTHOS, DEAD, EFFECT]


## Хост: зафиксировать финал, если его ещё нет. gs — GameState (или мок с полями
## outcome/outcome_reason). true — финал поставлен этим вызовом.
static func finish(gs: Object, result: String, reason: String) -> bool:
	if not String(gs.get("outcome")).is_empty():
		return false
	gs.set("outcome", result)
	gs.set("outcome_reason", reason)
	return true


## Поля карточки Древнего (bible.ancientOne) по причине — в порядке предпочтения:
## своя концовка, потом общая «Пробуждение». Пусто — у причины нет текста Древнего.
static func text_keys(result: String, reason: String) -> Array:
	if result == VICTORY:
		return ["victory"]
	match reason:
		MYTHOS:
			return ["timeUp", "awakening"]
		DEAD:
			return ["allFallen", "awakening"]
		_:
			return ["awakening"]


## Текст концовки: первое непустое поле Древнего, иначе общий ключ перевода.
static func body_text(ancient: Dictionary, result: String, reason: String) -> String:
	for k: String in text_keys(result, reason):
		var t: String = String(ancient.get(k, "")).strip_edges()
		if not t.is_empty():
			return t
	return fallback_body_key(result, reason)


## Заголовок модалки (ключ перевода) по причине.
static func title_key(result: String, reason: String) -> String:
	if result == VICTORY:
		return "OUTCOME_VICTORY_TITLE"
	match reason:
		MYTHOS:
			return "OUTCOME_TIMEUP_TITLE"
		DEAD:
			return "OUTCOME_FALLEN_TITLE"
		EFFECT:
			return "OUTCOME_LOST_TITLE"
		_:
			return "OUTCOME_DEFEAT_TITLE"


## Общий текст (ключ перевода), когда у Древнего концовки нет.
static func fallback_body_key(result: String, reason: String) -> String:
	if result == VICTORY:
		return "OUTCOME_VICTORY_BODY"
	match reason:
		MYTHOS:
			return "OUTCOME_TIMEUP_BODY"
		DEAD:
			return "OUTCOME_FALLEN_BODY"
		EFFECT:
			return "OUTCOME_LOST_BODY"
		_:
			return "OUTCOME_DEFEAT_BODY"
