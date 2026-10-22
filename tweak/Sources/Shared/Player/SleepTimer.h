// An in-app sleep timer (personal fork, Batch 12). The Live Activity has one,
// but only on its card; this one is set from the Player page and lives in the
// defaults, so it survives the app being swiped away mid-countdown. When it
// is up, playback pauses and the setting returns to Off.
#import <Foundation/Foundation.h>

// The choice: 0 Off, 1-4 a span of minutes, 5 the end of the track,
// 6-8 a count of tracks (after 2, after 3, after 5). The list only ever
// grows at the end — a stored choice must mean the same thing forever.
#define SGKeySleepTimer @"spotifyglass.sleepTimer"
// The deadline (seconds since 1970) while a span is armed, and the choice it
// was armed for, so changing the choice re-arms instead of inheriting.
#define SGKeySleepTimerEnd @"spotifyglass.sleepTimer.end"
#define SGKeySleepTimerArmed @"spotifyglass.sleepTimer.armed"
// The track an end-of-track timer was set on.
#define SGKeySleepTimerTrack @"spotifyglass.sleepTimer.track"
// How many tracks a track-count choice still has to go, current one
// included (Batch 56), counted on SGKeySleepTimerTrack like the above.
#define SGKeySleepTimerLeft @"spotifyglass.sleepTimer.left"
// Stop when the queue ends (Batch 56): a standing switch, not a timer —
// pause as the queue's last song finishes instead of rolling into
// Spotify's own picks. Repeat off only; a repeating queue never ends.
#define SGKeyStopAtQueueEnd @"spotifyglass.stopAtQueueEnd"

@class SGModRow;
NSArray<SGModRow *> *SGSleepTimerRows(void);

// Push an armed span's deadline out a quarter hour (Batch 34's row, Batch
// 43's gesture). A no-op unless a span is actually armed and still ahead.
void SGSleepTimerExtend(void);
// Choose from anywhere (the gesture grid): sets the choice and clears the
// last arming, so the countdown starts from this moment.
void SGSleepTimerChoose(NSInteger choice);
