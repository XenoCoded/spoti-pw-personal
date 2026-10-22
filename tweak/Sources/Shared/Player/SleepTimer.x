// The countdown: a one-second tick that reads the defaults, arms a deadline
// when a span is chosen, and pauses the player when the timer is up — the
// same end the Live Activity's timer uses, from inside the app.
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "SleepTimer.h"
#import "Shared/Lyrics/Lyrics.h"

static const NSInteger kSpans[] = {0, 15 * 60, 30 * 60, 45 * 60, 60 * 60, 0};
// End of track pauses this close to the end, so the next track never starts
// (the Live Activity's own figure, for the same reason).
static const NSInteger kEndOfTrackMs = 1500;

static void disarm(void);

void SGSleepTimerChoose(NSInteger choice) {
    disarm();
    [NSUserDefaults.standardUserDefaults setInteger:choice forKey:SGKeySleepTimer];
    SGLog(@"sleep timer: chosen %ld from a gesture", (long)choice);
}

static void disarm(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySleepTimerEnd];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySleepTimerArmed];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySleepTimerTrack];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySleepTimerLeft];
}

// Two paces (Batch 21 audit): an NSTimer cannot change its interval, so the
// timer is put down and another raised — one second while a countdown is
// armed (the end-of-track window is 1.5 s), fifteen while it is not, which
// is nearly all of the time. Arming from the settings page can lag up to
// the idle pace; the spans are fifteen minutes and up.
static NSTimer *sg_pace;
static BOOL sg_armedPace;
static void check(void);
static void setPace(BOOL armed) {
    if (sg_pace && sg_armedPace == armed) return;
    sg_armedPace = armed;
    [sg_pace invalidate];
    sg_pace = [NSTimer timerWithTimeInterval:armed ? 1 : 15 repeats:YES block:^(NSTimer *t) { check(); }];
    [NSRunLoop.mainRunLoop addTimer:sg_pace forMode:NSRunLoopCommonModes];
}

static void timerUp(id<SPTPlayer> player) {
    disarm();
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:SGKeySleepTimer];
    if (player.state && !player.state.isPaused) [player pause:nil];
    SGLog(@"sleep timer: up, paused");
}

static void check(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger choice = [defaults integerForKey:SGKeySleepTimer];
    id<SPTPlayer> player = SGKaraokePlayer();
    // Stop when the queue ends (Batch 56): a standing rule beside the
    // countdown, watched on the same tick. The last song of the queue is
    // playing, nothing is lined up behind it, and repeat is off — when it
    // reaches its end, pause there instead of letting Spotify roll into
    // its own picks. Once paused the state says so, and the rule rests.
    BOOL queueEndNear = NO;
    if (SGFlag(SGKeyStopAtQueueEnd, NO) && player.state) {
        SPTPlayerState *state = player.state;
        if (!state.isPaused && state.future.count == 0
            && !state.options.repeatingContext && !state.options.repeatingTrack) {
            double duration = [state respondsToSelector:@selector(duration)] ? state.duration : 0;
            NSInteger position = SGKaraokePositionMs();
            // Fast pace only for the last half minute; before that the
            // idle tick is soon enough to notice the moment coming.
            queueEndNear = duration > 0 && position >= 0 && duration * 1000 - position < 30000;
            if (queueEndNear && duration * 1000 - position < kEndOfTrackMs) {
                [player pause:nil];
                SGLog(@"queue end: paused at the end of the queue");
            }
        }
    }
    if (choice <= 0) {
        if ([defaults objectForKey:SGKeySleepTimerEnd] || [defaults objectForKey:SGKeySleepTimerTrack]) disarm();
        // The queue-end rule needs the fast pace while its moment is
        // anywhere near; the rest of the time it can tick with the idle.
        setPace(queueEndNear);
        return;
    }
    setPace(YES);
    if (!player) return;
    if (choice == 5) {
        // End of track: remember the track it was set on; a different one
        // means it slipped past the end unpaused, which still counts as up.
        NSString *trackID = SGKaraokePlayingTrack();
        NSString *armed = [defaults stringForKey:SGKeySleepTimerTrack];
        if (!armed) {
            if (trackID) [defaults setObject:trackID forKey:SGKeySleepTimerTrack];
            return;
        }
        double duration = [player.state respondsToSelector:@selector(duration)] ? player.state.duration : 0;
        NSInteger position = SGKaraokePositionMs();
        BOOL up = !trackID || ![trackID isEqualToString:armed]
            || (duration > 0 && position >= 0 && duration * 1000 - position < kEndOfTrackMs);
        if (up) timerUp(player);
        return;
    }
    if (choice >= 6) {
        // After N tracks (Batch 56): how many are left, the current one
        // included, lives in the defaults beside the track being counted
        // on, so the promise survives the app being swiped away. A new
        // track spends one; the last one's end is watched the way end of
        // track watches it, and slipping past that end unwatched still
        // counts as up.
        static const NSInteger kCounts[] = {0, 0, 0, 0, 0, 0, 2, 3, 5};
        if (choice >= (NSInteger)(sizeof(kCounts) / sizeof(kCounts[0]))) return;
        NSInteger left = [defaults integerForKey:SGKeySleepTimerLeft];
        NSString *trackID = SGKaraokePlayingTrack();
        NSString *counted = [defaults stringForKey:SGKeySleepTimerTrack];
        // Armed for a different choice is not armed at all — the same
        // rule the spans keep with their own armed key.
        if (left <= 0 || !counted.length || [defaults integerForKey:SGKeySleepTimerArmed] != choice) {
            if (trackID) {
                [defaults setInteger:kCounts[choice] forKey:SGKeySleepTimerLeft];
                [defaults setObject:trackID forKey:SGKeySleepTimerTrack];
                [defaults setInteger:choice forKey:SGKeySleepTimerArmed];
            }
            return;
        }
        if (trackID && ![trackID isEqualToString:counted]) {
            if (left <= 1) { timerUp(player); return; }
            [defaults setInteger:left - 1 forKey:SGKeySleepTimerLeft];
            [defaults setObject:trackID forKey:SGKeySleepTimerTrack];
            return;
        }
        if (left == 1) {
            double duration = [player.state respondsToSelector:@selector(duration)] ? player.state.duration : 0;
            NSInteger position = SGKaraokePositionMs();
            if (!trackID || (duration > 0 && position >= 0 && duration * 1000 - position < kEndOfTrackMs))
                timerUp(player);
        }
        return;
    }
    NSInteger armed = [defaults integerForKey:SGKeySleepTimerArmed];
    double end = [defaults doubleForKey:SGKeySleepTimerEnd];
    if (armed != choice || end <= 0) {
        [defaults setInteger:choice forKey:SGKeySleepTimerArmed];
        [defaults setDouble:NSDate.date.timeIntervalSince1970 + kSpans[choice] forKey:SGKeySleepTimerEnd];
        SGLog(@"sleep timer: armed for %ld minutes", (long)(kSpans[choice] / 60));
        return;
    }
    if (NSDate.date.timeIntervalSince1970 >= end) timerUp(player);
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        setPace(NO);
        check();
    });
    SGLog(@"sleep timer: watching");
}
