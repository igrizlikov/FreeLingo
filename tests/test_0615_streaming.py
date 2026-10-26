#!/usr/bin/env python3
"""Static FFI and UI guards for provisional local SSE streaming.
Does not stand in for a macOS build, a live llama-server, or speed metrics.
"""
from pathlib import Path
import plistlib
r=Path(__file__).resolve().parents[1]
core=(r/'src/lib.rs').read_text()
ui=(r/'native/main.m').read_text()
header=(r/'native/FreeLingoCore.h').read_text()
assert plistlib.loads((r/'assets/Info.plist').read_bytes())['CFBundleShortVersionString']=='0.6.19'
assert plistlib.loads((r/'assets/Info.plist').read_bytes())['CFBundleVersion']=='29'
assert 'fn curl_stream_request(' in core
assert 'fn sse_delta(' in core
assert 'data == "[DONE]" { continue; }' in core
assert 'serde_json::from_str::<Value>(data)' in core
assert '"stream"] = json!(true)' in core
assert '"--no-buffer"' in core and '"--max-time", "240"' in core
assert 'Duration::from_millis(120)' in core
assert 'translate_gemma_12b_model(&session.model) && progress.is_some()' in core
assert '"stream_fallback"' in core and 'curl_request(&format!' in core
assert 'let may_stream = done.is_some()' in core and 'trace.origin' in core
assert 'callback(ptr, 2, context_id as *mut c_void)' in core
assert 'if success == 2' in ui or 'if (success == 2)' in ui
assert '(__bridge FLJob *)context' in ui
assert '(__bridge_transfer FLJob *)context' in ui
assert 'dispatch_async(dispatch_get_main_queue()' in ui
assert 'job.generation != _mainGeneration' in ui
assert 'job.generation != _quickGeneration' in ui
assert '_replaceButton.enabled = NO;' in ui
assert 'if (job.comparisonStage > 0 || !partial.length) return;' in ui
assert 'translateProgress' not in header or 'success=2' in header
assert '"temperature": 0.0, "max_tokens": 2800' in core
assert '"--ctx-size", "6144", "--n-gpu-layers", "99"' in core
assert 'sse_delta_parser_reads_utf8_fragments_and_skips_usage' in core
assert 'streaming display' in (r/'replica/features.csv').read_text()
print('OK 0.6.15: SSE framing, FFI lifecycle, UI stale-generation guards, quality and sampling preserved')
