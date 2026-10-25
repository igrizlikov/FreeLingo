// FreeLingo: native macOS AppKit shell. Translation engine is the Rust static library.
// Independent implementation; does not embed DeepL code, resources or services.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Vision/Vision.h>
#import <dispatch/dispatch.h>
#import <CommonCrypto/CommonDigest.h>
#import <Sparkle/Sparkle.h>
#import <ServiceManagement/ServiceManagement.h>
#import <NaturalLanguage/NaturalLanguage.h>
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
// TranslateGemma requires an explicit source language. Detect locally with
// Apple's NaturalLanguage framework (no network requests). Reject uncertainty.
static NSString *FLSourceLanguage(NSString *text) {
    if (!text.length) return nil;
    NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
    [recognizer processString:text];
    NSString *code = recognizer.dominantLanguage;
    if (!code.length) return nil;
    if ([code hasPrefix:@"zh"]) code = @"zh";
    else if ([code containsString:@"-"]) code = [code componentsSeparatedByString:@"-"].firstObject;
    NSSet *supported = [NSSet setWithArray:@[@"ru", @"en", @"zh", @"fr", @"it"]];
    return [supported containsObject:code] ? code : nil;
}

static NSInteger FLModelIndexForID(NSString *modelID) {
    for (NSUInteger index = 0; index < FLModels().count; index++) {
        if ([FLModels()[index][@"id"] isEqualToString:modelID]) return (NSInteger)index;
    }
    return -1;
}

