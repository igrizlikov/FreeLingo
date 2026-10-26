#!/usr/bin/env python3
"""Source-level checks only. Apple Silicon benchmarking still required."""
from pathlib import Path
import plistlib
r=Path(__file__).resolve().parents[1]
rs=(r/'src/lib.rs').read_text()
m=(r/'native/main.m').read_text()
h=(r/'native/FreeLingoCore.h').read_text()
p=plistlib.loads((r/'assets/Info.plist').read_bytes())
assert p['CFBundleShortVersionString']=='0.6.18' and p['CFBundleVersion']=='28'
assert 'fl_set_flash_attention(int mode)' in h
assert 'pub extern "C" fn fl_set_flash_attention(mode: c_int)' in rs
assert 'static FLASH_ATTENTION_MODE: AtomicU8' in rs
assert 'fn effective_flash_mode(model: &Path)' in rs
assert 'if translate_gemma_12b_model(model)' in rs
assert 'cmd.args(["--flash-attn", flash_mode_name(flash_mode)]);' in rs
assert 'requested_flash = effective_flash_mode(&path)' in rs
assert 'previous.flash_mode != requested_flash' in rs
assert 'flash_fallback' in rs and '(start_server(&path, 0)?, 0)' in rs
assert 'requested_flash_attn' in rs
assert 'started=0 reused=1 flash_attn=' in rs
assert 'flash_attention_mode_is_only_for_translate_gemma_12b' in rs
assert '"temperature": 0.0, "max_tokens": 2800' in rs
assert 'fl_set_flash_attention((int)[NSUserDefaults.standardUserDefaults integerForKey:@"flashAttentionMode"])' in m
assert '@"flashAttentionMode": @0' in m
assert 'settingsFlashChanged:' in m
assert 'setInteger:mode forKey:@"flashAttentionMode"' in m
assert '[_settingsFlashPicker selectItemAtIndex:' in m
assert '[self settingsAction:@"Открыть журнал перевода…"' in m
assert '[root addSubview:_settingsFlashPicker];' in m
assert 'stream_fallback' in rs and 'curl_stream_request(' in rs
assert 'F34,Flash Attention A/B profile' in (r/'replica/features.csv').read_text()
print('OK: Flash Attention 12B optional presets, native FFI, fallback, logging, 0.6.15 settings preserved')
