extends CanvasLayer

## Дев-панель живого тюнинга (шейдеры, анимация, раскладка UI). Ctrl+M откр./закр.
## Все слайдеры, секции, кнопка «Сбросить» строятся из массива _specs ниже —
## чтобы добавить новый параметр достаточно дописать одну запись + сеттер-Callable.
## Изменения не сохраняются в settings.cfg — это инструмент тонкой настройки: найденное
## значение запекается константой в целевой скрипт (default: ссылается на неё же).
##
## Спека параметра:
##   {"section": "ИМЯ"}                              — заголовок новой секции
##   {"key": ..., "label": ..., "min": ..., "max": ...,
##    "step": ..., "default": ..., "set": Callable}  — слайдер

@onready var _root: Control = $Root
@onready var _vbox: VBoxContainer = %VBox

# Кэш: key -> {slider: HSlider, val: Label, default: float, set: Callable}.
var _rows: Dictionary = {}

# Идёт первичная раскладка панели (см. _add_row: дефолты прогоняются через
# сеттеры). Параметры, которыми в игре управляет СОСТОЯНИЕ (проявленность рун и
# сила виньетки ведутся треком Рока), на этом этапе трогать нельзя — иначе на
# старте партии руны включались бы на полную при нулевом Роке.
var _seeding: bool = false

# ── Спеки параметров ──────────────────────────────────────────────────────────


