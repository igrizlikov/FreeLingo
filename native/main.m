// FreeLingo: native macOS AppKit shell. Translation engine is the Rust static library.
// Independent implementation; does not embed DeepL code, resources or services.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Vision/Vision.h>
#import <dispatch/dispatch.h>
#import <CommonCrypto/CommonDigest.h>
#include "ModelManager.inc"
#import "FreeLingoCore.h"

static NSArray<NSString *> *FLLanguageNames(void) {
    return @[@"Русский", @"English (US)", @"Suomi", @"Deutsch", @"Français", @"Español", @"Italiano", @"日本語", @"中文"];
}
static NSArray<NSArray<NSString *> *> *FLShortcutLabels(void) {
    return @[
        @[@"⌘4", @"⌥⌘4", @"⌘1", @"⌃⌥T"],
        @[@"⌃⌘C", @"⇧⌘C", @"⌥⌘W", @"⌃⌥R"],
        @[@"⇧⌘2", @"⌥⌘2", @"⌃⌥O", @"⇧⌘5"]
    ];
}
// The four presets per action are deliberately distinct, to minimize conflicts.
static void FLShortcutFor(unsigned action, NSInteger choice, UInt32 *key, UInt32 *mods) {
    static const UInt32 keys[3][4] = { {21,21,18,17}, {8,8,13,15}, {19,19,31,23} };
    static const UInt32 flags[3][4] = {
        {cmdKey, cmdKey|optionKey, cmdKey, controlKey|optionKey},
        {controlKey|cmdKey, shiftKey|cmdKey, optionKey|cmdKey, controlKey|optionKey},
        {shiftKey|cmdKey, optionKey|cmdKey, controlKey|optionKey, shiftKey|cmdKey}
    };
    unsigned i = (unsigned)MAX(0, MIN(choice, 3));
    *key = keys[action][i];
    *mods = flags[action][i];
}
static NSString *FLShortcutSetting(unsigned action) {
    return @[@"translateShortcut", @"rewriteShortcut", @"ocrShortcut"][action];
}
static NSArray<NSString *> *FLLanguageCodes(void) {
    return @[@"ru", @"en", @"fi", @"de", @"fr", @"es", @"it", @"ja", @"zh"];
}
static NSString *FLSelectedLanguage(NSPopUpButton *picker) {
    NSInteger idx = picker.indexOfSelectedItem;
    return (idx >= 0 && idx < (NSInteger)FLLanguageCodes().count) ? FLLanguageCodes()[(NSUInteger)idx] : @"ru";
}
static NSButton *FLButton(NSString *title, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.bezelStyle = NSBezelStyleRounded;
    return b;
}
static NSTextField *FLLabel(NSString *s, CGFloat size) {
    NSTextField *t = [NSTextField labelWithString:s];
    t.font = [NSFont systemFontOfSize:size];
    t.textColor = NSColor.secondaryLabelColor;
    return t;
}
static NSScrollView *FLEditor(NSTextView **out, BOOL editable) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.autohidesScrollers = YES;
    NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    text.minSize = NSMakeSize(0, 200);
    text.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    text.verticallyResizable = YES;
    text.horizontallyResizable = NO;
    text.autoresizingMask = NSViewWidthSizable;
    text.textContainer.widthTracksTextView = YES;
    text.textContainerInset = NSMakeSize(14, 14);
    text.editable = editable;
    text.selectable = YES;
    text.font = [NSFont systemFontOfSize:16];
    text.backgroundColor = [NSColor colorWithCalibratedWhite:0.155 alpha:1.0];
    scroll.documentView = text;
    if (out) *out = text;
    return scroll;
}

@class FLAppDelegate;
@interface FLJob : NSObject
@property (nonatomic, weak) FLAppDelegate *controller;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSString *mode;
@property (nonatomic, assign) BOOL quick;
@property (nonatomic, assign) NSUInteger generation;
@end
@implementation FLJob
@end

@interface FLAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSURLSessionDownloadDelegate>
- (void)hotkey:(UInt32)identifier;
- (void)translationFinished:(NSString *)result success:(BOOL)ok job:(FLJob *)job;
@end

