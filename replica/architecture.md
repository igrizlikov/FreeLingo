# Архитектура (фактическая 0.5.4)

- `native/main.m` — AppKit окна, Carbon global hotkeys, AX text capture/replace, Vision OCR, UX main/popup.
- `native/ModelManager.inc` — фиксированный манифест GGUF (Hugging Face https + SHA), путь моделей, валидация файла, SHA-256.
- `native/ModelWindow.inc` — NSWindow выбора, NSURLSession downloads, progress, installation.
- `src/lib.rs` — FFI вызов без блокирования UI, private llama-server subprocess, локальный HTTP и выполнение запроса.
- `build-macos.sh` — сборка arm64 .app + ad-hoc подпись + DMG и SHA256, llama.cpp Metal.
- `.github/workflows/build-dmg.yml` — macOS runner, Rust tests, CLI inference smoke, DMG artifact.

Узкие места: Rust backend mutex сериализует все запросы; загрузки не возобновляются после прерывания; Mac UI не тестируется в CI; модель может существенно расходовать память после загрузки, что зависит от машины.
