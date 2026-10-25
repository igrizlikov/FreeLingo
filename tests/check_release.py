"""Static offline release checks; run with `python3 tests/check_release.py`."""
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
model = (root / 'native' / 'ModelManager.inc').read_text()
main = (root / 'native' / 'main.m').read_text()
ui = (root / 'native' / 'ModelWindow.inc').read_text()
core = (root / 'src' / 'lib.rs').read_text()

assert model.count('"sha256"') == 8, 'wrong number of model entries'
sha = re.findall(r'@"sha256": @"([a-f0-9]{64})"', model)
urls = re.findall(r'@"url": @"(https://huggingface\.co/[^\"]+)"', model)
assert len(sha) == len(urls) == model.count('@"minBytes":') == 8
assert len(set(sha)) == 8
for part in ('qwen3-0.6b', 'qwen3-1.7b', 'qwen3-4b', 'qwen3-8b', 'hy-mt2-7b', 'hy-mt2-1.8b'):
    assert part in model
assert 'CC_SHA256_Update' in model
assert 'malloc(64 * 1024)' in model and 'free(buffer);' in model, 'stack-overflow regression'
assert 'memcmp(magic.bytes, "GGUF", 4)' in model, 'incomplete model regression'
assert 'unsigned long long minimumBytes = ' in model, 'model-specific size validation regression'
assert '[@"minBytes"] longLongValue]' in model, 'NSString minBytes must use longLongValue'
assert '[@"minBytes"] unsignedLongLongValue]' not in model, 'NSString has no unsignedLongLongValue selector'
assert 'task != self->_modelTask || self->_verifyingModel' in ui, 'download event race regression'
assert 'if (session != self->_modelSession || !self->_verifyingModel) return;' in ui
assert (root / 'tests' / 'smoke_macos.py').exists()
assert 'NSURLSessionDownloadTask' in ui
assert 'modelDownloadFinished' in ui
assert '@"Заменить"' in main
assert '#include "ModelWindow.inc"' in main
assert '127.0.0.1' in core and 'Authorization: Bearer' in core
assert '--no-webui' in core
assert 'Ollama' not in core
assert 'hdiutil create' in (root / 'build-macos.sh').read_text()
assert (root / '.github/workflows/build-dmg.yml').exists()
ET.parse(root / 'assets/Info.plist')
subprocess.run(['bash', '-n', str(root / 'build-macos.sh')], check=True)
subprocess.run(['python3', str(root / 'tests' / 'test_dmg_retry.py')], check=True)
print('OK: model hashes, GGUF validation, heap SHA, URLSession race guards, Rust API, DMG workflow, plist and shell syntax')

# v0.6: menu-bar app mode and first-party login-item registration.
assert 'NSApplicationActivationPolicyAccessory' in main
assert 'setActivationPolicy:policy' in main
assert 'SMAppService.mainAppService' in main and 'registerAndReturnError:' in main
assert 'unregisterAndReturnError:' in main
assert '[self loginItemEnabled]' in main
assert 'statusIcon.template = YES' in main
assert (root / 'assets' / 'MenubarIcon-72.png').is_file()
assert 'SPUStandardUpdaterController' in main
assert 'SPARKLE_PUBLIC_ED_KEY' in (root / 'build-macos.sh').read_text()
assert (root / '.github/workflows/release.yml').is_file()
subprocess.run(['python3', str(root / 'tests' / 'test_appcast.py')], check=True)
print('OK: menu-bar icon, Dock toggle, Login Items, updater and signed appcast tooling')

# v0.6.1: real popup editing and prompt / response quality improvements.
assert 'FLEditor(&_resultEditor, YES)' in main, 'main translation result must be editable'
assert '_quickEditor.delegate = self' in main
assert '- (void)textDidChange:(NSNotification *)notification' in main
assert '[_quickPanel makeFirstResponder:_quickEditor]' in main
assert 'finishQuickEditing' in main
assert 'split_long_line(body, 1100)' in core
assert 'quality_issue(source, &result, translation_target(target))' in core
assert '"enable_thinking": false' in core
assert 'Qwen3-8B-Q4_K_M.gguf' in model
assert 'd98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785' in model
print('OK: edit in popup, content checks, splitting and Qwen3 8B catalog')

