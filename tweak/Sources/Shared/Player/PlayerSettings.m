// The lock screen's settings, gathered on one page (Batch 9): everything the
// lock screen can show — the Live Activity, the artwork (Apple's animated
// canvas, or the fork's lyric artwork in its twenty-six styles) and Spotify's
// own lock screen control flags. This page used to sit inside Player under
// the name "Lock screen widget", two taps deep.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "PlayerSettings.h"
#import "Shared/LiveActivity/LiveActivity.h"
#import "Shared/LockScreenArtwork/LockScreenArtwork.h"
#import "Shared/LyricArtwork/LyricArtwork.h"

UIViewController *SGLockScreenSettingsPage(void) {
    NSMutableArray<SGModSection *> *sections = [NSMutableArray array];
    if (@available(iOS 17.0, *)) {
        [sections addObject:SGSection(@"Live Activity", SGLiveActivityRows())];
    }
    [sections addObject:SGSection(@"Artwork", [[SGAnimatedArtworkRows() arrayByAddingObjectsFromArray:SGLyricArtworkRows()]
        arrayByAddingObject:SGFlagRow(@"Companion content", @"ios-feature-lockscreen.companion_content_enabled")])];
    [sections addObject:SGSection(@"Controls", @[
        SGFlagRow(@"Like and dislike buttons", @"ios-feature-lockscreen.like_dislike_enabled"),
        SGFlagRow(@"Skip button on podcasts", @"ios-feature-lockscreen.skip_button_on_podcasts"),
        SGFlagRow(@"Chapter skip controls", @"ios-feature-lockscreen.enable_chapter_skip_controls"),
        SGFlagRow(@"Burst skip", @"ios-feature-lockscreen.burst_skip_enabled"),
    ])];
    return [[SGModPage alloc] initWithTitle:@"Lock screen" intro:SGRestartNote sections:sections footer:nil];
}