static OSStatus FLHotkeyHandler(EventHandlerCallRef _unused, EventRef event, void *userData) {
    (void)_unused;
    EventHotKeyID hk = {0};
    OSStatus err = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                     NULL, sizeof(hk), NULL, &hk);
    if (err != noErr) return eventNotHandledErr;
    FLAppDelegate *controller = (__bridge FLAppDelegate *)userData;
    dispatch_async(dispatch_get_main_queue(), ^{ [controller hotkey:hk.id]; });
    return noErr;
}

static void FLRustCallback(char *raw, int success, void *context) {
    FLJob *job = (__bridge_transfer FLJob *)context;
    NSString *answer = raw ? [NSString stringWithUTF8String:raw] : @"Ошибка обработки";
    if (raw) fl_free_string(raw);
    if (!answer) answer = @"Ошибка кодировки";
    dispatch_async(dispatch_get_main_queue(), ^{
        [job.controller translationFinished:answer success:(success != 0) job:job];
    });
}

@implementation FLAppDelegate {
    NSWindow *_mainWindow;
    NSPanel *_quickPanel;
    NSStatusItem *_statusItem;
    NSTextView *_sourceEditor;
    NSTextView *_resultEditor;
    NSTextView *_quickEditor;
    NSSegmentedControl *_tabs;
    NSPopUpButton *_mainLanguage;
    NSPopUpButton *_quickLanguage;
    NSButton *_replaceButton;
    NSButton *_workButton;
    NSTextField *_statusLabel;
    NSString *_currentQuickSource;
    NSString *_currentQuickResult;
    NSString *_currentQuickMode;
    pid_t _originPID;
    AXUIElementRef _originElement;
    NSString *_originSelection;
    BOOL _lastTranslationOK;
    NSUInteger _quickGeneration;
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *_sessionHistory;
    EventHotKeyRef _translateHotkey;
    EventHotKeyRef _rewriteHotkey;
    EventHotKeyRef _ocrHotkey;
    EventHandlerRef _hotkeyHandler;
    NSWindow *_modelsWindow;
    NSPopUpButton *_modelPicker;
    NSTextField *_modelStatus;
    NSProgressIndicator *_modelProgress;
    NSButton *_modelDownload;
    NSButton *_modelUse;
    NSButton *_modelRemove;
    NSButton *_modelCancel;
    NSURLSession *_modelSession;
    NSURLSessionDownloadTask *_modelTask;
    NSInteger _downloadingModelIndex;
    BOOL _verifyingModel;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    _sessionHistory = [NSMutableArray new];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{ @"modelID": @"qwen3-1.7b", @"languageIndex": @0 }];
    [self createApplicationMenu];
    [self createMainWindow];
    [self createQuickPanel];
    [self createStatusMenu];
    [self createModelsWindow];
    [self registerGlobalHotkeys];
    [_mainWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (![self hasActiveModel]) [self showModels:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO; // Menu-bar icon and global shortcuts remain available.
}

- (void)applicationWillTerminate:(NSNotification *)n {
    (void)n;
    if (_translateHotkey) UnregisterEventHotKey(_translateHotkey);
    if (_rewriteHotkey) UnregisterEventHotKey(_rewriteHotkey);
    if (_ocrHotkey) UnregisterEventHotKey(_ocrHotkey);
    if (_hotkeyHandler) RemoveEventHandler(_hotkeyHandler);
    if (_originElement) { CFRelease(_originElement); _originElement = NULL; }
    [_modelTask cancel];
    [_modelSession invalidateAndCancel];
    fl_shutdown();
}

- (void)createApplicationMenu {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [bar addItem:appItem];
    NSMenu *application = [[NSMenu alloc] initWithTitle:@"FreeLingo"];
    appItem.submenu = application;
    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Настройки FreeLingo…" action:@selector(showSettings:) keyEquivalent:@","];
    settings.target = self;
    [application addItem:settings];
    NSMenuItem *models = [[NSMenuItem alloc] initWithTitle:@"Модели перевода…" action:@selector(showModels:) keyEquivalent:@"m"];
    models.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    models.target = self;
    [application addItem:models];
    [application addItem:NSMenuItem.separatorItem];
    [application addItemWithTitle:@"Скрыть FreeLingo" action:@selector(hide:) keyEquivalent:@"h"];
    [application addItemWithTitle:@"Завершить FreeLingo" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenuItem *editItem = [NSMenuItem new];
    [bar addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Правка"];
    editItem.submenu = edit;
    [edit addItemWithTitle:@"Отменить" action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:@"Повторить" action:@selector(redo:) keyEquivalent:@"Z"];
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:@"Вырезать" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Копировать" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Вставить" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Выделить всё" action:@selector(selectAll:) keyEquivalent:@"a"];
    [NSApp setMainMenu:bar];
}

- (void)createMainWindow {
    _mainWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1020, 660)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                   NSWindowStyleMaskMiniaturizable)
        backing:NSBackingStoreBuffered defer:NO];
    _mainWindow.title = @"FreeLingo";
    _mainWindow.minSize = NSMakeSize(700, 440);
    _mainWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [_mainWindow center];
    NSView *root = _mainWindow.contentView;
    root.wantsLayer = YES;
    root.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.14 alpha:1].CGColor;

    _tabs = [NSSegmentedControl segmentedControlWithLabels:@[@"Перевести текст", @"Улучшить текст", @"Перевести файлы", @"История"]
           trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(tabChanged:)];
    _tabs.selectedSegment = 0;
    _tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_tabs];

    _mainLanguage = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_mainLanguage addItemsWithTitles:FLLanguageNames()];
    _mainLanguage.translatesAutoresizingMaskIntoConstraints = NO;
    NSInteger savedIndex = [NSUserDefaults.standardUserDefaults integerForKey:@"languageIndex"];
    [_mainLanguage selectItemAtIndex:MAX(0, MIN(savedIndex, (NSInteger)FLLanguageNames().count - 1))];
    _mainLanguage.target = self;
    _mainLanguage.action = @selector(languageChanged:);
    [root addSubview:_mainLanguage];

    NSTextField *languageLabel = FLLabel(@"Язык перевода:", 13);
    languageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:languageLabel];

    NSScrollView *source = FLEditor(&_sourceEditor, YES);
    NSScrollView *result = FLEditor(&_resultEditor, NO);
    _sourceEditor.string = @"";
    _resultEditor.string = @"";
    NSStackView *columns = [NSStackView stackViewWithViews:@[source, result]];
    columns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    columns.distribution = NSStackViewDistributionFillEqually;
    columns.spacing = 10;
    columns.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:columns];

    _workButton = FLButton(@"Перевести", self, @selector(translateMain:));
    NSButton *copyButton = FLButton(@"Копировать результат", self, @selector(copyMain:));
    NSButton *saveButton = FLButton(@"Сохранить TXT", self, @selector(saveText:));
    NSButton *settingsButton = FLButton(@"Настройки", self, @selector(showSettings:));
    NSButton *modelsButton = FLButton(@"Модели…", self, @selector(showModels:));
    _statusLabel = FLLabel(@"Офлайн · ⌘4 · ⇧⌘2", 12);
    NSStackView *bottom = [NSStackView stackViewWithViews:@[_workButton, copyButton, saveButton, modelsButton, settingsButton, _statusLabel]];
    bottom.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottom.spacing = 10;
    bottom.alignment = NSLayoutAttributeCenterY;
    bottom.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:bottom];

    [NSLayoutConstraint activateConstraints:@[
        [_tabs.topAnchor constraintEqualToAnchor:root.topAnchor constant:18],
        [_tabs.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [languageLabel.topAnchor constraintEqualToAnchor:_tabs.bottomAnchor constant:20],
        [languageLabel.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [_mainLanguage.centerYAnchor constraintEqualToAnchor:languageLabel.centerYAnchor],
        [_mainLanguage.leadingAnchor constraintEqualToAnchor:languageLabel.trailingAnchor constant:12],
        [columns.topAnchor constraintEqualToAnchor:languageLabel.bottomAnchor constant:16],
        [columns.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [columns.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [columns.bottomAnchor constraintEqualToAnchor:bottom.topAnchor constant:-16],
        [bottom.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [bottom.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-12],
        [bottom.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-20],
    ]];
}

- (void)createQuickPanel {
    _quickPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 540, 370)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow)
        backing:NSBackingStoreBuffered defer:NO];
    _quickPanel.title = @"FreeLingo — быстрый перевод";
    _quickPanel.floatingPanel = YES;
    _quickPanel.hidesOnDeactivate = NO;
    _quickPanel.level = NSFloatingWindowLevel;
    _quickPanel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _quickPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSView *root = _quickPanel.contentView;
    _quickLanguage = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_quickLanguage addItemsWithTitles:FLLanguageNames()];
    [_quickLanguage selectItemAtIndex:_mainLanguage.indexOfSelectedItem];
    _quickLanguage.target = self;
    _quickLanguage.action = @selector(quickLanguageChanged:);
    _quickLanguage.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_quickLanguage];
    NSButton *dismiss = FLButton(@"Закрыть", self, @selector(dismissQuick:));
    dismiss.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:dismiss];
    NSScrollView *scroll = FLEditor(&_quickEditor, NO);
    _quickEditor.font = [NSFont systemFontOfSize:20];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];
    NSButton *copy = FLButton(@"Копировать", self, @selector(copyQuick:));
    NSButton *edit = FLButton(@"Редактировать…", self, @selector(editQuick:));
    _replaceButton = FLButton(@"Заменить", self, @selector(replaceSelection:));
    NSStackView *actions = [NSStackView stackViewWithViews:@[copy, edit, _replaceButton]];
    actions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actions.spacing = 12;
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:actions];
    [NSLayoutConstraint activateConstraints:@[
        [_quickLanguage.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [_quickLanguage.topAnchor constraintEqualToAnchor:root.topAnchor constant:17],
        [dismiss.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [dismiss.centerYAnchor constraintEqualToAnchor:_quickLanguage.centerYAnchor],
        [scroll.topAnchor constraintEqualToAnchor:_quickLanguage.bottomAnchor constant:16],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [scroll.bottomAnchor constraintEqualToAnchor:actions.topAnchor constant:-15],
        [actions.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [actions.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-18],
    ]];
}

- (void)createStatusMenu {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.title = @"文";
    _statusItem.button.toolTip = @"FreeLingo — локальный переводчик";
    NSMenu *menu = [NSMenu new];
    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Открыть FreeLingo" action:@selector(showMain:) keyEquivalent:@""];
    open.target = self; [menu addItem:open];
    NSMenuItem *translate = [[NSMenuItem alloc] initWithTitle:@"Перевести выделение  ⌘4" action:@selector(translateSelectionMenu:) keyEquivalent:@""];
    translate.target = self; [menu addItem:translate];
    NSMenuItem *clipboard = [[NSMenuItem alloc] initWithTitle:@"Перевести буфер обмена" action:@selector(translateClipboard:) keyEquivalent:@""];
    clipboard.target = self; [menu addItem:clipboard];
    NSMenuItem *ocr = [[NSMenuItem alloc] initWithTitle:@"Текст с экрана  ⇧⌘2" action:@selector(startOCR:) keyEquivalent:@""];
    ocr.target = self; [menu addItem:ocr];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *models = [[NSMenuItem alloc] initWithTitle:@"Выбрать и скачать модель…" action:@selector(showModels:) keyEquivalent:@""];
    models.target = self; [menu addItem:models];
    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Настройки…" action:@selector(showSettings:) keyEquivalent:@""];
    settings.target = self; [menu addItem:settings];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Завершить FreeLingo" action:@selector(terminate:) keyEquivalent:@""];
    [menu addItem:quit];
    _statusItem.menu = menu;
}

- (void)registerGlobalHotkeys {
    if (!_hotkeyHandler) {
        EventTypeSpec eventType = { kEventClassKeyboard, kEventHotKeyPressed };
        InstallApplicationEventHandler(FLHotkeyHandler, 1, &eventType, (__bridge void *)self, &_hotkeyHandler);
    }
    EventHotKeyRef *refs[3] = {&_translateHotkey, &_rewriteHotkey, &_ocrHotkey};
    BOOL failed = NO;
    for (unsigned i = 0; i < 3; ++i) {
        if (*refs[i]) { UnregisterEventHotKey(*refs[i]); *refs[i] = NULL; }
        UInt32 key = 0, mods = 0;
        FLShortcutFor(i, [NSUserDefaults.standardUserDefaults integerForKey:FLShortcutSetting(i)], &key, &mods);
        OSStatus status = RegisterEventHotKey(key, mods, (EventHotKeyID){'FRLG', i+1},
                                              GetApplicationEventTarget(), 0, refs[i]);
        if (status != noErr) failed = YES;
    }
    if (failed) _statusLabel.stringValue = @"Конфликт горячих клавиш: закрой DeepL или выбери другие сочетания в настройках.";
}

- (void)hotkey:(UInt32)identifier {
    if (identifier == 3) { [self startOCR:nil]; return; }
    [self translateSelectedTextWithMode:(identifier == 2 ? @"rewrite" : @"translate")];
}
- (void)translateSelectionMenu:(id)sender { (void)sender; [self translateSelectedTextWithMode:@"translate"]; }

- (void)forgetSelection {
    if (_originElement) { CFRelease(_originElement); _originElement = NULL; }
    _originPID = 0;
    _originSelection = nil;
}

- (NSString *)captureFrontSelection {
    [self forgetSelection];
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!front || front.processIdentifier == NSProcessInfo.processInfo.processIdentifier) return nil;
    _originPID = front.processIdentifier;
    AXUIElementRef app = AXUIElementCreateApplication(_originPID);
    CFTypeRef focused = NULL;
    AXError err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused);
    CFRelease(app);
    if (err != kAXErrorSuccess || !focused) return nil;
    AXUIElementRef field = (AXUIElementRef)focused;
    CFTypeRef selected = NULL;
    err = AXUIElementCopyAttributeValue(field, kAXSelectedTextAttribute, &selected);
    if (err != kAXErrorSuccess || !selected || CFGetTypeID(selected) != CFStringGetTypeID()) {
        if (selected) CFRelease(selected);
        CFRelease(field);
        return nil;
    }
    NSString *value = [(__bridge NSString *)selected copy];
    CFRelease(selected);
    if (!value.length) { CFRelease(field); return nil; }
    _originElement = field; // retain from CopyAttributeValue, released in forgetSelection.
    _originSelection = value;
    return value;
}