// This comparison is only used to verify that a clipboard copy represents
// the SAME selected text. Never translate clipboard content that fails it.
static NSString *FLWithoutWhitespace(NSString *text) {
    if (!text) return @"";
    NSArray<NSString *> *components = [text componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [components componentsJoinedByString:@""];
}

// Copy the existing pasteboard representations so a temporary read of a
// browser selection does not destroy the user's clipboard contents.
static NSArray<NSPasteboardItem *> *FLPasteboardSnapshot(NSPasteboard *pb) {
    NSMutableArray<NSPasteboardItem *> *backup = [NSMutableArray new];
    for (NSPasteboardItem *original in pb.pasteboardItems) {
        NSPasteboardItem *saved = [NSPasteboardItem new];
        for (NSPasteboardType type in original.types) {
            NSData *data = [original dataForType:type];
            if (data) [saved setData:data forType:type];
        }
        [backup addObject:saved];
    }
    return backup;
}

static BOOL FLSendCopyShortcut(void) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!source) return NO;
    CGEventRef down = CGEventCreateKeyboardEvent(source, (CGKeyCode)8, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, (CGKeyCode)8, false);
    BOOL good = (down != NULL && up != NULL);
    if (good) {
        CGEventSetFlags(down, kCGEventFlagMaskCommand);
        CGEventSetFlags(up, kCGEventFlagMaskCommand);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
    CFRelease(source);
    return good;
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
// Always paste plain text into FreeLingo: never inherit HTML/RTF fonts,
// colours or background from browsers, documents or other applications.
@interface FLPlainTextView : NSTextView
@end
@implementation FLPlainTextView
- (void)paste:(id)sender {
    [self pasteAsPlainText:sender];
}
@end

static NSScrollView *FLEditor(NSTextView * __strong *out, BOOL editable) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.autohidesScrollers = YES;
    FLPlainTextView *text = [[FLPlainTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    text.minSize = NSMakeSize(0, 200);
    text.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    text.verticallyResizable = YES;
    text.horizontallyResizable = NO;
    text.autoresizingMask = NSViewWidthSizable;
    text.textContainer.widthTracksTextView = YES;
    text.textContainerInset = NSMakeSize(14, 14);
    text.editable = editable;
    text.selectable = YES;
    text.richText = NO;
    text.importsGraphics = NO;
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
@property (nonatomic, assign) NSInteger comparisonStage;
@end
@implementation FLJob
@end

@interface FLAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSURLSessionDownloadDelegate, NSTextViewDelegate>
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
    SPUStandardUpdaterController *_updaterController;
    NSMenuItem *_dockMenuItem;
    NSMenuItem *_loginMenuItem;
    NSMenuItem *_updateMenuItem;
    NSMenuItem *_naturalTranslationItem;
    NSMenuItem *_literaryReviewItem;
    NSTextView *_sourceEditor;
    NSTextView *_resultEditor;
    NSTextView *_quickEditor;
    NSSegmentedControl *_tabs;
    NSPopUpButton *_mainLanguage;
    NSPopUpButton *_quickLanguage;
    NSButton *_replaceButton;
    NSButton *_quickEditButton;
    NSButton *_workButton;
    NSTextField *_statusLabel;
    NSString *_currentQuickSource;
    NSString *_currentQuickResult;
    NSString *_currentQuickMode;
    NSString *_quickOrigin;
    pid_t _originPID;
    AXUIElementRef _originElement;
    NSString *_originSelection;
    BOOL _lastTranslationOK;
    BOOL _quickEditTransitioning; // guards rapid/reentrant button activations
    NSUInteger _quickGeneration;
    NSUInteger _mainGeneration; // Prevent a cleared view from receiving a stale callback.
    NSUInteger _selectionCaptureGeneration; // Supersede pending hotkey clipboard probes.
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *_sessionHistory;
    EventHotKeyRef _translateHotkey;
    EventHotKeyRef _rewriteHotkey;
    EventHotKeyRef _ocrHotkey;
    EventHandlerRef _hotkeyHandler;
    NSWindow *_settingsWindow;
    NSRunningApplication *_settingsPreviousApp;
    NSButton *_settingsDockCheckbox;
    NSButton *_settingsLoginCheckbox;
    NSButton *_settingsNaturalCheckbox;
    NSButton *_settingsLiteraryCheckbox;
    NSPopUpButton *_settingsShortcut0;
    NSPopUpButton *_settingsShortcut1;
    NSPopUpButton *_settingsShortcut2;
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
    NSWindow *_comparisonWindow;
    NSTextView *_comparisonResult;
    NSString *_comparisonSource;
    NSString *_comparisonTarget;
    NSArray<NSString *> *_comparisonModels;
    BOOL _comparisonRunning;
    NSDate *_comparisonStart;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    _sessionHistory = [NSMutableArray new];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        @"modelID": @"translategemma-4b", @"languageIndex": @0,
        @"showDockIcon": @NO, @"naturalRussianTranslation": @YES, @"literaryRussianReview": @NO
    }];
    [self createApplicationMenu];
    [self createMainWindow];
    [self createQuickPanel];
    [self createStatusMenu];
    [self createModelsWindow];
    [self applyDockPreference];
    [self configureUpdates];
    [self registerGlobalHotkeys];
    // Dockless mode launches quietly and stays available from the menu bar.
    // Users can open the full UI from the status menu or a global shortcut.
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"showDockIcon"]) {
        [_mainWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
    // First-time setup still opens the model picker in dockless mode.
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
    _mainWindow.releasedWhenClosed = NO;
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
    NSScrollView *result = FLEditor(&_resultEditor, YES); // Users can correct translations in place.
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
    // Keep the Clear action above the source editor: the bottom toolbar must
    // remain usable even when the main window is at its minimum width.
    NSButton *clearButton = FLButton(@"Очистить", self, @selector(clearMain:));
    clearButton.toolTip = @"Очистить исходный текст и перевод (история сохранится)";
    clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:clearButton];
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
        [clearButton.centerYAnchor constraintEqualToAnchor:languageLabel.centerYAnchor],
        [clearButton.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [clearButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:_mainLanguage.trailingAnchor constant:12],
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
    _quickPanel.releasedWhenClosed = NO;
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
    _quickEditor.delegate = self;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];
    NSButton *copy = FLButton(@"Копировать", self, @selector(copyQuick:));
    _quickEditButton = FLButton(@"Редактировать", self, @selector(editQuick:));
    _replaceButton = FLButton(@"Заменить", self, @selector(replaceSelection:));
    NSStackView *actions = [NSStackView stackViewWithViews:@[copy, _quickEditButton, _replaceButton]];
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
    NSImage *statusIcon = [[NSImage alloc] initWithContentsOfFile:
        [NSBundle.mainBundle pathForResource:@"MenubarIcon" ofType:@"png"]];
    if (statusIcon) {
        statusIcon.size = NSMakeSize(18, 18);
        statusIcon.template = YES; // auto-contrasts with light/dark macOS menu bars
        _statusItem.button.image = statusIcon;
        _statusItem.button.imagePosition = NSImageOnly;
    } else {
        _statusItem.button.title = @"F⇄";
    }
    _statusItem.button.toolTip = @"FreeLingo — локальный переводчик";
    NSMenu *menu = [NSMenu new];
    // Keep the menu-bar popup minimal. All former actions and preferences
    // live in the native settings window; global shortcuts still work.
    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Настройки…" action:@selector(showSettings:) keyEquivalent:@""];
    settings.target = self;
    [menu addItem:settings];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Завершить FreeLingo" action:@selector(terminate:) keyEquivalent:@""];
    quit.target = NSApp;
    [menu addItem:quit];
    _statusItem.menu = menu;
}

