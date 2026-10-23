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
#import "Shared/Lyrics/Lyrics.h"

@interface SGStatsWatcher : NSObject <SGPlayerStateObserver>
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *countedURI;
@property (nonatomic) BOOL playing;
@property (nonatomic, strong) NSDate *since;
// A play waiting on the scrobble rule (Batch 85): the journal entry is
// already written, but the counter waits for the threshold.
@property (nonatomic, copy) NSString *pendingURI;
@property (nonatomic, copy) NSString *pendingTitle;
@property (nonatomic, copy) NSString *pendingArtist;
@property (nonatomic) NSTimeInterval pendingDuration;
@property (nonatomic, strong) NSTimer *ruleTimer;
@end

@implementation SGStatsWatcher

- (void)flush {
    if (self.playing && self.since && self.uri) {
        SGStatsAddListening(self.uri, -self.since.timeIntervalSinceNow);
    }
    self.since = [NSDate date];
}

- (void)dropPending {
    self.pendingURI = nil;
    self.pendingTitle = nil;
    self.pendingArtist = nil;
    [self.ruleTimer invalidate];
    self.ruleTimer = nil;
}

- (void)armPending:(NSString *)uri title:(NSString *)title artist:(NSString *)artist
          duration:(NSTimeInterval)duration {
    self.pendingURI = uri;
    self.pendingTitle = title;
    self.pendingArtist = artist;
    self.pendingDuration = duration;
    [self.ruleTimer invalidate];
    self.ruleTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self
                            selector:@selector(ruleTick) userInfo:nil repeats:YES];
}

// The scrobble rule's clock: a waiting play counts when the position
// crosses its threshold. Seeking past it counts, pausing freezes the
// position so nothing crosses, and a track skipped early simply never
// counts — the pending play dies with the track change.
- (void)ruleTick {
    if (!self.pendingURI) {
        [self.ruleTimer invalidate];
        self.ruleTimer = nil;
        return;
    }
    double durationMs = self.pendingDuration * 1000;
    double thresholdMs = SGInt(SGKeyStatsPlayRule, 0) == 2
        ? MIN(240000, durationMs) : durationMs * 0.5;
    if (thresholdMs <= 0) thresholdMs = 0;
    if (SGKaraokePositionMs() >= thresholdMs) {
        SGStatsCountPlay(self.pendingURI, self.pendingTitle, self.pendingArtist);
        self.countedURI = self.pendingURI;
        [self dropPending];
    }
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    // The master switch is read live (Batch 94): it used to be
    // launch-gated both ways — the watcher only existed when the
    // flag was on at %ctor, so on mid-session counted nothing and
    // off mid-session kept counting until a restart. Off drops the
    // in-flight stretch uncounted; on resumes with the next state.
    if (!SGFlag(SGKeyListeningStats, NO)) {
        [self dropPending];
        self.countedURI = nil;
        self.uri = nil;
        self.playing = NO;
        self.since = nil;
        return;
    }
    [self flush];
    NSString *uri = SGURIString(state.track.URI);
    BOOL playing = uri != nil && !state.isPaused;
    // A new track kills a waiting play uncounted; a pause and resume is
    // not a new track, so the wait survives it.
    if (![uri isEqualToString:self.uri]) [self dropPending];
    if (playing && uri && ![uri isEqualToString:self.countedURI]
        && ![uri isEqualToString:self.pendingURI]) {
        // The journal entry for the play (Batch 55) is written at once so
        // the heard seconds always have somewhere to land; only the play
        // counter can wait on the rule.
        SGStatsJournalPlay(uri, state.track.trackTitle, state.track.artistName, state.duration);
        if (SGInt(SGKeyStatsPlayRule, 0) == 0) {
            SGStatsCountPlay(uri, state.track.trackTitle, state.track.artistName);
            self.countedURI = uri;
        } else {
            [self armPending:uri title:state.track.trackTitle
                       artist:state.track.artistName duration:state.duration];
        }
    }
    if (!uri) {
        self.countedURI = nil;
        [self dropPending];
    }
    self.uri = uri;
    self.playing = playing;
    self.since = playing ? [NSDate date] : nil;
}

@end

static SGStatsWatcher *sg_watcher;

%ctor {
    sg_watcher = [SGStatsWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) { [sg_watcher flush]; }];
    SGLog(@"listening stats: watching (the switch is read live)");
}
