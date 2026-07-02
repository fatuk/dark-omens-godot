extends SceneTree

## Прототип симулятора баланса карт. Monte-Carlo на РЕАЛЬНОЙ математике движка
## (Dice + AssetCatalog/MonsterCatalog/SpellCatalog) — без параллельной реализации,
## поэтому цифры не расходятся с игрой. Гоняет карту тысячами бросков против
## реальных монстров по сетке навыков и пишет отчёт (JSON + CSV).
##
## Запуск: godot --headless -s res://tools/card_sim.gd   (или run_sim.ps1)
## Отчёт:  <проект>/sim-report/balance.{json,csv}
##
## Это вертикальный срез на 2 оружиях (improveSkill + addToDie) и Banishment.
## Масштабирование = добавить карты в _run(); механика (пул/успехи/резист/стойкость)
## уже общая и точная.

const ITERS := 20000
const OUT_DIR := "res://sim-report"
const STRENGTHS := [2, 3, 4]  # профили сыщика по Силе
const LORES := [2, 3, 4]  # профили по Знанию (заклинания)
const MONSTERS := ["zombie", "deep_one", "gug"]  # растущая стойкость 2/2/4


func _initialize() -> void:
	seed(12345)  # фикс-сид → отчёт воспроизводим (диффабелен в CI)
	var rows: Array = []
	_sim_weapons(rows)
	_sim_banishment(rows)
	_write_report(rows)
	quit()


# ── Ядро проверки (та же математика, что CheckFlow) ───────────────────────────
# Один бросок: пул = навык + внешний_мод (монстр/заклинание) + пре-бросковые моды
# карты (improveSkill/rollAdditionalDice); затем addToDie/convertDie на результат.
# Перебросы за концентрацию/улики НЕ моделируем (базовый расклад) — отмечено в отчёте.
func _check_successes(base_skill: int, external_mod: int, mods: Array, skill: String) -> int:
	var pool: int = maxi(1, base_skill + external_mod + Dice.pre_roll_bonus(mods, skill))
	var dice: Array = Dice.roll(pool)
	# Порог по умолчанию 5 (нейтрально). Blessed/Cursed — отдельный профиль на будущее.
	return int(Dice.result_with(dice, mods, skill).get("successes", 0))


# ── Оружие в бою ──────────────────────────────────────────────────────────────
func _sim_weapons(rows: Array) -> void:
	for wid: String in ["45_automatic", "18_derringer"]:
		var asset: Dictionary = AssetCatalog.by_id(wid)
		# whileOwned-ауры оружия на шаг Силы боя (improveSkill / addToDie).
		var mods: Array = AssetCatalog.passive_check_mods(asset, "combatEncounter")
		for strength: int in STRENGTHS:
			for mon_id: String in MONSTERS:
				var m: Dictionary = MonsterCatalog.by_id(mon_id)
				var cb: Dictionary = m.get("combat", {})
				var mon_mod: int = int(cb.get("modifier", 0))
				var tough: int = int(m.get("toughness", 1))
				var with_w: Dictionary = _combat_stats(strength, mon_mod, mods, m, tough)
				var base: Dictionary = _combat_stats(strength, mon_mod, [], m, tough)
				(
					rows
					. append(
						{
							"card": wid,
							"kind": "weapon",
							"skill": "Сила %d" % strength,
							"target": "%s (стойк. %d, бой%+d)" % [mon_id, tough, mon_mod],
							"p_win": with_w["p_win"],
							"p_win_base": base["p_win"],
							"lift": with_w["p_win"] - base["p_win"],
							"avg_hits": with_w["avg_hits"],
							"avg_hp_loss": with_w["avg_hp_loss"],
						}
					)
				)


func _combat_stats(
	strength: int, mon_mod: int, mods: Array, m: Dictionary, tough: int
) -> Dictionary:
	var dmg: int = int((m.get("combat", {}) as Dictionary).get("damage", 0))
	var wins: int = 0
	var sum_hits: int = 0
	var sum_hp: int = 0
	for _i in ITERS:
		var hits: int = _check_successes(strength, mon_mod, mods, "strength")
		var dealt: int = MonsterCatalog.apply_resistance(m, hits, "physical")
		if dealt >= tough:  # health_after = tough − dealt ≤ 0 → монстр повержен
			wins += 1
		sum_hits += hits
		sum_hp += maxi(0, dmg - hits)  # урон по сыщику = combat.damage − успехи
	return {
		"p_win": float(wins) / ITERS,
		"avg_hits": float(sum_hits) / ITERS,
		"avg_hp_loss": float(sum_hp) / ITERS,
	}