- (void)translateSelectedTextWithMode:(NSString *)mode {
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @1})) {
        [self presentMessage:@"Для чтения выделенного текста разреши FreeLingo в настройках macOS → Конфиденциальность и безопасность → Универсальный доступ."];
        return;
    }
    NSString *source = [self captureFrontSelection];
    if (!source.length) {
        [self presentMessage:@"Приложение не предоставило выделенный текст через Accessibility. Выдели текст в TextEdit или скопируй его и выбери «Перевести буфер обмена» в меню FreeLingo."];
        return;
    }
    [self showQuickForText:source mode:mode];
}

- (void)showQuickForText:(NSString *)source mode:(NSString *)mode {
    _currentQuickSource = [source copy];
    _currentQuickResult = @"";
    _currentQuickMode = [mode copy];
    _lastTranslationOK = NO;
    _replaceButton.enabled = NO;
    _quickEditor.string = @"Перевод…";
    [_quickLanguage selectItemAtIndex:_mainLanguage.indexOfSelectedItem];
    NSPoint cursor = NSEvent.mouseLocation;
    NSScreen *screen = [NSScreen screens].firstObject;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSPointInRect(cursor, candidate.frame)) { screen = candidate; break; }
    }
    NSRect visible = screen.visibleFrame;
    CGFloat x = MIN(MAX(cursor.x + 18, NSMinX(visible)), NSMaxX(visible) - _quickPanel.frame.size.width);
    CGFloat y = MIN(MAX(cursor.y - 28 - _quickPanel.frame.size.height, NSMinY(visible)), NSMaxY(visible) - _quickPanel.frame.size.height);
    [_quickPanel setFrameOrigin:NSMakePoint(x, y)];
    [_quickPanel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self request:source mode:mode quick:YES language:FLSelectedLanguage(_quickLanguage)];
}

