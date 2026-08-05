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
## (модалка сама себя освобождает при закрытии).
static func open(parent: Node, inv_name: String) -> void:
	var modal: ModalDialog = _MODAL.instantiate()
	parent.add_child(modal)
	# tr() — метод Node, из static его звать нельзя: переводим через сервер напрямую.
	modal.set_title(TranslationServer.translate(Investigators.display_name(inv_name)))
	modal.set_content(build(inv_name))
	modal.open()


## Блок «Спец-действие / Пассив» для встраивания в любую модалку.
static func build(inv_name: String) -> Control:
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
		_section(box, "INV_ABILITY_ACTION", ability)
	if not passive.is_empty():
		_section(box, "INV_ABILITY_PASSIVE", passive)
	return box


# Заголовок раздела + название способности + её описание.
static func _section(box: VBoxContainer, kind_key: String, data: Dictionary) -> void:
	var kind := UIStyle.label(kind_key, 13, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	kind.name = "Kind"
	box.add_child(kind)

	var nm: String = String(data.get("name", ""))
	if not nm.is_empty():
		var title := UIStyle.label(nm, 19, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
		title.name = "Name"
		box.add_child(title)

	box.add_child(_body(String(data.get("text", ""))))


static func _body(key: String) -> Label:
	var lbl := UIStyle.label(key, 15, UIColors.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Text"
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size.x = 420
	return lbl
