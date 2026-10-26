@interface FLGlassCanvas : NSView
@end
@implementation FLGlassCanvas
- (void)drawRect:(NSRect)dirtyRect { [NSColor.windowBackgroundColor setFill]; NSRectFill(dirtyRect); }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
@end

// Native Glass surfaces. Draw semantic colours in the current appearance so
// switching macOS appearance/contrast does not leave stale CALayer colours.
@interface FLGlassSurface : NSView
@property BOOL editor;
@end
@implementation FLGlassSurface
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, .5, .5)
        xRadius:16 yRadius:16];
    [(self.editor ? NSColor.textBackgroundColor : NSColor.controlBackgroundColor) setFill];
    [path fill];
    [NSColor.separatorColor setStroke];
    path.lineWidth = 1;
    [path stroke];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
@end

static void FLPin(NSView *child, NSView *parent, CGFloat inset) {
    child.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:child];
    [NSLayoutConstraint activateConstraints:@[
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:inset],
        [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-inset],
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor constant:inset],
        [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-inset]
    ]];
}
static NSStackView *FLStack(NSArray<NSView *> *views, BOOL vertical, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = vertical ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = vertical ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    stack.spacing = spacing;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}
static NSButton *FLIconButton(NSString *title, NSString *symbol, id target, SEL action) {
    NSButton *button = FLButton(title, target, action);
    button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    button.imagePosition = NSImageLeading;
    button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    button.toolTip = title;
    return button;
}
static NSTextField *FLHeading(NSString *title, CGFloat size) {
    NSTextField *label = FLLabel(title, size);
    label.font = [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    label.textColor = NSColor.labelColor;
    return label;
}
static NSView *FLEditorCard(NSScrollView *scroll, NSString *title, NSString *hint,
                          NSButton *action, NSTextField * __strong *counter) {
    FLGlassSurface *card = [FLGlassSurface new];
    card.editor = YES;
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *header = FLStack(@[FLHeading(title, 13), spacer, action], NO, 8);
    NSTextField *count = FLLabel(@"0 знаков", 11);
    count.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    *counter = count;
    NSTextField *help = FLLabel(hint, 11);
    help.lineBreakMode = NSLineBreakByTruncatingTail;
    [help setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *footer = FLStack(@[help, [NSView new], count], NO, 8);
    for (NSView *view in @[header, scroll, footer]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [header.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [header.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [header.heightAnchor constraintEqualToConstant:30],
        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:6],
        [scroll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:4],
        [scroll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-4],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-8],
        [footer.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [footer.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [footer.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14]
    ]];
    return card;
}
