from pathlib import Path
import plistlib, re
root=Path(__file__).resolve().parents[1]
pl=plistlib.loads((root/'assets/Info.plist').read_bytes())
assert re.fullmatch(r'0\.6\.\d+', pl['CFBundleShortVersionString'])
assert int(pl['CFBundleVersion']) >= 13
assert pl['SUEnableAutomaticChecks'] is True
assert pl['SUAutomaticallyUpdate'] is True
assert pl['SUVerifyUpdateBeforeExtraction'] is True
assert pl['SUFeedURL'].startswith('https://')
assert (root/'.github/workflows/release.yml').is_file()
assert 'REQUIRE_SPARKLE_SIGNING' in (root/'build-macos.sh').read_text()
assert 'sign_update' in (root/'.github/workflows/release.yml').read_text()
print('OK: Sparkle bootstrap and release configuration')
