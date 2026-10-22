// The bin's watcher: a player-state observer, the head gestures'
// shape — no second hook into the player. The state observer reports
// pauses and shuffles too, so a track is judged once, when its URI
// changes onto it; a binned track is skipped through the gesture
// grid's own perform, which is the one skip path every feature here
// shares (and the reason a skip feels like the user's own tap,
// haptics and all).
#import "Core/SGCore.h"
#import "TrackBin.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Gestures/Gestures.h"
#import "Headers/SPTPlayer.h"

@interface SGTrackBinWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGTrackBinWatcher {
    NSString *_seenURI;
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (!SGFlag(SGKeyTrackBin, NO)) { _seenURI = nil; return; }
    NSString *uri = SGURIString(state.track.URI);
    if (!uri.length || [uri isEqualToString:_seenURI]) return;
    _seenURI = [uri copy];
    if (!SGTrackBinned(uri)) return;
    SGLog(@"trash bin: skipping %@", uri);
    SGGesturePerform(SGGestureNextTrack);
}

@end

// Held in a static: the observer registry is weak (PlayerState.x), so a
// bare temporary deallocates as the constructor returns and the watcher
// never hears a thing — the bin never skipped a track.
static SGTrackBinWatcher *sg_watcher;

%ctor {
    sg_watcher = [SGTrackBinWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    SGLog(@"trash bin: watching");
}