- (void)openTranslationDiagnostics:(id)sender {
    (void)sender;
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    NSURL *folder = [[support URLByAppendingPathComponent:@"FreeLingo" isDirectory:YES]
        URLByAppendingPathComponent:@"Logs" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *file = [folder URLByAppendingPathComponent:@"translation-diagnostics.log"];
    if ([NSFileManager.defaultManager fileExistsAtPath:file.path])
        [NSWorkspace.sharedWorkspace openURL:file];
    else
        [self presentMessage:@"Журнал появится после нового перевода. Исходный текст в него не записывается."];
}

- (void)runComparisonStage:(NSInteger)stage {
    if (!_comparisonRunning || !_comparisonWindow) return;
    NSString *modelID = _comparisonModels[(NSUInteger)(stage - 1)];
    NSInteger idx = FLModelIndexForID(modelID);
    if (idx < 0 || !FLModelInstalled(idx)) {
        _comparisonRunning = NO;
        _comparisonResult.string = [_comparisonResult.string stringByAppendingFormat:@"\nМодель %@ не установлена.\n", modelID];
        return;
    }
    NSString *direction = _comparisonTarget;
    if ([modelID hasPrefix:@"translategemma-"]) {
        NSString *detected = FLSourceLanguage(_comparisonSource);
        if (!detected || [detected isEqualToString:_comparisonTarget]) {
            _comparisonRunning = NO;
            _comparisonResult.string = [_comparisonResult.string stringByAppendingString:
                @"\nTranslateGemma: не удалось однозначно определить исходный язык или он совпадает с целевым. Сравнение не завершено.\n"];
            return;
        }
        direction = [NSString stringWithFormat:@"%@>%@", detected, _comparisonTarget];
    }
    _comparisonResult.string = [_comparisonResult.string stringByAppendingFormat:
        @"\n%@ (направление %@): обрабатываю…\n", modelID, direction];
    _comparisonStart = [NSDate date];
    FLJob *job = [FLJob new];
    job.controller = self;
    job.source = [_comparisonSource copy];
    BOOL natural = [_comparisonTarget isEqualToString:@"ru"] &&
        [NSUserDefaults.standardUserDefaults boolForKey:@"naturalRussianTranslation"];
    NSString *effectiveMode = natural ? @"translate_natural" : @"translate";
    job.mode = effectiveMode;
    job.comparisonStage = stage;
    fl_work_async_diagnostic(_comparisonSource.UTF8String, direction.UTF8String, effectiveMode.UTF8String,
        FLModelURL(idx).path.UTF8String, "ab",
        (FLSourceLanguage(_comparisonSource) ?: @"unknown").UTF8String, FLRustCallback, (__bridge_retained void *)job);
}

- (void)compareTranslations:(id)sender {
    (void)sender;
    if (_comparisonRunning) {
        [self presentMessage:@"Сравнение уже выполняется."];
        return;
    }
    NSString *text = _sourceEditor.string.length ? _sourceEditor.string :
        [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!text.length || text.length > 15000) {
        [self presentMessage:@"Для сравнения вставь текст длиной до 15 000 символов в главное окно FreeLingo или в буфер обмена."];
        return;
    }
    NSInteger hy = FLModelIndexForID(@"hy-mt2-7b");
    NSInteger gemma = FLModelIndexForID(@"translategemma-4b");
    NSInteger gemma12 = FLModelIndexForID(@"translategemma-12b");
    BOOL canCompareSpecialists = FLModelInstalled(hy) && FLModelInstalled(gemma);
    BOOL canCompareGemmas = FLModelInstalled(gemma) && FLModelInstalled(gemma12);
    if (!canCompareSpecialists && !canCompareGemmas) {
        [self showModels:nil];
        [self presentMessage:@"Для сравнения установи TranslateGemma 4B и вторую модель: TranslateGemma 12B или Hy-MT2 7B."];
        return;
    }
    BOOL compareGemmas = canCompareGemmas;
    if (canCompareSpecialists && canCompareGemmas) {
        NSAlert *choice = [NSAlert new];
        choice.messageText = @"Выбери пару моделей";
        choice.informativeText = @"Обе модели последовательно получат один и тот же оригинал.";
        [choice addButtonWithTitle:@"Gemma 4B / 12B"];
        [choice addButtonWithTitle:@"Hy-MT2 / Gemma 4B"];
        [choice addButtonWithTitle:@"Отмена"];
        NSModalResponse answer = [choice runModal];
        if (answer == NSAlertThirdButtonReturn) return;
        compareGemmas = answer == NSAlertFirstButtonReturn;
    }
    _comparisonModels = compareGemmas ?
        @[@"translategemma-4b", @"translategemma-12b"] :
        @[@"hy-mt2-7b", @"translategemma-4b"];
    _comparisonSource = [text copy];
    _comparisonTarget = FLSelectedLanguage(_mainLanguage);
    if (![@[@"ru", @"en", @"zh", @"fr", @"it"] containsObject:_comparisonTarget]) {
        [self presentMessage:@"Сравнение доступно для русского, английского, китайского, французского и итальянского."];
        return;
    }
    if (!_comparisonWindow) {
        _comparisonWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 570)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
            backing:NSBackingStoreBuffered defer:NO];
        _comparisonWindow.releasedWhenClosed = NO;
        _comparisonWindow.title = @"FreeLingo — сравнение переводчиков";
        [_comparisonWindow center];
        NSScrollView *scroll = FLEditor(&_comparisonResult, NO);
        scroll.frame = _comparisonWindow.contentView.bounds;
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [_comparisonWindow.contentView addSubview:scroll];
    }
    _comparisonResult.string = @"A/B — обе модели получают ОДИН И ТОТ ЖЕ текст. Автоматический победитель не назначается.\nРезультаты остаются только в этом окне и не отправляются в интернет.\n";
    _comparisonRunning = YES;
    [_comparisonWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self runComparisonStage:1];
}

- (void)toggleLiteraryReview:(id)sender {
    (void)sender;
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:@"literaryRussianReview"];
    [NSUserDefaults.standardUserDefaults setBool:!enabled forKey:@"literaryRussianReview"];
    _literaryReviewItem.state = !enabled ? NSControlStateValueOn : NSControlStateValueOff;
    _settingsLiteraryCheckbox.state = !enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleNaturalTranslation:(id)sender {
    (void)sender;
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:@"naturalRussianTranslation"];
    [NSUserDefaults.standardUserDefaults setBool:!enabled forKey:@"naturalRussianTranslation"];
    _naturalTranslationItem.state = !enabled ? NSControlStateValueOn : NSControlStateValueOff;
    _settingsNaturalCheckbox.state = !enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

