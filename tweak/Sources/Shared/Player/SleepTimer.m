// The Player page's sleep timer row.
#import "SleepTimer.h"
#import "Settings/SGModPage.h"
#import "Core/SGPrefs.h"

NSArray<SGModRow *> *SGSleepTimerRows(void) {
    SGModRow *timer = SGChoiceRow(@"Sleep timer",
                         @"Pauses Spotify when the time is up. Set it here; the Live Activity's card has its own, for the lock screen.",
                         SGKeySleepTimer,
                         @[@"Off", @"15 minutes", @"30 minutes", @"45 minutes", @"1 hour", @"End of track"],
                         0);
    // While a span is armed, the value says when it lands (Batch 33) —
    // "30 minutes" set at nine is a different promise at half past.
    timer.value = ^NSString *{
        NSInteger choice = SGInt(SGKeySleepTimer, 0);
        NSArray<NSString *> *names = @[@"Off", @"15 minutes", @"30 minutes", @"45 minutes", @"1 hour", @"End of track"];
        NSString *name = choice >= 0 && choice < (NSInteger)names.count ? names[(NSUInteger)choice] : @"Off";
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        double end = [defaults doubleForKey:SGKeySleepTimerEnd];
        if (choice >= 1 && choice <= 4 && [defaults integerForKey:SGKeySleepTimerArmed] == choice && end > NSDate.date.timeIntervalSince1970) {
            NSDateFormatter *clock = [NSDateFormatter new];
            clock.dateStyle = NSDateFormatterNoStyle;
            clock.timeStyle = NSDateFormatterShortStyle;
            return [NSString stringWithFormat:@"%@ · %@", name, [clock stringFromDate:[NSDate dateWithTimeIntervalSince1970:end]]];
        }
        return name;
    };
    return @[timer];
}
