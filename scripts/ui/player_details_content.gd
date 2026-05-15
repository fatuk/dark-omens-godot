class_name PlayerDetailsContent
extends RefCounted

## Билдер контента модалки «Подробнее об игроках». Возвращает VBoxContainer,
## который picker отдаёт в ModalDialog.set_content().
##
## Снимок состояния NetworkManager на момент вызова — без подписок и
## auto-refresh: модалка пересобирается при каждом открытии.


static func build(nm: Node) -> Control:
	var vb := VBoxContainer.new()
	vb.name = "DetailsContent"
	vb.add_theme_constant_override("separation", 10)

	# Шапка: имя комнаты + наша роль. TranslationServer.translate() — статичный
	# аналог tr() (последний — instance-метод Object, недоступен из static).
	var fmt := TranslationServer.translate("LOBBY_DETAILS_ROOM_FMT")
	var room_lbl := UIStyle.label(fmt % nm.room_name, 14)
	room_lbl.name = "Room"
	vb.add_child(room_lbl)

	var role_key: String = "LOBBY_DETAILS_ROLE_HOST" if nm.is_host() else "LOBBY_DETAILS_ROLE_GUEST"
	var role_lbl := UIStyle.label(role_key, 11, UIColors.MUTED)
	role_lbl.name = "Role"
	vb.add_child(role_lbl)

	UIStyle.separator(vb)

	var hdr := UIStyle.label("LOBBY_PLAYERS_HEADER", 11, UIColors.MUTED)
	hdr.name = "PlayersHeader"
	vb.add_child(hdr)

	var host_id: String = nm.host_id if "host_id" in nm else ""
	for pid: String in nm.players.keys():
		var row := _make_row(pid, nm.players[pid], host_id)
		row.name = "Player_%s" % pid
		vb.add_child(row)
	return vb


static func _make_row(pid: String, info: Dictionary, host_id: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var is_host := pid == host_id
	var crown := UIStyle.label(
		"♛" if is_host else "◆", 16,
		UIColors.ACCENT if is_host else UIColors.MUTED,
	)
	crown.name = "Crown"
	crown.custom_minimum_size.x = 24
	row.add_child(crown)

	var info_vb := VBoxContainer.new()
	info_vb.name = "Info"
	info_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_vb.add_theme_constant_override("separation", 2)
	row.add_child(info_vb)

	var name_lbl := UIStyle.label(info.get("name", pid), 16)
	name_lbl.name = "Name"
	info_vb.add_child(name_lbl)

	var inv_name: String = info.get("investigator", "")
	var inv_lbl: Label
	if inv_name.is_empty():
		inv_lbl = UIStyle.label("—", 11, UIColors.MUTED)
	else:
		inv_lbl = UIStyle.label(Investigators.display_name(inv_name), 11, UIColors.ACCENT)
	inv_lbl.name = "Investigator"
	info_vb.add_child(inv_lbl)

	row.add_child(_make_status_tag(pid, info, host_id))
	return row


static func _make_status_tag(pid: String, info: Dictionary, host_id: String) -> Label:
	var key:   String
	var color: Color
	if pid == host_id:
		key   = "LOBBY_TAG_HOST"
		color = UIColors.ACCENT
	elif info.get("ready", false):
		key   = "LOBBY_TAG_READY"
		color = UIColors.READY
	else:
		key   = "LOBBY_TAG_WAITING"
		color = UIColors.MUTED
	var tag := UIStyle.label(key, 13, color, HORIZONTAL_ALIGNMENT_RIGHT)
	tag.name = "Tag"
	tag.custom_minimum_size.x = 100
	return tag
