"""Static offline release checks; run with `python3 tests/check_release.py`."""
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
model = (root / 'native' / 'ModelManager.inc').read_text()
main = (root / 'native' / 'main.m').read_text()
ui = (root / 'native' / 'ModelWindow.inc').read_text()
core = (root / 'src' / 'lib.rs').read_text()

assert model.count('"sha256"') == 4, 'wrong number of model entries'
sha = re.findall(r'@"sha256": @"([a-f0-9]{64})"', model)
urls = re.findall(r'@"url": @"(https://huggingface\.co/[^\"]+)"', model)
assert len(sha) == len(urls) == 4
assert len(set(sha)) == 4
for part in ('qwen3-0.6b', 'qwen3-1.7b', 'qwen3-4b', 'qwen3-8b'):
    assert part in model
assert 'CC_SHA256_Update' in model
assert 'malloc(64 * 1024)' in model and 'free(buffer);' in model, 'stack-overflow regression'
assert 'memcmp(magic.bytes, "GGUF", 4)' in model, 'incomplete model regression'
assert 'minimumBytes[4]' in model, 'model-specific size validation regression'
assert 'task != self->_modelTask || self->_verifyingModel' in ui, 'download event race regression'
assert 'if (session != self->_modelSession || !self->_verifyingModel) return;' in ui
assert (root / 'tests' / 'smoke_macos.py').exists()
assert 'NSURLSessionDownloadTask' in ui
assert 'modelDownloadFinished' in ui
assert '@"Заменить"' in main
assert '#include "ModelWindow.inc"' in main
assert '127.0.0.1' in core and 'Authorization: Bearer' in core
assert '--no-webui' in core
assert 'Ollama' not in core
assert 'hdiutil create' in (root / 'build-macos.sh').read_text()
assert (root / '.github/workflows/build-dmg.yml').exists()
ET.parse(root / 'assets/Info.plist')
subprocess.run(['bash', '-n', str(root / 'build-macos.sh')], check=True)
subprocess.run(['python3', str(root / 'tests' / 'test_dmg_retry.py')], check=True)
print('OK: model hashes, GGUF validation, heap SHA, URLSession race guards, Rust API, DMG workflow, plist and shell syntax')

# v0.6: menu-bar app mode and first-party login-item registration.
assert 'NSApplicationActivationPolicyAccessory' in main
assert 'setActivationPolicy:policy' in main
assert 'SMAppService.mainAppService' in main and 'registerAndReturnError:' in main
assert 'unregisterAndReturnError:' in main
assert '[self loginItemEnabled]' in main
assert 'statusIcon.template = YES' in main
assert (root / 'assets' / 'MenubarIcon-72.png').is_file()
assert 'SPUStandardUpdaterController' in main
assert 'SPARKLE_PUBLIC_ED_KEY' in (root / 'build-macos.sh').read_text()
assert (root / '.github/workflows/release.yml').is_file()
subprocess.run(['python3', str(root / 'tests' / 'test_appcast.py')], check=True)
print('OK: menu-bar icon, Dock toggle, Login Items, updater and signed appcast tooling')

# v0.6.1: real popup editing and prompt / response quality improvements.
assert 'FLEditor(&_resultEditor, YES)' in main, 'main translation result must be editable'
assert '_quickEditor.delegate = self' in main
assert '- (void)textDidChange:(NSNotification *)notification' in main
assert '[_quickPanel makeFirstResponder:_quickEditor]' in main
assert 'finishQuickEditing' in main
assert 'split_long_line(body, 1100)' in core
assert 'quality_issue(source, &result, target)' in core
assert '"enable_thinking": false' in core
assert 'Qwen3-8B-Q4_K_M.gguf' in model
assert 'd98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785' in model
print('OK: edit in popup, content checks, splitting and Qwen3 8B catalog')

# v0.6.3: editor hardening and stricter translation instructions.
import plistlib
plist = plistlib.loads((root / 'assets' / 'Info.plist').read_bytes())
assert plist['CFBundleShortVersionString'] == '0.6.3'
assert int(plist['CFBundleVersion']) == 13
assert '_quickEditTransitioning' in main
assert '_quickPanel makeFirstResponder:_quickEditButton' in main
assert 'quality_issue(source, &result, target)' in core
assert '--ctx-size", "6144"' in core
print('OK: version, editor reentrancy guards and translation quality checks')
