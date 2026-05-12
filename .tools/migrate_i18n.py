"""Одноразовая миграция: русские литералы UI → UPPERCASE translation keys."""
import csv, re
from pathlib import Path

# (russian_literal, KEY, english_translation)
MAPPING = [
    ("Пас",                                          "BTN_PASS",                     "Pass"),
    ("Код:",                                         "FORM_CODE",                    "Code:"),
    ("ВОЙТИ",                                        "BTN_LOG_IN",                   "LOG IN"),
    ("Выйти",                                        "MENU_QUIT",                    "Quit"),
    ("Язык:",                                        "FORM_LANGUAGE",                "Language:"),
    ("ОТМЕНА",                                       "BTN_CANCEL_BIG",               "CANCEL"),
    ("СЕРВЕР",                                       "SECTION_SERVER",               "SERVER"),
    ("  ГОТОВ",                                      "LOBBY_BTN_READY",              "  READY"),
    ("  ПАУЗА",                                      "PAUSE_TITLE",                  "  PAUSED"),
    ("Ваш ход",                                      "ACTION_YOUR_TURN",             "Your turn"),
    ("Ведущий",                                      "LOBBY_TAG_HOST",               "Host"),
    ("Готов ✓",                                 "LOBBY_TAG_READY",              "Ready ✓"),
    ("ДИСПЛЕЙ",                                      "SECTION_DISPLAY",              "DISPLAY"),
    ("Пароль:",                                      "FORM_PASSWORD",                "Password:"),
    ("СОЗДАТЬ",                                      "BTN_CREATE_BIG",               "CREATE"),
    ("\U0001f3ab Билет",                             "ACTION_TICKET",                "\U0001f3ab Ticket"),
    ("\U0001f4a4 Отдых",                             "ACTION_REST",                  "\U0001f4a4 Rest"),
    ("РАССУДОК",                                     "INV_PANEL_SANITY",             "SANITY"),
    ("Сбросить",                                     "BTN_RESET",                    "Reset"),
    ("  ВСТРЕЧА",                                    "ACTION_ENCOUNTER_BTN",         "  ENCOUNTER"),
    ("ЗАВЕРШИТЬ",                                    "BTN_FINISH_BIG",               "FINISH"),
    ("Название:",                                    "FORM_NAME",                    "Name:"),
    ("СОХРАНИТЬ",                                    "BTN_SAVE_BIG",                 "SAVE"),
    ("  ГОТОВ  ✓",                              "LOBBY_BTN_READY_DONE",         "  READY  ✓"),
    ("  ПОКИНУТЬ",                                   "LOBBY_BTN_LEAVE",              "  LEAVE"),
    ("Ожидает...",                                   "LOBBY_TAG_WAITING",            "Waiting..."),
    ("  НАСТРОЙКИ",                                  "MENU_BTN_SETTINGS",            "  SETTINGS"),
    ("Моя игра...",                                  "MENU_GAME_NAME_PLACEHOLDER",   "My game..."),
    ("Разрешение:",                                  "FORM_RESOLUTION",              "Resolution:"),
    ("Полный экран",                                 "SETTINGS_FULLSCREEN",          "Fullscreen"),
    ("  НАЧАТЬ ИГРУ",                                "LOBBY_BTN_START_GAME",         "  START GAME"),
    ("ОТПРАВИТЬ КОД",                                "LOGIN_BTN_SEND_CODE",          "SEND CODE"),
    ("⚙   НАСТРОЙКИ",                           "PAUSE_BTN_SETTINGS",           "⚙   SETTINGS"),
    ("ИГРОКИ В ЛОББИ",                               "LOBBY_PLAYERS_HEADER",         "PLAYERS IN LOBBY"),
    ("Подключение...",                               "STATUS_CONNECTING",            "Connecting..."),
    ("▶   ПРОДОЛЖИТЬ",                          "PAUSE_BTN_RESUME",             "▶   CONTINUE"),
    ("✦ Концентрация",                          "ACTION_FOCUS",                 "✦ Focus"),
    ("(необязательно)",
                                                     "FORM_OPTIONAL",                "(optional)"),
    ("ВОЙТИ В КОМНАТУ",                              "MENU_BTN_JOIN_ROOM",           "JOIN ROOM"),
    ("ВЫБЕРИТЕ СЫЩИКА",                              "LOBBY_PICK_HEADER",            "SELECT INVESTIGATOR"),
    ("ТЁМНЫЕ ЗНАМЕНИЯ",                              "APP_TITLE",                    "DARK OMENS"),
    ("(если требуется)",                             "FORM_IF_REQUIRED",             "(if required)"),
    ("СОСЕДНИЕ ЛОКАЦИИ",                             "SIDEBAR_NEIGHBORS",            "Neighboring Locations"),
    ("← Изменить email",                        "LOGIN_LINK_CHANGE_EMAIL",      "← Change email"),
    ("⌂   ГЛАВНОЕ МЕНЮ",                        "PAUSE_BTN_MAIN_MENU",          "⌂   MAIN MENU"),
    ("  ЗАКРЫТЬ КОМНАТУ",                            "LOBBY_BTN_CLOSE_ROOM",         "  CLOSE ROOM"),
    ("  СОЗДАТЬ КОМНАТУ",                            "MENU_BTN_CREATE_ROOM",         "  CREATE ROOM"),
    ("✕   ВЫЙТИ ИЗ ИГРЫ",                       "PAUSE_BTN_QUIT_GAME",          "✕   QUIT GAME"),
    ("  ОТКРЫТЫЕ КОМНАТЫ",                           "MENU_OPEN_ROOMS_HEADER",       "  OPEN ROOMS"),
    ("Проверка сессии...",                           "LOGIN_STATUS_CHECKING",        "Checking session..."),
    ("Нет активных комнат",                          "MENU_STATUS_NO_ROOMS",         "No active rooms"),
    ("  ВХОД / РЕГИСТРАЦИЯ",                         "LOGIN_HEADER_AUTH",            "  LOGIN / REGISTER"),
    ("Код отправлен на ...",                         "LOGIN_CODE_SENT_PREFIX",       "Code sent to ..."),
    ("Эффект старой плёнки",                         "SETTINGS_FX_OLD_FILM",         "Old film effect"),
    ("Выберите своего сыщика",                       "LOBBY_STATUS_PICK",            "Select your investigator"),
    ("  ВВЕДИТЕ КОД ИЗ ПИСЬМА",                      "LOGIN_HEADER_CODE",            "  ENTER CODE FROM EMAIL"),
    ("Ожидайте решения ведущего",                    "LOBBY_STATUS_WAIT_HOST",       "Wait for the host's decision"),
    ("ИГРОВОЙ ЛОГ  ·  ~ чтобы закрыть",         "CONSOLE_HEADER",               "GAME LOG  ·  ~ to close"),
    ("Войдите через email — пароль не нужен",   "LOGIN_HINT",                   "Sign in with email — no password needed"),
    ("Нажмите «Готов», затем можно начинать",
                                                     "LOBBY_HINT_HOST",
                                                     "Press «Ready», then you can start"),
    ("Выберите сыщика, затем нажмите «Готов»",
                                                     "LOBBY_HINT_PICK_THEN_READY",
                                                     "Pick an investigator, then press «Ready»"),
    ("Нажмите «Готов», чтобы подтвердить выбор",
                                                     "LOBBY_HINT_READY_TO_CONFIRM",
                                                     "Press «Ready» to confirm your choice"),
    ("по мотивам настольной игры «Древний Ужас»",
                                                     "APP_SUBTITLE",
                                                     "based on the Eldritch Horror board game"),
    ("У вас встреча на этой локации.\\n\\n(Заглушка — содержание встреч добавим позже.)",
                                                     "ENCOUNTER_STUB",
                                                     "You have an encounter at this location.\\n\\n(Stub — encounter content to be added later.)"),
]


