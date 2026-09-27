# Качалка листов карт из сохранения Tabletop Simulator (референсы Eldritch Horror).
#
#   make            — скачать все листы (make -j8 -k: параллельно, не останавливаться на ошибке)
#   make manifest   — только пересобрать targets.mk + manifest.csv
#   make clean      — удалить скачанное и сгенерированное
#
# Переменные (переопределяются из корневого Makefile или руками):
#   JSON  — сохранение TTS (по умолчанию — воркшоп-мод из папки TTS)
#   OUT   — куда складывать (по умолчанию EH_decks рядом)
#   CACHE — кэш картинок TTS: если URL умер, лист берётся оттуда
#
# Рецепты написаны под sh/curl/stat; на Windows корневой Makefile уводит их в Git Bash.

# Домашняя папка: из PowerShell HOME может быть не задан или чужой — берём USERPROFILE.
HOME_DIR := $(subst \,/,$(or $(USERPROFILE),$(HOME)))
TTS_DIR ?= $(HOME_DIR)/Documents/My Games/Tabletop Simulator
TTS_MOD ?= 2066860469
JSON    ?= $(TTS_DIR)/Mods/Workshop/$(TTS_MOD).json
OUT     ?= EH_decks
CACHE   ?= $(TTS_DIR)/Mods/Images
PY      ?= python
UA      := Mozilla/5.0 (Windows NT 10.0; Win64; x64)
MIN_BYTES := 5000   # меньше — заглушка imgur «removed» или HTML-страница

.DELETE_ON_ERROR:
.PHONY: all manifest download clean

all: targets.mk
	@$(MAKE) --no-print-directory download

# Второй проход: targets.mk уже есть, include подхватывает IMAGES и per-target URL/CACHE_NAMES.
-include targets.mk

download: $(IMAGES)
	@echo "Готово: $(words $(IMAGES)) файлов в $(OUT), манифест в manifest.csv"
	@if [ -s failed.txt ]; then echo "Не скачались (см. failed.txt): $$(wc -l < failed.txt)"; fi

# Путь к JSON бывает с пробелами («My Games») — пререквизитом его не сделать: make режет
# список по пробелам. Поэтому targets.mk пересобирается по явному `make manifest` или
# когда его ещё нет; JSON проверяем внутри рецепта.
targets.mk manifest.csv: gen_targets.py
	@test -f "$(JSON)" || { echo "нет сохранения TTS: $(JSON)"; exit 1; }
	@rm -f failed.txt
	$(PY) gen_targets.py "$(JSON)" "$(OUT)"

manifest:
	@rm -f targets.mk manifest.csv
	@$(MAKE) --no-print-directory targets.mk

# Скачать лист. Порядок: прямой URL → для Google Drive повтор с confirm=t (большие файлы
# отдают страницу подтверждения) → кэш TTS под любым из возможных имён → в failed.txt.
# Успех = файл больше MIN_BYTES и не начинается с '<' (HTML).
$(IMAGES):
	@mkdir -p "$(@D)"
	@ok=0; \
	fetch() { curl -fsSL -A "$(UA)" --max-time 90 -o "$@" "$$1" \
	   && [ "$$(stat -c%s "$@" 2>/dev/null || stat -f%z "$@")" -gt $(MIN_BYTES) ] \
	   && ! head -c4 "$@" | grep -qi '<'; }; \
	if fetch "$(URL)"; then ok=1; \
	elif echo "$(URL)" | grep -q 'drive.google.com' && fetch "$(URL)&confirm=t"; then ok=1; \
	else \
	  for c in $(CACHE_NAMES); do \
	    if [ -f "$(CACHE)/$$c" ]; then cp "$(CACHE)/$$c" "$@"; echo "[CACHE] $@"; ok=2; break; fi; \
	  done; \
	fi; \
	if [ "$$ok" = 1 ]; then echo "[OK]    $@"; \
	elif [ "$$ok" = 0 ]; then rm -f "$@"; echo "$@  <-  $(URL)" >> failed.txt; echo "[FAIL]  $@  <-  $(URL)"; exit 1; fi

clean:
	rm -rf "$(OUT)" targets.mk manifest.csv failed.txt