# v0.6.3: editor hardening and stricter translation instructions.
import plistlib
plist = plistlib.loads((root / 'assets' / 'Info.plist').read_bytes())
assert plist['CFBundleShortVersionString'] == '0.6.14'
assert int(plist['CFBundleVersion']) == 24
assert '_quickEditTransitioning' in main
assert '_quickPanel makeFirstResponder:_quickEditButton' in main
assert 'quality_issue(source, &result, translation_target(target))' in core
assert '--ctx-size", "6144"' in core
print('OK: version, editor reentrancy guards and translation quality checks')

# v0.6.4: target-specific translator modes and model integrity.
for expected in (
    "9f96256500f3fc1ab4d64336b58f52a949a95ad7516b0c229476eef782f9f77b",
    "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699",
    "hy-mt2-7b", "hy-mt2-1.8b", "minBytes",
):
    assert expected in model, expected
assert 'hy_mt2_prompt(' in core and 'hy_mt2_model(' in core
assert '"repeat_penalty": 1.05' in core and '"top_k": 20' in core
assert '"--jinja"' in core
assert 'SUPublicEDKey' in (root/'assets/Info.plist').read_text()
print('OK: Hy-MT2 models, sources, sha256 hashes, model-specific prompt/sampling and Sparkle')

assert (root / 'tests' / 'smoke_hy_macos.py').is_file()
print('OK: offline Hy-MT2 macOS smoke test included (not executed on Linux)')

# 0.6.5: native idiomatic Russian preset through official Hy-MT2 style templates.
assert 'naturalRussianTranslation' in main
assert 'toggleNaturalTranslation:' in main
assert 'translate_natural' in core and 'translate_natural' in main
assert 'translation style must strictly conform' in core
assert 'natural_style_uses_official_hy_style_template' in core
print('OK: opt-in A/B comparison between natural and standard Russian translation')

# v0.6.6: a two-stage editor with source fidelity and opt-in persistent signing.
assert 'literaryRussianReview' in main
assert 'translate_reviewed' in main and 'translate_reviewed' in core
assert 'polish_document(' in core and 'russian_editor_model(' in core
assert 'SIGNING_IDENTITY' in (root / 'build-macos.sh').read_text()
assert 'REQUIRE_STABLE_SIGNING' in (root / 'build-macos.sh').read_text()
print('OK: source-aware postediting mode and optional persistent code signing')

# v0.6.7: explicit comparison, no fabricated model-quality ranking and
# postedit diagnostics that never include the source or translated text.
assert 'translategemma-4b' in model
assert '526747309109c016db547c6fc1c7b0c9c286b5e7a7556827b5419fd9543a09cd' in model
assert 'translate_gemma_model' in core and 'source_lang_code' in core and 'target_lang_code' in core
assert 'translation-diagnostics.log' in core and 'polish_document(' in core
assert 'Сравнить Hy-MT2 и TranslateGemma' in main
assert 'FLSourceLanguage(' in main and 'NLLanguageRecognizer' in main
assert (root/'replica/quality_cases.json').exists()
assert (root/'tests/translation_ab_macos.py').exists()
print('OK: TranslateGemma 4B, explicit language routing, privacy-safe diagnostics, A/B UI, multilingual corpus')

# v0.6.8: only two items in status menu and four-tab preferences.
status_menu = main.split('- (void)createStatusMenu {', 1)[1].split('- (void)openTranslationDiagnostics:', 1)[0]
assert status_menu.count('[menu addItem:') == 2, 'menu bar icon must have only Settings and Quit'
assert 'initWithTitle:@"Настройки…"' in status_menu and 'initWithTitle:@"Завершить FreeLingo"' in status_menu
for action in ('Перевести выделение', 'Перевести буфер обмена', 'Текст с экрана', 'Естественный русский перевод',
               'Литературная вычитка', 'Выбрать и скачать модель', 'Сравнить Hy-MT2', 'Открыть журнал перевода',
               'Показывать значок в Dock', 'Запускать при входе', 'Проверить обновления'):
    assert ('initWithTitle:@"' + action) not in status_menu, f'extraneous status menu entry {action}'
assert 'NSTabView' in main and 'settingsGeneralTab' in main and 'settingsTranslationTab' in main
assert 'settingsShortcutsTab' in main and 'settingsActionsTab' in main
assert 'settingsCheckboxChanged:' in main and 'settingsShortcutChanged:' in main
assert 'registerGlobalHotkeys];' in main and 'checkForUpdates:' in main and 'compareTranslations:' in main
print('OK: compact status menu, functional native settings tabs and preserved actions')