def main():
    csv_path = Path("assets/i18n/translations.csv")

    # ── CSV: добавляем новые ключи ───────────────────────────────────────────
    existing = set()
    for row in csv.reader(csv_path.read_text(encoding="utf-8").splitlines()):
        if row and row[0].strip() and row[0] != "keys":
            existing.add(row[0])
    new_rows = [(k, ru, en) for ru, k, en in MAPPING if k not in existing]
    print(f"CSV: добавляю {len(new_rows)} новых, пропускаю {len(MAPPING) - len(new_rows)} существующих")
    with open(csv_path, "a", encoding="utf-8", newline="") as f:
        w = csv.writer(f, quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
        if new_rows:
            w.writerow([])
        for k, ru, en in new_rows:
            w.writerow([k, ru, en])

    ru_to_key = {ru: k for ru, k, _ in MAPPING}

    # ── tscn: text = "..." / placeholder_text / tooltip_text ─────────────────
    tscn_count = 0
    for p in Path("scenes").rglob("*.tscn"):
        s = p.read_text(encoding="utf-8")
        orig = s
        for ru, key in ru_to_key.items():
            for prop in ("text", "placeholder_text", "tooltip_text"):
                pat = f'{prop} = "{ru}"'
                if pat in s:
                    s = s.replace(pat, f'{prop} = "{key}"')
                    tscn_count += 1
        if s != orig:
            p.write_text(s, encoding="utf-8")
    print(f"tscn: {tscn_count} замен")

    # ── gd: .text = "...", UIStyle.button("...", ...), UIStyle.modal(.., "...", ..) ──
    patterns = [
        re.compile(r'(\.text\s*=\s*)"([^"]+)"'),
        re.compile(r'(UIStyle\.button\(\s*)"([^"]+)"'),
        re.compile(r'(UIStyle\.modal\([^,]+,\s*)"([^"]+)"'),
        re.compile(r'(_show_status\(\s*)"([^"]+)"'),
    ]
    gd_count = 0
    for p in Path("scripts").rglob("*.gd"):
        s = p.read_text(encoding="utf-8")
        orig = s
        for pat in patterns:
            def repl(m, cnt=[gd_count]):
                lit = m.group(2)
                if lit in ru_to_key:
                    return f'{m.group(1)}"{ru_to_key[lit]}"'
                return m.group(0)
            new_s = pat.sub(repl, s)
            # подсчитаем разницу: количество замещённых литералов
            cnt = sum(1 for m in pat.finditer(s) if m.group(2) in ru_to_key)
            gd_count += cnt
            s = new_s
        if s != orig:
            p.write_text(s, encoding="utf-8")
    print(f"gd: {gd_count} замен")


if __name__ == "__main__":
    main()
