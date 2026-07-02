extends SceneTree

## Симулятор баланса карт. Monte-Carlo на РЕАЛЬНОЙ математике движка (Dice +
## AssetCatalog/MonsterCatalog/SpellCatalog) — без параллельной реализации, цифры
## не расходятся с игрой. Гоняет карту тысячами бросков против реальных монстров
## по сетке навыков И числу перебросов (фокус/улики), пишет HTML-отчёт + JSON.
##
## Запуск: run_sim.ps1  (или godot --headless -s res://tools/card_sim.gd)
## Отчёт:  <проект>/sim-report/balance.{html,json}
##
## Вертикальный срез на 2 оружиях (improveSkill + addToDie) и Banishment.
## Масштабирование = добавить карты в _sim_*; механика (пул/успехи/перебросы/
## резист/стойкость) уже общая и точная.

const ITERS := 20000
const OUT_DIR := "res://sim-report"
const STRENGTHS := [2, 3, 4]  # профили сыщика по Силе
const LORES := [2, 3, 4]  # профили по Знанию (заклинания)
const MONSTERS := ["zombie", "deep_one", "gug"]  # растущая стойкость 2/2/4
const REROLLS := [0, 1, 2]  # доступно перебросов (фокус/улики)


func _initialize() -> void:
	seed(12345)  # фикс-сид → отчёт воспроизводим (диффабелен в CI)
	var weapons: Array = []
	var spells: Array = []
	_sim_weapons(weapons)
	_sim_banishment(spells)
	_write_json(weapons, spells)
	_write_html(weapons, spells)
	_console(weapons, spells)
	quit()


# ── Ядро проверки с перебросами (математика CheckFlow) ────────────────────────
# Пул = навык + внешний_мод (монстр/заклинание) + пре-бросковые моды карты
# (improveSkill/rollAdditionalDice). После броска — addToDie/convertDie. Перебросы:
# рероллим провальный куб (<5), стремясь к target, пока есть перебросы и провалы.
func _roll(
	base_skill: int, external_mod: int, mods: Array, skill: String, target: int, rerolls: int
) -> int:
	var pool: int = maxi(1, base_skill + external_mod + Dice.pre_roll_bonus(mods, skill))
	var base: Array = Dice.roll(pool)
	var s: int = _count(base, mods, skill)
	var left: int = rerolls
	while s < target and left > 0:
		var idx: int = _first_failing(base)
		if idx < 0:
			break  # провальных кубов нет — рероллить нечего
		base[idx] = Dice.roll_one()
		left -= 1
		s = _count(base, mods, skill)  # addToDie re-применяется идемпотентно
	return s


func _count(base: Array, mods: Array, skill: String) -> int:
	var modded: Array = Dice.apply_add_to_die(base, mods, skill)
	return Dice.count_successes_with(modded, mods, skill)


func _first_failing(dice: Array) -> int:
	for i in range(dice.size()):
		if int(dice[i]) < Dice.SUCCESS_MIN:
			return i
	return -1


# ── Оружие в бою ──────────────────────────────────────────────────────────────
func _sim_weapons(rows: Array) -> void:
	for wid: String in ["45_automatic", "18_derringer"]:
		var asset: Dictionary = AssetCatalog.by_id(wid)
		var mods: Array = AssetCatalog.passive_check_mods(asset, "combatEncounter")
		for strength: int in STRENGTHS:
			for mon_id: String in MONSTERS:
				var m: Dictionary = MonsterCatalog.by_id(mon_id)
				var cb: Dictionary = m.get("combat", {})
				var mon_mod: int = int(cb.get("modifier", 0))
				var tough: int = int(m.get("toughness", 1))
				var p: Dictionary = {}
				for rr: int in REROLLS:
					p[rr] = _combat_win_rate(strength, mon_mod, mods, m, tough, rr)
				var base_p: float = _combat_win_rate(strength, mon_mod, [], m, tough, 0)
				var hp: float = _combat_avg_hp(strength, mon_mod, mods, m, tough, 1)
				(
					rows
					. append(
						{
							"card": wid,
							"skill": "Сила %d" % strength,
							"target": "%s (стойк. %d, бой%+d)" % [mon_id, tough, mon_mod],
							"base": base_p,
							"p": p,
							"hp": hp,
							"flag": _flag(float(p[0]), float(p[REROLLS[-1]])),
						}
					)
				)


