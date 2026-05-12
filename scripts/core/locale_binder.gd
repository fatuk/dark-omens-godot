class_name LocaleBinder

## Привязка Control'ов к динамическим текстам (форматированные, конкатенации,
## значения из JSON-данных и т.п.) — авторефреш при смене локали.
##
## Для статического текста привязка не нужна: пишешь
##   label.text = "BTN_SAVE"     # ключ из CSV
## и Godot сам делает tr() при рендере + сам обновит при смене локали.
## LocaleBinder нужен только когда хранимый text — НЕ ключ (например результат
## конкатенации, форматирования, или производное значение).
##
## Usage:
##   LocaleBinder.bind(my_label, func() -> String:
##       return tr("ROUND_FMT") % GameState.round_num)
##
##   LocaleBinder.bind(_detail_roles, func() -> String:
##       return "  ·  ".join(inv.role.map(func(r): return tr(r))))
##
## Внутри: вешает meta на ноду + один глобальный subscriber на I18n.locale_changed.
## На смене языка проходим по всем нодам в группе и пересчитываем text.

const META_KEY  := "_locale_binder_getter"
const GROUP     := "_locale_bound"

static var _wired: bool = false


## Связывает свойство `text` контрола с getter-callable. Вызывает getter
## немедленно (для первой инициализации) и каждый раз при смене локали.
static func bind(node: Control, getter: Callable) -> void:
	_ensure_wired()
	if not is_instance_valid(node):
		return
	node.set_meta(META_KEY, getter)
	if not node.is_in_group(GROUP):
		node.add_to_group(GROUP)
	_apply(node)


## Снимает привязку (например перед освобождением ноды).
static func unbind(node: Control) -> void:
	if not is_instance_valid(node):
		return
	if node.has_meta(META_KEY):
		node.remove_meta(META_KEY)
	if node.is_in_group(GROUP):
		node.remove_from_group(GROUP)


# ── Внутренние ────────────────────────────────────────────────────────────────

static func _ensure_wired() -> void:
	if _wired:
		return
	_wired = true
	I18n.locale_changed.connect(_on_locale_changed_globally)


static func _on_locale_changed_globally(_locale: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for n: Node in tree.get_nodes_in_group(GROUP):
		if n is Control:
			_apply(n as Control)


static func _apply(node: Control) -> void:
	if not is_instance_valid(node):
		return
	if not node.has_meta(META_KEY):
		return
	var getter: Callable = node.get_meta(META_KEY)
	if not getter.is_valid():
		return
	var v: Variant = getter.call()
	if "text" in node:
		node.text = String(v)
