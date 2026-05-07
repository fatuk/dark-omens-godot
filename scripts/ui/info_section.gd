extends Control

## Зелёный орб справа на главной панели — отображает число (текущий раунд,
## количество омен и т.п.) поверх декоративного фона.

@export var label_text: String = "":
	set(v):
		label_text = v
		if is_node_ready():
			_label.text = v

@onready var _label: Label = %Label


func _ready() -> void:
	_label.text = label_text
