# REA-inspired investigation: DeepL reference -> FreeLingo

**Date:** 2026-10-24. **Scope:** independent behavioral parity on macOS; clean-room. **Tools actually used:** Mach-O file recognition, Info.plist extraction, `strings`, FreeLingo source reading, Python/bash static tests. **REA native-analysis provider:** NOT connected in this session. **macOS GUI E2E:** NOT RUN.

## Evidence inventory

| ID | Finding | Status | Evidence | Limitation |
| --- | --- | --- | --- | --- |
| DL-01 | User-supplied DeepL uses a universal Mach-O executable with arm64 and x86_64 | STATIC_INDICATOR | `file deepl_audit/DeepL` on provided DeepL.zip | Does not imply specific UI behavior |
| DL-02 | DeepL bundle identifies itself as `com.linguee.DeepLCopyTranslator`, version `26.10.12962491689`, min macOS `15.0` | SOURCE_CONFIRMED (bundle metadata) | `Info.plist` in uploaded DeepL.zip | Does not establish actual installed version on host |
| DL-03 | Executable contains `NSPanel` and `_CGEventPostToPid` references | STATIC_INDICATOR | `strings` from uploaded DeepL binary | Presence alone doesn't prove how popup or Replace work |
| DL-04 | Mini translator shows Copy / Edit / Replace | OBSERVED | Screenshots user attached in chat | No timing/focus or API traces |
| FL-01 | FreeLingo implements model download callback followed by SHA-256 verification on background queue | SOURCE_CONFIRMED | `native/ModelWindow.inc`: `didFinishDownloadingToURL`, `FLHashFile` | No direct proof of user's crash cause |
| FL-02 | In source 0.5.4 hash buffer moved to heap and reduced to 64 KiB | SOURCE_CONFIRMED | `native/ModelManager.inc` `FLHashFile` | Revised binary not tested in macOS GUI |
| FL-03 | App has model-size + GGUF signature check, in-app quick popup & Carbon hotkey | SOURCE_CONFIRMED | `native/ModelManager.inc`, `native/main.m` | Behavior in TextEdit/Safari not verified |
| FL-04 | CI 0.5.1 was previously successful | OBSERVED | User's screenshot of GitHub Actions run #3 | Version 0.5.4 not shown as built |

## Priority path: model-download crash (P0 / S1)

1. Exact repro: install new DMG, pick Qwen3 0.6B, download; record UI just before 100%, then crash dialog and `.ips` from `~/Library/Logs/DiagnosticReports/`.
2. Extract actual `.ips` exception, faulting thread and symbolic stack: `python scripts/crash_triage.py /path/to/FreeLingo*.ips` from updated Replica Workbench skill (tool gives **summary**, not verdict). Sanitize user paths before sharing.
3. Match stack with `native/ModelWindow.inc` transitions: download -> temp `.part` -> SHA worker -> completed GGUF -> selected model -> start local `llama-server`.
4. Distinguish competing hypotheses via one test each: worker stack exhaustion (different exception stack), callback race (delegate/main thread), corrupted GGUF (hash mismatch without crash), failed llama-server boot (engine log in user App Support/FreeLingo/Logs).
5. Execute new GitHub macOS CI `tests/smoke_macos.py` with `run_model_smoke` enabled (it tests the bundled engine on 0.6B). A green CI does not prove GUI stability.
6. Acceptance: two complete downloads without crash, 0.6B translation with network disabled, model selection and deletion, Quick popup and Replace in TextEdit with AX permission.

## Feature-specific REA trace requests once native REA is actually connected

- `Cmd+4` **one behavior only**: hotkey trigger -> selected-text capture -> window opening; include function or address evidence and note UNKNOWNs.
- Popup `Replace`: target PID, selection validation, fallback clipboard handling, cancel; produce behavior spec, not proprietary source.
- OCR region capture: determine observed permission prompt and data flow; identify native handler only when decompiler evidence supports it.

## Result

The visible evidence supports a **candidate**, not a confirmed stable FreeLingo release. Exact crash cause UNKNOWN without an `.ips` report. The replacement features in v0.5.4 need an ARM macOS smoke and manual test. Do not publish as fully tested.
