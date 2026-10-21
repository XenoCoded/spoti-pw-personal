// Bookmarks (personal fork, Batch 40): one saved moment per track, the
// AIMP/Winamp trick for long songs and podcasts. A–B repeat loops a
// passage now; a bookmark is for coming back — it lives in the defaults,
// keyed by the track, so it survives the app and the phone restarting.
#import <Foundation/Foundation.h>

@class SGModRow;
NSArray<SGModRow *> *SGBookmarkRows(void);

// The taps themselves, shared with the gesture grid (Batch 41).
void SGBookmarkSetCurrent(void);
void SGBookmarkGo(void);

#define SGKeyBookmarks @"spotifyglass.bookmarks"