- (void)request:(NSString *)text mode:(NSString *)mode quick:(BOOL)quick language:(NSString *)language {
    if (!text.length) return;
    NSInteger modelIndex = FLActiveModelIndex();
    if (!FLModelInstalled(modelIndex)) {
        [self showModels:nil];
        [self presentMessage:@"Сначала скачай и выбери модель в разделе «Модели»." ];
        return;
    }
    NSString *model = FLModelURL(modelIndex).path;
    FLJob *job = [FLJob new];
    job.controller = self;
    job.source = text;
    job.mode = mode;
    job.quick = quick;
    job.generation = quick ? ++_quickGeneration : 0;
    if (quick) _quickEditor.string = @"Обрабатываю локальной моделью…";
    else { _resultEditor.string = @"Обрабатываю локальной моделью…"; _workButton.enabled = NO; }
    fl_work_async(text.UTF8String, language.UTF8String, mode.UTF8String, model.UTF8String,
                  FLRustCallback, (__bridge_retained void *)job);
}

- (void)translationFinished:(NSString *)result success:(BOOL)ok job:(FLJob *)job {
    if (job.quick) {
        if (job.generation != _quickGeneration || ![_currentQuickSource isEqualToString:job.source] || ![_currentQuickMode isEqualToString:job.mode]) return;
        _currentQuickResult = ok ? result : @"";
        _quickEditor.string = ok ? result : [@"Ошибка: " stringByAppendingString:result];
        _lastTranslationOK = ok;
        _replaceButton.enabled = ok && (_originElement != NULL) && ([_originSelection isEqualToString:job.source]);
    } else {
        _resultEditor.string = ok ? result : [@"Ошибка: " stringByAppendingString:result];
        _workButton.enabled = YES;
        _statusLabel.stringValue = ok ? @"Перевод выполнен на Mac" : @"Ошибка движка. Открой «Модели» или проверь журнал.";
    }
    if (ok) {
        [_sessionHistory insertObject:@{ @"source": job.source, @"result": result } atIndex:0];
        if (_sessionHistory.count > 50) [_sessionHistory removeLastObject];
    }
}

