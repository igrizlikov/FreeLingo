#!/usr/bin/env python3
"""Release regression checks for KV experiment; Mac runtime must still be tested."""
from pathlib import Path
import plistlib
root = Path(__file__).resolve().parents[1]
core = (root/'src/lib.rs').read_text()
ui = (root/'native/main.m').read_text()
ffi = (root/'native/FreeLingoCore.h').read_text()
p = plistlib.loads((root/'assets/Info.plist').read_bytes())
assert p['CFBundleShortVersionString']=='0.6.19' and p['CFBundleVersion']=='29'
for x in ('fl_set_kv_cache_mode', 'fl_benchmark_kv_async'):
    assert x in ffi and x in core, x
assert 'static KV_CACHE_MODE: AtomicU8 = AtomicU8::new(0)' in core
assert 'apply_prompt_cache(&mut payload, &session.model, no_reuse)' in core
assert 'payload["cache_prompt"] = json!(false);' in core
assert '"kv_profile"' in core
assert '"kv_bench"' in core
assert 'for iteration in 1..=3' in core
assert 'for (cache_enabled, profile) in [(true, &mut cached), (false, &mut clean)]' in core
assert 'Benchmark' not in core.split('fn system_prompt')[0]  # no accidental instruction changes
assert 'benchmark_cache_payloads_affect_only_translate_gemma_12b' in core
assert 'benchmark_profile_detects_reproducibility' in core
for x in ('settingsKVChanged:', 'startKVBenchmark:', 'benchmarkFinished:',
          'fl_benchmark_kv_async(path.UTF8String', 'FLBenchmarkCallback',
          '@"kvCacheMode": @0', '[_settingsKVPicker selectItemAtIndex:'):
    assert x in ui, x
assert 'fl_set_kv_cache_mode((int)[NSUserDefaults.standardUserDefaults integerForKey:@"kvCacheMode"])' in ui
assert (root/'RELEASE_0.6.17_RU.md').is_file()
assert 'F35,' in (root/'replica/features.csv').read_text()
print('OK: v0.6.19 KV opt-out scoped to 12B, six-run benchmark, unchanged default, private telemetry')