func _combat_win_rate(
	strength: int, mon_mod: int, mods: Array, m: Dictionary, tough: int, rr: int
) -> float:
	var wins: int = 0
	for _i in ITERS:
		var hits: int = _roll(strength, mon_mod, mods, "strength", tough, rr)
		var dealt: int = MonsterCatalog.apply_resistance(m, hits, "physical")
		if dealt >= tough:  # health_after = tough − dealt ≤ 0 → повержен
			wins += 1
	return float(wins) / ITERS


func _combat_avg_hp(
	strength: int, mon_mod: int, mods: Array, m: Dictionary, tough: int, rr: int
) -> float:
	var dmg: int = int((m.get("combat", {}) as Dictionary).get("damage", 0))
	var sum_hp: int = 0
	for _i in ITERS:
		var hits: int = _roll(strength, mon_mod, mods, "strength", tough, rr)
		sum_hp += maxi(0, dmg - hits)  # урон по сыщику = combat.damage − успехи
	return float(sum_hp) / ITERS


# ── Заклинание Banishment (Lore-каст, defeatMonster maxToughness=testResult) ───
func _sim_banishment(rows: Array) -> void:
	var spell: Dictionary = SpellCatalog.by_id("banishment")
	var modifier: int = int((spell.get("front", {}) as Dictionary).get("modifier", 0))  # -1
	for lore: int in LORES:
		for mon_id: String in MONSTERS:
			var tough: int = int(MonsterCatalog.by_id(mon_id).get("toughness", 1))
			var need: int = maxi(1, tough - 1)  # reach = успехи+1 ≥ стойк. → успехи ≥ стойк−1
			var p_cast: Dictionary = {}
			var p_win: Dictionary = {}
			for rr: int in REROLLS:
				var casts: int = 0
				var wins: int = 0
				for _i in ITERS:
					var s: int = _roll(lore, modifier, [], "lore", need, rr)
					if s >= Dice.PASS_MIN:
						casts += 1
					if s >= Dice.PASS_MIN and s >= tough - 1:
						wins += 1
				p_cast[rr] = float(casts) / ITERS
				p_win[rr] = float(wins) / ITERS
			(
				rows
				. append(
					{
						"card": "banishment",
						"skill": "Знание %d" % lore,
						"target": "%s (стойк. %d)" % [mon_id, tough],
						"p_cast": p_cast,
						"p": p_win,
						"flag": _flag(float(p_win[0]), float(p_win[REROLLS[-1]])),
					}
				)
			)


# Флаг выброса: даже с максимумом перебросов почти не проходит → «слабо»;
# тривиально проходит без единого переброса → «имба». Обе крайности — «проверь тюнинг».
func _flag(p_min_rerolls: float, p_max_rerolls: float) -> String:
	if p_max_rerolls < 0.15:
		return "слабо"
	if p_min_rerolls > 0.85:
		return "имба"
	return ""


