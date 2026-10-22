// Vinyl mode (personal fork, Batch 82): the Redesigned player's cover
// becomes a spinning record — the playing artwork as the label, grooves
// etched in, the spin freezing where it is when playback pauses, the way
// a real turntable stops. Off until switched on; the native look is
// untouched.
#import <Foundation/Foundation.h>

@class SGModRow;
NSArray<SGModRow *> *SGRVinylRows(void);

// Off until switched on.
#define SGKeyVinyl @"spotifyglass.redesign.vinyl"