- (void)translateMain:(id)sender {
    (void)sender;
    NSString *mode = (_tabs.selectedSegment == 1) ? @"rewrite" : @"translate";
    NSString *text = _sourceEditor.string;
    if (!text.length) { [self presentMessage:@"Вставь текст в левое поле."]; return; }
    [self request:text mode:mode quick:NO language:FLSelectedLanguage(_mainLanguage)];
}
- (void)tabChanged:(id)sender {
    (void)sender;
    switch (_tabs.selectedSegment) {
        case 0: _workButton.title = @"Перевести"; break;
        case 1: _workButton.title = @"Улучшить текст"; break;
        case 2: [self openTextFile:nil]; break;
        case 3: {
            NSMutableString *content = [NSMutableString new];
            for (NSDictionary *item in _sessionHistory) {
                [content appendFormat:@"Исходный текст:\n%@\n\nПеревод:\n%@\n\n----------\n\n", item[@"source"], item[@"result"]];
            }
            _resultEditor.string = content.length ? content : @"История текущего запуска пуста. На диск ничего не записывается.";
            break;
        }
        default: break;
    }
}
- (void)languageChanged:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setInteger:_mainLanguage.indexOfSelectedItem forKey:@"languageIndex"];
}
- (void)quickLanguageChanged:(id)sender {
    (void)sender;
    if (_currentQuickSource.length) {
        _currentQuickResult = @"";
        _replaceButton.enabled = NO;
        [self request:_currentQuickSource mode:_currentQuickMode quick:YES language:FLSelectedLanguage(_quickLanguage)];
    }
}
- (void)showMain:(id)sender { (void)sender; [_mainWindow makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
- (void)editQuick:(id)sender {
    (void)sender;
    _sourceEditor.string = _currentQuickSource ?: @"";
    _resultEditor.string = _currentQuickResult ?: @"";
    _tabs.selectedSegment = [_currentQuickMode isEqualToString:@"rewrite"] ? 1 : 0;
    [self tabChanged:nil];
    [_quickPanel orderOut:nil];
    [self showMain:nil];
}
- (void)dismissQuick:(id)sender { (void)sender; [_quickPanel orderOut:nil]; }
- (void)copyQuick:(id)sender {
    (void)sender;
    if (_currentQuickResult.length) {
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        [pb clearContents]; [pb setString:_currentQuickResult forType:NSPasteboardTypeString];
    }
}
- (void)copyMain:(id)sender {
    (void)sender;
    if (_resultEditor.string.length) {
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        [pb clearContents]; [pb setString:_resultEditor.string forType:NSPasteboardTypeString];
    }
}

- (void)replaceSelection:(id)sender {
    (void)sender;
    if (!_lastTranslationOK || !_originElement || !_originSelection.length || !_currentQuickResult.length) return;
    CFTypeRef selected = NULL;
    AXError check = AXUIElementCopyAttributeValue(_originElement, kAXSelectedTextAttribute, &selected);
    BOOL identical = (check == kAXErrorSuccess && selected && CFGetTypeID(selected) == CFStringGetTypeID() &&
                       [(__bridge NSString *)selected isEqualToString:_originSelection]);
    if (selected) CFRelease(selected);
    if (!identical) {
        [self presentMessage:@"Замена отменена: исходное выделение изменилось или больше недоступно."];
        return;
    }
    // First attempt: no clipboard modification, no synthesized keystrokes.
    AXError set = AXUIElementSetAttributeValue(_originElement, kAXSelectedTextAttribute,
                                                (__bridge CFTypeRef)_currentQuickResult);
    if (set == kAXErrorSuccess) {
        [_quickPanel orderOut:nil];
        [self forgetSelection];
        return;
    }
    // Clipboard fallback requires explicit confirmation (some editors don't support AX replacement).
    NSAlert *confirm = [NSAlert new];
    confirm.messageText = @"Вставить перевод вместо выделения?";
    confirm.informativeText = @"Это приложение не поддержало прямую замену через Accessibility. FreeLingo вернётся к исходному окну и отправит ⌘V. Проверь, что выделение не поменялось.";
    [confirm addButtonWithTitle:@"Вставить"];
    [confirm addButtonWithTitle:@"Отмена"];
    if ([confirm runModal] != NSAlertFirstButtonReturn) return;

    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSMutableArray<NSPasteboardItem *> *backup = [NSMutableArray new];
    for (NSPasteboardItem *original in pb.pasteboardItems) {
        NSPasteboardItem *saved = [NSPasteboardItem new];
        for (NSPasteboardType type in original.types) {
            NSData *data = [original dataForType:type];
            if (data) [saved setData:data forType:type];
        }
        [backup addObject:saved];
    }
    [pb clearContents];
    [pb setString:_currentQuickResult forType:NSPasteboardTypeString];
    NSInteger ourChangeCount = pb.changeCount;
    NSRunningApplication *originalApp = [NSRunningApplication runningApplicationWithProcessIdentifier:_originPID];
    [_quickPanel orderOut:nil];
    [originalApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Only send paste if the clipboard is still ours. The user may have copied something new.
        if (pb.changeCount != ourChangeCount) return;
        CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        if (!src) return;
        CGEventRef down = CGEventCreateKeyboardEvent(src, (CGKeyCode)9, true);
        CGEventRef up = CGEventCreateKeyboardEvent(src, (CGKeyCode)9, false);
        if (down && up) {
            CGEventSetFlags(down, kCGEventFlagMaskCommand);
            CGEventSetFlags(up, kCGEventFlagMaskCommand);
            CGEventPost(kCGHIDEventTap, down);
            CGEventPost(kCGHIDEventTap, up);
        }
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        CFRelease(src);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (pb.changeCount == ourChangeCount) {
                [pb clearContents];
                if (backup.count) [pb writeObjects:backup];
            }
        });
    });
    [self forgetSelection];
}

