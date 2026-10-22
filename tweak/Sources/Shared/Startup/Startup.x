// Opens to, the moving parts: remembering the last place, and going there (or
// to the chosen tab) once at launch. Both halves are gated on the choice in
// the constructor — "Spotify decides" costs nothing at all, no observer, no
// timer, which the cold-start audit can hold the rest of the mod to as well.
//
// The jump waits a beat after the app first becomes active: Spotify's own
// launch routing (a tapped link, a notification, its own restore) lands
// first, and the mod's destination only fills the ordinary cold start. It
// fires once per process; coming back from the background is not a start.
#import "Core/SGCore.h"
#import "Startup.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Navigation/Links.h"

@interface SGStartupRecorder : NSObject <SGPlayerStateObserver>
@property (nonatomic, copy) NSString *recorded;
@end

@implementation SGStartupRecorder

- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *context = SGURIString(state.contextURI);
    // A search that happened to be playing is not a place worth reopening;
    // with no context at all, the track itself is the place.
    NSString *place = (context.length && ![context hasPrefix:@"spotify:search"])
        ? context : SGURIString(state.track.URI);
    if (!place.length || [place isEqualToString:self.recorded]) return;
    self.recorded = place;
    [NSUserDefaults.standardUserDefaults setObject:place forKey:SGKeyStartupLastURI];
}

@end

static SGStartupRecorder *sg_recorder;
static id sg_activeObserver;
static BOOL sg_jumped;

%ctor {
    NSInteger choice = SGInt(SGKeyStartup, SGStartupSpotifyDecides);
    if (choice == SGStartupSpotifyDecides) return;
    if (choice == SGStartupLastPlace) {
        sg_recorder = [SGStartupRecorder new];
        SGAddPlayerStateObserver(sg_recorder);
    }
    sg_activeObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        if (sg_jumped) return;
        sg_jumped = YES;
        [NSNotificationCenter.defaultCenter removeObserver:sg_activeObserver];
        sg_activeObserver = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSString *target = SGStartupTargetURI();
            if (target.length) {
                SGOpenSpotifyURI([NSURL URLWithString:target]);
                SGLog(@"startup: opened %@", target);
            }
        });
    }];
    SGLog(@"startup: on (choice %ld)", (long)choice);
}