func _build_specs() -> Array:
	return [
		{"section": "POST FX"},
		{
			"key": "sepia",
			"label": "Сепия",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.22,
			"set": _set_sepia
		},
		{"section": "ВЫДЕЛЕНИЕ ЛОКАЦИИ"},
		{
			"key": "ring_r",
			"label": "Радиус",
			"min": 20.0,
			"max": 100.0,
			"step": 1.0,
			"default": SelectionIndicator.RING_RADIUS,
			"set": _set_ring_r
		},
		{
			"key": "ring_w",
			"label": "Толщина",
			"min": 0.5,
			"max": 15.0,
			"step": 0.1,
			"default": SelectionIndicator.RING_THICKNESS,
			"set": _set_ring_w
		},
		{
			"key": "glow_in",
			"label": "Halo внутр.",
			"min": 20.0,
			"max": 120.0,
			"step": 1.0,
			"default": SelectionIndicator.GLOW_INNER,
			"set": _set_glow_in
		},
		{
			"key": "glow_out",
			"label": "Halo внеш.",
			"min": 30.0,
			"max": 200.0,
			"step": 1.0,
			"default": SelectionIndicator.GLOW_OUTER,
			"set": _set_glow_out
		},
		{
			"key": "glow_str",
			"label": "Сила halo",
			"min": 0.0,
			"max": 1.5,
			"step": 0.01,
			"default": SelectionIndicator.GLOW_STRENGTH,
			"set": _set_glow_str
		},
		{
			"key": "glow_fall",
			"label": "Спад halo",
			"min": 0.5,
			"max": 20.0,
			"step": 0.1,
			"default": SelectionIndicator.GLOW_FALLOFF,
			"set": _set_glow_fall
		},
		{
			"key": "off_x",
			"label": "Сдвиг X",
			"min": -50.0,
			"max": 50.0,
			"step": 0.5,
			"default": SelectionIndicator.OFFSET_X,
			"set": _set_off_x
		},
		{
			"key": "off_y",
			"label": "Сдвиг Y",
			"min": -50.0,
			"max": 50.0,
			"step": 0.5,
			"default": SelectionIndicator.OFFSET_Y,
			"set": _set_off_y
		},
		{
			"key": "pulse_spd",
			"label": "Пульс скор.",
			"min": 0.0,
			"max": 12.0,
			"step": 0.1,
			"default": SelectionIndicator.PULSE_SPEED,
			"set": _set_pulse_speed
		},
		{
			"key": "pulse_amt",
			"label": "Пульс размах",
			"min": 0.0,
			"max": 0.30,
			"step": 0.01,
			"default": SelectionIndicator.PULSE_AMOUNT,
			"set": _set_pulse_amount
		},
		{"section": "ВЕЕР КАРТ"},
		{
			"key": "hand_spread",
			"label": "Поворот",
			"min": 0.0,
			"max": 15.0,
			"step": 0.5,
			"default": HandCarousel.SPREAD,
			"set": _set_hand_spread
		},
		{
			"key": "hand_gap",
			"label": "Шаг X",
			"min": 20.0,
			"max": 180.0,
			"step": 1.0,
			"default": HandCarousel.GAP_X,
			"set": _set_hand_gap
		},
		{
			"key": "hand_arc",
			"label": "Дуга",
			"min": 0.0,
			"max": 30.0,
			"step": 0.1,
			"default": HandCarousel.ARC,
			"set": _set_hand_arc
		},
		{
			"key": "hand_lift",
			"label": "Подъём",
			"min": 0.0,
			"max": 260.0,
			"step": 1.0,
			"default": HandCarousel.LIFT,
			"set": _set_hand_lift
		},
		{
			"key": "hand_scale",
			"label": "Увеличение",
			"min": 1.0,
			"max": 2.2,
			"step": 0.01,
			"default": HandCarousel.HSCALE,
			"set": _set_hand_scale
		},
		{
			"key": "hand_push",
			"label": "Расступание",
			"min": 0.0,
			"max": 160.0,
			"step": 1.0,
			"default": HandCarousel.PUSH,
			"set": _set_hand_push
		},
		{
			"key": "hand_pivot",
			"label": "Центр (xH)",
			"min": 0.5,
			"max": 2.5,
			"step": 0.05,
			"default": HandCarousel.PIVOT_Y_FRAC,
			"set": _set_hand_pivot
		},
		{
			"key": "hand_below",
			"label": "Низ веера",
			"min": -120.0,
			"max": 140.0,
			"step": 1.0,
			"default": HandCarousel.HAND_BELOW,
			"set": _set_hand_below
		},
		{
			"key": "hand_anim",
			"label": "Анимация",
			"min": 0.05,
			"max": 0.80,
			"step": 0.01,
			"default": HandCarousel.ANIM,
			"set": _set_hand_anim
		},
		{
			"key": "hand_sfx_var",
			"label": "Звук вариаций",
			"min": 1.0,
			"max": 16.0,
			"step": 1.0,
			"default": float(HandCarousel.SCROLL_VARIATIONS),
			"set": _set_hand_sfx_var
		},
		{
			"key": "hand_sfx_pitch",
			"label": "Звук питч",
			"min": 0.0,
			"max": 0.30,
			"step": 0.01,
			"default": HandCarousel.SCROLL_PITCH,
			"set": _set_hand_sfx_pitch
		},
		{
			"key": "hand_arrow_x",
			"label": "Стрелки X",
			"min": 0.0,
			"max": 1000.0,
			"step": 1.0,
			"default": HandCarousel.ARROW_EDGE_X,
			"set": _set_arrow_x
		},
		{
			"key": "hand_arrow_y",
			"label": "Стрелки Y",
			"min": -200.0,
			"max": 200.0,
			"step": 1.0,
			"default": HandCarousel.ARROW_Y_OFF,
			"set": _set_arrow_y
		},
		{"section": "ТУМАН"},
		{
			"key": "fog_speed",
			"label": "Скорость",
			"min": 0.0,
			"max": 0.15,
			"step": 0.005,
			"default": 0.01,
			"set": _set_fog_speed
		},
		{
			"key": "fog_scale",
			"label": "Масштаб",
			"min": 0.5,
			"max": 6.0,
			"step": 0.05,
			"default": 0.6,
			"set": _set_fog_scale
		},
		{
			"key": "fog_density",
			"label": "Плотность",
			"min": 0.0,
			"max": 2.0,
			"step": 0.05,
			"default": 0.05,
			"set": _set_fog_density
		},
		{
			"key": "fog_ground",
			"label": "Низ. градиент",
			"min": 0.0,
			"max": 1.0,
			"step": 0.05,
			"default": 0.1,
			"set": _set_fog_ground
		},
		{
			"key": "fog_wisp",
			"label": "Клочковатость",
			"min": 0.0,
			"max": 1.0,
			"step": 0.05,
			"default": 0.35,
			"set": _set_fog_wisp
		},
		{
			"key": "fog_period",
			"label": "Период тайла",
			"min": 1.0,
			"max": 12.0,
			"step": 0.5,
			"default": 3.5,
			"set": _set_fog_period
		},
		{
			"key": "fog_freq",
			"label": "Частота шума",
			"min": 0.001,
			"max": 0.04,
			"step": 0.001,
			"default": 0.01,
			"set": _set_fog_freq
		},
		{
			"key": "fog_oct",
			"label": "Октавы",
			"min": 1.0,
			"max": 5.0,
			"step": 1.0,
			"default": 4.0,
			"set": _set_fog_oct
		},
		{"section": "ДЫМ ЧАТА"},
		{
			"key": "chat_swirl_amp",
			"label": "Размах",
			"min": 0.0,
			"max": 0.05,
			"step": 0.001,
			"default": 0.01,
			"set": _set_chat_swirl_amp
		},
		{
			"key": "chat_swirl_speed",
			"label": "Скорость",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 1.0,
			"set": _set_chat_swirl_speed
		},
		{"section": "КРУГ ЗНАМЕНИЙ"},
		{
			"key": "omen_radius",
			"label": "Радиус окна",
			"min": 20.0,
			"max": 120.0,
			"step": 1.0,
			"default": OmensCounter.MASK_RADIUS,
			"set": _set_omen_radius
		},
		{
			"key": "omen_off_x",
			"label": "Окно X",
			"min": -60.0,
			"max": 60.0,
			"step": 0.5,
			"default": OmensCounter.MASK_OFFSET_X,
			"set": _set_omen_off_x
		},
		{
			"key": "omen_off_y",
			"label": "Окно Y",
			"min": -60.0,
			"max": 60.0,
			"step": 0.5,
			"default": OmensCounter.MASK_OFFSET_Y,
			"set": _set_omen_off_y
		},
		{
			"key": "omen_pos_x",
			"label": "Позиция X",
			"min": -200.0,
			"max": 200.0,
			"step": 1.0,
			"default": OmensCounter.POS_OFFSET_X,
			"set": _set_omen_pos_x
		},
		{
			"key": "omen_pos_y",
			"label": "Позиция Y",
			"min": -200.0,
			"max": 200.0,
			"step": 1.0,
			"default": OmensCounter.POS_OFFSET_Y,
			"set": _set_omen_pos_y
		},
		{
			"key": "omen_dial_x",
			"label": "Диск X",
			"min": -80.0,
			"max": 80.0,
			"step": 0.5,
			"default": OmensCounter.DIAL_OFFSET_X,
			"set": _set_omen_dial_x
		},
		{
			"key": "omen_dial_y",
			"label": "Диск Y",
			"min": -80.0,
			"max": 80.0,
			"step": 0.5,
			"default": OmensCounter.DIAL_OFFSET_Y,
			"set": _set_omen_dial_y
		},
		{
			"key": "omen_angle",
			"label": "База угла",
			"min": -180.0,
			"max": 180.0,
			"step": 1.0,
			"default": OmensCounter.START_ANGLE_DEG,
			"set": _set_omen_angle
		},
		{
			"key": "omen_step",
			"label": "Шаг омена",
			"min": 10.0,
			"max": 90.0,
			"step": 1.0,
			"default": OmensCounter.STEP_DEG,
			"set": _set_omen_step
		},
		{"section": "СТОПКА ЖЕТОНОВ"},
		{
			"key": "ent_size",
			"label": "Размер",
			"min": 0.3,
			"max": 2.0,
			"step": 0.05,
			"default": MapLayer.ENTITY_SIZE_FRAC,
			"set": _set_ent_size
		},
		{
			"key": "ent_stack_y",
			"label": "Стопка Y",
			"min": -100.0,
			"max": 100.0,
			"step": 1.0,
			"default": MapLayer.ENTITY_STACK_Y,
			"set": _set_ent_stack_y
		},
		{
			"key": "ent_stack_x0",
			"label": "Стопка X0",
			"min": 0.0,
			"max": 100.0,
			"step": 1.0,
			"default": MapLayer.ENTITY_STACK_X0,
			"set": _set_ent_stack_x0
		},
		{
			"key": "ent_stack_dx",
			"label": "Наслоение X",
			"min": 0.0,
			"max": 60.0,
			"step": 1.0,
			"default": MapLayer.ENTITY_STACK_DX,
			"set": _set_ent_stack_dx
		},
		{
			"key": "ent_row_gap",
			"label": "Ряд шаг",
			"min": 10.0,
			"max": 100.0,
			"step": 1.0,
			"default": MapLayer.ENTITY_ROW_GAP,
			"set": _set_ent_row_gap
		},
		{
			"key": "ent_row_x0",
			"label": "Ряд X0",
			"min": 0.0,
			"max": 120.0,
			"step": 1.0,
			"default": MapLayer.ENTITY_ROW_X0,
			"set": _set_ent_row_x0
		},
		{
			"key": "ent_lerp",
			"label": "Скорость ряда",
			"min": 1.0,
			"max": 30.0,
			"step": 0.5,
			"default": MapLayer.ENTITY_HOVER_LERP,
			"set": _set_ent_lerp
		},
		{"section": "ДЫМ КАРТЫ"},
		{
			"key": "csmoke_speed",
			"label": "Скорость",
			"min": 0.0,
			"max": 0.30,
			"step": 0.005,
			"default": GameCard.SMOKE_SPEED,
			"set": _set_csmoke_speed
		},
		{
			"key": "csmoke_int",
			"label": "Плотность",
			"min": 0.0,
			"max": 1.5,
			"step": 0.01,
			"default": GameCard.SMOKE_INTENSITY,
			"set": _set_csmoke_intensity
		},
		{
			"key": "csmoke_scale",
			"label": "Крупность",
			"min": 1.0,
			"max": 8.0,
			"step": 0.1,
			"default": GameCard.SMOKE_SCALE,
			"set": _set_csmoke_scale
		},
		{
			"key": "csmoke_r",
			"label": "Цвет R",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": GameCard.SMOKE_TINT.r,
			"set": _set_csmoke_r
		},
		{
			"key": "csmoke_g",
			"label": "Цвет G",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": GameCard.SMOKE_TINT.g,
			"set": _set_csmoke_g
		},
		{
			"key": "csmoke_b",
			"label": "Цвет B",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": GameCard.SMOKE_TINT.b,
			"set": _set_csmoke_b
		},
		{"section": "МАГАЗИН · КАМЕРА"},
		{
			"key": "shop_cam_x",
			"label": "Камера · X",
			"min": -4.0,
			"max": 4.0,
			"step": 0.05,
			"default": ShopModal.CAM_X,
			"set": _set_shop_cam_x
		},
		{
			"key": "shop_cam_dist",
			"label": "Камера · Z",
			"min": 2.0,
			"max": 10.0,
			"step": 0.1,
			"default": ShopModal.CAM_DIST,
			"set": _set_shop_cam_dist
		},
		{
			"key": "shop_cam_height",
			"label": "Камера · высота",
			"min": 0.0,
			"max": 6.0,
			"step": 0.1,
			"default": ShopModal.CAM_HEIGHT,
			"set": _set_shop_cam_height
		},
		{
			"key": "shop_cam_pitch",
			"label": "Камера · наклон",
			"min": -60.0,
			"max": 0.0,
			"step": 1.0,
			"default": ShopModal.CAM_PITCH,
			"set": _set_shop_cam_pitch
		},
		{
			"key": "shop_cam_fov",
			"label": "Камера · FOV",
			"min": 15.0,
			"max": 60.0,
			"step": 1.0,
			"default": ShopModal.CAM_FOV,
			"set": _set_shop_cam_fov
		},
		{"section": "МАГАЗИН · РЯД"},
		{
			"key": "shop_card_tilt",
			"label": "Наклон карт",
			"min": 0.0,
			"max": 80.0,
			"step": 1.0,
			"default": ShopModal.CARD_TILT,
			"set": _set_shop_card_tilt
		},
		{
			"key": "shop_row_gap",
			"label": "Шаг ряда",
			"min": 0.6,
			"max": 2.5,
			"step": 0.02,
			"default": ShopModal.ROW_GAP,
			"set": _set_shop_row_gap
		},
		{
			"key": "shop_row_y",
			"label": "Ряд · Y",
			"min": -2.0,
			"max": 2.0,
			"step": 0.05,
			"default": ShopModal.ROW_Y,
			"set": _set_shop_row_y
		},
		{
			"key": "shop_row_z",
			"label": "Ряд · Z",
			"min": -3.0,
			"max": 3.0,
			"step": 0.05,
			"default": ShopModal.ROW_Z,
			"set": _set_shop_row_z
		},
		{
			"key": "shop_hover_up",
			"label": "Наведение · вверх",
			"min": 0.0,
			"max": 2.0,
			"step": 0.05,
			"default": ShopModal.HOVER_UP,
			"set": _set_shop_hover_up
		},
		{
			"key": "shop_hover_fwd",
			"label": "Наведение · к камере",
			"min": 0.0,
			"max": 3.0,
			"step": 0.05,
			"default": ShopModal.HOVER_FWD,
			"set": _set_shop_hover_fwd
		},
		{
			"key": "shop_hover_scale",
			"label": "Наведение · масштаб",
			"min": 1.0,
			"max": 2.0,
			"step": 0.01,
			"default": ShopModal.HOVER_SCALE,
			"set": _set_shop_hover_scale
		},
		{"section": "МАГАЗИН · СВЕТ Л (фонарь)"},
		{
			"key": "shop_lamp_energy",
			"label": "Л · яркость",
			"min": 0.0,
			"max": 16.0,
			"step": 0.1,
			"default": ShopModal.LAMP_ENERGY,
			"set": _set_shop_lamp_energy
		},
		{
			"key": "shop_lamp_range",
			"label": "Л · дальность",
			"min": 1.0,
			"max": 60.0,
			"step": 0.5,
			"default": ShopModal.LAMP_RANGE,
			"set": _set_shop_lamp_range
		},
		{
			"key": "shop_lamp_atten",
			"label": "Л · спад (градиент)",
			"min": 0.1,
			"max": 8.0,
			"step": 0.05,
			"default": ShopModal.LAMP_ATTEN,
			"set": _set_shop_lamp_atten
		},
		{
			"key": "shop_lamp_x",
			"label": "Л · X",
			"min": -8.0,
			"max": 8.0,
			"step": 0.1,
			"default": ShopModal.LAMP_X,
			"set": _set_shop_lamp_x
		},
		{
			"key": "shop_lamp_y",
			"label": "Л · Y",
			"min": 0.0,
			"max": 8.0,
			"step": 0.1,
			"default": ShopModal.LAMP_Y,
			"set": _set_shop_lamp_y
		},
		{
			"key": "shop_lamp_z",
			"label": "Л · Z",
			"min": -4.0,
			"max": 8.0,
			"step": 0.1,
			"default": ShopModal.LAMP_Z,
			"set": _set_shop_lamp_z
		},
		{
			"key": "shop_lamp_r",
			"label": "Л · R",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": ShopModal.LAMP_R,
			"set": _set_shop_lamp_r
		},
		{
			"key": "shop_lamp_g",
			"label": "Л · G",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": ShopModal.LAMP_G,
			"set": _set_shop_lamp_g
		},
		{
			"key": "shop_lamp_b",
			"label": "Л · B",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": ShopModal.LAMP_B,
			"set": _set_shop_lamp_b
		},
		{"section": "МАГАЗИН · СВЕТ П (свеча)"},
		{
			"key": "shop_lamp2_energy",
			"label": "П · яркость",
			"min": 0.0,
			"max": 16.0,
			"step": 0.1,
			"default": ShopModal.LAMP2_ENERGY,
			"set": _set_shop_lamp2_energy
		},
		{
			"key": "shop_lamp2_range",
			"label": "П · дальность",
			"min": 1.0,
			"max": 60.0,
			"step": 0.5,
			"default": ShopModal.LAMP2_RANGE,
			"set": _set_shop_lamp2_range
		},
		{
			"key": "shop_lamp2_atten",
			"label": "П · спад (градиент)",
			"min": 0.1,
			"max": 8.0,
			"step": 0.05,
			"default": ShopModal.LAMP2_ATTEN,
			"set": _set_shop_lamp2_atten
		},
		{
			"key": "shop_lamp2_x",
			"label": "П · X",
			"min": -8.0,
			"max": 8.0,
			"step": 0.1,
			"default": ShopModal.LAMP2_X,
			"set": _set_shop_lamp2_x
		},
		{
			"key": "shop_lamp2_y",
			"label": "П · Y",
			"min": 0.0,
			"max": 8.0,
			"step": 0.1,
			"default": ShopModal.LAMP2_Y,
			"set": _set_shop_lamp2_y
		},
		{
			"key": "shop_lamp2_z",
			"label": "П · Z",
			"min": -4.0,
			"max": 8.0,
			"step": 0.1,
			"default": ShopModal.LAMP2_Z,
			"set": _set_shop_lamp2_z
		},
		{
			"key": "shop_lamp2_r",
			"label": "П · R",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": ShopModal.LAMP2_R,
			"set": _set_shop_lamp2_r
		},
		{
			"key": "shop_lamp2_g",
			"label": "П · G",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": ShopModal.LAMP2_G,
			"set": _set_shop_lamp2_g
		},
		{
			"key": "shop_lamp2_b",
			"label": "П · B",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": ShopModal.LAMP2_B,
			"set": _set_shop_lamp2_b
		},
		{"section": "МАГАЗИН · СВЕТ ОКРУЖ."},
		{
			"key": "shop_ambient",
			"label": "Окружающий",
			"min": 0.0,
			"max": 2.0,
			"step": 0.05,
			"default": ShopModal.AMBIENT,
			"set": _set_shop_ambient
		},
		{
			"key": "shop_amb_r",
			"label": "Окруж. · R",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": ShopModal.AMBIENT_R,
			"set": _set_shop_amb_r
		},
		{
			"key": "shop_amb_g",
			"label": "Окруж. · G",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": ShopModal.AMBIENT_G,
			"set": _set_shop_amb_g
		},
		{
			"key": "shop_amb_b",
			"label": "Окруж. · B",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": ShopModal.AMBIENT_B,
			"set": _set_shop_amb_b
		},
		{"section": "МАГАЗИН · ТЕНЬ"},
		{
			"key": "shop_shadow_alpha",
			"label": "Плотность тени",
			"min": 0.0,
			"max": 1.0,
			"step": 0.02,
			"default": ShopModal.SHADOW_ALPHA,
			"set": _set_shop_shadow_alpha
		},
		{
			"key": "shop_shadow_scale",
			"label": "Размер тени",
			"min": 0.8,
			"max": 1.8,
			"step": 0.01,
			"default": ShopModal.SHADOW_SCALE,
			"set": _set_shop_shadow_scale
		},
		{
			"key": "shop_shadow_width",
			"label": "Ширина тени",
			"min": 0.5,
			"max": 2.0,
			"step": 0.01,
			"default": ShopModal.SHADOW_WIDTH,
			"set": _set_shop_shadow_width
		},
		{
			"key": "shop_shadow_x",
			"label": "Тень · X",
			"min": -0.5,
			"max": 0.5,
			"step": 0.01,
			"default": ShopModal.SHADOW_X,
			"set": _set_shop_shadow_x
		},
		{
			"key": "shop_shadow_y",
			"label": "Тень · Y",
			"min": -0.5,
			"max": 0.5,
			"step": 0.01,
			"default": ShopModal.SHADOW_Y,
			"set": _set_shop_shadow_y
		},
		{
			"key": "shop_shadow_z",
			"label": "Тень · Z",
			"min": -0.5,
			"max": 0.5,
			"step": 0.01,
			"default": ShopModal.SHADOW_Z,
			"set": _set_shop_shadow_z
		},
		{"section": "САЙДБАР · ТЕНЬ"},
		{
			"key": "sb_shadow_alpha",
			"label": "Плотность",
			"min": 0.0,
			"max": 1.0,
			"step": 0.02,
			"default": LocationSidebar.SHADOW_ALPHA,
			"set": _set_sb_shadow_alpha
		},
		{
			"key": "sb_shadow_size",
			"label": "Размытие",
			"min": 0.0,
			"max": 140.0,
			"step": 1.0,
			"default": LocationSidebar.SHADOW_SIZE,
			"set": _set_sb_shadow_size
		},
		{
			"key": "sb_shadow_grow",
			"label": "Расширение",
			"min": 0.0,
			"max": 60.0,
			"step": 1.0,
			"default": LocationSidebar.SHADOW_GROW,
			"set": _set_sb_shadow_grow
		},
		{
			"key": "sb_shadow_x",
			"label": "Сдвиг X",
			"min": -60.0,
			"max": 60.0,
			"step": 1.0,
			"default": LocationSidebar.SHADOW_OFFSET_X,
			"set": _set_sb_shadow_x
		},
		{
			"key": "sb_shadow_y",
			"label": "Сдвиг Y",
			"min": -60.0,
			"max": 60.0,
			"step": 1.0,
			"default": LocationSidebar.SHADOW_OFFSET_Y,
			"set": _set_sb_shadow_y
		},
		{"section": "ГАЛЕРЕЯ · ТЕКСТ (углы трапеции)"},
		{
			"key": "gal_tl_x",
			"label": "Верх-лев X",
			"min": 800.0,
			"max": 2600.0,
			"step": 5.0,
			"default": GalleryModal.TEXT_QUAD_TL.x,
			"set": _set_gal_tl_x
		},
		{
			"key": "gal_tl_y",
			"label": "Верх-лев Y",
			"min": 1100.0,
			"max": 1700.0,
			"step": 5.0,
			"default": GalleryModal.TEXT_QUAD_TL.y,
			"set": _set_gal_tl_y
		},
		{
			"key": "gal_tr_x",
			"label": "Верх-прав X",
			"min": 800.0,
			"max": 2600.0,
			"step": 5.0,
			"default": GalleryModal.TEXT_QUAD_TR.x,
			"set": _set_gal_tr_x
		},
		{
			"key": "gal_tr_y",
			"label": "Верх-прав Y",
			"min": 1100.0,
			"max": 1700.0,
			"step": 5.0,
			"default": GalleryModal.TEXT_QUAD_TR.y,
			"set": _set_gal_tr_y
		},
		{
			"key": "gal_br_x",
			"label": "Низ-прав X",
			"min": 800.0,
			"max": 2600.0,
			"step": 5.0,
			"default": GalleryModal.TEXT_QUAD_BR.x,
			"set": _set_gal_br_x
		},
		{
			"key": "gal_br_y",
			"label": "Низ-прав Y",
			"min": 1100.0,
			"max": 1700.0,
			"step": 5.0,
			"default": GalleryModal.TEXT_QUAD_BR.y,
			"set": _set_gal_br_y
		},
		{
			"key": "gal_bl_x",
			"label": "Низ-лев X",
			"min": 800.0,
			"max": 2600.0,
			"step": 5.0,
			"default": GalleryModal.TEXT_QUAD_BL.x,
			"set": _set_gal_bl_x
		},
		{
			"key": "gal_bl_y",
			"label": "Низ-лев Y",
			"min": 1100.0,
			"max": 1700.0,
			"step": 5.0,
			"default": GalleryModal.TEXT_QUAD_BL.y,
			"set": _set_gal_bl_y
		},
		{
			"key": "gal_font",
			"label": "Шрифт",
			"min": 20.0,
			"max": 80.0,
			"step": 1.0,
			"default": GalleryModal.TEXT_FONT_SIZE,
			"set": _set_gal_font
		},
		{
			"key": "gal_mx",
			"label": "Поле X",
			"min": 0.0,
			"max": 250.0,
			"step": 5.0,
			"default": GalleryModal.TEXT_MARGIN.x,
			"set": _set_gal_mx
		},
		{
			"key": "gal_my",
			"label": "Поле Y",
			"min": 0.0,
			"max": 250.0,
			"step": 5.0,
			"default": GalleryModal.TEXT_MARGIN.y,
			"set": _set_gal_my
		},
		{"section": "КУБЫ"},
		{
			"key": "die_gap",
			"label": "Зазор рамок",
			"min": 0.0,
			"max": 40.0,
			"step": 1.0,
			"default": DiceTray.DIE_GAP,
			"set": _set_die_gap
		},
		{
			"key": "die_bonus_r",
			"label": "Добавленный R",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": DiceTray.C_MARK_BONUS.r,
			"set": _set_die_bonus_r
		},
		{
			"key": "die_bonus_g",
			"label": "Добавленный G",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": DiceTray.C_MARK_BONUS.g,
			"set": _set_die_bonus_g
		},
		{
			"key": "die_bonus_b",
			"label": "Добавленный B",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": DiceTray.C_MARK_BONUS.b,
			"set": _set_die_bonus_b
		},
		{
			"key": "die_blocked_r",
			"label": "Отнятый R",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": DiceTray.C_MARK_BLOCKED.r,
			"set": _set_die_blocked_r
		},
		{
			"key": "die_blocked_g",
			"label": "Отнятый G",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": DiceTray.C_MARK_BLOCKED.g,
			"set": _set_die_blocked_g
		},
		{
			"key": "die_blocked_b",
			"label": "Отнятый B",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": DiceTray.C_MARK_BLOCKED.b,
			"set": _set_die_blocked_b
		},
		{"section": "РУНЫ РОКА"},
		{
			"key": "runes_amount",
			"label": "Проявленность",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 1.0,
			"set": _set_runes_amount
		},
		{
			"key": "runes_grid",
			"label": "Ячеек",
			"min": 2.0,
			"max": 24.0,
			"step": 1.0,
			"default": 16.0,
			"set": _set_runes_grid
		},
		{
			"key": "runes_glyph_scale",
			"label": "Размер знака",
			"min": 0.1,
			"max": 2.0,
			"step": 0.01,
			"default": 0.84,
			"set": _set_runes_glyph_scale
		},
		{
			"key": "runes_reveal_spread",
			"label": "Разброс появления",
			"min": 0.01,
			"max": 1.0,
			"step": 0.01,
			"default": 0.73,
			"set": _set_runes_reveal_spread
		},
		{
			"key": "runes_intensity",
			"label": "Яркость",
			"min": 0.0,
			"max": 3.0,
			"step": 0.05,
			"default": 1.05,
			"set": _set_runes_intensity
		},
		{
			"key": "runes_pulse_speed",
			"label": "Скорость пульса",
			"min": 0.0,
			"max": 4.0,
			"step": 0.05,
			"default": 2.15,
			"set": _set_runes_pulse_speed
		},
		{
			"key": "runes_pulse_depth",
			"label": "Глубина пульса",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.61,
			"set": _set_runes_pulse_depth
		},
		{
			"key": "runes_drift",
			"label": "Дрейф",
			"min": 0.0,
			"max": 0.5,
			"step": 0.005,
			"default": 0.2,
			"set": _set_runes_drift
		},
		{
			"key": "runes_edge_bias",
			"label": "Руны к краям",
			"min": 0.0,
			"max": 2.0,
			"step": 0.05,
			"default": 1.05,
			"set": _set_runes_edge_bias
		},
		{
			"key": "runes_r",
			"label": "Цвет R",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.64,
			"set": _set_runes_r
		},
		{
			"key": "runes_g",
			"label": "Цвет G",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.85,
			"set": _set_runes_g
		},
		{
			"key": "runes_b",
			"label": "Цвет B",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.55,
			"set": _set_runes_b
		},
		{
			"key": "runes_size_jitter",
			"label": "Разброс размера",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.45,
			"set": _set_runes_size_jitter
		},
		{
			"key": "runes_pos_jitter",
			"label": "Разброс позиции",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.35,
			"set": _set_runes_pos_jitter
		},
		{"section": "ВИНЬЕТКА"},
		{
			"key": "vig_strength",
			"label": "Сила",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.56,
			"set": _set_vig_strength
		},
		{
			"key": "vig_start",
			"label": "Начало",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.45,
			"set": _set_vig_start
		},
		{
			"key": "vig_softness",
			"label": "Растушёвка",
			"min": 0.01,
			"max": 1.0,
			"step": 0.01,
			"default": 0.85,
			"set": _set_vig_softness
		},
		{
			"key": "vig_r",
			"label": "Цвет R",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.01,
			"set": _set_vig_r
		},
		{
			"key": "vig_g",
			"label": "Цвет G",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.03,
			"set": _set_vig_g
		},
		{
			"key": "vig_b",
			"label": "Цвет B",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": 0.0,
			"set": _set_vig_b
		},
		{"section": "КАРТА · ТЕНИ"},
		{
			"key": "shadow_radius",
			"label": "Мягкость",
			"min": 0.0,
			"max": 16.0,
			"step": 0.5,
			"default": MapLayer.SHADOW_RADIUS,
			"set": _set_shadow_radius
		},
		{
			"key": "shadow_dark",
			"label": "Плотность",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": MapLayer.SHADOW_DARKNESS,
			"set": _set_shadow_dark
		},
		{
			"key": "shadow_spread",
			"label": "Расширение",
			"min": 1.0,
			"max": 1.3,
			"step": 0.01,
			"default": MapLayer.SHADOW_SPREAD,
			"set": _set_shadow_spread
		},
		{
			"key": "shadow_dy",
			"label": "Сдвиг вниз, px",
			"min": -8.0,
			"max": 16.0,
			"step": 0.5,
			"default": MapLayer.SHADOW_OFFSET_Y,
			"set": _set_shadow_dy
		},
		{"section": "КАРТА · ОРЕОЛ ХОДА"},
		{
			"key": "turn_glow_alpha",
			"label": "Яркость",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": InvestigatorPin.GLOW_ALPHA,
			"set": _set_turn_glow_alpha
		},
		{
			"key": "turn_glow_spread",
			"label": "Размах",
			"min": 1.05,
			"max": 2.5,
			"step": 0.05,
			"default": InvestigatorPin.GLOW_SPREAD,
			"set": _set_turn_glow_spread
		},
		{
			"key": "turn_glow_pulse_speed",
			"label": "Скорость пульсации",
			"min": 0.0,
			"max": 8.0,
			"step": 0.1,
			"default": InvestigatorPin.GLOW_PULSE_SPEED,
			"set": _set_turn_glow_pulse_speed
		},
		{
			"key": "turn_glow_pulse_amount",
			"label": "Глубина пульсации",
			"min": 0.0,
			"max": 0.6,
			"step": 0.01,
			"default": InvestigatorPin.GLOW_PULSE_AMOUNT,
			"set": _set_turn_glow_pulse_amount
		},
		{
			"key": "pin_away_alpha",
			"label": "Прозрачность вышедшего",
			"min": 0.1,
			"max": 1.0,
			"step": 0.05,
			"default": InvestigatorPin.AWAY_ALPHA,
			"set": _set_pin_away_alpha
		},
		{"section": "КАРТА · ПАНОРАМИРОВАНИЕ"},
		{
			"key": "map_friction",
			"label": "Трение инерции",
			"min": 0.3,
			"max": 12.0,
			"step": 0.1,
			"default": WorldMap.INERTIA_FRICTION,
			"set": _set_map_friction
		},
		{
			"key": "map_stop",
			"label": "Порог остановки",
			"min": 1.0,
			"max": 60.0,
			"step": 1.0,
			"default": WorldMap.INERTIA_MIN_SPEED,
			"set": _set_map_stop
		},
		{
			"key": "map_flick",
			"label": "Окно броска, мс",
			"min": 20.0,
			"max": 400.0,
			"step": 10.0,
			"default": float(WorldMap.FLICK_WINDOW_MS),
			"set": _set_map_flick
		},
		{
			"key": "map_click",
			"label": "Порог клика, px",
			"min": 1.0,
			"max": 24.0,
			"step": 1.0,
			"default": WorldMap.CLICK_THRESHOLD,
			"set": _set_map_click
		},
		{
			"key": "map_zoom_speed",
			"label": "Плавность зума",
			"min": 2.0,
			"max": 30.0,
			"step": 0.5,
			"default": WorldMap.ZOOM_SPEED,
			"set": _set_map_zoom_speed
		},
		{
			"key": "map_zoom_step",
			"label": "Шаг колеса",
			"min": 0.02,
			"max": 0.5,
			"step": 0.01,
			"default": WorldMap.ZOOM_STEP_REF,
			"set": _set_map_zoom_step
		},
		{"section": "МОДАЛКИ"},
		{
			"key": "modal_backdrop",
			"label": "Затемнение фона",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": UIStyle.MODAL_BACKDROP_ALPHA,
			"set": _set_modal_backdrop
		},
		{
			"key": "modal_fade_in",
			"label": "Появление, сек",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": UIStyle.MODAL_FADE_IN,
			"set": _set_modal_fade_in
		},
		{
			"key": "modal_fade_out",
			"label": "Закрытие, сек",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": UIStyle.MODAL_FADE_OUT,
			"set": _set_modal_fade_out
		},
		{
			"key": "modal_pop",
			"label": "Масштаб выплывания",
			"min": 0.5,
			"max": 1.0,
			"step": 0.01,
			"default": UIStyle.MODAL_POP,
			"set": _set_modal_pop
		},
		{"section": "ПРОСМОТР КАРТЫ"},
		{
			"key": "cpv_max_h",
			"label": "Высота карты",
			"min": 400.0,
			"max": 1600.0,
			"step": 10.0,
			"default": CardPreview.MAX_H,
			"set": _set_cpv_max_h
		},
		{
			"key": "cpv_margin",
			"label": "Отступ от краёв",
			"min": 0.0,
			"max": 300.0,
			"step": 2.0,
			"default": CardPreview.MARGIN_V,
			"set": _set_cpv_margin
		},
		{
			"key": "cpv_backdrop",
			"label": "Затемнение фона",
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"default": CardPreview.BACKDROP_ALPHA,
			"set": _set_cpv_backdrop
		},
	]


