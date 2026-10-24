#!/usr/bin/env python3
"""Test DMG retry block without macOS tooling, including terminal failure."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
script = (root / 'build-macos.sh').read_text()
start = script.index('DMG_OUTPUT="$ROOT/dist/FreeLingo-${APP_VERSION}-AppleSilicon.dmg"')
end = script.index('echo "DMG built:', start)
retry_block = script[start:end]
prelude = r'''
ROOT="$1"
STAGE="$ROOT/dist/dmg-stage"
APP_VERSION="0.6.0"
ATTEMPTS=0
sync() { :; }
sleep() { :; }
hdiutil() {
  case "$1" in
    create)
      ATTEMPTS=$((ATTEMPTS + 1))
      if [[ "${FAIL_FOREVER:-0}" = 1 || "$ATTEMPTS" -lt 3 ]]; then
        echo 'hdiutil: create failed - Resource busy' >&2
        return 1
      fi
      printf 'mock-dmg\n' > "$DMG_OUTPUT"
      return 0
      ;;
    verify) [[ -s "$DMG_OUTPUT" ]] ;;
    info) echo 'mock hdiutil info'; return 0 ;;
  esac
}
'''
for fail_forever, expected_attempts in ((False, 3), (True, 5)):
    with tempfile.TemporaryDirectory() as temp:
        temp_path = Path(temp)
        (temp_path / 'dist/dmg-stage').mkdir(parents=True)
        trailer = 'echo "ATTEMPT_COUNT=$ATTEMPTS"\n'
        run = subprocess.run(['bash', '-c', 'set -euo pipefail\n' + prelude + retry_block + trailer, 'bash', str(temp_path)],
                             capture_output=True, text=True,
                             env={'FAIL_FOREVER': '1' if fail_forever else '0', 'PATH': '/usr/bin:/bin'})
        output = run.stdout + run.stderr
        if fail_forever:
            assert run.returncode != 0 and 'after 5 attempts' in output, (run.returncode, output)
        else:
            assert run.returncode == 0 and f'ATTEMPT_COUNT={expected_attempts}' in output, (run.returncode, output)
            assert (temp_path/'dist/FreeLingo-0.6.0-AppleSilicon.dmg').read_bytes() == b'mock-dmg\n'
print('PASS: DMG retry recovers from 2 busy errors and stops safely on 5 persistent errors')
