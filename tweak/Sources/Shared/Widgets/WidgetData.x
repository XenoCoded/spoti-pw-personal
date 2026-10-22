// Keeps the widgets' data written: on every player state change, and on
// a slow timer while things play, since the current line moves without
// a state change ever announcing it.
#import "Core/SGCore.h"
#import "WidgetData.h"
#import "Shared/Player/PlayerState.h"

@interface SGWidgetWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGWidgetWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    SGWidgetDataWrite();
}
@end

// Held in a static: the observer registry is weak (PlayerState.x), so a
// bare temporary deallocates as the constructor returns and the widgets
// were left to the slow timer alone — stale by up to twenty seconds, or
// for good while paused.
static SGWidgetWatcher *sg_watcher;

%ctor {
    sg_watcher = [SGWidgetWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    // One write as the app settles (Batch 91): a widget added while a
    // song was already playing otherwise waited for the next track
    // change or the playing-only timer to say anything at all.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ SGWidgetDataWrite(); });
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:20 repeats:YES block:^(NSTimer *t) {
            if (!SGPlayerState().isPaused) SGWidgetDataWrite();
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
}