// Accessory mode has no Dock icon but keeps status item, hotkeys and windows.
- (void)applyDockPreference {
    BOOL showDock = [NSUserDefaults.standardUserDefaults boolForKey:@"showDockIcon"];
    NSApplicationActivationPolicy policy = showDock ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory;
    if (NSApp.activationPolicy != policy && ![NSApp setActivationPolicy:policy]) {
        [self presentMessage:@"Не удалось изменить режим отображения в Dock."];
        return;
    }
    _dockMenuItem.state = showDock ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleDockIcon:(id)sender {
    (void)sender;
    BOOL currentlyShown = [NSUserDefaults.standardUserDefaults boolForKey:@"showDockIcon"];
    [NSUserDefaults.standardUserDefaults setBool:!currentlyShown forKey:@"showDockIcon"];
    [self applyDockPreference];
}

// ServiceManagement stores the real login-item state in macOS, not UserDefaults.
- (BOOL)loginItemEnabled {
    return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
}

- (BOOL)setLoginItemEnabled:(BOOL)enabled {
    SMAppService *service = SMAppService.mainAppService;
    if ((service.status == SMAppServiceStatusEnabled) == enabled) return YES;
    NSError *error = nil;
    BOOL ok = enabled ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
    if (!ok) {
        [self presentMessage:[NSString stringWithFormat:@"Не удалось изменить автозапуск: %@\nПроверь Системные настройки → Основные → Объекты входа и расширения.",
                              error.localizedDescription ?: @"неизвестная ошибка"]];
    }
    return ok;
}

- (void)toggleLoginItem:(id)sender {
    (void)sender;
    [self setLoginItemEnabled:![self loginItemEnabled]];
    _loginMenuItem.state = [self loginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)configureUpdates {
    // If the repository owner has not configured signing, explicitly disable
    // the updater. Never install an unverified remote executable.
    NSString *publicKey = [NSBundle.mainBundle objectForInfoDictionaryKey:@"SUPublicEDKey"];
    NSString *feed = [NSBundle.mainBundle objectForInfoDictionaryKey:@"SUFeedURL"];
    if (publicKey.length == 0 || feed.length == 0) return;
    _updaterController = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES
                                                                     updaterDelegate:nil
                                                                  userDriverDelegate:nil];
}

- (void)checkForUpdates:(id)sender {
    if (!_updaterController) {
        [self presentMessage:@"Автообновления пока не активированы в этой сборке. Владелец репозитория должен один раз настроить подпись Sparkle и выпуск GitHub Releases."];
        return;
    }
    [NSApp activateIgnoringOtherApps:YES];
    [_updaterController checkForUpdates:sender];
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

// Some browsers expose a flat kAXSelectedTextAttribute even when their
// normal Copy command preserves paragraphs. For long single-line selections,
// probe ⌘C while the SOURCE app is still in front. Only prefer the clipboard
// if the non-whitespace text matches the trusted AX selection. No clipboard
// text is logged, persisted or used if a different selection was copied.
- (void)captureParagraphsAndTranslate:(NSString *)axText mode:(NSString *)mode {
    NSUInteger generation = ++_selectionCaptureGeneration;
    pid_t appPID = _originPID;
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSInteger initialChangeCount = pb.changeCount;
    NSArray<NSPasteboardItem *> *backup = FLPasteboardSnapshot(pb);
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != appPID || !FLSendCopyShortcut()) {
        [self showQuickForText:axText mode:mode origin:@"hotkey"];
        return;
    }
    // Do not activate FreeLingo until the source application handles ⌘C.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSInteger afterCopyChangeCount = pb.changeCount;
        NSString *copied = afterCopyChangeCount != initialChangeCount ?
            [pb stringForType:NSPasteboardTypeString] : nil;
        BOOL sameContent = copied.length > 0 &&
            [FLWithoutWhitespace(copied) isEqualToString:FLWithoutWhitespace(axText)];
        // Never overwrite a new clipboard update from the user. Restore only
        // if we can verify the clipboard holds the text copied by our request.
        if (sameContent && pb.changeCount == afterCopyChangeCount) {
            [pb clearContents];
            if (backup.count) [pb writeObjects:backup];
        }
        if (generation != self->_selectionCaptureGeneration || self->_originPID != appPID) return;
        BOOL restoredParagraphs = sameContent &&
            [copied rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound;
        [self showQuickForText:(restoredParagraphs ? copied : axText) mode:mode
                      origin:(restoredParagraphs ? @"hotkey_clipboard" : @"hotkey")];
    });
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
    if (source.length >= 220 &&
        [source rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location == NSNotFound) {
        [self captureParagraphsAndTranslate:source mode:mode];
    } else {
        ++_selectionCaptureGeneration;
        [self showQuickForText:source mode:mode origin:@"hotkey"];
    }
}

- (void)showQuickForText:(NSString *)source mode:(NSString *)mode origin:(NSString *)origin {
    _quickOrigin = [origin copy];
    [self finishQuickEditing];
    _currentQuickSource = [source copy];
    _currentQuickResult = @"";
    _currentQuickMode = [mode copy];
    _lastTranslationOK = NO;
    _replaceButton.enabled = NO;
    _quickEditButton.enabled = NO;
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
    if (quick) [self finishQuickEditing];
    NSInteger modelIndex = FLActiveModelIndex();
    if (!FLModelInstalled(modelIndex)) {
        [self showModels:nil];
        [self presentMessage:@"Сначала скачай и выбери модель в разделе «Модели»." ];
        return;
    }
    NSString *model = FLModelURL(modelIndex).path;
    FLJob *job = [FLJob new];
    job.controller = self;
    job.source = [text copy];
    job.mode = [mode copy];
    job.quick = quick;
    job.generation = quick ? ++_quickGeneration : ++_mainGeneration;
    if (quick) { _quickEditButton.enabled = NO; _quickEditor.string = @"Обрабатываю локальной моделью…"; }
    else { _resultEditor.string = @"Обрабатываю локальной моделью…"; _workButton.enabled = NO; }
    // Select a style preset without changing the UI's logical translate mode
    // (used by popup lifecycle guards). Other target languages remain unchanged.
    NSString *effectiveMode = mode;
    if ([mode isEqualToString:@"translate"] && [language isEqualToString:@"ru"]) {
        NSString *activeID = FLModels()[(NSUInteger)modelIndex][@"id"];
        if ([activeID hasPrefix:@"hy-mt2-"] &&
            [NSUserDefaults.standardUserDefaults boolForKey:@"literaryRussianReview"]) {
            effectiveMode = @"translate_reviewed";
        } else if ([NSUserDefaults.standardUserDefaults boolForKey:@"naturalRussianTranslation"]) {
            effectiveMode = @"translate_natural";
        }
    }
    NSString *targetArgument = language;
    if ([FLModels()[(NSUInteger)modelIndex][@"id"] isEqualToString:@"translategemma-4b"] &&
        [effectiveMode hasPrefix:@"translate"]) {
        NSString *detected = FLSourceLanguage(text);
        if (!detected || [detected isEqualToString:language]) {
            [self presentMessage:@"TranslateGemma: не удалось определить исходный язык или он совпадает с целевым. Попробуй более длинный текст на другом языке."];
            if (quick) _quickEditor.string = @"Не удалось определить исходный язык.";
            else { _resultEditor.string = @"Не удалось определить исходный язык."; _workButton.enabled = YES; }
            return;
        }
        targetArgument = [NSString stringWithFormat:@"%@>%@", detected, language];
    }
    NSString *origin = quick ? (_quickOrigin ?: @"hotkey") : @"main";
    NSString *sourceLanguage = FLSourceLanguage(text) ?: @"unknown";
    fl_work_async_diagnostic(text.UTF8String, targetArgument.UTF8String, effectiveMode.UTF8String,
        model.UTF8String, origin.UTF8String, sourceLanguage.UTF8String, FLRustCallback, (__bridge_retained void *)job);
}

- (void)translationFinished:(NSString *)result success:(BOOL)ok job:(FLJob *)job {
    // Record lifecycle only; never log the user's source or translated text.
    NSLog(@"FreeLingo.UI translationFinished model_job=%@ success=%d quick=%d", job.comparisonStage > 0 ? @"comparison" : @"regular", ok, job.quick);
    if (job.comparisonStage > 0) {
        if (!_comparisonRunning) return;
        NSTimeInterval elapsed = -[_comparisonStart timeIntervalSinceNow];
        _comparisonResult.string = [_comparisonResult.string stringByAppendingFormat:
            @"\n%@ — %.1f с:\n%@\n", ok ? @"Результат" : @"Ошибка", elapsed, result];
        if (job.comparisonStage == 1) [self runComparisonStage:2];
        else {
            _comparisonRunning = NO;
            _comparisonResult.string = [_comparisonResult.string stringByAppendingString:
                @"\nСравни естественность языка, сохранение фактов и время перевода.\n"];
        }
        return;
    }
    if (job.quick) {
        if (_quickEditor.editable) return;
        if (job.generation != _quickGeneration || ![_currentQuickSource isEqualToString:job.source] || ![_currentQuickMode isEqualToString:job.mode]) return;
        _currentQuickResult = ok ? result : @"";
        _quickEditor.string = ok ? result : [@"Ошибка: " stringByAppendingString:result];
        _lastTranslationOK = ok;
        _quickEditButton.enabled = ok && _currentQuickResult.length > 0;
        _replaceButton.enabled = ok && (_originElement != NULL) &&
            [FLWithoutWhitespace(_originSelection) isEqualToString:FLWithoutWhitespace(job.source)];
    } else {
        if (job.generation != _mainGeneration) return; // cleared or superseded
        _resultEditor.string = ok ? result : [@"Ошибка: " stringByAppendingString:result];
        _workButton.enabled = YES;
        _statusLabel.stringValue = ok ? @"Перевод выполнен на Mac" : @"Ошибка движка. Открой «Модели» или проверь журнал.";
    }
    if (ok) {
        [_sessionHistory insertObject:@{ @"source": job.source, @"result": result } atIndex:0];
        if (_sessionHistory.count > 50) [_sessionHistory removeLastObject];
    }
}

- (void)clearMain:(id)sender {
    (void)sender;
    ++_mainGeneration; // Ignore results from translations already in flight.
    _sourceEditor.string = @"";
    _resultEditor.string = @"";
    _workButton.enabled = YES;
    _statusLabel.stringValue = @"Поля очищены";
    [_mainWindow makeFirstResponder:_sourceEditor];
    // Do not change translation history, the selected model or the language.
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
// Do not move between an NSPanel and a dockless main NSWindow just to edit.
// Editing in place also preserves the original selection used by Replace.
- (void)finishQuickEditing {
    if (!_quickEditor || !_quickEditButton) return;
    if (_quickEditor.editable) {
        // Commit the IME composition and resign the text view BEFORE changing
        // its editability. The button may be triggered repeatedly while the
        // panel is key; never remove editing from the active responder.
        if ([_quickPanel.firstResponder isKindOfClass:NSTextView.class]) {
            [_quickPanel makeFirstResponder:_quickEditButton];
        }
        _currentQuickResult = [_quickEditor.string copy];
        _quickEditor.editable = NO;
    }
    _quickEditButton.title = @"Редактировать";
}
- (void)editQuick:(id)sender {
    (void)sender;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self editQuick:nil]; });
        return;
    }
    if (_quickEditTransitioning || !_quickPanel || !_quickEditor || !_quickEditButton) return;
    _quickEditTransitioning = YES;
    @try {
        if (_quickEditor.editable) {
            [self finishQuickEditing];
            return;
        }
        if (!_lastTranslationOK || !_currentQuickResult.length) {
            [self presentMessage:@"Сначала получи перевод, затем его можно будет исправить."];
            return;
        }
        _quickEditor.editable = YES;
        _quickEditButton.title = @"Готово";
        [_quickPanel makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        if (![_quickPanel makeFirstResponder:_quickEditor]) {
            _quickEditor.editable = NO;
            _quickEditButton.title = @"Редактировать";
            return;
        }
        [_quickEditor setSelectedRange:NSMakeRange(_quickEditor.string.length, 0)];
    } @finally {
        _quickEditTransitioning = NO;
    }
}
- (void)textDidChange:(NSNotification *)notification {
    if (notification.object == _quickEditor && _quickEditor.editable) {
        _currentQuickResult = [_quickEditor.string copy];
        _replaceButton.enabled = _lastTranslationOK && _currentQuickResult.length > 0 &&
            _originElement != NULL && [_originSelection isEqualToString:_currentQuickSource];
    }
}
- (void)dismissQuick:(id)sender {
    (void)sender;
    [self finishQuickEditing];
    ++_quickGeneration; // invalidate results from requests finishing after Close
    [_quickPanel orderOut:nil];
}
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

    // Capture the original AX element before releasing our selection state.
    // The asynchronous paste must re-verify BOTH the original focused app and
    // its selected text after the warning dialog and window activation.
    AXUIElementRef retainedElement = _originElement ? (AXUIElementRef)CFRetain(_originElement) : NULL;
    pid_t originalPID = _originPID;
    NSString *originalSelection = [_originSelection copy];
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
    NSRunningApplication *originalApp = [NSRunningApplication runningApplicationWithProcessIdentifier:originalPID];
    [_quickPanel orderOut:nil];
    [originalApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (pb.changeCount != ourChangeCount) {
            if (retainedElement) CFRelease(retainedElement);
            return; // The user has copied a different text: preserve their clipboard.
        }
        CFTypeRef selectedNow = NULL;
        AXError axError = retainedElement ? AXUIElementCopyAttributeValue(retainedElement, kAXSelectedTextAttribute, &selectedNow) : kAXErrorFailure;
        BOOL sameSelection = (axError == kAXErrorSuccess && selectedNow && CFGetTypeID(selectedNow) == CFStringGetTypeID() &&
                              [(__bridge NSString *)selectedNow isEqualToString:originalSelection]);
        if (selectedNow) CFRelease(selectedNow);
        BOOL correctApp = (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == originalPID);
        if (!correctApp || !sameSelection) {
            [pb clearContents];
            if (backup.count) [pb writeObjects:backup];
            if (retainedElement) CFRelease(retainedElement);
            [self presentMessage:@"Безопасная замена отменена: исходное окно или выделение изменилось. Скопируй перевод вручную."];
            return;
        }
        CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        CGEventRef down = src ? CGEventCreateKeyboardEvent(src, (CGKeyCode)9, true) : NULL;
        CGEventRef up = src ? CGEventCreateKeyboardEvent(src, (CGKeyCode)9, false) : NULL;
        if (down && up) {
            CGEventSetFlags(down, kCGEventFlagMaskCommand);
            CGEventSetFlags(up, kCGEventFlagMaskCommand);
            CGEventPost(kCGHIDEventTap, down);
            CGEventPost(kCGHIDEventTap, up);
        }
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        if (src) CFRelease(src);
        if (retainedElement) CFRelease(retainedElement);
        if (!src || !down || !up) {
            [self presentMessage:@"Не удалось отправить ⌘V. Скопируй перевод вручную."];
        }
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
    [self showQuickForText:clip mode:@"translate" origin:@"clipboard"];
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
            if (text.length) [self showQuickForText:text mode:@"translate" origin:@"ocr"];
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
        [self presentMessage:@"Поддерживается импорт TXT и MD. DOCX, PDF и SRT/VTT с сохранением структуры пока не реализованы."];
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

// A native settings window replaces the crowded menu-bar popup.
// Preferences are stored immediately. Existing actions remain accessible.
- (void)translateSelectionFromSettings:(id)sender {
    (void)sender;
    // Return focus to the app that had the selection before Settings opened.
    // If there is no such app, explain that the global shortcut is preferred.
    NSRunningApplication *origin = _settingsPreviousApp;
    if (!origin || origin.isTerminated) {
        [self presentMessage:@"Выдели текст в другом приложении и нажми горячую клавишу перевода (по умолчанию ⌘4)."];
        return;
    }
    [_settingsWindow orderOut:nil];
    [origin activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self translateSelectedTextWithMode:@"translate"];
    });
}

