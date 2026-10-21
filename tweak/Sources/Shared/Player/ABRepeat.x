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
    SGLog(@"a-b repeat: B at %.1fs, looping %.1fs to %.1fs", sg_b, sg_a, sg_b);
}

void SGABClear(void) {
    sg_a = sg_b = -1;
    sg_track = nil;
}

static void check(void) {
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
