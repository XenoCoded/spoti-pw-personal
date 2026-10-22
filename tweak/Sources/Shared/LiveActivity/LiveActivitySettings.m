// The Live Activity page (App/ModSettings.x links it from the root, under either look).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "LiveActivity.h"

static NSArray<NSString *> *viewNames(void) {
    return @[@"Lyrics", @"Queue", @"Control menu"];
}

// The rows alone, so the Lock screen page can hold them beside the artwork
// rows (Batch 9: one home for everything the lock screen shows).
NSArray<SGModRow *> *SGLiveActivityRows(void) {
    SGModRow *on = SGOptionRow(@"Live Activity", nil, SGKeyLiveActivity);
    on.changed = ^(BOOL value) { SGSetLiveActivityEnabled(value); };
    SGModRow *view = SGChoiceRow(@"Shows", nil, SGKeyLiveActivityView, viewNames(), SGLiveActivityLyrics);
    SGModRow *idle = SGChoiceRow(@"After pausing", @"Ends the activity instead of leaving it on the lock screen until the system expires it.",
                                 SGKeyLiveActivityIdleEnd,
                                 @[@"End after 5 minutes", @"End after 1 minute", @"Keep showing"],
                                 SGLiveActivityIdleEnd5Min);
    // The lyrics view's manners (Batch 59): whether the next line rides
    // under the current one, and whether a long break counts down to it.
    SGModRow *lines = SGChoiceRow(@"Lines", nil, SGKeyLiveActivityLines,
                                  @[@"Current + next", @"Current only"], 0);
    SGModRow *interlude = SGSwitchRow(@"Interlude countdown", @"During a long break between lines, the card counts down to the next line instead of sitting on a note.", SGKeyLiveActivityInterlude);
    // The card's accent (Batch 69): the cover's own colour, resolved by
    // the artwork palette the accents already use, or Spotify green.
    SGModRow *tint = SGChoiceRow(@"Tint", @"The card's accent colour: the playing cover's own, or Spotify green.", SGKeyLiveActivityTint,
                                 @[@"Cover colour", @"Spotify green"], 0);
    return @[on, view, idle, lines, interlude, tint];
}

UIViewController *SGLiveActivitySettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Live Activity" intro:nil sections:@[
        SGSection(nil, SGLiveActivityRows()),
    ] footer:nil];
}

NSString *SGLiveActivitySummary(void) {
    if (!SGFlag(SGKeyLiveActivity, NO)) return @"Off";
    NSInteger index = SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics);
    NSArray<NSString *> *names = viewNames();
    return index >= 0 && index < (NSInteger)names.count ? names[index] : names.firstObject;
}
