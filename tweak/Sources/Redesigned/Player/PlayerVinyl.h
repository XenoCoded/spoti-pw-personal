// Vinyl mode (personal fork, Batch 82): the Redesigned player's cover
// becomes a spinning record — the playing artwork as the label, grooves
// etched in, the spin freezing where it is when playback pauses, the way
// a real turntable stops. Off until switched on; the native look is
// untouched.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// The vinyl disc attached under this tilt view, if any (Batch 94):
// PlayerArtwork's cover lookup asks, so it can never mistake the
// record for the cover and cache the mistake.
UIView *SGRVinylDiscIn(UIView *tilt);

@class SGModRow;
NSArray<SGModRow *> *SGRVinylRows(void);

// Off until switched on.
#define SGKeyVinyl @"spotifyglass.redesign.vinyl"
