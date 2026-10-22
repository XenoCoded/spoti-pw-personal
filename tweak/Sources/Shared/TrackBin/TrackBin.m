// The bin's store: one defaults list, read whole and written whole,
// the artist block's way — the list is a person's handful of grudges,
// not a database.
#import "TrackBin.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"

NSString *const SGTrackURI = @"uri";
NSString *const SGTrackTitle = @"title";
NSString *const SGTrackArtist = @"artist";

NSArray<NSDictionary *> *SGBinnedTracks(void) {
    NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyTrackBinList];
    return list ?: @[];
}

static void save(NSArray<NSDictionary *> *list) {
    [NSUserDefaults.standardUserDefaults setObject:list forKey:SGKeyTrackBinList];
}

BOOL SGTrackBinned(NSString *uri) {
    if (!uri.length) return NO;
    for (NSDictionary *track in SGBinnedTracks()) {
        if ([track[SGTrackURI] isEqualToString:uri]) return YES;
    }
    return NO;
}

void SGBinTrack(NSDictionary *track) {
    if (!track[SGTrackURI] || SGTrackBinned(track[SGTrackURI])) return;
    save([SGBinnedTracks() arrayByAddingObject:track]);
}

void SGUnbinTrack(NSString *uri) {
    NSPredicate *other = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *track, NSDictionary *bindings) {
        return ![track[SGTrackURI] isEqualToString:uri];
    }];
    save([SGBinnedTracks() filteredArrayUsingPredicate:other]);
}

NSDictionary *SGPlayingTrackEntry(void) {
    SPTPlayerTrack *track = SGPlayerState().track;
    NSString *uri = SGURIString(track.URI);
    if (!uri.length) return nil;
    return @{SGTrackURI: uri,
             SGTrackTitle: track.trackTitle ?: @"",
             SGTrackArtist: track.artistName ?: @""};
}
