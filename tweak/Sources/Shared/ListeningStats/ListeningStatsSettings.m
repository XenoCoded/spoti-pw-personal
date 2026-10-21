// The Listening stats page: the switch, the totals, the tops, and the clear. Linked
// from the Player page (App/Pages.m).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "ListeningStats.h"
#import "Shared/Navigation/Links.h"

static void confirmClear(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear listening stats?"
        message:@"Every count this phone has kept is deleted, and counting starts again from nothing. Spotify's own history is untouched."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) { SGStatsClear(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// The tracks with the most time on them, most first; an artist's time is the sum of
// their tracks', there being no second store for them.
static NSArray<NSDictionary *> *topTracks(NSDictionary *snapshot, NSUInteger limit) {
    NSDictionary *tracks = snapshot[@"tracks"];
    NSArray<NSString *> *uris = [tracks keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"seconds"] compare:a[@"seconds"]];
    }];
    NSMutableArray<NSDictionary *> *top = [NSMutableArray array];
    for (NSString *uri in uris) {
        if (top.count == limit) break;
        if ([tracks[uri][@"seconds"] doubleValue] < 1) continue;
        // The URI rides along (Batch 25): a top song is a door, not a plaque.
        NSMutableDictionary *entry = [tracks[uri] mutableCopy];
        entry[@"uri"] = uri;
        [top addObject:entry];
    }
    return top;
}

static NSArray<NSDictionary *> *topArtists(NSDictionary *snapshot, NSUInteger limit) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *byArtist = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in [snapshot[@"tracks"] allValues]) {
        NSString *name = [entry[@"artist"] length] ? entry[@"artist"] : @"Unknown artist";
        NSMutableDictionary *total = byArtist[name] ?: [@{@"name": name, @"seconds": @0, @"plays": @0} mutableCopy];
        total[@"seconds"] = @([total[@"seconds"] doubleValue] + [entry[@"seconds"] doubleValue]);
        total[@"plays"] = @([total[@"plays"] doubleValue] + [entry[@"plays"] doubleValue]);
        byArtist[name] = total;
    }
    NSArray<NSDictionary *> *sorted = [byArtist.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"seconds"] compare:a[@"seconds"]];
    }];
    NSMutableArray<NSDictionary *> *top = [NSMutableArray array];
    for (NSDictionary *artist in sorted) {
        if (top.count == limit) break;
        if ([artist[@"seconds"] doubleValue] < 1) continue;
        [top addObject:artist];
    }
    return top;
}

