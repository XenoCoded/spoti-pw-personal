// Opens to (personal fork): where Spotify lands when it starts. Spotify always
// opens on its own home; the user asked for the choice — back where they left
// off (the last playlist, album or artist that was playing), or a tab they
// pick. The choice is a plain defaults integer, read at launch like the rest
// of the mod's switches; "Last place" is remembered by the watchers in
// Startup.x — the player state's own context URI, and every navigation the
// app makes through its link dispatcher.
#import <UIKit/UIKit.h>

#define SGKeyStartup @"spotifyglass.startup"
#define SGKeyStartupLastURI @"spotifyglass.startup.lastURI"

typedef NS_ENUM(NSInteger, SGStartupChoice) {
    SGStartupSpotifyDecides = 0,
    SGStartupLastPlace = 1,
    SGStartupHome = 2,
    SGStartupSearch = 3,
    SGStartupLibrary = 4,
};

// The row for the Mod Settings root.
@class SGModRow;
SGModRow *SGStartupRow(void);

// The URI the chosen destination opens, or nil when there is nothing to open
// (Spotify decides, or Last place before anything has played).
NSString *SGStartupTargetURI(void);