# ── Жизненный цикл ────────────────────────────────────────────────────────────


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root.visible = false
	UIStyle.style_panel(%Panel, 12)
	_build_ui()
	# Панель тюнинга (Ctrl+M) — только dev; в релизе игрок её не открывает.
	set_process_unhandled_input(OS.is_debug_build())


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_M and k.ctrl_pressed:
			_root.visible = not _root.visible
			get_viewport().set_input_as_handled()


# ── Построение UI ─────────────────────────────────────────────────────────────


func _build_ui() -> void:
	_seeding = true
	_add_title("  ТЮНИНГ  ·  Ctrl+M")
	for spec: Dictionary in _build_specs():
		if spec.has("section"):
			_add_section(String(spec.section))
		else:
			_add_row(spec)
	_seeding = false
	_add_reset_button()


func _add_title(text: String) -> void:
	var lbl := Label.new()
	lbl.name = "Label"
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 26)
	lbl.add_theme_color_override("font_color", UIColors.ACCENT)
	_vbox.add_child(lbl)


func _add_section(title: String) -> void:
	var spacer := Control.new()
	spacer.name = "Spacer"
	spacer.custom_minimum_size = Vector2(0, 12)
	_vbox.add_child(spacer)
	var lbl := Label.new()
	lbl.name = "Label"
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", UIColors.WARNING)
	_vbox.add_child(lbl)


