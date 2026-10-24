#!/usr/bin/env python3
"""Opt-in CI smoke on a real macOS runner: download model, verify and translate.
No model is shipped inside the DMG. Never send text to a cloud inference API.
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
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "dist/FreeLingo.app/Contents/MacOS/llama-server"
URL = "https://huggingface.co/QuantFactory/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B.Q4_K_M.gguf"
SHA256 = "7af3fdf842f87b24672f8a7f1dd50404043f0bfb71093ff91c31d2b49df4631d"


def get_json(url, token, data=None, timeout=10):
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
    req = urllib.request.Request(url, headers=headers, data=json.dumps(data).encode() if data else None)
    with urllib.request.urlopen(req, timeout=timeout) as f:
        return json.loads(f.read().decode("utf-8"))


def test_inference(path: Path):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    token = "smoke-" + os.urandom(12).hex()
    command = [str(SERVER), "--model", str(path), "--host", "127.0.0.1", "--port", str(port),
               "--ctx-size", "2048", "--n-gpu-layers", "0", "--no-webui", "--alias", "freelingo",
               "--api-key", token]
    print("Starting bundled llama-server with CPU fallback...", flush=True)
    with tempfile.TemporaryFile() as log:
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        try:
            health = f"http://127.0.0.1:{port}/health"
            deadline = time.monotonic() + 180
            last_error = ""
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError(f"llama-server exited with code {proc.returncode}")
                try:
                    if get_json(health, token).get("status") == "ok":
                        break
                except (urllib.error.URLError, ValueError, OSError) as exc:
                    last_error = str(exc)
                time.sleep(0.8)
            else:
                raise RuntimeError("model did not become healthy in time: " + last_error)
            result = get_json(f"http://127.0.0.1:{port}/v1/chat/completions", token, {
                "model": "freelingo", "stream": False, "temperature": 0.1, "max_tokens": 96,
                "chat_template_kwargs": {"enable_thinking": False},
                "messages": [
                    {"role": "system", "content": "Translate to Russian. Reply ONLY with the translation. /no_think"},
                    {"role": "user", "content": "Hello!"},
                ],
            }, timeout=150)
            text = result["choices"][0]["message"]["content"]
            if not isinstance(text, str) or not text.strip():
                raise RuntimeError("Model returned no text")
            print("PASS: local inference response:", repr(text[:120]), flush=True)
        except Exception:
            log.seek(0)
            print("llama-server output (tail):", log.read().decode("utf-8", "replace")[-6000:], file=sys.stderr)
            raise
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)


def main():
    if sys.platform != "darwin" or not SERVER.is_file():
        raise RuntimeError("Requires a macOS CI build and bundled llama-server")
    with tempfile.TemporaryDirectory(prefix="freelingo-smoke-") as directory:
        path = Path(directory) / "Qwen3-0.6B.Q4_K_M.gguf"
        print("Downloading test GGUF model (484 MB)...", flush=True)
        h = hashlib.sha256()
        request = urllib.request.Request(URL, headers={"User-Agent": "FreeLingo-CI/0.5.4"})
        with urllib.request.urlopen(request, timeout=120) as source, path.open("wb") as target:
            while chunk := source.read(4 * 1024 * 1024):
                h.update(chunk)
                target.write(chunk)
        if h.hexdigest() != SHA256:
            raise RuntimeError("SHA-256 mismatch for downloaded smoke-test model")
        with path.open("rb") as file:
            if file.read(4) != b"GGUF":
                raise RuntimeError("Model is not a GGUF file")
        print("PASS: official GGUF SHA-256 verified", flush=True)
        test_inference(path)


if __name__ == "__main__":
    main()
