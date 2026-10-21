// A–B repeat: the watcher. Position is the karaoke clock the whole mod
// reads; the jump back is the player's own seekTo:, both proven wherever
// the mod touches playback. The timer ticks twice a second and does two
// pointer compares when no loop is set, so an unused feature costs
// nothing.
#import "Core/SGCore.h"
#import "ABRepeat.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Headers/SPTPlayer.h"

static double sg_a = -1, sg_b = -1;
static NSString *sg_track;

// The points persist (Batch 47), keyed to their track like the
// bookmarks: a passage you are practising should still be marked when
// you come back tomorrow. The Player page's rows show the points, so a
// restored loop is never invisible — and Clear forgets them everywhere.
#define SGKeyABA @"spotifyglass.abRepeat.a"
#define SGKeyABB @"spotifyglass.abRepeat.b"
#define SGKeyABTrack @"spotifyglass.abRepeat.track"

static void persist(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (sg_a >= 0 && sg_track) {
        [defaults setDouble:sg_a forKey:SGKeyABA];
        [defaults setDouble:sg_b forKey:SGKeyABB];
        [defaults setObject:sg_track forKey:SGKeyABTrack];
    } else {
        [defaults removeObjectForKey:SGKeyABA];
        [defaults removeObjectForKey:SGKeyABB];
        [defaults removeObjectForKey:SGKeyABTrack];
    }
}

static void restoreIfNeeded(void) {
    if (sg_a >= 0) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *stored = [defaults stringForKey:SGKeyABTrack];
    if (!stored || ![stored isEqualToString:SGKaraokePlayingTrack()]) return;
    sg_a = [defaults doubleForKey:SGKeyABA];
    sg_b = [defaults doubleForKey:SGKeyABB];
    sg_track = [stored copy];
    SGLog(@"a-b repeat: restored %.1fs to %.1fs", sg_a, sg_b);
}

double SGABPointA(void) { return sg_a; }
double SGABPointB(void) { return sg_b; }

static double nowSeconds(void) {
    NSInteger ms = SGKaraokePositionMs();
    return ms >= 0 ? ms / 1000.0 : -1;
}

void SGABSetPointA(void) {
    double now = nowSeconds();
    if (now < 0) return;
    sg_a = now;
    sg_track = [SGKaraokePlayingTrack() copy];
    if (sg_b >= 0 && sg_b <= sg_a + 1) sg_b = -1;
    persist();
    SGLog(@"a-b repeat: A at %.1fs", sg_a);
}

void SGABSetPointB(void) {
    double now = nowSeconds();
    if (now < 0) return;
    if (sg_a < 0) { SGABSetPointA(); return; }
    if (now <= sg_a + 1) {
        SGLog(@"a-b repeat: B must sit after A, ignored");
        return;
    }
    sg_b = now;
    persist();
    SGLog(@"a-b repeat: B at %.1fs, looping %.1fs to %.1fs", sg_b, sg_a, sg_b);
}

void SGABClear(void) {
    sg_a = sg_b = -1;
    sg_track = nil;
    persist();
}

static void check(void) {
    restoreIfNeeded();
    if (sg_a < 0 || sg_b < 0) return;
    NSString *playing = SGKaraokePlayingTrack();
    if (![playing isEqualToString:sg_track]) {
        SGABClear();
        return;
    }
    double now = nowSeconds();
    if (now >= sg_b) {
        id<SPTPlayer> player = SGKaraokePlayer();
        [player seekTo:sg_a];
        SGLog(@"a-b repeat: back to A (%.1fs)", sg_a);
    }
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { check(); }];
    });
    SGLog(@"a-b repeat: watching");
}
