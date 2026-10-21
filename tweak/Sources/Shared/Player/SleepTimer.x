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
    if (choice <= 0) {
        if ([defaults objectForKey:SGKeySleepTimerEnd] || [defaults objectForKey:SGKeySleepTimerTrack]) disarm();
        setPace(NO);
        return;
    }
    setPace(YES);
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
        setPace(NO);
        check();
    });
    SGLog(@"sleep timer: watching");
}
