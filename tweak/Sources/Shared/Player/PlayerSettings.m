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
#import "Shared/LyricArtwork/LyricClip.h"
#import "Shared/LyricsSources/LyricsSources.h"

UIViewController *SGLockScreenSettingsPage(void) {
    NSMutableArray<SGModSection *> *sections = [NSMutableArray array];
    if (@available(iOS 17.0, *)) {
        [sections addObject:SGSection(@"Live Activity", SGLiveActivityRows())];
    }
    [sections addObject:SGSection(@"Artwork", [[SGAnimatedArtworkRows() arrayByAddingObjectsFromArray:SGLyricArtworkRows()]
        arrayByAddingObject:SGFlagRow(@"Companion content", @"ios-feature-lockscreen.companion_content_enabled")])];
    [sections addObject:SGSection(@"Storage", @[
        SGStatActionRow(@"Animated clips", @"Rendered lyric clips kept on the phone. They render again if cleared.",
            ^NSString *{ return [NSByteCountFormatter stringFromByteCount:(long long)SGLyricClipCacheBytes() countStyle:NSByteCountFormatterCountStyleFile]; },
            ^{ SGLyricClipCacheClear(); }),
        SGStatActionRow(@"Offline lyrics", @"Lyrics kept on the phone for offline play. They are fetched again if cleared.",
            ^NSString *{ return [NSByteCountFormatter stringFromByteCount:(long long)SGLyricsCacheBytes() countStyle:NSByteCountFormatterCountStyleFile]; },
            ^{ SGLyricsCacheClear(); }),
    ])];
    [sections addObject:SGSection(@"Controls", @[
        SGFlagRow(@"Like and dislike buttons", @"ios-feature-lockscreen.like_dislike_enabled"),
        SGFlagRow(@"Skip button on podcasts", @"ios-feature-lockscreen.skip_button_on_podcasts"),
        SGFlagRow(@"Chapter skip controls", @"ios-feature-lockscreen.enable_chapter_skip_controls"),
        SGFlagRow(@"Burst skip", @"ios-feature-lockscreen.burst_skip_enabled"),
    ])];
    return [[SGModPage alloc] initWithTitle:@"Lock screen" intro:SGRestartNote sections:sections footer:nil];
}

// The queue as text: the playing track, then what's up next, one a line —
// the shape you would paste to a friend. Read from the player the karaoke
// system already watches; its state's `future` is the same list the Live
// Activity reads its up-next from.
#import "Shared/Lyrics/Lyrics.h"
#import "PlayerState.h"
#import "Headers/SPTPlayer.h"

static NSTimeInterval sg_copiedAt;

static NSString *queueText(void) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = player.state;
    if (!state.track) return nil;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^add)(SPTPlayerTrack *, NSString *) = ^(SPTPlayerTrack *track, NSString *mark) {
        if (!track.trackTitle.length) return;
        NSString *uri = SGURIString(track.URI);
        if (uri && [seen containsObject:uri]) return;
        if (uri) [seen addObject:uri];
        NSString *artist = track.artistName.length ? [@" — " stringByAppendingString:track.artistName] : @"";
        [lines addObject:[NSString stringWithFormat:@"%@%@%@", mark, track.trackTitle, artist]];
    };
    add(state.track, @"▶ ");
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    if ([future isKindOfClass:NSArray.class]) {
        for (id candidate in (NSArray *)future) {
            if ([candidate isKindOfClass:objc_getClass("SPTPlayerTrack")]) add(candidate, @"· ");
            if (lines.count >= 21) break;
        }
    }
    return lines.count ? [lines componentsJoinedByString:@"\n"] : nil;
}

NSArray<SGModRow *> *SGQueueShareRows(void) {
    return @[SGStatActionRow(@"Copy the queue as text",
        @"The playing song and what's up next, one a line, ready to paste anywhere.",
        ^NSString *{
            return NSDate.date.timeIntervalSince1970 - sg_copiedAt < 2.5 ? @"Copied ✓" : @"Copy";
        },
        ^{
            NSString *text = queueText();
            if (!text) return;
            UIPasteboard.generalPasteboard.string = text;
            sg_copiedAt = NSDate.date.timeIntervalSince1970;
        })];
}
