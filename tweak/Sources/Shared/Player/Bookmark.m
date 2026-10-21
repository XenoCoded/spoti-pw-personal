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

void SGBookmarkSetCurrent(void) {
    NSString *track = SGKaraokePlayingTrack();
    NSInteger ms = SGKaraokePositionMs();
    if (!track || ms < 0) return;
    NSMutableDictionary *marks = bookmarks();
    marks[track] = @(ms / 1000.0);
    saveBookmarks(marks);
    SGLog(@"bookmark: %@ at %.1fs", track, ms / 1000.0);
}

void SGBookmarkGo(void) {
    double mark = bookmarkFor(SGKaraokePlayingTrack());
    if (mark < 0) return;
    id<SPTPlayer> player = SGKaraokePlayer();
    [player seekTo:mark];
}

static NSMutableDictionary<NSString *, NSNumber *> *intros(void) {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyIntros];
    return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

static double introFor(NSString *track) {
    NSNumber *mark = track ? intros()[track] : nil;
    return mark ? mark.doubleValue : -1;
}

NSArray<SGModRow *> *SGBookmarkRows(void) {
    SGModRow *set = SGStatActionRow(@"Bookmark this moment", @"Saved for this track, whenever you come back to it.",
        ^NSString *{
            return formatTime(bookmarkFor(SGKaraokePlayingTrack()));
        }, ^{
            SGBookmarkSetCurrent();
        });
    SGModRow *go = SGStatActionRow(@"Go to the bookmark", nil,
        ^NSString *{
            double mark = bookmarkFor(SGKaraokePlayingTrack());
            return mark >= 0 ? formatTime(mark) : @"—";
        }, ^{
            SGBookmarkGo();
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
    // Intro skip (Batch 48): the same moment, working by itself — mark
    // where the talking stops and the track jumps there on every play.
    SGModRow *intro = SGStatActionRow(@"Skip intro to here", @"Marks this spot as the end of the intro; the track jumps to it on every play.",
        ^NSString *{
            return formatTime(introFor(SGKaraokePlayingTrack()));
        }, ^{
            NSString *track = SGKaraokePlayingTrack();
            NSInteger ms = SGKaraokePositionMs();
            if (!track || ms < 1000) return;
            NSMutableDictionary *marks = intros();
            marks[track] = @(ms / 1000.0);
            [NSUserDefaults.standardUserDefaults setObject:marks forKey:SGKeyIntros];
            SGLog(@"intro skip: %@ marked at %.1fs", track, ms / 1000.0);
        });
    SGModRow *clearIntro = SGActionRow(@"Clear the intro skip", nil, ^{
        NSString *track = SGKaraokePlayingTrack();
        if (!track) return;
        NSMutableDictionary *marks = intros();
        [marks removeObjectForKey:track];
        [NSUserDefaults.standardUserDefaults setObject:marks forKey:SGKeyIntros];
    });
    clearIntro.visible = ^BOOL { return introFor(SGKaraokePlayingTrack()) >= 0; };
    return @[set, go, clear, intro, clearIntro];
}
