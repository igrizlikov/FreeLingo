# Иконка FreeLingo 0.5.2

Добавлены файлы assets/FreeLingoIcon.png и assets/FreeLingo.icns.
В assets/Info.plist добавлен ключ CFBundleIconFile, а build-macos.sh копирует .icns внутрь пакета .app перед codesign.

В GitHub нужно заменить два файла: build-macos.sh, assets/Info.plist и загрузить assets/FreeLingo.icns. Затем снова запустить Actions → Build FreeLingo DMG (Apple Silicon). Готовый DMG сохранит имя FreeLingo-0.5-AppleSilicon.dmg для совместимости с текущим workflow.

Проверены файлы иконки и plist; сборка macOS после обновления не запускалась.
