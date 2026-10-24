#!/bin/bash
set -o pipefail
cd "$(dirname "$0")" || exit 1
printf '\n=== FreeLingo: сборка macOS приложения ===\n\n'
./build-macos.sh
status=$?
if [ "$status" -eq 0 ]; then
  echo 'Готово: dist/FreeLingo-0.5-AppleSilicon.dmg'
  open dist/FreeLingo-0.5-AppleSilicon.dmg
else
  echo
  echo 'Сборка не завершена. Скопируй текст ошибки из этого окна.'
fi
printf '\nНажми Enter, чтобы закрыть окно...'
read -r _
exit "$status"
