// Scan mode's watcher, the A–B / intro-skip shape: a half-second
// timer over the shared player state, nothing of its own hooked. A
// track is armed when its URI arrives; the slice is counted in ticks
// heard while actually playing, so a pause stretches the wait instead
// of eating the slice, and the skip goes through the gesture grid's
// perform like every other skip in the mod. Repeat-one is a fresh
// play: the position falling back to the start re-arms the same URI.
#import "Core/SGCore.h"
#import "ScanMode.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Headers/SPTPlayer.h"

static NSString *sg_scanURI;
static BOOL sg_scanSeeked;
static BOOL sg_scanFired;
static double sg_scanHeard;

static void tick(void) {
    if (!SGFlag(SGKeyScanMode, NO)) { sg_scanURI = nil; return; }
    SPTPlayerState *state = SGPlayerState();
    NSString *uri = SGURIString(state.track.URI);
    if (!uri.length) { sg_scanURI = nil; return; }
    if (![uri isEqualToString:sg_scanURI]) {
        sg_scanURI = [uri copy];
        sg_scanSeeked = NO;
        sg_scanFired = NO;
        sg_scanHeard = 0;
    } else if (sg_scanFired && state.position < 1) {
        // The same track again from the top: a fresh play of it.
        sg_scanSeeked = NO;
        sg_scanFired = NO;
        sg_scanHeard = 0;
    }
    if (state.isPaused || sg_scanFired) return;

    if (!sg_scanSeeked) {
        sg_scanSeeked = YES;
        if (SGInt(SGKeyScanOffset, 1) == 1 && state.duration > 0) {
            double target = state.duration * 0.4;
            if (state.position < target) {
                id<SPTPlayer> player = SGKaraokePlayer();
                [player seekTo:target];
                SGLog(@"scan: %@ into the middle at %.0fs", uri, target);
            }
        }
    }
    sg_scanHeard += 0.5;
    if (sg_scanHeard >= SGScanSliceSeconds()) {
        sg_scanFired = YES;
        SGLog(@"scan: slice heard, next");
        SGGesturePerform(SGGestureNextTrack);
    }
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { tick(); }];
    });
    SGLog(@"scan mode: watching");
}