# ── Заклинание Banishment (Lore-каст, defeatMonster maxToughness=testResult) ───
func _sim_banishment(rows: Array) -> void:
	var spell: Dictionary = SpellCatalog.by_id("banishment")
	var front: Dictionary = spell.get("front", {})
	var modifier: int = int(front.get("modifier", 0))  # -1
	for lore: int in LORES:
		for mon_id: String in MONSTERS:
			var tough: int = int(MonsterCatalog.by_id(mon_id).get("toughness", 1))
			var casts: int = 0
			var defeats: int = 0
			for _i in ITERS:
				var s: int = _check_successes(lore, modifier, [], "lore")
				if s < Dice.PASS_MIN:
					continue  # каст провалился (успехов < 1)
				casts += 1
				var reach: int = s + 1  # onPass addSuccesses +1 → maxToughness = успехи+1
				if reach >= tough:
					defeats += 1
			(
				rows
				. append(
					{
						"card": "banishment",
						"kind": "spell",
						"skill": "Знание %d" % lore,
						"target": "%s (стойк. %d)" % [mon_id, tough],
						"p_cast": float(casts) / ITERS,
						"p_win": float(defeats) / ITERS,
					}
				)
			)


# ── Отчёт ─────────────────────────────────────────────────────────────────────
func _write_report(rows: Array) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# JSON — машиночитаемый, полный.
	var jf: FileAccess = FileAccess.open(OUT_DIR + "/balance.json", FileAccess.WRITE)
	jf.store_string(JSON.stringify({"iters": ITERS, "rows": rows}, "  "))
	jf.close()

	# CSV — для Excel/дифа. Колонки — объединение ключей всех строк.
	var cols: Array = [
		"card",
		"kind",
		"skill",
		"target",
		"p_win",
		"p_win_base",
		"lift",
		"p_cast",
		"avg_hits",
		"avg_hp_loss"
	]
	var cf: FileAccess = FileAccess.open(OUT_DIR + "/balance.csv", FileAccess.WRITE)
	cf.store_line(",".join(cols))
	for r_v: Variant in rows:
		var r: Dictionary = r_v
		var cells: Array = []
		for c: String in cols:
			cells.append(_csv_cell(_fmt(r.get(c, ""))))
		cf.store_line(",".join(cells))
	cf.close()

	# Консоль — быстрый обзор.
	print("\n=== Card balance (%d итераций/строку) ===" % ITERS)
	for r_v2: Variant in rows:
		var r2: Dictionary = r_v2
		if r2["kind"] == "weapon":
			print(
				(
					"%-13s %-8s vs %-26s  P(побед)=%s  (без карты %s, +%s)  урон−%s"
					% [
						r2["card"],
						r2["skill"],
						r2["target"],
						_pct(r2["p_win"]),
						_pct(r2["p_win_base"]),
						_pct(r2["lift"]),
						_fmt(r2["avg_hp_loss"])
					]
				)
			)
		else:
			print(
				(
					"%-13s %-10s vs %-22s  P(каст)=%s  P(побед)=%s"
					% [r2["card"], r2["skill"], r2["target"], _pct(r2["p_cast"]), _pct(r2["p_win"])]
				)
			)
	print("\nОтчёт: %s/balance.{json,csv}" % ProjectSettings.globalize_path(OUT_DIR))


func _fmt(v: Variant) -> String:
	if v is float:
		return "%.3f" % v
	return str(v)


# Квотирование ячейки CSV (RFC 4180): если внутри запятая/кавычка/перевод строки —
# оборачиваем в кавычки, внутренние кавычки удваиваем.
func _csv_cell(s: String) -> String:
	if s.contains(",") or s.contains('"') or s.contains("\n"):
		return '"%s"' % s.replace('"', '""')
	return s


func _pct(v: Variant) -> String:
	return "%5.1f%%" % (float(v) * 100.0)
