// The playing song's own colour (personal fork): the cover's average, lifted until
// it can stand as an accent, kept in memory for whoever draws with it — the two
// looks' accent systems, when their Match cover art switch is on. Nothing is
// stored; a colour is worth having only while its song is playing.
#import <Foundation/Foundation.h>
#import <stdint.h>

// Posted on the main queue whenever the colour changes; the accent systems
// refresh their cached swap from it.
extern NSNotificationName const SGArtworkPaletteChangedNotification;

// Starts watching the player (idempotent, cheap to call).
void SGArtworkPaletteStart(void);
// The current track's colour as 0xRRGGBB; NO before the first cover lands.
BOOL SGArtworkPaletteRGB(uint32_t *rgbOut);
