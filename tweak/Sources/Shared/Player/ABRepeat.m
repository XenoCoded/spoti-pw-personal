// A–B repeat: the Player page's rows. Set the points while the passage
// plays; the values read back what is set, and Clear takes the loop off.
#import "ABRepeat.h"
#import "Settings/SGModPage.h"

static NSString *formatPoint(double seconds) {
    if (seconds < 0) return @"—";
    NSInteger total = (NSInteger)seconds;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

NSArray<SGModRow *> *SGABRepeatRows(void) {
    SGModRow *a = SGStatActionRow(@"Set point A", @"Where the loop starts.",
        ^NSString *{ return formatPoint(SGABPointA()); }, ^{ SGABSetPointA(); });
    SGModRow *b = SGStatActionRow(@"Set point B", @"Where it ends, and jumps back to A.",
        ^NSString *{ return formatPoint(SGABPointB()); }, ^{ SGABSetPointB(); });
    SGModRow *clear = SGActionRow(@"Clear the loop", nil, ^{ SGABClear(); });
    clear.visible = ^BOOL { return SGABPointA() >= 0; };
    return @[a, b, clear];
}
