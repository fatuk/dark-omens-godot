class_name Phases
extends RefCounted

## Имена фаз раунда — значение GameState.phase. Константы вместо магических строк
## (опечатка в сравнении фазы = тихий баг). ВНИМАНИЕ: строки "encounter"/"mythos"
## встречаются и как owner/driver проверок, и как kind карты — это ДРУГИЕ понятия,
## их сюда НЕ сводим (совпадение значения случайно).
##
## Цикл: ACTION → ENCOUNTER → MYTHOS → ACTION (следующий раунд). "" — игра не идёт.

const ACTION := "action"
const ENCOUNTER := "encounter"
const MYTHOS := "mythos"
