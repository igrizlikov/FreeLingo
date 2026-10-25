#!/usr/bin/env python3
"""Local, privacy-minimizing summary of macOS .ips/.crash reports.

No network. Does not emit usernames, source report paths, UUIDs or raw report body.
Does not infer a root cause; the stack summary is triage evidence only.
"""

import argparse
import json
import re
from pathlib import Path


def _read_json_or_ndjson(raw: str):
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            return obj
    except json.JSONDecodeError:
        pass
    lines = raw.splitlines()
    if len(lines) > 1:
        try:
            header, body = json.loads(lines[0]), json.loads("\n".join(lines[1:]))
            if isinstance(header, dict) and isinstance(body, dict):
                return {**header, **body}
        except json.JSONDecodeError:
            pass
    return None


def _safe_symbol(value):
    text = str(value or "?")
    # Strip complete filesystem paths (which may contain usernames), retain filename only.
    text = re.sub(r"/(?:[^\s/]+/)+([^\s/:]+)", r"\1", text)
    return text[:160]


def _extract_ips(obj):
    exception = obj.get("exception") or {}
    termination = obj.get("termination") or {}
    threads = obj.get("threads") or []
    thread_id = obj.get("faultingThread")
    thread = None
    if isinstance(thread_id, int) and 0 <= thread_id < len(threads):
        thread = threads[thread_id]
    if thread is None:
        thread = next((th for th in threads if th.get("triggered")), None)
    if thread is None:
        thread = {}
    images = obj.get("usedImages") or []
    frames = []
    for frame in thread.get("frames", [])[:8]:
        img_index = frame.get("imageIndex")
        image = "?"
        if isinstance(img_index, int) and 0 <= img_index < len(images):
            image = _safe_symbol(images[img_index].get("name"))
        frames.append({"image": image, "symbol": _safe_symbol(frame.get("symbol") or f"offset:{frame.get('imageOffset','?')}")})
    return {
        "format": "ips",
        "app": _safe_symbol(obj.get("procName") or obj.get("app_name") or "unknown"),
        "version": _safe_symbol(obj.get("bundleInfo", {}).get("CFBundleShortVersionString") or "unknown"),
        "exception": _safe_symbol(exception.get("type") or "unknown"),
        "signal": _safe_symbol(exception.get("signal") or termination.get("namespace") or "unknown"),
        "faulting_thread": thread_id if isinstance(thread_id, int) else "unknown",
        "top_frames": frames,
        "root_cause": "NOT DETERMINED - requires symbolication and a reproducible test",
    }


def _extract_legacy(raw):
    def field(pattern):
        m = re.search(pattern, raw, re.MULTILINE)
        return _safe_symbol(m.group(1).strip()) if m else "unknown"
    ident = field(r"^Process:\s*(.+)$")
    app = ident.split(" [")[0]
    exc = field(r"^Exception Type:\s*(.+)$")
    signal = field(r"^Exception Codes:\s*(.+)$")
    tid = field(r"^Crashed Thread:\s*(\d+)")
    blocks = re.split(r"^Thread \d+ Crashed:\s*$", raw, maxsplit=1, flags=re.MULTILINE)
    frames = []
    if len(blocks) > 1:
        started = False
        for line in blocks[1].splitlines():
            if not line.strip():
                if started:
                    break
                continue
            started = True
            m = re.match(r"\s*\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+(.+)", line)
            if m:
                frames.append({"image": _safe_symbol(m.group(1)), "symbol": _safe_symbol(m.group(2))})
            if len(frames) >= 8:
                break
    return {
        "format": "crash",
        "app": app,
        "version": field(r"^Version:\s*(.+)$"),
        "exception": exc,
        "signal": signal,
        "faulting_thread": tid,
        "top_frames": frames,
        "root_cause": "NOT DETERMINED - requires symbolication and a reproducible test",
    }


def summarize(raw):
    obj = _read_json_or_ndjson(raw)
    return _extract_ips(obj) if obj else _extract_legacy(raw)


def main():
    parser = argparse.ArgumentParser(description="Summarize local macOS crash reports without leaking file paths")
    parser.add_argument("report", type=Path, help="path to .ips or .crash (read-only)")
    parser.add_argument("--json", action="store_true", help="output structured JSON")
    args = parser.parse_args()
    if args.report.stat().st_size > 30_000_000:
        parser.error("report too large (>30 MB)")
    result = summarize(args.report.read_text(encoding="utf-8", errors="replace"))
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        for key in ["format", "app", "version", "exception", "signal", "faulting_thread", "root_cause"]:
            print(f"{key}: {result[key]}")
        print("top_frames:")
        for frame in result["top_frames"]:
            print(f"  - {frame['image']}: {frame['symbol']}")


if __name__ == "__main__":
    main()
