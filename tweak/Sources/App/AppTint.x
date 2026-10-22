// The tint itself: light hooks on the stock controls, refreshed when the
// artwork palette moves so a new song re-tints the app with its cover.
#import <UIKit/UIKit.h>
#import "AppTint.h"
#import "Core/SGCore.h"
#import "Core/SGUIMode.h"
#import "Settings/SGModPage.h"
#import "Native/Appearance/Appearance.h"
#import "Redesigned/Kit/SGRAccent.h"
#import "Shared/ArtworkPalette/ArtworkPalette.h"

UIColor *SGAppTintColor(void) {
    return SGRedesignedUIStored() ? SGRAccentColor() : SGAccentColor();
}

SGModRow *SGAppTintRow(void) {
    SGModRow *row = SGOptionRow(@"Accent on every control",
        @"The accent reaches Spotify's own switches, sliders and menus too, not just the mod's screens. With Match cover art on, the whole app re-tints with each song.",
        SGKeyAppTint);
    row.defaultOn = YES;
    return row;
}

// One control, tinted if a colour is going. The bars are here too: a tab
// bar or navigation bar holds colours it was handed when it was built, and
// nothing in UIKit re-reads them — left to itself the bar kept the old
// accent until a page change happened to rebuild it. A tab bar of the
// mod's own (the redesign's glass bar reads SGRAccent() as it lays out) is
// also told to lay out again, which is the pass that re-reads it.
static void tintControl(UIView *view, UIColor *color) {
    if ([view isKindOfClass:UISwitch.class]) {
        ((UISwitch *)view).onTintColor = color;
    } else if ([view isKindOfClass:UISlider.class]) {
        ((UISlider *)view).minimumTrackTintColor = color;
    } else if ([view isKindOfClass:UISegmentedControl.class]) {
        ((UISegmentedControl *)view).selectedSegmentTintColor = color;
    } else if ([view isKindOfClass:UIProgressView.class]) {
        ((UIProgressView *)view).progressTintColor = color;
    } else if ([view isKindOfClass:UITabBar.class]) {
        ((UITabBar *)view).tintColor = color;
        [view setNeedsLayout];
    } else if ([view isKindOfClass:UINavigationBar.class]) {
        ((UINavigationBar *)view).tintColor = color;
    } else if ([NSStringFromClass(view.class) containsString:@"TabBar"]) {
        [view setNeedsLayout];
    }
}

static void tintTree(UIView *view, UIColor *color) {
    tintControl(view, color);
    for (UIView *child in view.subviews) tintTree(child, color);
}

static void refreshTint(void);
// Refreshes are debounced (Batch 21 audit): the palette can announce itself
// several times as a cover lands, and walking every window for each one is
// waste. One walk, a beat after the last announcement.
static dispatch_block_t sg_pendingRefresh;
static void refreshTintSoon(void) {
    if (sg_pendingRefresh) dispatch_block_cancel(sg_pendingRefresh);
    sg_pendingRefresh = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        sg_pendingRefresh = nil;
        refreshTint();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), sg_pendingRefresh);
}

// Every window again: a new song's colour is only worth having if the
// controls already on screen take it too. The walk runs inside an
// animation block (Batch 77): window tint and the colours UIKit
// derives from it cross-fade to the new song's colour instead of
// snapping; the few control colours that cannot animate (a switch's
// on-tint) simply change, the way they always did.
static void refreshTint(void) {
    UIColor *color = SGAppTintColor();
    if (!color) return;
    [UIView animateWithDuration:0.6 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                window.tintColor = color;
                tintTree(window, color);
            }
        }
    } completion:nil];
}

%hook UISwitch
- (void)didMoveToWindow {
    %orig;
    UIColor *color = SGAppTintColor();
    if (color) self.onTintColor = color;
}
%end

%hook UISlider
- (void)didMoveToWindow {
    %orig;
    UIColor *color = SGAppTintColor();
    if (color) self.minimumTrackTintColor = color;
}
%end

%hook UISegmentedControl
- (void)didMoveToWindow {
    %orig;
    UIColor *color = SGAppTintColor();
    if (color) self.selectedSegmentTintColor = color;
}
%end

%hook UIWindow
- (void)didMoveToWindow {
    %orig;
    UIColor *color = SGAppTintColor();
    if (color) self.tintColor = color;
}
%end

%ctor {
    if (!SGFlag(SGKeyAppTint, YES)) return;
    %init;
    SGRequireClasses(@[@"UISwitch", @"UISlider", @"UIWindow"]);
    [NSNotificationCenter.defaultCenter addObserverForName:SGArtworkPaletteChangedNotification
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *note) { refreshTintSoon(); }];
    // A picked accent is a defaults write, and until now nothing listened
    // for one: the tint only moved when the next song's palette landed, so
    // a new accent reached the screen piecemeal — a control as it was drawn
    // again, the bar not until a page change. The note itself does not say
    // what changed, and the mod writes defaults often, so the colour is
    // compared and only a real change refreshes.
    static UIColor *lastTint;
    lastTint = SGAppTintColor();
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *note) {
        UIColor *now = SGAppTintColor();
        if (!now || [now isEqual:lastTint]) return;
        lastTint = now;
        refreshTintSoon();
    }];
    dispatch_async(dispatch_get_main_queue(), ^{ refreshTint(); });
    SGLog(@"app tint: on");
}
