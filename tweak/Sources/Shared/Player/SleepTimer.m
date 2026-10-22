// The Player page's sleep timer row.
#import "SleepTimer.h"
#import "Settings/SGModPage.h"
#import "Core/SGPrefs.h"

static BOOL spanArmed(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger choice = SGInt(SGKeySleepTimer, 0);
    return choice >= 1 && choice <= 4
        && [defaults integerForKey:SGKeySleepTimerArmed] == choice
        && [defaults doubleForKey:SGKeySleepTimerEnd] > NSDate.date.timeIntervalSince1970;
}

void SGSleepTimerExtend(void) {
    if (!spanArmed()) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:[defaults doubleForKey:SGKeySleepTimerEnd] + 900 forKey:SGKeySleepTimerEnd];
}

NSArray<SGModRow *> *SGSleepTimerRows(void) {
    // The names are the stored choices, in order — see SleepTimer.h on
    // why the list only grows at the end.
    NSArray<NSString *> *names = @[@"Off", @"15 minutes", @"30 minutes", @"45 minutes", @"1 hour",
                                   @"End of track", @"After 2 tracks", @"After 3 tracks", @"After 5 tracks"];
    SGModRow *timer = SGChoiceRow(@"Sleep timer",
                         @"Pauses Spotify when the time is up. Set it here; the Live Activity's card has its own, for the lock screen.",
                         SGKeySleepTimer,
                         names,
                         0);
    // While a span is armed, the value says when it lands (Batch 33) —
    // "30 minutes" set at nine is a different promise at half past. A
    // track count says how many are left instead (Batch 56).
    timer.value = ^NSString *{
        NSInteger choice = SGInt(SGKeySleepTimer, 0);
        NSString *name = choice >= 0 && choice < (NSInteger)names.count ? names[(NSUInteger)choice] : @"Off";
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        double end = [defaults doubleForKey:SGKeySleepTimerEnd];
        if (choice >= 1 && choice <= 4 && [defaults integerForKey:SGKeySleepTimerArmed] == choice && end > NSDate.date.timeIntervalSince1970) {
            NSDateFormatter *clock = [NSDateFormatter new];
            clock.dateStyle = NSDateFormatterNoStyle;
            clock.timeStyle = NSDateFormatterShortStyle;
            return [NSString stringWithFormat:@"%@ · %@", name, [clock stringFromDate:[NSDate dateWithTimeIntervalSince1970:end]]];
        }
        if (choice >= 6) {
            NSInteger left = [defaults integerForKey:SGKeySleepTimerLeft];
            if (left > 0) return [NSString stringWithFormat:@"%@ · %ld left", name, (long)left];
        }
        return name;
    };
    // One more quarter hour (Batch 34): the timer is about to land and
    // sleep is not. The countdown reads the end key on every check, so
    // pushing it out is the whole feature — no re-arming, no lost span.
    SGModRow *extend = SGActionRow(@"Add 15 minutes", nil, ^{
        SGSleepTimerExtend();
    });
    extend.visible = ^BOOL { return spanArmed(); };
    // The queue's own end (Batch 56): not a countdown but a rule — when
    // the last song of the queue finishes, stop there.
    SGModRow *queueEnd = SGOptionRow(@"Stop when the queue ends",
        @"Pauses as the last song in the queue finishes, instead of rolling into Spotify's picks. Only with repeat off — a repeating queue never ends.",
        SGKeyStopAtQueueEnd);
    return @[timer, extend, queueEnd];
}
