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

static void disarm(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySleepTimerEnd];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySleepTimerArmed];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySleepTimerTrack];
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
    if (choice <= 0) {
        if ([defaults objectForKey:SGKeySleepTimerEnd] || [defaults objectForKey:SGKeySleepTimerTrack]) disarm();
        return;
    }
    id<SPTPlayer> player = SGKaraokePlayer();
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
    if (choice > 5) return;
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
        NSTimer *timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { check(); }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
    SGLog(@"sleep timer: watching");
}
