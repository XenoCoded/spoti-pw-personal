// Scan mode's rows: the switch and its two choices, bundled on the
// Player page — one section, everything about the mode in it.
#import "ScanMode.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"

double SGScanSliceSeconds(void) {
    static const double slices[] = {10, 15, 30};
    NSInteger choice = SGInt(SGKeyScanSeconds, 1);
    return slices[choice < 0 ? 1 : choice > 2 ? 2 : choice];
}

NSArray<SGModRow *> *SGScanModeRows(void) {
    // The reader defaults OFF (Batch 93): the switch showed ON while
    // scan mode was off.
    SGModRow *scan = SGSwitchRow(@"Scan mode", @"Play a short slice of each track, then move on — for skimming long playlists. A pause holds the slice.", SGKeyScanMode);
    scan.defaultOn = NO;
    return @[
        scan,
        SGChoiceRow(@"Slice length", nil, SGKeyScanSeconds,
                    @[@"10 seconds", @"15 seconds", @"30 seconds"], 1),
        SGChoiceRow(@"Slice from", @"The middle is a place, not a hook detector — it is just where choruses tend to live.", SGKeyScanOffset,
                    @[@"The start", @"The middle"], 1),
    ];
}
