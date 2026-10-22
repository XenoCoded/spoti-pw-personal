// Star ratings (Batch 58): the user's own 0-5 stars per track, kept in the
// defaults on this phone — Spotify's heart is a different thing, and the
// mod has no proven way (and no intention) of touching it. Ratings are the
// classic power-listener feature Spotify took away (foobar2000, AIMP and
// Poweramp all keep theirs in the player's own store, exactly like this);
// here they feed the stats page's Hall of Fame and the gesture grid.
#import <Foundation/Foundation.h>

#define SGKeyRatings @"spotifyglass.ratings"

// 0 is unrated; setting 0 clears the rating.
NSInteger SGRatingForURI(NSString *uri);
void SGSetRating(NSString *uri, NSInteger stars);
// Every rating, URI → stars, as stored.
NSDictionary<NSString *, NSNumber *> *SGAllRatings(void);
// "★★★★☆" for a count — the one way stars are written anywhere in the mod.
NSString *SGStarsString(NSInteger stars);

// Cycle the playing track: unrated → 1 → … → 5 → unrated (the gesture).
void SGRateUpCurrent(void);

@class SGModRow;
NSArray<SGModRow *> *SGRatingsRows(void);
