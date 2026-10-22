// The head gestures' rows: one switch, and what each motion does, picked
// from the same list the double-tap grid picks from — a nod and a shake
// are two more ways of asking for a gesture action, nothing new to learn.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "HeadGestures.h"
#import "Shared/Gestures/Gestures.h"

NSArray<SGModRow *> *SGHeadGestureRows(void) {
    SGModRow *nod = SGChoiceRow(@"On a nod", nil, SGKeyHeadGestureNod,
        SGGestureActionNames(), SGGestureRateUp);
    nod.visible = ^BOOL { return SGFlag(SGKeyHeadGestures, NO); };
    SGModRow *shake = SGChoiceRow(@"On a head shake", nil, SGKeyHeadGestureShake,
        SGGestureActionNames(), SGGestureNextTrack);
    shake.visible = ^BOOL { return SGFlag(SGKeyHeadGestures, NO); };
    return @[
        SGOptionRow(@"Head gestures",
            @"With AirPods in, nod or shake your head to work the player — no hands, no screen. iOS may ask for Motion & Fitness access for Spotify; without it, or without AirPods that track head motion, nothing happens.",
            SGKeyHeadGestures),
        nod,
        shake,
    ];
}
