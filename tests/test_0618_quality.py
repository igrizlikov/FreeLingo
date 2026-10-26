#!/usr/bin/env python3
"""Offline deterministic quality-suite checks, no inference needed."""
from collections import Counter
import json
from pathlib import Path
import sys
r=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(r/'tests'))
from quality_review_macos import review_warnings, number_tokens, report
cases=json.loads((r/'replica/quality_ru_0618.json').read_text('utf-8'))
assert len(cases)>=16
assert {x['source_lang'] for x in cases}=={'en','fr','it','zh'}
assert len({x['id'] for x in cases})==len(cases)
for x in cases:
    assert x['source'].strip() and x['target_lang']=='ru' and len(x['checks'])>=3
    assert x['source_lang'] in ('en','it','fr','zh')
case={'source':'In 1918, 20 people died.\n\nIn 1919, 30 returned.','checks':['1918']}
assert review_warnings(case,'В 1918 году погибло 20 человек.\n\nВ 1919 году вернулись 30 человек.')==[]
assert any('Числа' in x for x in review_warnings(case, 'В 1918 году погибло 20 человек.\n\nВ 1920 году вернулись 30 человек.'))
assert any('абзац' in x for x in review_warnings(case, 'В 1918 году погибло 20 человек, в 1919 году вернулись 30 человек.'))
assert any('иероглиф' in x for x in review_warnings(case,'В городе 上海 живёт множество людей.'))
assert number_tokens('In 08 of 1918, 20')==Counter({'8':1,'1918':1,'20':1})
assert 'Ручная оценка' in report([dict(case,id='x',source_lang='en')],[{'id':'x','output':'В 1918 году.', 'warnings':[]}])
core=(r/'src/lib.rs').read_text()
assert 'fn translation_review_flags(' in core and 'fn numeric_tokens(' in core
assert 'trace.log(&path, "quality_review"' in core
assert 'fn quality_review_reports_numeric_drift_but_does_not_reject()' in core
assert 'fn quality_review_observes_paragraphs_without_changing_translation()' in core
assert 'return Err("Модель вернула пустой результат"' in core
assert 'translate_gemma_12b_model(&session.model) && progress.is_some()' in core
assert '"temperature": 0.0, "max_tokens": 2800' in core
print('OK: multilingual corpus, numbers/paragraph/scripting heuristic, no model alteration, private review')
