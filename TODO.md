# TODO

## Аудио

- [ ] **Вариативность звука клика кнопок.** Добавить 2 дополнительных
      `btn-click` сэмпла, играть случайным выбором без подряд-повторов
      (если выпал тот же индекс, что в прошлый раз — берём следующий).
  - `SfxManager`: массив `SFX_BTN_CLICKS: Array[AudioStream]` +
    функция `play_random_btn_click()` с полем `_last_btn_idx`.
  - `UIStyle.attach_click_sfx` — поменять вызов на `play_random_btn_click()`.
  - Файлы кладутся в `assets/audio/sfx/` (например `btn-click-2.wav`,
    `btn-click-3.wav`).
