from pathlib import Path
import re
r=Path(__file__).resolve().parents[1]
ui=(r/'native/main.m').read_text()
models=(r/'native/ModelManager.inc').read_text()
core=(r/'src/lib.rs').read_text()
assert 'restoredParagraphs ? @"hotkey_clipboard" : @"hotkey"' in ui
assert 'sameContent && pb.changeCount == afterCopyChangeCount' in ui
assert '[FLWithoutWhitespace(copied) isEqualToString:FLWithoutWhitespace(axText)]' in ui
assert 'if (backup.count) [pb writeObjects:backup];' in ui
assert 'FLSendCopyShortcut' in ui
assert re.search(r'_comparisonModels\s*=\s*compareGemmas\s*\?',ui)
assert 'content_hash={} raw_chars=' in core
assert 'translategemma-12b-it-Q4_K_M.gguf' in models
assert 'http://' not in models
print('OK: v0.6.12 capture and model catalog static regression')
