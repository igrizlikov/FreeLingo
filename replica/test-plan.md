# План проверки FreeLingo 0.5.4

| ID | Уровень | Действия | Ожидаемое | Статус |
|---|---|---|---|---|
| T01 | Static Linux | `python3 tests/check_release.py` | SHA-манифест, heap SHA, guards, подпись, plist, bash синтаксис | **Проверено** |
| T02 | Build macOS CI | `./build-macos.sh` | `dist/FreeLingo-0.5.4-AppleSilicon.dmg`, SHA256 | Не выполнено для 0.5.4 |
| T03 | Runtime CI macOS | `python3 tests/smoke_macos.py` | Загрузить 0.6B, сверить SHA256, запустить сервер, получить непустой перевод | Не выполнено |
| T04 | macOS UI | Загрузить Qwen3 1.7B от 0 до 100% | Нет падения, проверка SHA, статус «готова» | Не выполнено |
| T05 | macOS UI | Перевести «Hello, world!» -> русский | Непустой адекватный перевод, можно копировать | Не выполнено |
| T06 | macOS UI | Отключить Wi-Fi и перевести повторно | Перевод по локальной модели работает офлайн | Не выполнено |
| T07 | macOS UI | TextEdit: выделить -> ⌘4 | Popup у курсора, корректные разрешения | Не выполнено |
| T08 | macOS UI | TextEdit: popup -> «Заменить» | Только выделенный текст заменён | Не выполнено |
| T09 | macOS UI | Сменить окно/выделение после открытия popup -> «Заменить» | Операция отменена, чужой текст не изменён | Не выполнено |
| T10 | macOS UI | OCR участка экрана через ⇧⌘2 | Верный текст/перевод, нет зависания | Не выполнено |
| T11 | macOS UI | Отменить загрузку на середине, повторить | Не остаётся ложного «Установлена», повторная загрузка корректна | Не выполнено |
| T12 | macOS UI | Сменить 0.6B → 1.7B между запросами | Выбранная модель используется; нет мёртвого llama-server | Не выполнено |
| T13 | macOS UI | Повреждённый GGUF (не в Production) | Не активируется, UI предлагает скачать заново | Не выполнено |
| T14 | macOS UI | Два монитора, разные Spaces | Popup внутри видимой области, корректный фокус | Не выполнено |

Только T01 выполняется локально в текущей среде; остальные тесты требуют macOS SDK или графического macOS-сеанса. Для краша сохранять `~/Library/Logs/DiagnosticReports/FreeLingo*.ips` (если существует).

## FreeLingo 0.6.9 — регрессионные сценарии
| ID | Тип | Действие | Ожидаемый результат | Статус |
|---|---|---|---|---|
| T15 | macOS E2E | Gemma 4B, один английский текст с двумя абзацами через главное окно и ⌘4 | Один контекст запроса и близкие результаты | Не выполнено |
| T16 | macOS E2E | После завершения перевода открыть и закрыть настройки 10 раз | Нет аварийного завершения | Не выполнено |
| T17 | macOS E2E | Закрыть и снова открыть главное окно, настройки и окно сравнения | Нет зависаний/крашей | Не выполнено |
| T18 | macOS E2E | Обновиться с 0.6.8, активная Gemma | Предпочтение модели и загруженные GGUF сохранены | Не выполнено |

## FreeLingo 0.6.10 — вставка и очистка
| ID | Тип | Действие | Ожидаемый результат | Статус |
|---|---|---|---|---|
| T28 | macOS E2E | Скопировать в Safari форматированный текст с жирными заголовками, вставить в главное окно ⌘V | Только текст и переносы строк, никакой RTF/HTML-стилизации | Не выполнено |
| T29 | macOS E2E | Нажать «Очистить» после перевода | Исходник и результат пусты, история/выбор модели/язык сохранены | Не выполнено |
| T30 | macOS E2E | Нажать «Очистить» сразу после начала длительного перевода | Поздний callback не восстанавливает результат | Не выполнено |


## 0.6.11 trace invariants

- Same short English text pasted in main and selected via Accessibility with TranslateGemma: `hash` and canonical counts identical in same session; `origin` differs; `layout`/`chunks` equal.
- Different source: different HMAC. After restart: hash changes even for same source. No source/result text or private keys in log.
- Two consecutive A/B requests: same input HMAC for stages `ab-hy` and `ab-gemma`; unique UUID per stage; language target identical.
- Unsupported/inconclusive detected language is recorded as `unknown`; user sees an error rather than a misleading successful comparison.
- Clear while translating: UI remains empty and no stale result returns; backend records completion.