# v0.6.9: same whole-document translation engine for short texts, prevent window
# lifetime use-after-close; retain user-selected translator across Sparkle updates.
assert 'length <= latin_limit && (!has_cjk(source) || length <= 1300)' in core
assert 'source.len() <= 5200' in core
assert 'if translate_gemma_12b_model(model) { 3600 } else { 3000 }' in core
assert 'short_specialized_document' in core and '"whole"' in core and '"chunked"' in core
assert '_mainWindow.releasedWhenClosed = NO' in main
assert '_settingsWindow.releasedWhenClosed = NO' in main
assert '_quickPanel.releasedWhenClosed = NO' in main
assert '_comparisonWindow.releasedWhenClosed = NO' in main
assert '@"modelID": @"translategemma-4b"' in main
assert 'NSString *effectiveMode = natural ? @"translate_natural" : @"translate";' in main
assert 'FreeLingo.UI settings_open:begin' in main
print('OK: v0.6.9 context consistency, explicit window retention and UI lifecycle markers')

# v0.6.10: plain-text paste, accessible Clear button and no stale results.
assert '@interface FLPlainTextView : NSTextView' in main
assert '[self pasteAsPlainText:sender];' in main
assert 'text.richText = NO;' in main and 'text.importsGraphics = NO;' in main
assert 'FLPlainTextView *text = [[FLPlainTextView alloc]' in main
assert 'FLButton(@"Очистить", self, @selector(clearMain:))' in main
assert 'if (job.generation != _mainGeneration) return;' in main
assert 'job.generation = quick ? ++_quickGeneration : ++_mainGeneration;' in main
assert '++_mainGeneration; // Ignore results' in main
print('OK: v0.6.10 plain-text editors, one-click clear and stale-result guard')

# 0.6.11: private request correlation across main/hotkey/A-B.
assert 'void fl_work_async_diagnostic(' in (root/'native/FreeLingoCore.h').read_text()
assert main.count('fl_work_async_diagnostic(') == 2
assert 'origin:@"hotkey"' in main and 'origin:@"ocr"' in main and 'origin:@"clipboard"' in main
assert '"ab",' in main and '_comparisonSourceCode' in main
for field in ('request_id=', 'origin=', 'source_hash=', 'raw_hash=', 'pair=', 'source_lang=', 'target_lang=', 'operation=', 'chunks=', 'temperature=', 'top_p=', 'top_k=', 'repeat_penalty=', 'max_tokens=', 'result_hash='):
    assert field in core, field
assert 'TRACE_HASHER.get_or_init(RandomState::new)' in core
assert 'origin.UTF8String' in main
print('OK: v0.6.11 keyed session fingerprints, provenance, parameter and layout tracing')

# v0.6.12: preserve paragraphs from third-party selections and 12B A/B.
assert 'FLWithoutWhitespace' in main and 'FLPasteboardSnapshot' in main
assert 'FLSendCopyShortcut' in main and 'captureParagraphsAndTranslate:' in main
assert 'hotkey_clipboard' in main and 'hotkey_clipboard' in core
assert 'sameContent && pb.changeCount == afterCopyChangeCount' in main
assert 'FLWithoutWhitespace(_originSelection)' in main
assert 'content_hash=' in core
assert 'translategemma-12b-it-Q4_K_M.gguf' in model
assert '9196d728812afbf5efc10b539298585725edc3a4ecc092c22fdde5bbaf41879e' in model
assert '_comparisonModels' in main and '@"translategemma-12b"' in main
assert 'if (![downloadedID isEqualToString:@"translategemma-12b"])' in ui
assert 'trace_session()' in core
print('OK: v0.6.12 paragraph-preserving clipboard probe, safe replacement, content hash, TranslateGemma 12B')

# v0.6.13: short-fragment source override and both TranslateGemma generations.
assert 'FLSourceLanguageNames' in main and 'FLResolvedSourceLanguage' in main
assert '_mainSourceLanguage' in main and '_quickSourceLanguage' in main
assert 'quickSourceLanguageChanged:' in main and 'sourceLanguage = FLResolvedSourceLanguage' in main
assert '[activeModelID hasPrefix:@"translategemma-"]' in main
assert '[FLModels()[(NSUInteger)modelIndex][@"id"] isEqualToString:@"translategemma-4b"]' not in main
assert '_comparisonSourceCode = FLResolvedSourceLanguage(text, _mainSourceLanguage)' in main
print('OK: v0.6.13 explicit source language in main and popup, both Gemma sizes')
