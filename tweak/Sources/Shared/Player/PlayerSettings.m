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
#import "Shared/ListeningStats/ListeningStats.h"
#import "PlayerState.h"
#import "Headers/SPTPlayer.h"

static NSTimeInterval sg_copiedAt;
static NSTimeInterval sg_linkCopiedAt;

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
    // The way in (Batch 51): whoever receives the queue usually wants
    // the song that's playing right now first.
    NSString *playingId = SGKaraokePlayingTrack();
    if (playingId.length) {
        [lines addObject:@""];
        [lines addObject:[@"https://open.spotify.com/track/" stringByAppendingString:playingId]];
    }
    // The other direction (Batch 26): what led here, most recent first.
    id reverse = [state respondsToSelector:@selector(reverse)] ? state.reverse : nil;
    if ([reverse isKindOfClass:NSArray.class] && ((NSArray *)reverse).count) {
        [lines addObject:@""];
        [lines addObject:@"Played before"];
        for (id candidate in (NSArray *)reverse) {
            if ([candidate isKindOfClass:objc_getClass("SPTPlayerTrack")]) add(candidate, @"· ");
            if (lines.count >= 33) break;
        }
    }
    return lines.count ? [lines componentsJoinedByString:@"\n"] : nil;
}

NSArray<SGModRow *> *SGQueueShareRows(void) {
    // Your history with this track (Batch 44): the stats store already
    // knows — the Player page is where the question occurs to anyone.
    SGModRow *history = SGStatRow(@"Your history with this track", ^NSString *{
        SPTPlayerState *state = SGPlayerState();
        NSString *uri = state ? SGURIString(state.track.URI) : nil;
        NSDictionary *tracks = SGStatsSnapshot()[@"tracks"];
        NSDictionary *entry = uri ? tracks[uri] : nil;
        if (![entry isKindOfClass:NSDictionary.class] || [entry[@"plays"] integerValue] == 0) return @"First listen";
        // Its rank among everything ever counted (Batch 49): plays say
        // how often, the rank says how much it matters here.
        double seconds = [entry[@"seconds"] doubleValue];
        NSInteger rank = 1;
        for (NSDictionary *other in tracks.allValues) {
            if ([other[@"seconds"] doubleValue] > seconds) rank++;
        }
        return [NSString stringWithFormat:@"%@ plays · %@ · # %ld",
            entry[@"plays"], SGStatsFormatTime(seconds), (long)rank];
    });
    history.visible = ^BOOL {
        return SGFlag(SGKeyListeningStats, NO) && SGPlayerState() != nil;
    };
    SGModRow *link = SGStatActionRow(@"Copy link to this track",
        @"The open.spotify.com link, ready to send to anyone.",
        ^NSString *{
            return NSDate.date.timeIntervalSince1970 - sg_linkCopiedAt < 2.5 ? @"Copied ✓" : @"Copy";
        },
        ^{
            NSString *track = SGKaraokePlayingTrack();
            if (!track.length) return;
            UIPasteboard.generalPasteboard.string =
                [@"https://open.spotify.com/track/" stringByAppendingString:track];
            sg_linkCopiedAt = NSDate.date.timeIntervalSince1970;
        });
    link.visible = ^BOOL { return SGKaraokePlayingTrack().length > 0; };
    SGModRow *name = SGStatActionRow(@"Copy track name",
        @"Title and artist as plain text.",
        ^NSString *{ return @"Copy"; },
        ^{
            SPTPlayerState *state = SGPlayerState();
            NSString *title = state.track.trackTitle;
            if (!title.length) return;
            NSString *artist = state.track.artistName.length
                ? [@" — " stringByAppendingString:state.track.artistName] : @"";
            UIPasteboard.generalPasteboard.string = [title stringByAppendingString:artist];
        });
    name.visible = link.visible;
    return @[history, link, name, SGStatActionRow(@"Copy the queue as text",
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