UIViewController *SGListeningStatsPage(void) {
    SGModRow *on = SGOptionRow(@"Listening stats", @"Counts time and plays on this phone only, in the app's own files. Nothing is sent anywhere.", SGKeyListeningStats);
    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObject:SGSection(nil, @[on])];
    if (SGFlag(SGKeyListeningStats, NO)) {
        NSDictionary *snapshot = SGStatsSnapshot();
        double total = [snapshot[@"totalSeconds"] doubleValue];
        NSDictionary *tracks = snapshot[@"tracks"];
        NSInteger plays = 0;
        for (NSDictionary *entry in tracks.allValues) plays += [entry[@"plays"] integerValue];
        // Today and the last seven days, out of the per-day buckets the
        // tracker keeps (Batch 31). Stores from before the buckets read 0.
        NSDictionary *days = [snapshot[@"days"] isKindOfClass:NSDictionary.class] ? snapshot[@"days"] : @{};
        NSDateFormatter *dayFormat = [NSDateFormatter new];
        dayFormat.dateFormat = @"yyyy-MM-dd";
        double todaySeconds = [days[[dayFormat stringFromDate:NSDate.date]] doubleValue];
        double weekSeconds = 0;
        for (NSInteger back = 0; back < 7; back++) {
            NSDate *day = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-back toDate:NSDate.date options:0];
            weekSeconds += [days[[dayFormat stringFromDate:day]] doubleValue];
        }
        [sections addObject:SGSection(@"So far", @[
            SGStatRow(@"Time listened", ^NSString *{ return SGStatsFormatTime(total); }),
            SGStatRow(@"Today", ^NSString *{ return SGStatsFormatTime(todaySeconds); }),
            SGStatRow(@"Last 7 days", ^NSString *{ return SGStatsFormatTime(weekSeconds); }),
            SGStatRow(@"Songs played", ^NSString *{ return @(plays).stringValue; }),
            SGStatRow(@"Different songs", ^NSString *{ return @(tracks.count).stringValue; }),
        ])];
        NSArray<NSDictionary *> *songs = topTracks(snapshot, 5);
        if (songs.count) {
            NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
            for (NSDictionary *entry in songs) {
                NSString *title = [entry[@"title"] length] ? entry[@"title"] : @"Unknown track";
                NSString *detail = [NSString stringWithFormat:@"%@ · %@ plays",
                                    SGStatsFormatTime([entry[@"seconds"] doubleValue]), entry[@"plays"]];
                NSString *uri = entry[@"uri"];
                [rows addObject:SGStatActionRow(title, entry[@"artist"], ^NSString *{ return detail; }, ^{
                    if (uri.length) SGOpenSpotifyURI([NSURL URLWithString:uri]);
                })];
            }
            [sections addObject:SGSection(@"Top songs", rows)];
        }
        NSArray<NSDictionary *> *artists = topArtists(snapshot, 5);
        if (artists.count) {
            NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
            for (NSDictionary *artist in artists) {
                NSString *detail = SGStatsFormatTime([artist[@"seconds"] doubleValue]);
                NSString *name = artist[@"name"];
                [rows addObject:SGStatActionRow(name, nil, ^NSString *{ return detail; }, ^{
                    // No artist URI is kept, so the door is a search for them.
                    NSString *query = [name stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
                    if (query) SGOpenSpotifyURI([NSURL URLWithString:[@"spotify:search:" stringByAppendingString:query]]);
                })];
            }
            [sections addObject:SGSection(@"Top artists", rows)];
        }
        // The same report as text (Batch 28): the tops this phone knows,
        // ready to paste anywhere. The snapshot is captured with the rows
        // and never changes under them.
        SGModRow *export = SGStatActionRow(@"Export stats as text", nil, ^NSString *{ return @"Copy"; }, ^{
            NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:@"Listening stats"];
            [lines addObject:[NSString stringWithFormat:@"Time listened: %@", SGStatsFormatTime(total)]];
            [lines addObject:[NSString stringWithFormat:@"Today: %@", SGStatsFormatTime(todaySeconds)]];
            [lines addObject:[NSString stringWithFormat:@"Last 7 days: %@", SGStatsFormatTime(weekSeconds)]];
            [lines addObject:[NSString stringWithFormat:@"Songs played: %ld", (long)plays]];
            [lines addObject:@""];
            [lines addObject:@"Top songs"];
            for (NSDictionary *entry in songs) {
                NSString *title = [entry[@"title"] length] ? entry[@"title"] : @"Unknown track";
                NSString *artist = [entry[@"artist"] length] ? [@" — " stringByAppendingString:entry[@"artist"]] : @"";
                [lines addObject:[NSString stringWithFormat:@"· %@%@ (%@, %@ plays)",
                    title, artist, SGStatsFormatTime([entry[@"seconds"] doubleValue]), entry[@"plays"]]];
            }
            [lines addObject:@""];
            [lines addObject:@"Top artists"];
            for (NSDictionary *artist in artists) {
                [lines addObject:[NSString stringWithFormat:@"· %@ (%@)",
                    artist[@"name"], SGStatsFormatTime([artist[@"seconds"] doubleValue])]];
            }
            UIPasteboard.generalPasteboard.string = [lines componentsJoinedByString:@"\n"];
        });
        SGModRow *clear = SGActionRow(@"Clear listening stats", nil, ^{ confirmClear(); });
        clear.color = SGRed();
        [sections addObject:SGSection(nil, @[export, clear])];
    }
    return [[SGModPage alloc] initWithTitle:@"Listening stats" intro:SGRestartNote sections:sections footer:nil];
}

NSString *SGListeningStatsSummary(void) {
    if (!SGFlag(SGKeyListeningStats, NO)) return @"Off";
    double total = [SGStatsSnapshot()[@"totalSeconds"] doubleValue];
    return total >= 60 ? SGStatsFormatTime(total) : @"Nothing yet";
}
