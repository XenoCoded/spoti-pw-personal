// The Player page's sleep timer row.
#import "SleepTimer.h"
#import "Settings/SGModPage.h"

NSArray<SGModRow *> *SGSleepTimerRows(void) {
    return @[SGChoiceRow(@"Sleep timer",
                         @"Pauses Spotify when the time is up. Set it here; the Live Activity's card has its own, for the lock screen.",
                         SGKeySleepTimer,
                         @[@"Off", @"15 minutes", @"30 minutes", @"45 minutes", @"1 hour", @"End of track"],
                         0)];
}