- (void)settingsCheckboxChanged:(NSButton *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = sender.state == NSControlStateValueOn;
    switch (sender.tag) {
        case 1:
            [defaults setBool:enabled forKey:@"showDockIcon"];
            [self applyDockPreference];
            break;
        case 2:
            if (enabled != [self loginItemEnabled]) [self setLoginItemEnabled:enabled];
            sender.state = [self loginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
            break;
        case 3:
            [defaults setBool:enabled forKey:@"naturalRussianTranslation"];
            break;
        case 4:
            [defaults setBool:enabled forKey:@"literaryRussianReview"];
            break;
        default:
            break;
    }
}

- (void)settingsShortcutChanged:(NSPopUpButton *)sender {
    if (sender.tag < 0 || sender.tag > 2) return;
    [NSUserDefaults.standardUserDefaults setInteger:sender.indexOfSelectedItem
                                           forKey:FLShortcutSetting((unsigned)sender.tag)];
    [self registerGlobalHotkeys];
}

- (NSButton *)settingsCheckbox:(NSString *)title tag:(NSInteger)tag
                            y:(CGFloat)y onView:(NSView *)root {
    NSButton *control = [[NSButton alloc] initWithFrame:NSMakeRect(24, y, 635, 28)];
    control.buttonType = NSButtonTypeSwitch;
    control.title = title;
    control.tag = tag;
    control.font = [NSFont systemFontOfSize:14];
    control.target = self;
    control.action = @selector(settingsCheckboxChanged:);
    [root addSubview:control];
    return control;
}

- (NSButton *)settingsAction:(NSString *)title selector:(SEL)action
                          frame:(NSRect)frame onView:(NSView *)root {
    NSButton *button = FLButton(title, self, action);
    button.frame = frame;
    [root addSubview:button];
    return button;
}

- (void)settingsHeading:(NSString *)title subtitle:(NSString *)subtitle onView:(NSView *)root {
    NSTextField *heading = [NSTextField labelWithString:title];
    heading.frame = NSMakeRect(24, 367, 620, 33);
    heading.font = [NSFont boldSystemFontOfSize:22];
    [root addSubview:heading];
    NSTextField *sub = FLLabel(subtitle, 12);
    sub.frame = NSMakeRect(24, 340, 640, 25);
    [root addSubview:sub];
}

- (NSView *)settingsGeneralTab {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 676, 418)];
    [self settingsHeading:@"Основные" subtitle:@"Поведение FreeLingo и установка обновлений" onView:root];
    _settingsDockCheckbox = [self settingsCheckbox:@"Показывать значок в Dock" tag:1 y:287 onView:root];
    _settingsLoginCheckbox = [self settingsCheckbox:@"Запускать при входе в macOS" tag:2 y:250 onView:root];
    [self settingsAction:@"Открыть FreeLingo" selector:@selector(showMain:)
                   frame:NSMakeRect(24, 177, 192, 32) onView:root];
    [self settingsAction:@"Выбрать модель…" selector:@selector(showModels:)
                   frame:NSMakeRect(230, 177, 192, 32) onView:root];
    [self settingsAction:@"Проверить обновления…" selector:@selector(checkForUpdates:)
                   frame:NSMakeRect(436, 177, 208, 32) onView:root];
    NSTextField *info = FLLabel(@"Модели хранятся локально. Обновления приложения проверяются через Sparkle.", 12);
    info.frame = NSMakeRect(24, 122, 640, 30);
    [root addSubview:info];
    return root;
}

