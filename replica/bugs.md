# FreeLingo — журнал дефектов (Replica Audit 2026-10-24)

Обозначения: **S1** — блокирует основную работу; **S2** — серьёзно ухудшает/рискует данными; **S3** — функциональный пробел; **S4** — косметический.

| Приоритет | Дефект | Фактическое подтверждение | Изменение v0.5.4 | Проверка |
|---|---|---|---|---|
| S1 | Аварийное завершение после 100% загрузки GGUF | Скриншот пользователя, стек падения пока не получен. В предыдущей версии в GCD worker находился буфер хеширования 1 МБ. | Выделение 64 КиБ в куче, явное освобождение, проверка ошибок потока, дополнительные guards для NSURLSession. | macOS: завершение загрузки 0.6B/1.7B без падения; возможные ошибки SHA показываются в UI |
| S1 | Реальный перевод не был включён в тесты сборки | Зелёный GitHub Actions #3 подтверждает сборку DMG, но не работу inference | Добавлен `tests/smoke_macos.py`: download GGUF+SHA256+llama-server+localhost completion; запуск по умолчанию при workflow_dispatch | Получить зелёный CI со включённым `run_model_smoke`, проверить перевод и popup на Mac |
| S2 | Некорректно установленная модель определялась только по условию size >400 MiB | `native/ModelManager.inc` до аудита | Отдельные минимальные пороги размеров + обязательная сигнатура `GGUF` | Проверить повреждённый/короткий файл: приложение не должно его активировать |
| S2 | Запоздалые callback-и URLSession могли переписать UI проверки и вызвать повторное завершение | `native/ModelWindow.inc` до аудита | Проверка актуальности task/session, блокировка progress в режиме SHA | Отменить загрузку/повторно запустить; смотреть корректность статусов |
| S2 | Вставка через ⌘V могла выполняться после смены исходного окна или выделения | `native/main.m` до аудита | Перед вставкой повторная проверка frontmost PID + AX selection и отмена при несовпадении | Из TextEdit переключиться в другое приложение во время диалога; ничего не должно заменяться |
| S3 | Нет полного перевода DOCX/PDF/PPTX | `native/main.m` поддерживает TXT/MD | Не изменено | Отдельная подсистема, не считать выполненным |
| S3 | Нет SRT/VTT с сохранением таймкодов | `native/main.m` | Не изменено | Отдельная подсистема |
| S3 | История только в памяти текущего запуска | `native/main.m` | Не изменено | Добавить постоянное локальное хранение с opt-out |

**Не установлено:** точная причина конкретного macOS crash без `.ips` и результат работы текущего исправления на Mac. Статический аудит и smoke-тесты не заменяют GUI E2E.

## CI-DMG-001: hdiutil Resource busy on GitHub macOS 15 (2026-10-24)

- Severity S2, blocks DMG artifact, not compilation.
- OBSERVED: run 108781400808 fails at `hdiutil create -srcfolder` with `Resource busy`, after Rust tests 4/4, arm64 binaries and signing.
- CAUSE STATUS: CI EBUSY transient is likely; exact resource holder UNKNOWN (no system trace).
- FIX: sync, five bounded retries with backoff, remove partial image and verify before upload.
- STATUS: shell syntax and mocked retry tests locally; real macOS CI UNTESTED.


## 0.6.1 — регрессионные проблемы, выявленные пользователем

| ID | Приоритет | Наблюдение | Причина/гипотеза | Изменение | Статус |
| --- | --- | --- | --- | --- | --- |
| FL-QA-01 | P1 | Плохой перевод: plural brothers -> singular, Chinese 护士, буквальные выражения | SOURCE_CONFIRMED: промпт без проверки чисел/смысла и 1700 max_tokens; влияние размера модели подтверждено не было | Более подробный prompt, абзацные запросы, retry при чужой письменности / truncation, Qwen3 8B | Непроверено на Mac |
| FL-QA-02 | P0 | «Редактировать» не открывает доступное редактирование; после повторных кликов приложение закрылось | SOURCE_CONFIRMED: результат в главном окне readonly; причина crash UNKNOWN без .ips | Редактирование непосредственно в NSPanel и editable main result | Непроверено на Mac |

## 2026-10-25 — 0.6.3 исправления (SOURCE_CONFIRMED, macOS E2E не выполнялся)

- UI-EDIT-003: reentrant clicks «Редактировать»/«Готово» — добавлена защита переходов и смена responder до отключения редактируемости, плюс инвалидирование callback после закрытия. Исходное сообщение пользователя: приложение закрывалось после нескольких нажатий. Причина не подтверждена без .ips.
- QUALITY-002: Qwen3 4B теряла числа и профессию, иногда вставляла китайские символы. Добавлен prompt + проверка некоторых отклонений + повторная генерация. Качество реальной 4B пока **не подтверждено**.
- UPD-003: версия 0.6.3/13 для проверки Sparkle 0.6.2->0.6.3. Подписанный архив/установка ещё не проверены.

## TCC/Accessibility разрешение повторно требуется после обновлений (наблюдал пользователь, 2026-10-25)

**SOURCE_CONFIRMED:** `build-macos.sh` 0.6.5 использует ad-hoc `codesign --sign -`, что меняет designated requirement при каждом обновлении.

**PARTIAL:** 0.6.6 позволяет задать постоянную identity. Пока в GitHub Actions не импортирован постоянный сертификат, проблема останется. После настройки требуется на реальном Mac проверить `codesign -dvv` и обновление через Sparkle.

### 2026-10-25 — RU translation remains nonidiomatic after postediting
- OBSERVED: English family sample translated with Hy-MT2 7B; awkward calques and poor word choice remained.
- OBSERVED: Qwen postediting sometimes replaced «пожилая» with «старая».
- SOURCE_CONFIRMED: earlier 0.6.6 postedit silently returned original on rejection; diagnostics now distinguish decisions.
- UNTESTED: 0.6.7 A/B test between Hy-MT2 7B and TranslateGemma 4B has not run on real hardware.

## 2026-10-25 — 0.6.8: конфликт контекста перевода и вероятный UI-crash
- FL-QUALITY-009 (OBSERVED): пользователь показал лучший перевод Gemma через ⌘4, чем из главного окна на одном рассказе. SOURCE_CONFIRMED: Rust разрезал **каждую** строку независимо. 0.6.9: специализированные модели для текстов до 3000 символов получают один запрос с полным контекстом. UNTESTED E2E.
- FL-APPKIT-010 (OBSERVED): после перевода, при открытии настроек FreeLingo иногда закрывается. CRASH CAUSE UNKNOWN: нет .ips, не утверждать что это NSWindow use-after-free. 0.6.9 делает releasedWhenClosed=NO для сохраняемых NSWindow и NSPanel, добавляет приватные NSLog метки. Требуется повторить сценарий на macOS и разобрать crash-report, если воспроизведётся.
