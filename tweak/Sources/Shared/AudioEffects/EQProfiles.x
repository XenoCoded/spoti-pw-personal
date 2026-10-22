// The route watcher: one system notification, no hooks. The class
// the app launched on is the starting point (nothing is captured or
// applied until the output actually changes); each change hands the
// outgoing class its current gains to keep, and the incoming class
// gets its saved shape back. All of it on the main queue — the DSP
// apply path is main-thread, and route notifications are not.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "EQProfiles.h"

static NSString *sg_lastClass;

static void routeChanged(void) {
    if (!SGFlag(SGKeyDSPAutoEQ, NO)) { sg_lastClass = SGEQCurrentRouteClass(); return; }
    NSString *now = SGEQCurrentRouteClass();
    if ([now isEqualToString:sg_lastClass]) return;
    if (sg_lastClass) SGEQCaptureProfile(sg_lastClass);
    sg_lastClass = [now copy];
    SGEQApplyProfile(now);
}

%ctor {
    sg_lastClass = [SGEQCurrentRouteClass() copy];
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
                                                      object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ routeChanged(); });
    }];
    SGLog(@"eq profiles: watching from %@", sg_lastClass);
}
