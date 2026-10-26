#!/usr/bin/env python3
"""Offline, local, human-reviewed TranslateGemma 12B accuracy audit.

No network services other than the ephemeral 127.0.0.1 llama-server. Output
contains both source and translation and remains in user's private Diagnostics.
"""
from __future__ import annotations
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys
import time

from translation_ab_macos import app_server, json_call, payload_for, server_for, MODELS, SUPPORT

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / 'replica' / 'quality_ru_0618.json'
MODEL_NAME = 'TranslateGemma 12B'


def number_tokens(text: str) -> Counter[str]:
    """Heuristic only: written-out numerals and locale formats need human review."""
    return Counter((n.lstrip('0') or '0') for n in re.findall(r'[0-9]+', text))


def review_warnings(case: dict, output: str) -> list[str]:
    src = case['source']
    warnings = []
    before = number_tokens(src)
    after = number_tokens(output)
    if before and before != after:
        warnings.append('Числа требуют проверки (возможна запись словами)')
    para = lambda text: len([part for part in re.split(r'\n\s*\n', text) if part.strip()])
    if para(src) > 1 and para(src) != para(output):
        warnings.append('Изменилось количество абзацев')
    if any('\u3400' <= ch <= '\u9fff' for ch in output):
        warnings.append('В результате остались китайские иероглифы')
    if not output.strip():
        warnings.append('Пустой перевод')
    if len(src) >= 100 and len(output.strip()) < len(src) // 5:
        warnings.append('Результат слишком короткий — возможен пропуск')
    return warnings


def report(cases: list[dict], results: list[dict]) -> str:
    by_id = {r['id']: r for r in results}
    lines = ['# FreeLingo 0.6.18 — ручная проверка TranslateGemma 12B', '',
             'Отчёт локальный. Флаги — эвристики, не доказательство ошибок модели. '
             'Точность, полноту, стиль и перевод имён оценивает человек.', '']
    for case in cases:
        result = by_id.get(case['id'], {})
        output = result.get('output', '')
        lines.extend([f"## {case['id']} ({case['source_lang']}→ru)", '',
                      '**Исходник:**', '', case['source'], '',
                      '**Перевод:**', '', output or f"Ошибка: {result.get('error', 'нет данных')}", '',
                      '**Автоматические предупреждения:** ' + (', '.join(result.get('warnings', [])) or 'нет'), '',
                      '**Ручная проверка:**', ''])
        for item in case['checks']:
            lines.append('- [ ] ' + item)
        lines.extend(['', '**Ручная оценка:** точность __/5; естественность __/5; полнота __/5.', ''])
    return '\n'.join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description='Локальная проверка точности и естественности RU переводов')
    parser.add_argument('--limit', type=int, default=0)
    parser.add_argument('--dry-run', action='store_true', help='Проверка корпуса без запуска модели')
    args = parser.parse_args()
    cases = json.loads(CORPUS.read_text('utf-8'))
    if args.limit > 0:
        cases = cases[:args.limit]
    if args.dry_run:
        for c in cases:
            print(c['id'], c['source_lang'], 'checks:', len(c['checks']))
        print('OK: сценарии проверки доступны; модель не запускалась')
        return
    if sys.platform != 'darwin':
        raise SystemExit('Для запуска модели нужен Mac с установленным FreeLingo.')
    model = MODELS / 'translategemma-12b-it-Q4_K_M.gguf'
    if not model.is_file() or model.stat().st_size < 2_000_000_000 or model.open('rb').read(4) != b'GGUF':
        raise SystemExit('Установи TranslateGemma 12B Q4_K_M через менеджер моделей FreeLingo.')
    proc, log, port, token = server_for(model, app_server())
    results = []
    try:
        for case in cases:
            started = time.monotonic()
            try:
                payload = payload_for(MODEL_NAME, case)
                response = json_call(f'http://127.0.0.1:{port}/v1/chat/completions', token, payload, timeout=240)
                output = response['choices'][0]['message']['content']
                error = None
            except Exception as exc:
                output, error = '', type(exc).__name__
            results.append({'id': case['id'], 'lang': case['source_lang'],
                            'seconds': round(time.monotonic() - started, 3),
                            'output': output, 'error': error,
                            'warnings': review_warnings(case, output)})
            print(f"{case['id']}: {results[-1]['seconds']} c, предупреждений: {len(results[-1]['warnings'])}", flush=True)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
            proc.wait(timeout=10)
        log.close()
    diagnostics = SUPPORT / 'Diagnostics'
    diagnostics.mkdir(parents=True, exist_ok=True)
    # Restrict report access: files contain source/translated texts.
    for name, content in [('quality-0.6.18.md', report(cases, results)),
                          ('quality-0.6.18.json', json.dumps(results, ensure_ascii=False, indent=2))]:
        path = diagnostics / name
        path.write_text(content, encoding='utf-8')
        path.chmod(0o600)
        print('Локальный отчёт:', path)


if __name__ == '__main__':
    main()