- (NSView *)settingsTranslationTab {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 676, 418)];
    [self settingsHeading:@"Перевод" subtitle:@"Качество русского и диагностика локальных моделей" onView:root];
    _settingsNaturalCheckbox = [self settingsCheckbox:@"Естественный русский перевод" tag:3 y:282 onView:root];
    _settingsLiteraryCheckbox = [self settingsCheckbox:@"Литературная вычитка русского (медленнее)" tag:4 y:242 onView:root];
    [self settingsAction:@"Сравнить Hy-MT2 и TranslateGemma / 4B и 12B…" selector:@selector(compareTranslations:)
                   frame:NSMakeRect(24, 158, 298, 34) onView:root];
    [self settingsAction:@"Открыть журнал перевода…" selector:@selector(openTranslationDiagnostics:)
                   frame:NSMakeRect(336, 158, 282, 34) onView:root];
    NSTextField *info = FLLabel(@"Для русского рекомендуем TranslateGemma 4B. Выбор модели — в разделе «Основные». Вычитка Qwen экспериментальная.", 12);
    info.frame = NSMakeRect(24, 103, 637, 32);
    [root addSubview:info];
    return root;
}

- (NSView *)settingsShortcutsTab {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 676, 418)];
    [self settingsHeading:@"Горячие клавиши" subtitle:@"Изменения применяются и сохраняются сразу" onView:root];
    NSArray<NSString *> *names = @[@"Перевести выделение", @"Улучшить текст", @"Текст с экрана (OCR)"];
    NSPopUpButton *controls[3] = { nil, nil, nil };
    for (unsigned i = 0; i < 3; ++i) {
        CGFloat y = 265 - 56 * i;
        NSTextField *label = FLLabel(names[i], 14);
        label.frame = NSMakeRect(24, y + 2, 260, 24);
        [root addSubview:label];
        NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(305, y, 322, 28) pullsDown:NO];
        [picker addItemsWithTitles:FLShortcutLabels()[i]];
        picker.tag = (NSInteger)i;
        picker.target = self;
        picker.action = @selector(settingsShortcutChanged:);
        [root addSubview:picker];
        controls[i] = picker;
    }
    _settingsShortcut0 = controls[0];
    _settingsShortcut1 = controls[1];
    _settingsShortcut2 = controls[2];
    NSTextField *info = FLLabel(@"Если сочетание занято другой программой, выбери альтернативу.", 12);
    info.frame = NSMakeRect(24, 67, 620, 31);
    [root addSubview:info];
    return root;
}