func _add_row(spec: Dictionary) -> void:
	var key: String = String(spec.key)
	var min_v: float = float(spec.min)
	var max_v: float = float(spec.max)
	var step: float = float(spec.step)
	var init_v: float = float(spec.default)
	var setter: Callable = spec.set as Callable

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 12)

	var lbl := Label.new()
	lbl.name = "Label"
	lbl.text = String(spec.label)
	lbl.custom_minimum_size = Vector2(172, 0)
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var sl := HSlider.new()
	sl.name = "Slider"
	sl.min_value = min_v
	sl.max_value = max_v
	sl.step = step
	sl.value = init_v
	sl.custom_minimum_size = Vector2(0, 32)  # выше трек — легче попасть/крутить
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(sl)

	var val := Label.new()
	val.name = "Value"
	val.text = _fmt(init_v, step)
	val.custom_minimum_size = Vector2(88, 0)
	val.add_theme_font_size_override("font_size", 22)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val)

	_vbox.add_child(row)
	_rows[key] = {"slider": sl, "val": val, "default": init_v, "set": setter, "step": step}

	# Применяем дефолт сразу — на случай если константы расходятся с тем, что
	# уже выставлено в материале.
	setter.call(init_v)
	sl.value_changed.connect(
		func(v: float) -> void:
			setter.call(v)
			val.text = _fmt(v, step)
	)


