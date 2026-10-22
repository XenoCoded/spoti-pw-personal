// Intro skip (personal fork, Batch 48): the watcher. Once a track has a
// marked intro end (set from the Player page's Bookmarks section, in the
// same defaults dictionary family as the bookmarks), playing that track
// jumps straight to the mark. The check is the A–B watcher's shape: a
// slow timer, the karaoke clock, the player's own seekTo: — and it fires
// once per play of a track, so seeking back into the intro by hand is
// never fought.
#import "Core/SGCore.h"
#import "Bookmark.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Headers/SPTPlayer.h"

static NSString *sg_appliedFor;

static void check(void) {
    NSString *track = SGKaraokePlayingTrack();
    if (!track) { sg_appliedFor = nil; return; }
    if ([track isEqualToString:sg_appliedFor]) {
        // A restart is a fresh play and earns a fresh skip; the position
        // falling back to the start is the only signal there is.
        NSInteger ms = SGKaraokePositionMs();
        if (ms >= 0 && ms < 1000) sg_appliedFor = nil;
        else return;
    }
    NSDictionary *intros = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyIntros];
    NSNumber *mark = [intros isKindOfClass:NSDictionary.class] ? intros[track] : nil;
    if (![mark isKindOfClass:NSNumber.class]) return;
    NSInteger ms = SGKaraokePositionMs();
    if (ms < 0) return;
    double position = ms / 1000.0;
    // Only from inside the intro: a track resumed past the mark (a
    // bookmark jump, a cross-device handoff) is left alone, and counts
    // as handled so the check stays cheap.
    if (position >= mark.doubleValue) { sg_appliedFor = [track copy]; return; }
    id<SPTPlayer> player = SGKaraokePlayer();
    [player seekTo:mark.doubleValue];
    sg_appliedFor = [track copy];
    SGLog(@"intro skip: %@ to %.1fs", track, mark.doubleValue);
}

// The timer exists only while a mark does (Batch 93): with no intros
// stored, the old shape woke twice a second forever to read an empty
// dictionary. Marks are written to defaults, and every write posts
// NSUserDefaultsDidChangeNotification — the watcher follows the store,
// so a mark set mid-session arms the timer on the spot, exactly as
// before, and clearing the last mark puts it down.
static NSTimer *sg_timer;

static void refreshTimer(void) {
    NSDictionary *intros = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyIntros];
    BOOL armed = [intros isKindOfClass:NSDictionary.class] && intros.count > 0;
    if (armed && !sg_timer) {
        sg_timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { check(); }];
        [NSRunLoop.mainRunLoop addTimer:sg_timer forMode:NSRunLoopCommonModes];
    } else if (!armed && sg_timer) {
        [sg_timer invalidate];
        sg_timer = nil;
    }
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        refreshTimer();
        [NSNotificationCenter.defaultCenter
            addObserverForName:NSUserDefaultsDidChangeNotification object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) { refreshTimer(); }];
    });
    SGLog(@"intro skip: watching");
}
