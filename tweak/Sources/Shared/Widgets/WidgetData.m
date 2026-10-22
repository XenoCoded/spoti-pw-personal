// What the widgets show, written from the app side. The numbers are the
// listening stats page's own, computed the same way from the same
// snapshot; the song and its line are the karaoke system's.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "WidgetData.h"
#import "Shared/ListeningStats/ListeningStats.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"

// The Swift half (WidgetReload.swift), declared the way the Live
// Activity's bridge is declared to its hook.
@interface SGWidgetReload : NSObject
+ (void)reloadWidgets;
+ (void)reloadNowPlaying;
@end

static NSString *const sg_suite = @"group.com.spotify.client.widget.data";

NSArray<SGModRow *> *SGWidgetRows(void) {
    // The writer's gate defaults ON (below), so the row says so too
    // (Batch 93): it used to show OFF on a fresh install while the
    // widgets were already being fed — the AppTint pattern, applied.
    SGModRow *row = SGOptionRow(@"Home & lock screen widgets",
        @"Now Playing and Listening Today, fed by this phone alone: the song, the line being sung, and the stats it keeps. Add them from the widget gallery like any other widget.",
        SGKeyWidgets);
    row.defaultOn = YES;
    return @[row];
}

void SGWidgetDataWrite(void) {
    NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:sg_suite];
    if (!suite) return;
    if (!SGFlag(SGKeyWidgets, YES)) {
        // Off used to freeze the last song on the home screen for good
        // (Batch 93): the suite is cleared once, so the widgets go
        // blank instead of presenting a song from days ago as current.
        if ([suite stringForKey:@"sg.title"]) {
            for (NSString *key in @[@"sg.title", @"sg.artist", @"sg.line", @"sg.day",
                                    @"sg.playsToday", @"sg.minutesToday", @"sg.streak", @"sg.topTitle"])
                [suite removeObjectForKey:key];
            NSURL *container = [NSFileManager.defaultManager
                containerURLForSecurityApplicationGroupIdentifier:sg_suite];
            if (container) [NSFileManager.defaultManager
                removeItemAtURL:[container URLByAppendingPathComponent:@"sg-cover.jpg"] error:nil];
            [SGWidgetReload reloadWidgets];
        }
        return;
    }
    SPTPlayerState *state = SGPlayerState();
    NSString *title = state.track.trackTitle ?: @"";
    NSString *artist = state.track.artistName ?: @"";
    BOOL songChanged = ![title isEqualToString:[suite stringForKey:@"sg.title"]]
                    || ![artist isEqualToString:[suite stringForKey:@"sg.artist"]];
    [suite setObject:title forKey:@"sg.title"];
    [suite setObject:artist forKey:@"sg.artist"];
    [suite setObject:NSDate.date forKey:@"sg.updatedAt"];
    // The line being sung, from the same lines and clock the player shows.
    NSString *trackID = SGKaraokePlayingTrack();
    NSArray<SGKaraokeLine *> *lines = trackID ? SGKaraokeLinesForTrack(trackID) : nil;
    NSInteger lead = lines.count ? SGKaraokeLeadLine(lines, SGKaraokePositionMs()) : -1;
    NSString *line = lead >= 0 && lead < (NSInteger)lines.count
        ? (SGKaraokeLineText(lines[(NSUInteger)lead]) ?: @"") : @"";
    BOOL lineChanged = ![line isEqualToString:[suite stringForKey:@"sg.line"] ?: @""];
    [suite setObject:line forKey:@"sg.line"];
    // The day so far, out of the stats store's day buckets. The stats
    // scan walks every track ever heard, so it runs on a cadence
    // (Batch 93) — a song change, or twenty seconds — not on every
    // player report; the numbers move no faster than that anyway.
    // The formatter is pinned (POSIX + Gregorian): unpinned, the day
    // keys fork under a Buddhist or Japanese calendar and today reads
    // as zero on both sides of the suite (pass 8 F1).
    static NSTimeInterval sg_statsAt;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (songChanged || now - sg_statsAt >= 20) {
        sg_statsAt = now;
        NSDictionary *snapshot = SGStatsSnapshot();
        NSDictionary *days = [snapshot[@"days"] isKindOfClass:NSDictionary.class] ? snapshot[@"days"] : @{};
        NSDictionary *daysPlays = [snapshot[@"daysPlays"] isKindOfClass:NSDictionary.class] ? snapshot[@"daysPlays"] : @{};
        NSDateFormatter *dayFormat = [NSDateFormatter new];
        dayFormat.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        dayFormat.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        dayFormat.dateFormat = @"yyyy-MM-dd";
        NSString *todayKey = [dayFormat stringFromDate:NSDate.date];
        [suite setObject:todayKey forKey:@"sg.day"];
        double todaySeconds = [days[todayKey] doubleValue];
        NSInteger todayPlays = [daysPlays[todayKey] integerValue];
        NSInteger streak = 0;
        for (NSInteger back = (todaySeconds > 0 ? 0 : 1); back < 400; back++) {
            NSDate *day = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-back toDate:NSDate.date options:0];
            if ([days[[dayFormat stringFromDate:day]] doubleValue] > 0) streak++;
            else break;
        }
        NSString *topTitle = @"";
        double topSeconds = 0;
        for (NSDictionary *entry in [snapshot[@"tracks"] allValues]) {
            if ([entry[@"seconds"] doubleValue] > topSeconds) {
                topSeconds = [entry[@"seconds"] doubleValue];
                topTitle = entry[@"title"] ?: @"";
            }
        }
        [suite setInteger:(NSInteger)(todaySeconds / 60) forKey:@"sg.minutesToday"];
        [suite setInteger:todayPlays forKey:@"sg.playsToday"];
        [suite setInteger:streak forKey:@"sg.streak"];
        [suite setObject:topTitle forKey:@"sg.topTitle"];
    }
    NSURL *container = [NSFileManager.defaultManager
        containerURLForSecurityApplicationGroupIdentifier:sg_suite];
    NSURL *coverFile = container ? [container URLByAppendingPathComponent:@"sg-cover.jpg"] : nil;
    MPMediaItemArtwork *artwork = MPNowPlayingInfoCenter.defaultCenter
        .nowPlayingInfo[MPMediaItemPropertyArtwork];
    UIImage *image = [artwork imageWithSize:CGSizeMake(400, 400)];
    if (songChanged) {
        // The cover rides as a file in the shared container, swapped with
        // the song; the widgets ask for a fresh look at the same moment.
        // A song with no cover to send takes the old file away with it,
        // or the widget keeps showing the previous song's face.
        NSData *jpeg = image ? UIImageJPEGRepresentation(image, 0.75) : nil;
        if (coverFile && jpeg) [jpeg writeToURL:coverFile atomically:YES];
        else if (coverFile) [NSFileManager.defaultManager removeItemAtURL:coverFile error:nil];
        // One log line per song (Batch 91): this path had no logging at
        // all, so a suite the shim never redirected — writes landing in
        // a private store, the widget reading a different one — looked
        // exactly like success from everywhere.
        SGLog(@"widgets: %@ — %@ (container %@)", title, artist,
              container ? @"shared" : @"MISSING");
        [SGWidgetReload reloadWidgets];
    } else {
        // A cover that was not ready at the track-change instant still
        // lands when it arrives (Batch 93): the slot was empty or held
        // nothing, and no later write ever filled it for that song.
        if (coverFile && image && ![NSFileManager.defaultManager fileExistsAtPath:coverFile.path]) {
            NSData *jpeg = UIImageJPEGRepresentation(image, 0.75);
            if (jpeg && [jpeg writeToURL:coverFile atomically:YES]) [SGWidgetReload reloadNowPlaying];
        }
        if (lineChanged) {
            // The line is the widget's moving part, but a reload per
            // line (~every four seconds, all day) spends WidgetKit's
            // budget and ends with even song changes deferred
            // (Batch 93): the Now Playing kind only, at most once a
            // minute — the line is a glance, not a teleprompter.
            static NSTimeInterval sg_lineReloadAt;
            if (now - sg_lineReloadAt >= 60) {
                sg_lineReloadAt = now;
                [SGWidgetReload reloadNowPlaying];
            }
        }
    }
}
