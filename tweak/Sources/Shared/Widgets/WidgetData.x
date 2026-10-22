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

%ctor {
    SGAddPlayerStateObserver([SGWidgetWatcher new]);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:20 repeats:YES block:^(NSTimer *t) {
            if (!SGPlayerState().isPaused) SGWidgetDataWrite();
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
}
