// The profiles' page: the switch, where the sound is going right
// now, a save-it-now tap for the impatient, and the saved profiles
// with a tap to clear each. Built fresh when opened, the stats
// page's way, so every label is the truth as it stands.
#import "Core/SGCore.h"
#import "EQProfiles.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"

UIViewController *SGEQProfilesSettingsPage(void) {
    NSMutableArray<SGModSection *> *sections = [NSMutableArray array];
    NSString *current = SGEQCurrentRouteClass();
    SGModRow *on = SGOptionRow(@"EQ follows the output", @"Speaker, headphones, Bluetooth and the car each keep their own EQ. Leaving one saves its sound; arriving restores it.", SGKeyDSPAutoEQ);
    SGModRow *now = SGStatRow(@"Listening on", ^NSString *{ return SGEQRouteClassName(SGEQCurrentRouteClass()); });
    SGModRow *save = SGActionRow([NSString stringWithFormat:@"Save the current EQ for %@", SGEQRouteClassName(current)], @"Captures the EQ gains as they stand; the automatic save when you switch outputs does this too.", ^{
        SGEQCaptureProfile(SGEQCurrentRouteClass());
    });
    [sections addObject:SGSection(nil, @[on, now, save])];

    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    for (NSString *routeClass in @[@"speaker", @"headphones", @"bluetooth", @"car"]) {
        if (!SGEQHasProfile(routeClass)) continue;
        [rows addObject:SGActionRow([SGEQRouteClassName(routeClass) stringByAppendingString:@" profile"],
                                     @"Saved — tap to clear it", ^{
            SGEQClearProfile(routeClass);
        })];
    }
    if (rows.count) [sections addObject:SGSection(@"Saved profiles — tap to clear", rows)];
    return [[SGModPage alloc] initWithTitle:@"EQ by output" intro:nil sections:sections footer:nil];
}