- (NSView *)settingsActionsTab {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 676, 418)];
    [self settingsHeading:@"Действия" subtitle:@"Перевод, распознавание текста и инструменты" onView:root];
    [self settingsAction:@"Перевести выделение" selector:@selector(translateSelectionFromSettings:)
                   frame:NSMakeRect(24, 265, 290, 34) onView:root];
    [self settingsAction:@"Перевести буфер обмена" selector:@selector(translateClipboard:)
                   frame:NSMakeRect(334, 265, 290, 34) onView:root];
    [self settingsAction:@"Распознать текст с экрана" selector:@selector(startOCR:)
                   frame:NSMakeRect(24, 209, 290, 34) onView:root];
    [self settingsAction:@"Открыть окно переводчика" selector:@selector(showMain:)
                   frame:NSMakeRect(334, 209, 290, 34) onView:root];
    [self settingsAction:@"Выбрать и скачать модель" selector:@selector(showModels:)
                   frame:NSMakeRect(24, 153, 290, 34) onView:root];
    NSTextField *note = FLLabel(@"Для выделенного текста обычно удобнее ⌘4. Кнопка вернёт фокус в прежнее приложение и попробует прочитать выделение.", 12);
    note.frame = NSMakeRect(24, 78, 626, 45);
    note.lineBreakMode = NSLineBreakByWordWrapping;
    note.maximumNumberOfLines = 2;
    [root addSubview:note];
    return root;
}

