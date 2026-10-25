#!/usr/bin/env python3
"""Offline regression checks for multilingual comparison request shapes."""
from pathlib import Path
import importlib.util
import json
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('ab', ROOT/'tests/translation_ab_macos.py')
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
cases=json.loads((ROOT/'replica/quality_cases.json').read_text())
assert len(cases)>=10
assert {c['target_lang'] for c in cases} >= set('ru en zh fr it'.split())
for case in cases:
    assert case['source'] and case['source_lang'] in mod.LANG_NAMES
    assert case['target_lang'] in mod.LANG_NAMES
    for model in mod.MODEL_FILES:
        j=mod.payload_for(model,case)
        assert j['messages'][0]['role']=='user'
        assert j['stream'] is False
        if model.startswith('Hy-'):
            assert mod.LANG_NAMES[case['target_lang']] in j['messages'][0]['content']
        else:
            assert j['chat_template_kwargs']['source_lang_code']==case['source_lang']
            assert j['chat_template_kwargs']['target_lang_code']==case['target_lang']
            assert j['messages'][0]['content']==case['source']
print(f'OK: {len(cases)} corpus entries across 5 languages; all model payloads checked')
