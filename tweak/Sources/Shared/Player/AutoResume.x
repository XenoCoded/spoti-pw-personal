// Auto-resume (personal fork, Batch 71): the bookmark watcher. A
// bookmark is saved for coming back to; with the Player page's switch
// on, coming back happens by itself — a track that has a bookmark
// jumps straight to it when it starts. The intro skip's shape exactly:
// a slow timer, the karaoke clock, the player's own seekTo:, firing
// once per play of a track so a rewind by hand is never fought. A
// track carrying both an intro mark and a bookmark takes both jumps
// in turn — intro first, then on to the bookmark — each watcher keeps
// its own memory, so neither re-fires.
#import "Core/SGCore.h"
#import "Bookmark.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Headers/SPTPlayer.h"

static NSString *sg_resumedFor;

static void check(void) {
    if (!SGFlag(SGKeyBookmarkAutoResume, NO)) { sg_resumedFor = nil; return; }
    NSString *track = SGKaraokePlayingTrack();
    if (!track) { sg_resumedFor = nil; return; }
    if ([track isEqualToString:sg_resumedFor]) {
        // A restart is a fresh play and earns a fresh jump; the position
        // falling back to the start is the only signal there is.
        NSInteger ms = SGKaraokePositionMs();
        if (ms >= 0 && ms < 1000) sg_resumedFor = nil;
        else return;
    }
    NSDictionary *marks = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyBookmarks];
    NSNumber *mark = [marks isKindOfClass:NSDictionary.class] ? marks[track] : nil;
    // A stored value that is not a number (a restored backup, an older
    // build) is no mark at all; the sanitised reader in Bookmark.m
    // cannot speak for this second, direct one (Batch 91).
    if (![mark isKindOfClass:NSNumber.class]) return;
    // A mark in the first seconds is a place the play passes anyway, and
    // one saved by accident there would yank every play for nothing.
    if (mark.doubleValue < 5) { sg_resumedFor = [track copy]; return; }
    NSInteger ms = SGKaraokePositionMs();
    if (ms < 0) return;
    double position = ms / 1000.0;
    // Only from before the mark: a track resumed past it (a cross-device
    // handoff, the bookmark row's own jump) is left alone, and counts as
    // handled so the check stays cheap.
    if (position >= mark.doubleValue) { sg_resumedFor = [track copy]; return; }
    id<SPTPlayer> player = SGKaraokePlayer();
    [player seekTo:mark.doubleValue];
    sg_resumedFor = [track copy];
    SGLog(@"auto-resume: %@ to %.1fs", track, mark.doubleValue);
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { check(); }];
    });
    SGLog(@"auto-resume: watching");
}
