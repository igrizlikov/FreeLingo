#!/usr/bin/env python3
"""Static guardrails for 12B speed iteration; real throughput needs macOS."""
from pathlib import Path
import re
r=Path(__file__).resolve().parents[1]
s=(r/'src/lib.rs').read_text()
assert 'fn packed_translation_batches(source: &str)' in s
assert 'if translate_gemma_12b_model(model) { 3600 } else { 3000 }' in s
assert '&& (!has_cjk(source) || length <= 1300)' in s
assert 'source.len() <= 5200' in s
assert 'for (text, separator) in batches' in s
assert 'output.push_str(&separator)' in s
assert 'if short_specialized_document { "whole" } else if packed.is_some() { "packed" }' in s
assert '"perf"' in s and 'prompt_n=' in s and 'predicted_ms=' in s
assert 'started=0 reused=1' in s
for name in ('twelve_b_short_story_over_three_thousand_chars_uses_one_request',
             'twelve_b_long_text_packs_multiple_paragraphs_without_eating_separators',
             'twelve_b_long_single_line_respects_utf8_boundary'):
    assert name in s
assert '"--ctx-size", "6144", "--n-gpu-layers", "99"' in s, 'Metal offload accidentally changed'
assert '"temperature": 0.0, "max_tokens": 2800' in s, 'Sampling intentionally unchanged'
assert (r/'assets/Info.plist').read_text().count('0.6.14')==1
print('OK 0.6.14: 12B batching, original sampling, Metal settings, performance timing')
