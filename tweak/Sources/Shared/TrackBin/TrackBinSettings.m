// The bin's page: the master switch, the bin-this-track tap, and the
// list itself. Rows are built when the page opens, the stats page's
// way — what a row says is the list as it stands then. Taking a track
// out is a tap on its row; there is no separate edit mode to find.
#import "Core/SGCore.h"
#import "TrackBin.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Gestures/Gestures.h"

UIViewController *SGTrackBinSettingsPage(void) {
    NSMutableArray<SGModSection *> *sections = [NSMutableArray array];
    SGModRow *on = SGOptionRow(@"Trash bin", @"Binned tracks are skipped the moment they start — in playlists, the queue, autoplay, anywhere.", SGKeyTrackBin);
    SGModRow *bin = SGActionRow(@"Bin the playing track", nil, ^{
        NSDictionary *entry = SGPlayingTrackEntry();
        if (!entry) return;
        SGBinTrack(entry);
        // Binning the song in your ears should end it, not just the
        // next time it comes around — with the bin on, skip it now.
        if (SGFlag(SGKeyTrackBin, NO)) SGGesturePerform(SGGestureNextTrack);
        SGLog(@"trash bin: binned %@", entry[SGTrackTitle]);
    });
    bin.color = SGRed();
    [sections addObject:SGSection(nil, @[on, bin])];

    NSArray<NSDictionary *> *tracks = SGBinnedTracks();
    if (tracks.count) {
        NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
        for (NSDictionary *track in tracks) {
            NSString *title = [track[SGTrackTitle] length] ? track[SGTrackTitle] : @"Unknown track";
            NSString *artist = [track[SGTrackArtist] length] ? track[SGTrackArtist] : nil;
            NSString *uri = track[SGTrackURI];
            [rows addObject:SGActionRow(title, artist, ^{
                SGUnbinTrack(uri);
            })];
        }
        [sections addObject:SGSection(@"In the bin — tap to take back out", rows)];
    }
    return [[SGModPage alloc] initWithTitle:@"Trash bin" intro:nil sections:sections footer:nil];
}