- (void)syncSettingsControls {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    _settingsDockCheckbox.state = [defaults boolForKey:@"showDockIcon"] ? NSControlStateValueOn : NSControlStateValueOff;
    _settingsLoginCheckbox.state = [self loginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    _settingsNaturalCheckbox.state = [defaults boolForKey:@"naturalRussianTranslation"] ? NSControlStateValueOn : NSControlStateValueOff;
    _settingsLiteraryCheckbox.state = [defaults boolForKey:@"literaryRussianReview"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSArray<NSPopUpButton *> *shortcuts = @[_settingsShortcut0, _settingsShortcut1, _settingsShortcut2];
    for (unsigned i = 0; i < 3; ++i) {
        NSInteger choice = [defaults integerForKey:FLShortcutSetting(i)];
        [shortcuts[i] selectItemAtIndex:MAX(0, MIN(choice, 3))];
    }
}

- (void)showSettings:(id)sender {
    (void)sender;
    // AppKit window creation and control updates must be on the main thread.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showSettings:nil]; });
        return;
    }
    NSLog(@"FreeLingo.UI settings_open:begin");
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (front && front.processIdentifier != NSProcessInfo.processInfo.processIdentifier)
        _settingsPreviousApp = front;
    if (!_settingsWindow) {
        _settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 730, 506)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
            backing:NSBackingStoreBuffered defer:NO];
        _settingsWindow.releasedWhenClosed = NO;
        _settingsWindow.title = @"FreeLingo — Настройки";
        [_settingsWindow center];
        NSView *root = _settingsWindow.contentView;
        NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(15, 14, 700, 477)];
        tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSArray<NSString *> *titles = @[@"Основные", @"Перевод", @"Горячие клавиши", @"Действия"];
        NSArray<NSView *> *views = @[[self settingsGeneralTab], [self settingsTranslationTab],
                                     [self settingsShortcutsTab], [self settingsActionsTab]];
        for (NSUInteger i = 0; i < titles.count; ++i) {
            NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:titles[i]];
            item.label = titles[i];
            item.view = views[i];
            [tabs addTabViewItem:item];
        }
        [root addSubview:tabs];
    }
    [self syncSettingsControls];
    [_settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    NSLog(@"FreeLingo.UI settings_open:complete");
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
        app.activationPolicy = [[NSUserDefaults standardUserDefaults] objectForKey:@"showDockIcon"] == nil ||
            ![[NSUserDefaults standardUserDefaults] boolForKey:@"showDockIcon"]
            ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular;
        FLAppDelegate *delegate = [FLAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
