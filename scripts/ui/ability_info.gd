class_name AbilityInfo

## Карточка способностей сыщика: спец-действие и пассив одним блоком.
## Общая для двух точек показа — аватар на карте (investigator_panel) и
## центральный портрет в карусели выбора (investigator_picker), — чтобы текст и
## вёрстка не разъезжались.
##
## Данные берём из data/investigators.json (ability/passive). Сыщик без
## способностей показывает нейтральную строку, а не пустое окно.

const _MODAL := preload("res://scenes/ui/modal_dialog.tscn")


## Открыть модалку со способностями сыщика. parent — узел, к которому её цеплять
## (модалка сама себя освобождает при закрытии). Если это МОЙ сыщик и способность
## сейчас применима — внизу появляется кнопка «использовать»: активация живёт
## здесь, а не в панели действий (у медальонов нет арта под пятую кнопку).
static func open(parent: Node, inv_name: String) -> void:
	var modal: ModalDialog = _MODAL.instantiate()
	parent.add_child(modal)
	# tr() — метод Node, из static его звать нельзя: переводим через сервер напрямую.
	modal.set_title(TranslationServer.translate(Investigators.display_name(inv_name)))
	var use: Button = null
	if _is_mine(inv_name) and GameState.can_use_ability():
		use = UIStyle.button(
			String(Investigators.ability(inv_name).get("name", "")), UIColors.ACCENT
		)
		use.name = "UseAbility"
		use.add_theme_font_size_override("font_size", 19)  # читается как заголовок
		use.pressed.connect(
			func() -> void:
				modal.close()
				_activate(parent, inv_name)
		)
	modal.set_content(build(inv_name, use))
	modal.open()


# Показываем ли способность СВОЕГО сыщика в идущей партии (только тогда её можно
# применить: в карусели выбора партии ещё нет).
static func _is_mine(inv_name: String) -> bool:
	if not GameState.active:
		return false
	return String(GameState.my_player().get("investigator", "")) == inv_name


# Запуск способности: встроенный вид с вводом открывает свой диалог, обычная
# DSL-программа уходит хосту сразу.
static func _activate(parent: Node, inv_name: String) -> void:
	match Investigators.ability_kind(inv_name):
		"convertVitality":
			_open_convert_vitality(parent)
			return
		"strikeMonster":
			_open_strike_monster(parent, inv_name)
			return
	GameState.perform_action(GameActions.INVESTIGATOR_ABILITY)


# «Вы и 1 монстр на вашей локации теряете по 1 здоровью» (Фрэнк Далтон): монстр
# один — бьём сразу; несколько — игрок выбирает, кого. Валидирует хост.
static func _open_strike_monster(parent: Node, inv_name: String) -> void:
	var loc: String = String(GameState.my_player().get("location", ""))
	var here: Array = GameState.monsters.get(loc, [])
	if here.is_empty():
		return
	if here.size() == 1:
		GameState.perform_action(GameActions.INVESTIGATOR_ABILITY, {"monster": "%s#0" % loc})
		return
	var modal: ModalDialog = _MODAL.instantiate()
	parent.add_child(modal)
	modal.set_title(
		TranslationServer.translate(String(Investigators.ability(inv_name).get("name", "")))
	)
	var box := VBoxContainer.new()
	box.name = "StrikePick"
	box.add_theme_constant_override("separation", 10)
	var hint := UIStyle.label("ABILITY_STRIKE_PROMPT", UIStyle.MODAL_FS_BODY)
	hint.name = "Hint"
	box.add_child(hint)
	for i in range(here.size()):
		var inst: Variant = here[i]
		var mid: String = (
			String((inst as Dictionary).get("id", "")) if inst is Dictionary else String(inst)
		)
		var btn := UIStyle.button(
			String(GameState.monster_def(mid).get("nameKey", mid)), UIColors.ACCENT
		)
		btn.name = "Monster%d" % i
		var ref: String = "%s#%d" % [loc, i]
		btn.pressed.connect(
			func() -> void:
				modal.close()
				GameState.perform_action(GameActions.INVESTIGATOR_ABILITY, {"monster": ref})
		)
		box.add_child(btn)
	modal.set_content(box)
	modal.open()


