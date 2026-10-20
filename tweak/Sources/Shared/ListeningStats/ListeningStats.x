// The counting: one observer of the shared player state (Shared/Player/PlayerState),
// no hook of its own. A stretch of playing runs from one state change to the next, and
// its length goes to the track that was current when it began; a track is counted as
// played when it is heard playing and has not been counted since it became current,
// so a pause and resume is not a second play, and neither is sitting on the page.
//
// Two honest limits: a track repeated on repeat-one never crosses a state change, so
// its repeats are not counted; and a stretch still running when the app is killed is
// lost with it, beyond the flush at a tidy termination.
#import "Core/SGCore.h"
#import "ListeningStats.h"
#import "Shared/Player/PlayerState.h"

@interface SGStatsWatcher : NSObject <SGPlayerStateObserver>
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *countedURI;
@property (nonatomic) BOOL playing;
@property (nonatomic, strong) NSDate *since;
@end

@implementation SGStatsWatcher

- (void)flush {
    if (self.playing && self.since && self.uri) {
        SGStatsAddListening(self.uri, -self.since.timeIntervalSinceNow);
    }
    self.since = [NSDate date];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self flush];
    NSString *uri = SGURIString(state.track.URI);
    BOOL playing = uri != nil && !state.isPaused;
    if (playing && ![uri isEqualToString:self.countedURI]) {
        SGStatsCountPlay(uri, state.track.trackTitle, state.track.artistName);
        self.countedURI = uri;
    }
    if (!uri) self.countedURI = nil;
    self.uri = uri;
    self.playing = playing;
    self.since = playing ? [NSDate date] : nil;
}

@end

static SGStatsWatcher *sg_watcher;

%ctor {
    if (!SGFlag(SGKeyListeningStats, NO)) return;
    sg_watcher = [SGStatsWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) { [sg_watcher flush]; }];
    SGLog(@"listening stats: on");
}