- (void)translateClipboard:(id)sender {
    (void)sender;
    [self forgetSelection];
    NSString *clip = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!clip.length) { [self presentMessage:@"В буфере обмена нет текста."]; return; }
    [self showQuickForText:clip mode:@"translate"];
}

- (void)startOCR:(id)sender {
    (void)sender;
    [self forgetSelection];
    [_quickPanel orderOut:nil];
    NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"freelingo-ocr-%@.png", NSUUID.UUID.UUIDString]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
        task.arguments = @[@"-i", @"-x", file];
        NSError *error = nil;
        BOOL started = [task launchAndReturnError:&error];
        if (started) [task waitUntilExit];
        if (!started || task.terminationStatus != 0 || ![NSFileManager.defaultManager fileExistsAtPath:file]) {
            return; // Escape/cancelled selection.
        }
        VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = YES;
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithURL:[NSURL fileURLWithPath:file] options:@{}];
        BOOL recognized = [handler performRequests:@[request] error:&error];
        NSMutableArray<NSString *> *lines = [NSMutableArray new];
        if (recognized) {
            for (VNRecognizedTextObservation *observation in request.results) {
                VNRecognizedText *candidate = [observation topCandidates:1].firstObject;
                if (candidate.string.length) [lines addObject:candidate.string];
            }
        }
        [NSFileManager.defaultManager removeItemAtPath:file error:nil];
        NSString *text = [lines componentsJoinedByString:@"\n"];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (text.length) [self showQuickForText:text mode:@"translate"];
            else [self presentMessage:@"Текст на выбранном участке не найден или недоступно распознавание."];
        });
    });
}