# ── Отчёты ────────────────────────────────────────────────────────────────────
func _write_json(weapons: Array, spells: Array) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var f: FileAccess = FileAccess.open(OUT_DIR + "/balance.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"iters": ITERS, "weapons": weapons, "spells": spells}, "  "))
	f.close()


func _write_html(weapons: Array, spells: Array) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var h: Array = []
	h.append(_HTML_HEAD)
	h.append("<h1>⚔ Баланс карт</h1>")
	h.append(
		(
			(
				"<div class='sub'>%d бросков на ячейку · фикс-сид · перебросы = фокус/улики · "
				+ "порог 5 · БЕЗ рероллов на грани addToDie (аппроксимация)</div>"
			)
			% ITERS
		)
	)

	# Оружие
	h.append("<h2>Оружие · P(победа над монстром)</h2>")
	h.append("<table><tr><th>Карта</th><th>Навык</th><th>Цель</th><th>без карты</th>")
	for rr: int in REROLLS:
		h.append("<th>%d фокуса</th>" % rr)
	h.append("<th>~урон (1 фокус)</th><th>флаг</th></tr>")
	for r_v: Variant in weapons:
		var r: Dictionary = r_v
		h.append("<tr>")
		h.append(
			"<td class='card'>%s</td><td>%s</td><td>%s</td>" % [r["card"], r["skill"], r["target"]]
		)
		h.append("<td class='muted'>%s</td>" % _pct(r["base"]))
		for rr2: int in REROLLS:
			h.append(_prob_td(float((r["p"] as Dictionary)[rr2])))
		h.append("<td class='muted'>%.2f</td>" % r["hp"])
		h.append(_flag_td(String(r["flag"])))
		h.append("</tr>")
	h.append("</table>")

	# Заклинания
	h.append("<h2>Заклинания · P(каст) / P(победа)</h2>")
	h.append("<table><tr><th>Карта</th><th>Навык</th><th>Цель</th>")
	for rr3: int in REROLLS:
		h.append("<th>каст@%d</th><th>побед@%d</th>" % [rr3, rr3])
	h.append("<th>флаг</th></tr>")
	for s_v: Variant in spells:
		var s: Dictionary = s_v
		h.append("<tr>")
		h.append(
			"<td class='card'>%s</td><td>%s</td><td>%s</td>" % [s["card"], s["skill"], s["target"]]
		)
		for rr4: int in REROLLS:
			h.append("<td class='muted'>%s</td>" % _pct(float((s["p_cast"] as Dictionary)[rr4])))
			h.append(_prob_td(float((s["p"] as Dictionary)[rr4])))
		h.append(_flag_td(String(s["flag"])))
		h.append("</tr>")
	h.append("</table>")
	h.append("</body></html>")

	var f: FileAccess = FileAccess.open(OUT_DIR + "/balance.html", FileAccess.WRITE)
	f.store_string("\n".join(h))
	f.close()


func _console(weapons: Array, spells: Array) -> void:
	print("\n=== Card balance (%d бросков/ячейку) ===" % ITERS)
	for r_v: Variant in weapons:
		var r: Dictionary = r_v
		print(
			(
				"%-13s %-8s vs %-26s  P(побед) 0/1/2 фокуса = %s / %s / %s  %s"
				% [
					r["card"],
					r["skill"],
					r["target"],
					_pct((r["p"] as Dictionary)[0]),
					_pct((r["p"] as Dictionary)[1]),
					_pct((r["p"] as Dictionary)[2]),
					("[%s]" % r["flag"]) if r["flag"] != "" else "",
				]
			)
		)
	for s_v: Variant in spells:
		var s: Dictionary = s_v
		print(
			(
				"%-13s %-10s vs %-22s  P(побед) 0/1/2 = %s / %s / %s  %s"
				% [
					s["card"],
					s["skill"],
					s["target"],
					_pct((s["p"] as Dictionary)[0]),
					_pct((s["p"] as Dictionary)[1]),
					_pct((s["p"] as Dictionary)[2]),
					("[%s]" % s["flag"]) if s["flag"] != "" else "",
				]
			)
		)
	print("\nОтчёт: %s/balance.html" % ProjectSettings.globalize_path(OUT_DIR))


# ── HTML-хелперы ──────────────────────────────────────────────────────────────
func _pct(v: Variant) -> String:
	return "%.1f%%" % (float(v) * 100.0)


# Ячейка вероятности с цветом текста по градиенту red→green.
func _prob_td(p: float) -> String:
	var color: String = "#cc3a2e"  # <15% красный
	if p >= 0.65:
		color = "#4db870"  # ≥65% зелёный
	elif p >= 0.40:
		color = "#c7a84a"  # ≥40% жёлтый
	elif p >= 0.15:
		color = "#c77a2e"  # ≥15% оранжевый
	return "<td style='color:%s;font-weight:bold'>%s</td>" % [color, _pct(p)]


func _flag_td(flag: String) -> String:
	if flag == "слабо":
		return "<td class='flag weak'>слабо</td>"
	if flag == "имба":
		return "<td class='flag op'>имба</td>"
	return "<td></td>"


const _HTML_HEAD := """<!DOCTYPE html><html lang='ru'><head><meta charset='utf-8'>
<title>Баланс карт — Dark Omens</title><style>
body{background:#0d0b18;color:#d4cfc0;font-family:monospace;font-size:13px;padding:24px}
h1{color:#c7a84a;font-size:22px;margin-bottom:4px}
h2{color:#8a7050;font-size:13px;text-transform:uppercase;letter-spacing:1px;margin:24px 0 8px}
.sub{color:#7a7060;font-size:11px;margin-bottom:8px}
table{border-collapse:collapse;width:100%;margin-bottom:8px}
th{text-align:left;color:#7a7060;font-weight:normal;padding:6px 10px;border-bottom:1px solid #3d2e10}
td{padding:5px 10px;border-bottom:1px solid #1a1525}
tr:hover td{background:#14111f}
.card{color:#c7a84a}
.muted{color:#7a7060}
.flag{font-weight:bold;text-align:center}
.flag.weak{color:#cc3a2e}
.flag.op{color:#b06fd4}
</style></head><body>"""