func _add_reset_button() -> void:
	var spacer := Control.new()
	spacer.name = "Spacer"
	spacer.custom_minimum_size = Vector2(0, 12)
	_vbox.add_child(spacer)
	var btn := Button.new()
	btn.name = "Button"
	btn.text = "BTN_RESET"
	UIStyle.style_button(btn, UIColors.WARNING)
	btn.pressed.connect(_on_reset)
	_vbox.add_child(btn)


func _on_reset() -> void:
	for key: String in _rows:
		var r: Dictionary = _rows[key]
		var sl: HSlider = r.slider
		sl.value = r.default  # триггерит value_changed → setter + val.text


func _fmt(v: float, step: float) -> String:
	if step >= 1.0:
		return "%d" % int(round(v))
	return "%.2f" % v


# ── Setters: один на параметр ─────────────────────────────────────────────────


func _post_fx_mat() -> ShaderMaterial:
	var overlay: ColorRect = PostFx.get_node("Overlay") as ColorRect
	return overlay.material as ShaderMaterial


func _sel_mat() -> ShaderMaterial:
	return SelectionIndicator.get_shared_material()


func _set_sepia(v: float) -> void:
	var m := _post_fx_mat()
	if m:
		m.set_shader_parameter("sepia_amount", v)


func _set_ring_r(v: float) -> void:
	_sel_mat().set_shader_parameter("ring_r", v)


func _set_ring_w(v: float) -> void:
	_sel_mat().set_shader_parameter("ring_w", v)


func _set_glow_in(v: float) -> void:
	_sel_mat().set_shader_parameter("glow_inner", v)


func _set_glow_out(v: float) -> void:
	_sel_mat().set_shader_parameter("glow_outer", v)


func _set_glow_str(v: float) -> void:
	_sel_mat().set_shader_parameter("glow_strength", v)


func _set_glow_fall(v: float) -> void:
	_sel_mat().set_shader_parameter("glow_falloff", v)


func _set_off_x(v: float) -> void:
	var off := SelectionIndicator.get_offset()
	SelectionIndicator.set_offset(v, off.y)


func _set_off_y(v: float) -> void:
	var off := SelectionIndicator.get_offset()
	SelectionIndicator.set_offset(off.x, v)


func _set_pulse_speed(v: float) -> void:
	SelectionIndicator.set_pulse(v, SelectionIndicator.get_pulse_amount())


func _set_pulse_amount(v: float) -> void:
	SelectionIndicator.set_pulse(SelectionIndicator.get_pulse_speed(), v)


# ── Веер карт (HandCarousel) ──────────────────────────────────────────────────
# Параметры — static на HandCarousel; здесь только пишем их и просим живой
# инстанс (если он есть на карте) переложиться. Вне карты карусели нет — тогда
# значение просто сохранится в static и применится при следующем открытии.


