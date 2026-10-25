from pathlib import Path
s=Path(__file__).resolve().parents[1].joinpath('native/main.m').read_text()
menu=s.split('- (void)createStatusMenu {',1)[1].split('- (void)openTranslationDiagnostics:',1)[0]
assert menu.count('[menu addItem:') == 2
assert '[menu addItem:settings]' in menu and '[menu addItem:quit]' in menu
assert '_statusItem.menu = menu' in menu
settings=s.split('- (void)settingsCheckboxChanged:',1)[1].split('- (void)presentMessage:',1)[0]
for method in ('showModels:', 'checkForUpdates:', 'compareTranslations:', 'openTranslationDiagnostics:', 'showMain:', 'translateClipboard:', 'startOCR:', 'translateSelectionFromSettings:'):
    assert method in settings, method
for setting in ('showDockIcon','naturalRussianTranslation','literaryRussianReview'):
    assert f'[defaults setBool:enabled forKey:@"{setting}"]' in settings, setting
assert 'FLShortcutSetting((unsigned)sender.tag)' in settings
assert 'registerGlobalHotkeys];' in settings
assert 'if (!_settingsWindow)' in settings
print('OK: minimal 2-item status menu, complete action and preference wiring')