# Диалог «внутреннего равновесия»: из какого запаса потратить и сколько — столько
# же вернётся в другой. Пределы: источник не ниже 1, приёмник не выше максимума
# (те же гварды дублирует хост). Направление одно за раз.
static func _open_convert_vitality(parent: Node) -> void:
	var me: Dictionary = GameState.my_player()
	var hp: int = int(me.get("hp", 0))
	var san: int = int(me.get("sanity", 0))
	var max_hp_to_san: int = mini(maxi(0, hp - 1), maxi(0, int(me.get("sanity_max", 0)) - san))
	var max_san_to_hp: int = mini(maxi(0, san - 1), maxi(0, int(me.get("hp_max", 0)) - hp))
	if max_hp_to_san <= 0 and max_san_to_hp <= 0:
		return

	var modal: ModalDialog = _MODAL.instantiate()
	parent.add_child(modal)
	modal.set_title(TranslationServer.translate("INV_MEI_LIN_ABILITY_NAME"))
	var box := VBoxContainer.new()
	box.name = "ConvertAlloc"
	box.add_theme_constant_override("separation", 12)
	var hint := UIStyle.label("ABILITY_CONVERT_PROMPT", UIStyle.MODAL_FS_BODY)
	hint.name = "Hint"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 360
	box.add_child(hint)

	var state := {"hp": 0, "san": 0}  # сколько тратим ИЗ здоровья / ИЗ рассудка
	var rows := {}
	var upd_ref := {"fn": Callable()}
	if max_hp_to_san > 0:
		rows["hp"] = UIStyle.stepper_row(box, "ABILITY_CONVERT_HP_TO_SAN", state, "hp", upd_ref)
	if max_san_to_hp > 0:
		rows["san"] = UIStyle.stepper_row(box, "ABILITY_CONVERT_SAN_TO_HP", state, "san", upd_ref)
	var upd := func() -> void:
		for k_v: Variant in rows:
			var k: String = k_v
			var r: Dictionary = rows[k]
			(r["count"] as Label).text = str(state[k])
			var cap: int = max_hp_to_san if k == "hp" else max_san_to_hp
			var other: int = int(state["san"] if k == "hp" else state["hp"])
			(r["plus"] as Button).disabled = int(state[k]) >= cap or other > 0
			(r["minus"] as Button).disabled = int(state[k]) <= 0
	upd_ref["fn"] = upd
	upd.call()

	var confirm := UIStyle.button("ABILITY_CONFIRM", UIColors.ACCENT)
	confirm.name = "Confirm"
	var confirmed := {"v": false}
	confirm.pressed.connect(
		func() -> void:
			confirmed["v"] = true
			modal.close()
	)
	box.add_child(confirm)
	modal.set_content(box)
	modal.closed.connect(
		func() -> void:
			if not confirmed["v"]:
				return
			var amount: int = maxi(int(state["hp"]), int(state["san"]))
			if amount <= 0:
				return
			var from: String = "hp" if int(state["hp"]) > 0 else "sanity"
			GameState.perform_action(
				GameActions.INVESTIGATOR_ABILITY, {"from": from, "amount": amount}
			)
	)
	modal.open()


## Блок «спец-действие + пассив» для встраивания в любую модалку. Разделы не
## подписываем: сверху всегда активка, под ней пассив — читается и без подписей.
## action_btn (если передан) встаёт ВМЕСТО названия спец-действия: название на
## самой кнопке, дублировать его строкой выше незачем.
static func build(inv_name: String, action_btn: Button = null) -> Control:
	var box := VBoxContainer.new()
	box.name = "AbilityInfo"
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size.x = 420

	var ability: Dictionary = Investigators.ability(inv_name)
	var passive: Dictionary = Investigators.passive(inv_name)
	if ability.is_empty() and passive.is_empty():
		box.add_child(_body("INV_ABILITY_NONE"))
		return box

	if not ability.is_empty():
		_section(box, ability, action_btn)
	if not passive.is_empty():
		_section(box, passive)
	return box


# Шапка (кнопка запуска ИЛИ название) + описание способности.
static func _section(box: VBoxContainer, data: Dictionary, btn: Button = null) -> void:
	var nm: String = String(data.get("name", ""))
	if btn != null:
		box.add_child(btn)
	elif not nm.is_empty():
		var title := UIStyle.label(
			nm, UIStyle.MODAL_FS_TITLE, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER
		)
		title.name = "Name"
		box.add_child(title)

	box.add_child(_body(String(data.get("text", ""))))


static func _body(key: String) -> Label:
	var lbl := UIStyle.label(key, UIStyle.MODAL_FS_BODY, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Text"
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size.x = 420
	return lbl
