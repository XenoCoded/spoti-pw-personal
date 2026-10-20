// An in-app sleep timer (personal fork, Batch 12). The Live Activity has one,
// but only on its card; this one is set from the Player page and lives in the
// defaults, so it survives the app being swiped away mid-countdown. When it
// is up, playback pauses and the setting returns to Off.
#import <Foundation/Foundation.h>

// The choice: 0 Off, 1-4 a span of minutes, 5 the end of the track.
#define SGKeySleepTimer @"spotifyglass.sleepTimer"
// The deadline (seconds since 1970) while a span is armed, and the choice it
// was armed for, so changing the choice re-arms instead of inheriting.
#define SGKeySleepTimerEnd @"spotifyglass.sleepTimer.end"
#define SGKeySleepTimerArmed @"spotifyglass.sleepTimer.armed"
// The track an end-of-track timer was set on.
#define SGKeySleepTimerTrack @"spotifyglass.sleepTimer.track"

@class SGModRow;
NSArray<SGModRow *> *SGSleepTimerRows(void);
// Choose from anywhere (the gesture grid): sets the choice and clears the
// last arming, so the countdown starts from this moment.
void SGSleepTimerChoose(NSInteger choice);
