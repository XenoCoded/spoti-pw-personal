// Bookmarks: the Player page's rows. Everything reads the playing track
// and the karaoke clock at tap time; the jump is the player's seekTo:.
#import "Bookmark.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Headers/SPTPlayer.h"

static NSMutableDictionary<NSString *, NSNumber *> *bookmarks(void) {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyBookmarks];
    return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

static void saveBookmarks(NSDictionary *marks) {
    [NSUserDefaults.standardUserDefaults setObject:marks forKey:SGKeyBookmarks];
}

static NSString *formatTime(double seconds) {
    if (seconds < 0) return @"—";
    NSInteger total = (NSInteger)seconds;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

static double bookmarkFor(NSString *track) {
    NSNumber *mark = track ? bookmarks()[track] : nil;
    return mark ? mark.doubleValue : -1;
}

NSArray<SGModRow *> *SGBookmarkRows(void) {
    SGModRow *set = SGStatActionRow(@"Bookmark this moment", @"Saved for this track, whenever you come back to it.",
        ^NSString *{
            return formatTime(bookmarkFor(SGKaraokePlayingTrack()));
        }, ^{
            NSString *track = SGKaraokePlayingTrack();
            NSInteger ms = SGKaraokePositionMs();
            if (!track || ms < 0) return;
            NSMutableDictionary *marks = bookmarks();
            marks[track] = @(ms / 1000.0);
            saveBookmarks(marks);
            SGLog(@"bookmark: %@ at %.1fs", track, ms / 1000.0);
        });
    SGModRow *go = SGStatActionRow(@"Go to the bookmark", nil,
        ^NSString *{
            double mark = bookmarkFor(SGKaraokePlayingTrack());
            return mark >= 0 ? formatTime(mark) : @"—";
        }, ^{
            double mark = bookmarkFor(SGKaraokePlayingTrack());
            if (mark < 0) return;
            id<SPTPlayer> player = SGKaraokePlayer();
            [player seekTo:mark];
        });
    go.visible = ^BOOL { return bookmarkFor(SGKaraokePlayingTrack()) >= 0; };
    SGModRow *clear = SGActionRow(@"Clear the bookmark", nil, ^{
        NSString *track = SGKaraokePlayingTrack();
        if (!track) return;
        NSMutableDictionary *marks = bookmarks();
        [marks removeObjectForKey:track];
        saveBookmarks(marks);
    });
    clear.visible = go.visible;
    return @[set, go, clear];
}
