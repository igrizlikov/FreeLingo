#!/usr/bin/env python3
"""Run both installed GGUFs on identical multilingual corpus through the bundled server.

MAC ONLY; no extra pip packages; writes a PRIVATE local report; never uploads text.
This reports model outputs and timings. HUMAN REVIEW decides translation quality.
Run from the FreeLingo 0.6.12 source folder after build or with the app installed.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = Path.home() / 'Library/Application Support/FreeLingo'
MODELS = SUPPORT / 'Models'
CASES = ROOT / 'replica/quality_cases.json'
MODEL_FILES = {
    'Hy-MT2 7B': 'Hy-MT2-7B-Q4_K_M.gguf',
    'TranslateGemma 4B': 'translategemma-4b_Q4_K_M.gguf',
    'TranslateGemma 12B': 'translategemma-12b-it-Q4_K_M.gguf',
}
LANG_NAMES = {'ru':'Russian', 'en':'English', 'zh':'Chinese', 'fr':'French', 'it':'Italian'}

def app_server() -> Path:
    choices = [Path('/Applications/FreeLingo.app/Contents/MacOS/llama-server'),
               ROOT / 'dist/FreeLingo.app/Contents/MacOS/llama-server']
    for p in choices:
        if p.is_file(): return p
    raise RuntimeError('Не найден llama-server. Установи FreeLingo в /Applications.')

def json_call(url: str, token: str, payload=None, timeout=240) -> dict:
    body = json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None
    with urllib.request.urlopen(urllib.request.Request(url, data=body, headers={
        'Authorization':'Bearer '+token, 'Content-Type':'application/json'}), timeout=timeout) as resp:
        return json.loads(resp.read())

def server_for(model: Path, binary: Path):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
    token = os.urandom(20).hex()
    args=[str(binary),'--model',str(model),'--host','127.0.0.1','--port',str(port),
          '--ctx-size','6144','--n-gpu-layers','99','--jinja','--no-webui',
          '--alias','freelingo','--api-key',token]
    logfile=tempfile.TemporaryFile()
    proc=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=logfile,stderr=subprocess.STDOUT)
    try:
        until=time.monotonic()+135
        while time.monotonic()<until:
            if proc.poll() is not None: raise RuntimeError('llama-server exited')
            try:
                if json_call(f'http://127.0.0.1:{port}/health',token,timeout=3).get('status')=='ok':
                    return proc,logfile,port,token
            except Exception: pass
            time.sleep(0.8)
        raise RuntimeError('llama-server did not become ready in 135s')
    except Exception:
        logfile.seek(0);print(logfile.read().decode('utf-8','replace')[-4000:],file=sys.stderr)
        proc.terminate();proc.wait(timeout=10);logfile.close();raise

def payload_for(model_name: str, case: dict) -> dict:
    src=case['source_lang'];target=case['target_lang'];text=case['source']
    if model_name.startswith('Hy-'):
        return {'model':'freelingo','stream':False,'temperature':0.7,'top_p':0.6,
                'top_k':20,'repeat_penalty':1.05,'max_tokens':2048,
                'messages':[{'role':'user','content': f'Translate the following text into {LANG_NAMES[target]}. Note that you should only output the translated result without any additional explanation:\n\n{text}'}]}
    return {'model':'freelingo','stream':False,'temperature':0.0,'max_tokens':2800,
            'chat_template_kwargs':{'source_lang_code':src,'target_lang_code':target},
            'messages':[{'role':'user','content':text}]}

def main():
    parser=argparse.ArgumentParser(description='Локальный A/B-тест TranslateGemma 4B / 12B или Hy-MT2')
    parser.add_argument('--limit',type=int,default=0,help='0 = все тексты')
    parser.add_argument('--models', default='TranslateGemma 4B,TranslateGemma 12B',
                        help='Перечисли названия моделей через запятую')
    args=parser.parse_args()
    if sys.platform != 'darwin': raise SystemExit('Тест запускается только на macOS.')
    binary=app_server()
    cases=json.loads(CASES.read_text())
    if args.limit: cases=cases[:args.limit]
    selected = [name.strip() for name in args.models.split(',')]
    if len(selected) != 2 or len(set(selected)) != 2 or any(name not in MODEL_FILES for name in selected):
        raise SystemExit('Выбери две разные модели из: ' + ', '.join(MODEL_FILES))
    output=[]
    for name in selected:
        filename = MODEL_FILES[name]
        model=MODELS / filename
        if not model.is_file() or model.stat().st_size < 2_000_000_000 or model.open('rb').read(4)!=b'GGUF':
            raise SystemExit(f'Скачай модель {name} через менеджер FreeLingo, затем запусти сравнение ещё раз.')
        proc,log,port,token=server_for(model,binary)
        try:
            for case in cases:
                start=time.monotonic()
                try:
                    res=json_call(f'http://127.0.0.1:{port}/v1/chat/completions',token,payload_for(name,case))
                    result=res['choices'][0]['message']['content']
                    if not result: raise RuntimeError('Empty model response')
                    error=None
                except Exception as exc:
                    result='';error=str(exc)
                item={'model':name,'id':case['id'],'from':case['source_lang'],
                      'to':case['target_lang'],'seconds':round(time.monotonic()-start,2),
                      'output':result,'error':error,'human_checks':case.get('human_checks',[])}
                output.append(item)
                print(f"{name}: {case['id']} {item['seconds']}s {'ERROR '+error if error else 'OK'}",flush=True)
        finally:
            proc.terminate()
            try:proc.wait(timeout=10)
            except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=10)
            log.close()
    folder=SUPPORT / 'Diagnostics';folder.mkdir(parents=True,exist_ok=True)
    report=folder / 'comparison-0.6.12.md'
    pieces=['# FreeLingo 0.6.12 — локальное сравнение переводов','',
            'Автоматическое ранжирование отключено. Оценка естественности требует носителя языка.','']
    for case in cases:
        pieces.extend(['## '+case['id'], '','**Исходный:** '+case['source'],''])
        if case.get('reference_ru'): pieces.extend(['**Человеческий образец:** '+case['reference_ru'],''])
        for item in output:
            if item['id']==case['id']:
                pieces.extend([f"**{item['model']} ({item['seconds']} с):**",'',item['output'] or 'Ошибка: '+str(item['error']),''])
        pieces.append('**Проверить:** '+', '.join(case.get('human_checks',[])));pieces.append('')
    report.write_text('\n'.join(pieces),encoding='utf-8')
    (folder/'comparison-0.6.12.json').write_text(json.dumps(output,ensure_ascii=False,indent=2))
    print('Отчёт сохранён:',report)

if __name__=='__main__':
    main()
