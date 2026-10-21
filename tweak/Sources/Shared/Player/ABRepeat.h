// A–B repeat (personal fork, Batch 36): the passage loop every serious
// player has — Tauon, foobar2000, VLC — and Spotify never got. Mark where
// the good part starts and where it ends; when playback reaches the end
// it jumps back to the start, until the points are cleared or the track
// changes. The points live in memory only: they are a session thing, and
// a loop waiting for you tomorrow is a trap, not a feature.
#import <Foundation/Foundation.h>

@class SGModRow;
NSArray<SGModRow *> *SGABRepeatRows(void);

// The points, in seconds into the track they were set on; -1 when unset.
double SGABPointA(void);
double SGABPointB(void);
void SGABSetPointA(void);
void SGABSetPointB(void);
void SGABClear(void);