func _relayout_hand() -> void:
	# Все вееры (рука + чат-композер) — параметры static общие, перекладываем оба.
	get_tree().call_group("hand_carousel", "relayout")


func _set_hand_spread(v: float) -> void:
	HandCarousel.SPREAD = v
	_relayout_hand()


func _set_hand_gap(v: float) -> void:
	HandCarousel.GAP_X = v
	_relayout_hand()


func _set_hand_arc(v: float) -> void:
	HandCarousel.ARC = v
	_relayout_hand()


func _set_hand_lift(v: float) -> void:
	HandCarousel.LIFT = v
	_relayout_hand()


func _set_hand_scale(v: float) -> void:
	HandCarousel.HSCALE = v
	_relayout_hand()


func _set_hand_push(v: float) -> void:
	HandCarousel.PUSH = v
	_relayout_hand()


func _set_hand_pivot(v: float) -> void:
	HandCarousel.PIVOT_Y_FRAC = v
	_relayout_hand()


func _set_hand_below(v: float) -> void:
	HandCarousel.HAND_BELOW = v
	_relayout_hand()


func _set_hand_anim(v: float) -> void:
	HandCarousel.ANIM = v  # применится на следующей перекладке


func _set_hand_sfx_var(v: float) -> void:
	HandCarousel.SCROLL_VARIATIONS = int(round(v))


func _set_hand_sfx_pitch(v: float) -> void:
	HandCarousel.SCROLL_PITCH = v


func _set_arrow_x(v: float) -> void:
	HandCarousel.ARROW_EDGE_X = v
	_relayout_hand()


func _set_arrow_y(v: float) -> void:
	HandCarousel.ARROW_Y_OFF = v
	_relayout_hand()


# ── Туман (home.tscn, узел в группе "fog") ────────────────────────────────────
# Униформы шейдера пишем прямо в материал; частоту/октавы — в FastNoiseLite
# внутри NoiseTexture2D (текстура регенерируется на лету). Вне home-сцены тумана
# нет — сеттеры тогда просто ничего не делают.


func _fog_mat() -> ShaderMaterial:
	var n := get_tree().get_first_node_in_group("fog")
	if n is ColorRect:
		return (n as ColorRect).material as ShaderMaterial
	return null


func _fog_noise() -> FastNoiseLite:
	var m := _fog_mat()
	if m:
		var tex := m.get_shader_parameter("noise_tex") as NoiseTexture2D
		if tex:
			return tex.noise as FastNoiseLite
	return null


func _set_fog_param(param: String, v: float) -> void:
	var m := _fog_mat()
	if m:
		m.set_shader_parameter(param, v)


func _set_fog_speed(v: float) -> void:
	_set_fog_param("speed", v)


func _set_fog_scale(v: float) -> void:
	_set_fog_param("scale", v)


func _set_fog_density(v: float) -> void:
	_set_fog_param("density", v)


func _set_fog_ground(v: float) -> void:
	_set_fog_param("ground", v)


func _set_fog_wisp(v: float) -> void:
	_set_fog_param("wispiness", v)


func _set_fog_period(v: float) -> void:
	_set_fog_param("noise_period", v)


func _set_fog_freq(v: float) -> void:
	var n := _fog_noise()
	if n:
		n.frequency = v


func _set_fog_oct(v: float) -> void:
	var n := _fog_noise()
	if n:
		n.fractal_octaves = int(round(v))


# ── Дым чата (балун сообщения; map_layer в группе "map_layer") ────────────────
# Униформы swirl_* пишем прямо в общий материал балуна. Вне карты map_layer нет —
# сеттеры тогда просто ничего не делают (как у тумана вне home-сцены).


func _chat_smoke_mat() -> ShaderMaterial:
	var n := get_tree().get_first_node_in_group("map_layer")
	if n != null and n.has_method("chat_smoke_material"):
		return n.call("chat_smoke_material") as ShaderMaterial
	return null


func _set_chat_swirl_amp(v: float) -> void:
	var m := _chat_smoke_mat()
	if m:
		m.set_shader_parameter("swirl_amp", v)


func _set_chat_swirl_speed(v: float) -> void:
	var m := _chat_smoke_mat()
	if m:
		m.set_shader_parameter("swirl_speed", v)


# ── Круг знамений (OmensCounter, группа "omens_counter") ──────────────────────
# Радиус/сдвиг маски применяет сам OmensCounter в _process (читает static). Угол/шаг
# требуют переприменения поворота — дёргаем живой узел (вне игры его нет — no-op).


func _omens_reapply() -> void:
	var n := get_tree().get_first_node_in_group("omens_counter")
	if n != null and n.has_method("debug_reapply_angle"):
		n.call("debug_reapply_angle")


func _set_omen_radius(v: float) -> void:
	OmensCounter.MASK_RADIUS = v


func _set_omen_off_x(v: float) -> void:
	OmensCounter.MASK_OFFSET_X = v


func _set_omen_off_y(v: float) -> void:
	OmensCounter.MASK_OFFSET_Y = v


func _set_omen_pos_x(v: float) -> void:
	OmensCounter.POS_OFFSET_X = v  # применяет сам узел в _process


func _set_omen_pos_y(v: float) -> void:
	OmensCounter.POS_OFFSET_Y = v


func _set_omen_dial_x(v: float) -> void:
	OmensCounter.DIAL_OFFSET_X = v  # применяет сам узел в _process


func _set_omen_dial_y(v: float) -> void:
	OmensCounter.DIAL_OFFSET_Y = v


func _set_omen_angle(v: float) -> void:
	OmensCounter.START_ANGLE_DEG = v
	_omens_reapply()


func _set_omen_step(v: float) -> void:
	OmensCounter.STEP_DEG = v
	_omens_reapply()


# ── Стопка жетонов локации (MapLayer.ENTITY_* — static; _process читает их каждый
# кадр, поэтому ребилд не нужен, достаточно присвоить) ─────────────────────────
func _set_ent_size(v: float) -> void:
	MapLayer.ENTITY_SIZE_FRAC = v


func _set_ent_stack_y(v: float) -> void:
	MapLayer.ENTITY_STACK_Y = v


func _set_ent_stack_x0(v: float) -> void:
	MapLayer.ENTITY_STACK_X0 = v


func _set_ent_stack_dx(v: float) -> void:
	MapLayer.ENTITY_STACK_DX = v


func _set_ent_row_gap(v: float) -> void:
	MapLayer.ENTITY_ROW_GAP = v


func _set_ent_row_x0(v: float) -> void:
	MapLayer.ENTITY_ROW_X0 = v


func _set_ent_lerp(v: float) -> void:
	MapLayer.ENTITY_HOVER_LERP = v


# ── Дым карты-сообщения (GameCard.SMOKE_* — static; пушим в живые карты по группе) ──
# Вне открытого веера карт нет — сеттер просто сохранит значение в static (применится
# при следующем построении карт). refresh_smoke() перекладывает static → uniform.


func _refresh_card_smoke() -> void:
	for c in get_tree().get_nodes_in_group("smoke_card"):
		c.call("refresh_smoke")


func _set_csmoke_speed(v: float) -> void:
	GameCard.SMOKE_SPEED = v
	_refresh_card_smoke()


func _set_csmoke_intensity(v: float) -> void:
	GameCard.SMOKE_INTENSITY = v
	_refresh_card_smoke()


func _set_csmoke_scale(v: float) -> void:
	GameCard.SMOKE_SCALE = v
	_refresh_card_smoke()


func _set_csmoke_r(v: float) -> void:
	var c := GameCard.SMOKE_TINT
	c.r = v
	GameCard.SMOKE_TINT = c
	_refresh_card_smoke()


func _set_csmoke_g(v: float) -> void:
	var c := GameCard.SMOKE_TINT
	c.g = v
	GameCard.SMOKE_TINT = c
	_refresh_card_smoke()


func _set_csmoke_b(v: float) -> void:
	var c := GameCard.SMOKE_TINT
	c.b = v
	GameCard.SMOKE_TINT = c
	_refresh_card_smoke()


# ── Магазин · карты ───────────────────────────────────────────────────────────
# Каждый сеттер меняет static var на ShopModal и просит открытый магазин
# перераскладиться (группа "shop_modal" → relayout → _layout_stage).


func _relayout_shop() -> void:
	get_tree().call_group("shop_modal", "relayout")


func _set_shop_cam_x(v: float) -> void:
	ShopModal.CAM_X = v
	_relayout_shop()


func _set_shop_cam_dist(v: float) -> void:
	ShopModal.CAM_DIST = v
	_relayout_shop()


func _set_shop_cam_height(v: float) -> void:
	ShopModal.CAM_HEIGHT = v
	_relayout_shop()


func _set_shop_cam_pitch(v: float) -> void:
	ShopModal.CAM_PITCH = v
	_relayout_shop()


