#!/usr/bin/env python3
"""Optional macOS E2E of official Hy-MT2 1.8B GGUF through bundled llama.cpp.

Run only on Apple Silicon after `./build-macos.sh`. Downloads 1.13 GB once to a
private temporary directory, verifies the official SHA-256 and checks that five
language targets return nonempty text. This is not an accuracy benchmark.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / 'dist/FreeLingo.app/Contents/MacOS/llama-server'
NAME = 'Hy-MT2-1.8B-Q4_K_M.gguf'
SOURCE_URL = 'https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/' + NAME
SHA256 = 'dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699'


def download(path: Path) -> None:
    print('Downloading Hy-MT2 1.8B Q4_K_M for smoke test (~1.13 GB)...', flush=True)
    digest = hashlib.sha256()
    with urllib.request.urlopen(urllib.request.Request(SOURCE_URL, headers={'User-Agent':'FreeLingo-CI/0.6.4'}), timeout=120) as src, path.open('wb') as dest:
        while block := src.read(2 * 1024 * 1024):
            dest.write(block)
            digest.update(block)
    if digest.hexdigest() != SHA256:
        raise RuntimeError('Hy-MT2 SHA-256 mismatch: refuse to execute model')
    if path.open('rb').read(4) != b'GGUF':
        raise RuntimeError('Hy-MT2 file has no GGUF header')


def call_json(url: str, token: str, data: dict | None = None, timeout: int = 120) -> dict:
    body = json.dumps(data).encode() if data is not None else None
    request = urllib.request.Request(url, data=body, headers={
        'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def test_translation(path: Path) -> None:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    token = os.urandom(24).hex()
    command = [str(SERVER), '--model', str(path), '--host', '127.0.0.1', '--port', str(port),
               '--ctx-size', '6144', '--n-gpu-layers', '0', '--jinja', '--no-webui',
               '--alias', 'freelingo', '--api-key', token]
    with tempfile.TemporaryFile() as logfile:
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=logfile, stderr=subprocess.STDOUT)
        try:
            health = f'http://127.0.0.1:{port}/health'
            deadline = time.monotonic() + 200
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError('llama-server quit before health check')
                try:
                    if call_json(health, token, timeout=3).get('status') == 'ok':
                        break
                except Exception:
                    pass
                time.sleep(1)
            else:
                raise RuntimeError('llama-server did not load Hy-MT2 in 200s')
            cases = [('Russian', 'My mother is a nurse at a large hospital. I have two brothers.'),
                     ('English', 'Я живу недалеко от гор.'),
                     ('Chinese', 'Я очень люблю свою семью.'),
                     ('French', 'Я очень люблю свою семью.'),
                     ('Italian', 'Я очень люблю свою семью.')]
            for language, source in cases:
                payload = {'model':'freelingo', 'stream':False, 'temperature':0.7,
                           'top_p':0.6, 'top_k':20, 'repeat_penalty':1.05,
                           'max_tokens':160,
                           'messages':[{'role':'user', 'content':
                               f'Translate the following text into {language}. Note that you should only output the translated result without any additional explanation:\n\n{source}'}]}
                result = call_json(f'http://127.0.0.1:{port}/v1/chat/completions', token, payload, timeout=180)
                translated = result['choices'][0]['message']['content'].strip()
                if not translated:
                    raise RuntimeError(f'Empty {language} output')
                if language == 'Russian' and not any('\u0400' <= ch <= '\u052f' for ch in translated):
                    raise RuntimeError('Russian output has no Cyrillic')
                if language == 'Chinese' and not any('\u4e00' <= ch <= '\u9fff' for ch in translated):
                    raise RuntimeError('Chinese output has no Han characters')
                print(f'PASS target={language}: {translated[:140]!r}', flush=True)
        except Exception:
            logfile.seek(0)
            print(logfile.read().decode('utf-8','replace')[-7500:], file=sys.stderr)
            raise
        finally:
            proc.terminate()
            try: proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=8)


def main() -> None:
    if sys.platform != 'darwin' or not SERVER.is_file():
        raise SystemExit('Run on macOS with bundled llama-server from ./build-macos.sh')
    with tempfile.TemporaryDirectory(prefix='freelingo-hy-smoke-') as directory:
        path = Path(directory) / NAME
        download(path)
        test_translation(path)

if __name__ == '__main__':
    main()
