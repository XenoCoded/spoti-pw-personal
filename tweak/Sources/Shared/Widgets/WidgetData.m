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
@end

static NSString *const sg_suite = @"group.com.spotify.client.widget.data";

NSArray<SGModRow *> *SGWidgetRows(void) {
    return @[SGOptionRow(@"Home & lock screen widgets",
        @"Now Playing and Listening Today, fed by this phone alone: the song, the line being sung, and the stats it keeps. Add them from the widget gallery like any other widget.",
        SGKeyWidgets)];
}

void SGWidgetDataWrite(void) {
    if (!SGFlag(SGKeyWidgets, YES)) return;
    NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:sg_suite];
    if (!suite) return;
    SPTPlayerState *state = SGPlayerState();
    NSString *title = state.track.trackTitle ?: @"";
    NSString *artist = state.track.artistName ?: @"";
    BOOL songChanged = ![title isEqualToString:[suite stringForKey:@"sg.title"]]
                    || ![artist isEqualToString:[suite stringForKey:@"sg.artist"]];
    [suite setObject:title forKey:@"sg.title"];
    [suite setObject:artist forKey:@"sg.artist"];
    // The line being sung, from the same lines and clock the player shows.
    NSString *trackID = SGKaraokePlayingTrack();
    NSArray<SGKaraokeLine *> *lines = trackID ? SGKaraokeLinesForTrack(trackID) : nil;
    NSInteger lead = lines.count ? SGKaraokeLeadLine(lines, SGKaraokePositionMs()) : -1;
    NSString *line = lead >= 0 && lead < (NSInteger)lines.count
        ? (SGKaraokeLineText(lines[(NSUInteger)lead]) ?: @"") : @"";
    BOOL lineChanged = ![line isEqualToString:[suite stringForKey:@"sg.line"] ?: @""];
    [suite setObject:line forKey:@"sg.line"];
    // The day so far, out of the stats store's day buckets.
    NSDictionary *snapshot = SGStatsSnapshot();
    NSDictionary *days = [snapshot[@"days"] isKindOfClass:NSDictionary.class] ? snapshot[@"days"] : @{};
    NSDictionary *daysPlays = [snapshot[@"daysPlays"] isKindOfClass:NSDictionary.class] ? snapshot[@"daysPlays"] : @{};
    NSDateFormatter *dayFormat = [NSDateFormatter new];
    dayFormat.dateFormat = @"yyyy-MM-dd";
    double todaySeconds = [days[[dayFormat stringFromDate:NSDate.date]] doubleValue];
    NSInteger todayPlays = [daysPlays[[dayFormat stringFromDate:NSDate.date]] integerValue];
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
    if (songChanged) {
        // The cover rides as a file in the shared container, swapped with
        // the song; the widgets ask for a fresh look at the same moment.
        // A song with no cover to send takes the old file away with it,
        // or the widget keeps showing the previous song's face.
        NSURL *container = [NSFileManager.defaultManager
            containerURLForSecurityApplicationGroupIdentifier:sg_suite];
        MPMediaItemArtwork *artwork = MPNowPlayingInfoCenter.defaultCenter
            .nowPlayingInfo[MPMediaItemPropertyArtwork];
        UIImage *image = [artwork imageWithSize:CGSizeMake(400, 400)];
        NSData *jpeg = image ? UIImageJPEGRepresentation(image, 0.75) : nil;
        NSURL *coverFile = container ? [container URLByAppendingPathComponent:@"sg-cover.jpg"] : nil;
        if (coverFile && jpeg) [jpeg writeToURL:coverFile atomically:YES];
        else if (coverFile) [NSFileManager.defaultManager removeItemAtURL:coverFile error:nil];
        // One log line per song (Batch 91): this path had no logging at
        // all, so a suite the shim never redirected — writes landing in
        // a private store, the widget reading a different one — looked
        // exactly like success from everywhere.
        SGLog(@"widgets: %@ — %@ (container %@)", title, artist,
              container ? @"shared" : @"MISSING");
        [SGWidgetReload reloadWidgets];
    } else if (lineChanged) {
        // The line is the widget's moving part; it refreshes on its own
        // change too, not only when the song turns over.
        [SGWidgetReload reloadWidgets];
    }
}
