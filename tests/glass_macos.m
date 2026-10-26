// Exercise the production AppKit layout and lifecycle without hotkeys,
// downloads, updating, persistent preferences or access to other apps.
#define main FLProductionMain
#include "../native/main.m"
#undef main
#include <stdio.h>
static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void CheckLayout(NSView *view) {
    if ([view isKindOfClass:NSScrollView.class] || [NSStringFromClass(view.class) hasPrefix:@"_"]) return;
    Check(!view.hasAmbiguousLayout, [NSString stringWithFormat:@"ambiguous %@", view.class]);
    for (NSView *child in view.subviews) CheckLayout(child);
}
static void Snapshot(NSWindow *window, NSString *path) {
    [window.contentView layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep = [window.contentView bitmapImageRepForCachingDisplayInRect:window.contentView.bounds];
    [window.contentView cacheDisplayInRect:window.contentView.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"modelID":@"translategemma-12b"} forName:NSArgumentDomain];
        FLAppDelegate *controller = [FLAppDelegate new];
        [controller createMainWindow];
        NSWindow *window = [controller valueForKey:@"mainWindow"];
        NSTextView *source = [controller valueForKey:@"sourceEditor"];
        NSTextView *result = [controller valueForKey:@"resultEditor"];
        NSButton *work = [controller valueForKey:@"workButton"];
        NSPopUpButton *language = [controller valueForKey:@"mainLanguage"];
        [controller setValue:[NSMutableArray new] forKey:@"sessionHistory"];
        [language selectItemAtIndex:0];
        NSString *sample = @"A good translation preserves meaning, tone and detail.\n\nFreeLingo processes your text locally on your Mac.";
        source.string = sample;
        result.string = @"Хороший перевод сохраняет смысл, тон и детали.\n\nFreeLingo обрабатывает ваш текст локально на вашем Mac.";
        [controller refreshGlassUI];
        [window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        for (NSString *appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
            window.appearance = [NSAppearance appearanceNamed:appearance];
            for (NSNumber *minimum in @[@NO, @YES]) {
                [window setContentSize:minimum.boolValue ? NSMakeSize(1000,578) : NSMakeSize(1180,740)];
                [window.contentView layoutSubtreeIfNeeded];
                [window displayIfNeeded];
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                CheckLayout(window.contentView);
                Check(source.visibleRect.size.width > 250 && source.visibleRect.size.height > 100, @"usable editor at minimum size");
                if (argc > 1) Snapshot(window, [NSString stringWithFormat:@"%s/glass-%@-%@.png", argv[1], [appearance isEqualToString:NSAppearanceNameAqua] ? @"light" : @"dark", minimum.boolValue ? @"minimum" : @"default"]);
            }
        }
        NSButton *history = [NSButton new]; history.tag = 3;
        NSString *saved = result.string;
        [controller navigateMain:history];
        Check(!work.enabled, @"history does not start translation");
        history.tag = 0; [controller navigateMain:history];
        Check([result.string isEqualToString:saved], @"return from history restores completed translation");
        FLJob *job = [FLJob new]; job.controller = controller; job.source = sample; job.mode = @"translate"; job.generation = 7;
        [controller setValue:@7 forKey:@"mainGeneration"];
        [controller setValue:@YES forKey:@"mainTranslating"];
        [controller translationProgress:@"Частичный перевод" job:job];
        Check([result.string isEqualToString:@"Частичный перевод"], @"streaming reaches result editor");
        history.tag=3; [controller navigateMain:history];
        Check([result.string isEqualToString:@"Частичный перевод"], @"history cannot replace active stream");
        [controller translationFinished:@"Полный перевод" success:YES job:job];
        Check(work.enabled && result.editable, @"completion restores editing and translation action");
        Check([[controller valueForKey:@"sessionHistory"] count] == 1, @"only terminal result enters history");
        [controller clearMain:nil];
        [controller translationProgress:@"Устаревший поток" job:job];
        [controller translationFinished:@"Устаревший результат" success:YES job:job];
        Check(!source.string.length && !result.string.length, @"clear rejects stale callbacks");
        Check([[controller valueForKey:@"sessionHistory"] count] == 1, @"clear preserves history");
        Check([FLResolvedSourceLanguage(sample, [controller valueForKey:@"mainSourceLanguage"]) isEqualToString:@"en"], @"automatic source language preserved");
        Check([FLSelectedLanguage(language) isEqualToString:@"ru"], @"target language preserved");
        Check(source.richText == NO && result.richText == NO && source.allowsUndo, @"plain text and undo");
        Check([work.keyEquivalent isEqualToString:@"\r"] && work.keyEquivalentModifierMask == NSEventModifierFlagCommand, @"command Return");
        printf("PASS: light/dark default/minimum layouts, usable editors, history restore, streaming, stale callbacks, completion, clear, auto language, target, plain text, undo, command Return\n");
        [window close];
    }
    return 0;
}