func _set_shop_cam_fov(v: float) -> void:
	ShopModal.CAM_FOV = v
	_relayout_shop()


func _set_shop_card_tilt(v: float) -> void:
	ShopModal.CARD_TILT = v
	_relayout_shop()


func _set_shop_row_gap(v: float) -> void:
	ShopModal.ROW_GAP = v
	_relayout_shop()


func _set_shop_row_y(v: float) -> void:
	ShopModal.ROW_Y = v
	_relayout_shop()


func _set_shop_row_z(v: float) -> void:
	ShopModal.ROW_Z = v
	_relayout_shop()


func _set_shop_hover_up(v: float) -> void:
	ShopModal.HOVER_UP = v
	_relayout_shop()


func _set_shop_hover_fwd(v: float) -> void:
	ShopModal.HOVER_FWD = v
	_relayout_shop()


func _set_shop_hover_scale(v: float) -> void:
	ShopModal.HOVER_SCALE = v
	_relayout_shop()


func _set_shop_ambient(v: float) -> void:
	ShopModal.AMBIENT = v
	_relayout_shop()


func _set_shop_lamp_energy(v: float) -> void:
	ShopModal.LAMP_ENERGY = v
	_relayout_shop()


func _set_shop_lamp_x(v: float) -> void:
	ShopModal.LAMP_X = v
	_relayout_shop()


func _set_shop_lamp_y(v: float) -> void:
	ShopModal.LAMP_Y = v
	_relayout_shop()


func _set_shop_lamp_z(v: float) -> void:
	ShopModal.LAMP_Z = v
	_relayout_shop()


func _set_shop_lamp_r(v: float) -> void:
	ShopModal.LAMP_R = v
	_relayout_shop()


func _set_shop_lamp_g(v: float) -> void:
	ShopModal.LAMP_G = v
	_relayout_shop()


func _set_shop_lamp_b(v: float) -> void:
	ShopModal.LAMP_B = v
	_relayout_shop()


func _set_shop_lamp_range(v: float) -> void:
	ShopModal.LAMP_RANGE = v
	_relayout_shop()


func _set_shop_lamp_atten(v: float) -> void:
	ShopModal.LAMP_ATTEN = v
	_relayout_shop()


func _set_shop_lamp2_energy(v: float) -> void:
	ShopModal.LAMP2_ENERGY = v
	_relayout_shop()


func _set_shop_lamp2_x(v: float) -> void:
	ShopModal.LAMP2_X = v
	_relayout_shop()


func _set_shop_lamp2_y(v: float) -> void:
	ShopModal.LAMP2_Y = v
	_relayout_shop()


func _set_shop_lamp2_z(v: float) -> void:
	ShopModal.LAMP2_Z = v
	_relayout_shop()


func _set_shop_lamp2_r(v: float) -> void:
	ShopModal.LAMP2_R = v
	_relayout_shop()


func _set_shop_lamp2_g(v: float) -> void:
	ShopModal.LAMP2_G = v
	_relayout_shop()


func _set_shop_lamp2_b(v: float) -> void:
	ShopModal.LAMP2_B = v
	_relayout_shop()


func _set_shop_lamp2_range(v: float) -> void:
	ShopModal.LAMP2_RANGE = v
	_relayout_shop()


func _set_shop_lamp2_atten(v: float) -> void:
	ShopModal.LAMP2_ATTEN = v
	_relayout_shop()


func _set_shop_amb_r(v: float) -> void:
	ShopModal.AMBIENT_R = v
	_relayout_shop()


func _set_shop_amb_g(v: float) -> void:
	ShopModal.AMBIENT_G = v
	_relayout_shop()


func _set_shop_amb_b(v: float) -> void:
	ShopModal.AMBIENT_B = v
	_relayout_shop()


func _set_shop_shadow_alpha(v: float) -> void:
	ShopModal.SHADOW_ALPHA = v
	_relayout_shop()


func _set_shop_shadow_scale(v: float) -> void:
	ShopModal.SHADOW_SCALE = v
	_relayout_shop()


func _set_shop_shadow_width(v: float) -> void:
	ShopModal.SHADOW_WIDTH = v
	_relayout_shop()


func _set_shop_shadow_x(v: float) -> void:
	ShopModal.SHADOW_X = v
	_relayout_shop()


func _set_shop_shadow_y(v: float) -> void:
	ShopModal.SHADOW_Y = v
	_relayout_shop()


func _set_shop_shadow_z(v: float) -> void:
	ShopModal.SHADOW_Z = v
	_relayout_shop()


# ── Тень сайдбара локации (LocationSidebar.SHADOW_* — static; живой сайдбар в
# группе "location_sidebar" перерисовывает StyleBox по apply_shadow) ──────────


func _reapply_sidebar_shadow() -> void:
	get_tree().call_group("location_sidebar", "apply_shadow")


func _set_sb_shadow_alpha(v: float) -> void:
	LocationSidebar.SHADOW_ALPHA = v
	_reapply_sidebar_shadow()


func _set_sb_shadow_size(v: float) -> void:
	LocationSidebar.SHADOW_SIZE = v
	_reapply_sidebar_shadow()


func _set_sb_shadow_grow(v: float) -> void:
	LocationSidebar.SHADOW_GROW = v
	_reapply_sidebar_shadow()


func _set_sb_shadow_x(v: float) -> void:
	LocationSidebar.SHADOW_OFFSET_X = v
	_reapply_sidebar_shadow()


func _set_sb_shadow_y(v: float) -> void:
	LocationSidebar.SHADOW_OFFSET_Y = v
	_reapply_sidebar_shadow()


# ── Текст-стенд галереи (GalleryModal.TEXT_* — static; живой инстанс в группе
# "gallery_modal" пересобирает меш/лейбл по apply_text_tuning) ─────────────────


func _reapply_gallery_text() -> void:
	get_tree().call_group("gallery_modal", "apply_text_tuning")


func _set_gal_tl_x(v: float) -> void:
	GalleryModal.TEXT_QUAD_TL = Vector2(v, GalleryModal.TEXT_QUAD_TL.y)
	_reapply_gallery_text()


func _set_gal_tl_y(v: float) -> void:
	GalleryModal.TEXT_QUAD_TL = Vector2(GalleryModal.TEXT_QUAD_TL.x, v)
	_reapply_gallery_text()


func _set_gal_tr_x(v: float) -> void:
	GalleryModal.TEXT_QUAD_TR = Vector2(v, GalleryModal.TEXT_QUAD_TR.y)
	_reapply_gallery_text()


func _set_gal_tr_y(v: float) -> void:
	GalleryModal.TEXT_QUAD_TR = Vector2(GalleryModal.TEXT_QUAD_TR.x, v)
	_reapply_gallery_text()


func _set_gal_br_x(v: float) -> void:
	GalleryModal.TEXT_QUAD_BR = Vector2(v, GalleryModal.TEXT_QUAD_BR.y)
	_reapply_gallery_text()


func _set_gal_br_y(v: float) -> void:
	GalleryModal.TEXT_QUAD_BR = Vector2(GalleryModal.TEXT_QUAD_BR.x, v)
	_reapply_gallery_text()


func _set_gal_bl_x(v: float) -> void:
	GalleryModal.TEXT_QUAD_BL = Vector2(v, GalleryModal.TEXT_QUAD_BL.y)
	_reapply_gallery_text()


func _set_gal_bl_y(v: float) -> void:
	GalleryModal.TEXT_QUAD_BL = Vector2(GalleryModal.TEXT_QUAD_BL.x, v)
	_reapply_gallery_text()


func _set_gal_font(v: float) -> void:
	GalleryModal.TEXT_FONT_SIZE = v
	_reapply_gallery_text()


func _set_gal_mx(v: float) -> void:
	GalleryModal.TEXT_MARGIN = Vector2(v, GalleryModal.TEXT_MARGIN.y)
	_reapply_gallery_text()


# ── Руны Рока (шейдер doom_runes; живой слой ищем по группе) ─────────────────


# Записать uniform в живой слой рун. Слоя нет (мы не в партии) — тихо выходим.
func _runes_set(param: String, value: Variant) -> void:
	for n in get_tree().get_nodes_in_group(DoomRunes.GROUP):
		n.call("set_param", param, value)


func _runes_set_color(comp: int, v: float) -> void:
	for n in get_tree().get_nodes_in_group(DoomRunes.GROUP):
		var c: Variant = n.call("get_param", "tint")
		var col: Color = c if c is Color else Color(0.35, 0.85, 0.55, 1.0)
		col[comp] = v
		n.call("set_param", "tint", col)


