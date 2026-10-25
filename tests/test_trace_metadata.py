#!/usr/bin/env python3
"""Static cross-language correlation/privacy regression checks (non-macOS)."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
native=(root/'native/main.m').read_text()
engine=(root/'src/lib.rs').read_text()
header=(root/'native/FreeLingoCore.h').read_text()
assert native.count('fl_work_async_traced(')==2, 'main and A/B must call traced ABI'
assert 'void fl_work_async_traced(' in header
assert 'pub extern "C" fn fl_work_async_traced(' in engine
assert 'pub extern "C" fn fl_work_async(' in engine, 'keep old ABI'
assert 'FLCanonicalTranslationSource(_comparisonSource)' in native
assert 'FLCanonicalTranslationSource(text)' in native
for origin in ('@"main"','@"hotkey"','@"clipboard"','@"ocr"','@"ab-hy"','@"ab-gemma"'):
    assert origin in native, f'Missing origin {origin}'
assert 'CCHmac(kCCHmacAlgSHA256' in native
assert 'SecRandomCopyBytes(kSecRandomDefault' in native
assert 'if (!keyAvailable) return @"unavailable"' in native
assert 'CC_SHA256(' not in native, 'Never log unsalted hash'
assert '"origin", "hash", "detected", "target"' not in engine # no raw string array dumped
assert 'trace_event(&path, trace, "layout"' in engine
assert 'request_chunk_count(normalized_source, short_specialized_document)' in engine
assert 'trace_event(Path::new(&model), &trace, "finish"' in engine
assert 'source_hash: safe_field(' in engine
assert 'fn trace_fields_reject_newlines_and_untrusted_strings()' in engine
assert 'fn diagnostic_chunk_count_matches_actual_split()' in engine
# ensure the logged v2 format omits source/user content and model path
line=next(x for x in engine.splitlines() if '{seconds} v2 id=' in x)
for token in ('id=', 'origin=', 'model=', 'hash=', 'detected=', 'target=', 'event=', 'detail='):
    assert token in line
for forbidden in ('source={}', 'result={}', 'text={}', 'path={}'): assert forbidden not in line
assert re.search(r'\bCFBundleShortVersionString\b', (root/'assets/Info.plist').read_text())
print('OK: traced ABI + all origins + ephemeral HMAC + privacy-safe normalized source/metadata')
