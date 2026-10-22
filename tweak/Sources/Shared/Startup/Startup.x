// Opens to, the moving parts: remembering the last place, and going there (or
// to the chosen tab) once at launch. Both halves are gated on the choice in
// the constructor — "Spotify decides" costs nothing at all, no observer, no
// timer, which the cold-start audit can hold the rest of the mod to as well.
//
// The last place is remembered two ways, whichever happened most recently:
// the playing context, from the player state, and any page the app itself
// navigates to, from the link dispatcher — a playlist browsed without
// playing anything is a place too, and the player alone never hears of it.
//
// The jump itself used to be one blind call a second and a half after the
// app became active, and on a cold start that lands before the link
// dispatcher exists (it is built as the main UI loads): the call answered
// NO, the result was never looked at, and the app opened on Home as if the
// setting did not exist. Now the jump waits for the dispatcher, gives
// Spotify's own launch routing (a tapped link, a notification, its own
// restore) a beat more, and opens; for Last place it opens once more a
// little later if the remembered place is still the remembered place, in
// case Spotify's restore landed after the first try. It fires once per
// process; coming back from the background is not a start.
#import "Core/SGCore.h"
#import "Startup.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Navigation/Links.h"
#import "Headers/SPTLinkDispatcherImplementation.h"

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
static BOOL sg_jumped, sg_recordNav;
static NSString *sg_lastNav;
static NSInteger sg_attempts;

static void sg_tryJump(void) {
    if (sg_jumped) return;
    sg_attempts++;
    NSString *target = SGStartupTargetURI();
    if (!target.length) { sg_jumped = YES; return; }
    if (SGLinkDispatcher()) {
        sg_jumped = YES;
        // The dispatcher is up, which is to say the main UI has loaded;
        // one beat more for Spotify's own launch routing to land first.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL opened = SGOpenSpotifyURI([NSURL URLWithString:target]);
            SGLog(@"startup: opened %@ (%@)", target, opened ? @"accepted" : @"refused");
            if (!sg_recordNav) return;
            // Spotify's own restore can still land after this and put the
            // app back on Home; if the remembered place has not moved since
            // (nobody has navigated anywhere), open it once more.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSString *now = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyStartupLastURI];
                if ([now isEqualToString:target]) SGOpenSpotifyURI([NSURL URLWithString:target]);
            });
        });
        return;
    }
    if (sg_attempts > 20) {   // a quarter of a minute with no dispatcher: try blind, once
        sg_jumped = YES;
        SGOpenSpotifyURI([NSURL URLWithString:target]);
        SGLog(@"startup: the dispatcher never came up, opened %@ blind", target);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ sg_tryJump(); });
}

// Every page the app navigates to is a candidate last place, the dispatcher
// being the one door they all go through. Searches and the app's internal
// plumbing are not places, and a URI carrying a query is a moment, not a
// page.
static void recordNavigation(NSURL *uri) {
    if (!sg_recordNav || !uri) return;
    NSString *text = uri.absoluteString;
    if (![text hasPrefix:@"spotify:"] || [text hasPrefix:@"spotify:search"] ||
        [text hasPrefix:@"spotify:internal"] || [text containsString:@"?"]) return;
    if ([text isEqualToString:sg_lastNav]) return;
    sg_lastNav = text;
    [NSUserDefaults.standardUserDefaults setObject:text forKey:SGKeyStartupLastURI];
}

%hook SPTLinkDispatcherImplementation
// 9.1.90's shape; the interactionID form below is 9.1.78's, kept for
// older builds — on 9.1.90 it simply never fires (Batch 93).
- (void)navigateToURI:(NSURL *)uri options:(id)options reason:(id)reason
    completionHandler:(id)completionHandler resultHandler:(id)resultHandler {
    %orig;
    recordNavigation(uri);
}
- (void)navigateToURI:(NSURL *)uri options:(long long)options interactionID:(id)interactionID {
    %orig;
    recordNavigation(uri);
}
%end

%ctor {
    NSInteger choice = SGInt(SGKeyStartup, SGStartupSpotifyDecides);
    if (choice == SGStartupSpotifyDecides) return;
    %init;
    if (choice == SGStartupLastPlace) {
        sg_recorder = [SGStartupRecorder new];
        SGAddPlayerStateObserver(sg_recorder);
        sg_recordNav = YES;
    }
    sg_activeObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        if (sg_jumped) return;
        [NSNotificationCenter.defaultCenter removeObserver:sg_activeObserver];
        sg_activeObserver = nil;
        sg_tryJump();
    }];
    SGLog(@"startup: on (choice %ld)", (long)choice);
}