func _set_runes_amount(v: float) -> void:
	if _seeding:
		return  # на старте проявленность ведёт трек Рока, а не дефолт слайдера
	# Трогаем слайдер — переводим слой в ручной режим, иначе следующий синк вернёт
	# значение с трека Рока и покрутить не выйдет.
	DoomRunes.MANUAL = true
	DoomRunes.MANUAL_AMOUNT = v
	_runes_set("amount", v)


func _set_runes_grid(v: float) -> void:
	_runes_set("grid", v)


func _set_runes_glyph_scale(v: float) -> void:
	_runes_set("glyph_scale", v)


func _set_runes_reveal_spread(v: float) -> void:
	_runes_set("reveal_spread", v)


func _set_runes_intensity(v: float) -> void:
	_runes_set("intensity", v)


func _set_runes_pulse_speed(v: float) -> void:
	_runes_set("pulse_speed", v)


func _set_runes_pulse_depth(v: float) -> void:
	_runes_set("pulse_depth", v)


func _set_runes_drift(v: float) -> void:
	_runes_set("drift", v)


func _set_runes_edge_bias(v: float) -> void:
	_runes_set("edge_bias", v)


func _set_runes_r(v: float) -> void:
	_runes_set_color(0, v)


func _set_runes_g(v: float) -> void:
	_runes_set_color(1, v)


func _set_runes_b(v: float) -> void:
	_runes_set_color(2, v)


func _set_runes_size_jitter(v: float) -> void:
	_runes_set("size_jitter", v)


func _set_runes_pos_jitter(v: float) -> void:
	_runes_set("pos_jitter", v)


func _set_vig_strength(v: float) -> void:
	if _seeding:
		return  # как и проявленность — на старте ведёт трек Рока
	DoomRunes.MANUAL = true  # иначе следующий синк перебьёт значением с трека
	DoomRunes.MANUAL_VIGNETTE = v
	_runes_set("vig_strength", v)


func _set_vig_start(v: float) -> void:
	_runes_set("vig_start", v)


func _set_vig_softness(v: float) -> void:
	_runes_set("vig_softness", v)


# Цвет виньетки покомпонентно (тот же приём, что у цвета рун).
func _vig_set_color(comp: int, v: float) -> void:
	for n in get_tree().get_nodes_in_group(DoomRunes.GROUP):
		var c: Variant = n.call("get_param", "vig_color")
		var col: Color = c if c is Color else Color(0.0, 0.0, 0.0, 1.0)
		col[comp] = v
		n.call("set_param", "vig_color", col)


func _set_vig_r(v: float) -> void:
	_vig_set_color(0, v)


func _set_vig_g(v: float) -> void:
	_vig_set_color(1, v)


func _set_vig_b(v: float) -> void:
	_vig_set_color(2, v)


# ── Кубы (DiceTray.DIE_GAP — static; пушим в живые лотки по группе) ──────────


func _set_die_bonus_r(v: float) -> void:
	var c: Color = DiceTray.C_MARK_BONUS
	c.r = v
	DiceTray.C_MARK_BONUS = c
	_refresh_dice_marks()


func _set_die_bonus_g(v: float) -> void:
	var c: Color = DiceTray.C_MARK_BONUS
	c.g = v
	DiceTray.C_MARK_BONUS = c
	_refresh_dice_marks()


func _set_die_bonus_b(v: float) -> void:
	var c: Color = DiceTray.C_MARK_BONUS
	c.b = v
	DiceTray.C_MARK_BONUS = c
	_refresh_dice_marks()


func _set_die_blocked_r(v: float) -> void:
	var c: Color = DiceTray.C_MARK_BLOCKED
	c.r = v
	DiceTray.C_MARK_BLOCKED = c
	_refresh_dice_marks()


func _set_die_blocked_g(v: float) -> void:
	var c: Color = DiceTray.C_MARK_BLOCKED
	c.g = v
	DiceTray.C_MARK_BLOCKED = c
	_refresh_dice_marks()


func _set_die_blocked_b(v: float) -> void:
	var c: Color = DiceTray.C_MARK_BLOCKED
	c.b = v
	DiceTray.C_MARK_BLOCKED = c
	_refresh_dice_marks()


# Перекрасить пометки пула в живых лотках (без пересборки).
func _refresh_dice_marks() -> void:
	for t in get_tree().get_nodes_in_group(DiceTray.GAP_GROUP):
		t.call("refresh_marks")


func _set_die_gap(v: float) -> void:
	DiceTray.DIE_GAP = v
	for t in get_tree().get_nodes_in_group(DiceTray.GAP_GROUP):
		t.call("refresh_gap")


func _set_gal_my(v: float) -> void:
	GalleryModal.TEXT_MARGIN = Vector2(GalleryModal.TEXT_MARGIN.x, v)
	_reapply_gallery_text()


# ── Просмотр карты (CardPreview) ──────────────────────────────────────────────
# Слой создаётся по тапу и живёт до закрытия, поэтому правку показываем сразу на
# открытом просмотре; закрыт — значения подхватит следующий.


func _refresh_card_preview() -> void:
	for p in get_tree().get_nodes_in_group(CardPreview.GROUP):
		p.call("refresh_tuning")


func _set_cpv_max_h(v: float) -> void:
	CardPreview.MAX_H = v
	_refresh_card_preview()


func _set_cpv_margin(v: float) -> void:
	CardPreview.MARGIN_V = v
	_refresh_card_preview()


func _set_cpv_backdrop(v: float) -> void:
	CardPreview.BACKDROP_ALPHA = v
	_refresh_card_preview()


# ── Модалки: общий эффект открытия/закрытия ───────────────────────────────────
# Длительности и «выплывание» подхватит следующий переход; затемнение видно сразу
# на всех открытых окнах.


func _set_modal_backdrop(v: float) -> void:
	UIStyle.MODAL_BACKDROP_ALPHA = v
	UIStyle.refresh_backdrops()


func _set_modal_fade_in(v: float) -> void:
	UIStyle.MODAL_FADE_IN = v


func _set_modal_fade_out(v: float) -> void:
	UIStyle.MODAL_FADE_OUT = v


func _set_modal_pop(v: float) -> void:
	UIStyle.MODAL_POP = v


# ── Карта: панорамирование и зум ──────────────────────────────────────────────
# Все значения читаются на месте каждый кадр, поэтому живой карте ничего
# пересылать не нужно — правка действует со следующего же движения.


func _set_map_friction(v: float) -> void:
	WorldMap.INERTIA_FRICTION = v


func _set_map_stop(v: float) -> void:
	WorldMap.INERTIA_MIN_SPEED = v


func _set_map_flick(v: float) -> void:
	WorldMap.FLICK_WINDOW_MS = int(v)


func _set_map_click(v: float) -> void:
	WorldMap.CLICK_THRESHOLD = v


func _set_map_zoom_speed(v: float) -> void:
	WorldMap.ZOOM_SPEED = v


func _set_map_zoom_step(v: float) -> void:
	WorldMap.ZOOM_STEP_REF = v


# ── Карта: тени медальонов и плашек ───────────────────────────────────────────


func _refresh_map_shadows() -> void:
	for m in get_tree().get_nodes_in_group("map_layer"):
		m.call("refresh_shadows")


func _set_shadow_radius(v: float) -> void:
	MapLayer.SHADOW_RADIUS = v
	_refresh_map_shadows()


func _set_shadow_dark(v: float) -> void:
	MapLayer.SHADOW_DARKNESS = v
	_refresh_map_shadows()


func _set_shadow_dy(v: float) -> void:
	MapLayer.SHADOW_OFFSET_Y = v
	_refresh_map_shadows()


func _set_shadow_spread(v: float) -> void:
	MapLayer.SHADOW_SPREAD = v
	_refresh_map_shadows()


# ── Карта: ореол «сейчас ходит» на пине сыщика ────────────────────────────────


func _refresh_turn_glow() -> void:
	for p: Node in get_tree().get_nodes_in_group(InvestigatorPin.GROUP):
		p.call("refresh_glow")


func _set_turn_glow_alpha(v: float) -> void:
	InvestigatorPin.GLOW_ALPHA = v
	_refresh_turn_glow()


func _set_turn_glow_spread(v: float) -> void:
	InvestigatorPin.GLOW_SPREAD = v
	_refresh_turn_glow()


func _set_turn_glow_pulse_speed(v: float) -> void:
	InvestigatorPin.GLOW_PULSE_SPEED = v
	_refresh_turn_glow()


func _set_turn_glow_pulse_amount(v: float) -> void:
	InvestigatorPin.GLOW_PULSE_AMOUNT = v
	_refresh_turn_glow()


# Прозрачность карточки вышедшего игрока. Ореол тут ни при чём, поэтому не
# refresh_glow, а прямое переприменение по текущему connected из состояния.
func _set_pin_away_alpha(v: float) -> void:
	InvestigatorPin.AWAY_ALPHA = v
	for m: Node in get_tree().get_nodes_in_group("map_layer"):
		m.call("refresh_away")
