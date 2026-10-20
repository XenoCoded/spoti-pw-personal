// App-wide accent tint (personal fork, Batch 10): the rice, everywhere. The
// accent the user picked — or the playing cover's colour, with Match cover art
// on — takes over the stock controls Spotify's own screens are built from:
// switches, sliders, segmented controls, progress bars and the window tint
// behind alerts and carets. While Spotify's own green is the accent, nothing
// is tinted: there is no colour to spread.
#import <Foundation/Foundation.h>

#define SGKeyAppTint @"spotifyglass.apptint"

@class SGModRow;
// The switch for the Appearance section, beside App font.
SGModRow *SGAppTintRow(void);
// The colour to spread, from whichever look is stored; nil for Spotify green.
@class UIColor;
UIColor *SGAppTintColor(void);