- (void)openTextFile:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    if ([panel runModal] != NSModalResponseOK) return;
    NSURL *url = panel.URL;
    NSString *ext = url.pathExtension.lowercaseString;
    if (![@[@"txt", @"md"] containsObject:ext]) {
        [self presentMessage:@"В версии 0.5 поддерживается импорт TXT и MD. DOCX, PDF и SRT/VTT с сохранением структуры пока не реализованы."];
        return;
    }
    NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&error];
    if (!source) { [self presentMessage:error.localizedDescription ?: @"Не удалось открыть текстовый файл."]; return; }
    _sourceEditor.string = source;
    _tabs.selectedSegment = 0;
    _workButton.title = @"Перевести";
}

- (void)saveText:(id)sender {
    (void)sender;
    if (!_resultEditor.string.length) return;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"FreeLingo-translation.txt";
    if ([panel runModal] == NSModalResponseOK) {
        NSError *error = nil;
        BOOL ok = [_resultEditor.string writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (!ok) [self presentMessage:error.localizedDescription ?: @"Не удалось сохранить файл."];
    }
}

#include "ModelWindow.inc"

- (void)showSettings:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Горячие клавиши FreeLingo";
    alert.informativeText = @"Все модели работают локально. Для скачивания и переключения нажми «Модели…» в основном окне.";
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 145)];
    NSArray<NSString *> *names = @[@"Перевести выделение", @"Улучшить текст", @"OCR области экрана"];
    NSMutableArray<NSPopUpButton *> *popups = [NSMutableArray new];
    for (unsigned i = 0; i < 3; ++i) {
        CGFloat y = 99 - 39*i;
        NSTextField *row = FLLabel(names[i], 12);
        row.frame = NSMakeRect(0, y + 2, 173, 20);
        [form addSubview:row];
        NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(174, y, 244, 25) pullsDown:NO];
        [popup addItemsWithTitles:FLShortcutLabels()[i]];
        NSInteger choice = [NSUserDefaults.standardUserDefaults integerForKey:FLShortcutSetting(i)];
        [popup selectItemAtIndex:MAX(0, MIN(choice, 3))];
        [form addSubview:popup];
        [popups addObject:popup];
    }
    alert.accessoryView = form;
    [alert addButtonWithTitle:@"Сохранить"];
    [alert addButtonWithTitle:@"Отмена"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        for (unsigned i = 0; i < 3; ++i)
            [NSUserDefaults.standardUserDefaults setInteger:popups[i].indexOfSelectedItem forKey:FLShortcutSetting(i)];
        [self registerGlobalHotkeys];
    }
}

- (void)presentMessage:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"FreeLingo";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}
@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        FLAppDelegate *delegate = [FLAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
