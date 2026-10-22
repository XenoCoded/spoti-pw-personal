// AirPods head gestures (Batch 66): a nod and a head shake, read from the
// AirPods' motion (CMHeadphoneMotionManager), each performing one of the
// gesture actions (Shared/Gestures) — the nod the mod's like (rate the
// track up a star) and the shake the next track, until the Player page
// says otherwise. Spotify's own like has no proven selector in this
// codebase, so the nod performs the rating, the fork's heart.
#import <Foundation/Foundation.h>

#define SGKeyHeadGestures @"spotifyglass.headGestures"
// The SGGestureAction each motion performs, stored as its number.
#define SGKeyHeadGestureNod @"spotifyglass.headGestures.nod"
#define SGKeyHeadGestureShake @"spotifyglass.headGestures.shake"

@class SGModRow;
// The Player page's Head gestures section: the switch and the two actions.
NSArray<SGModRow *> *SGHeadGestureRows(void);
