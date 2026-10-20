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

// One control, tinted if a colour is going.
static void tintControl(UIView *view, UIColor *color) {
    if ([view isKindOfClass:UISwitch.class]) {
        ((UISwitch *)view).onTintColor = color;
    } else if ([view isKindOfClass:UISlider.class]) {
        ((UISlider *)view).minimumTrackTintColor = color;
    } else if ([view isKindOfClass:UISegmentedControl.class]) {
        ((UISegmentedControl *)view).selectedSegmentTintColor = color;
    } else if ([view isKindOfClass:UIProgressView.class]) {
        ((UIProgressView *)view).progressTintColor = color;
    }
}

static void tintTree(UIView *view, UIColor *color) {
    tintControl(view, color);
    for (UIView *child in view.subviews) tintTree(child, color);
}

// Every window again: a new song's colour is only worth having if the
// controls already on screen take it too.
static void refreshTint(void) {
    UIColor *color = SGAppTintColor();
    if (!color) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            window.tintColor = color;
            tintTree(window, color);
        }
    }
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
                                                  usingBlock:^(NSNotification *note) { refreshTint(); }];
    dispatch_async(dispatch_get_main_queue(), ^{ refreshTint(); });
    SGLog(@"app tint: on");
}
