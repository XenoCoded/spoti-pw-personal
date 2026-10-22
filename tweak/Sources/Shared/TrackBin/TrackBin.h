// Trash bin (personal fork, Batch 74): the artist block's twin, one
// level down. A binned track is skipped the moment it starts, whatever
// brought it up — a playlist, the queue, autoplay, a radio. A track is
// kept by URI, with the title and artist it had when it was binned, so
// a rename changes nothing. Binned is not deleted: the bin is a list
// on this page's sibling, and taking a track back out is one tap.
#import <UIKit/UIKit.h>

#define SGKeyTrackBin @"spotifyglass.trackBin"
#define SGKeyTrackBinList @"spotifyglass.trackBin.list"

extern NSString *const SGTrackURI;     // NSString, spotify:track:…
extern NSString *const SGTrackTitle;   // NSString
extern NSString *const SGTrackArtist;  // NSString

NSArray<NSDictionary *> *SGBinnedTracks(void);
void SGBinTrack(NSDictionary *track);
void SGUnbinTrack(NSString *uri);
BOOL SGTrackBinned(NSString *uri);

// The playing track as a bin entry ({uri, title, artist}), nil before
// the player has reported one.
NSDictionary *SGPlayingTrackEntry(void);

UIViewController *SGTrackBinSettingsPage(void);
