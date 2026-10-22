// The Listening stats page: the switch, the totals, the tops, and the clear. Linked
// from the Player page (App/Pages.m).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "ListeningStats.h"
#import "ChartCard.h"
#import "Shared/Player/Ratings.h"
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

// "2:31" for a span of seconds — the journal reads in clock time, not the
// "2 min" the totals use.
static NSString *clockTime(NSTimeInterval seconds) {
    NSInteger total = (NSInteger)seconds;
    if (total >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
        (long)(total / 3600), (long)((total % 3600) / 60), (long)(total % 60)];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

// When a journal entry began: the time of day, with the day once it is not
// today any more.
static NSString *journalWhen(NSTimeInterval when) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:when];
    NSDateFormatter *format = [NSDateFormatter new];
    format.dateFormat = [NSCalendar.currentCalendar isDateInToday:date] ? @"h:mm a" : @"MMM d, h:mm a";
    return [format stringFromDate:date];
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
        NSDictionary *daysPlays = [snapshot[@"daysPlays"] isKindOfClass:NSDictionary.class] ? snapshot[@"daysPlays"] : @{};
        NSInteger todayPlays = [daysPlays[[dayFormat stringFromDate:NSDate.date]] integerValue];
        NSDictionary *daysTracks = [snapshot[@"daysTracks"] isKindOfClass:NSDictionary.class] ? snapshot[@"daysTracks"] : @{};
        NSInteger todaySongs = [daysTracks[[dayFormat stringFromDate:NSDate.date]] count];
        double weekSeconds = 0;
        for (NSInteger back = 0; back < 7; back++) {
            NSDate *day = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-back toDate:NSDate.date options:0];
            weekSeconds += [days[[dayFormat stringFromDate:day]] doubleValue];
        }
        // Week over week (Batch 50): the seven days before the seven
        // above, as a signed percentage — the one number that says
        // whether the habit is growing.
        double lastWeekSeconds = 0;
        for (NSInteger back = 7; back < 14; back++) {
            NSDate *day = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-back toDate:NSDate.date options:0];
            lastWeekSeconds += [days[[dayFormat stringFromDate:day]] doubleValue];
        }
        NSString *wowText = @"—";
        if (lastWeekSeconds > 0) {
            double change = (weekSeconds - lastWeekSeconds) / lastWeekSeconds * 100;
            wowText = [NSString stringWithFormat:@"%@%.0f%%", change > 0 ? @"+" : @"", change];
        }
        // The streak and the biggest day (Batch 45): both are just the
        // day buckets read in a row / read for the largest. A day that has
        // not got going yet does not break the streak — it has not had
        // its chance.
        NSInteger streak = 0;
        for (NSInteger back = (todaySeconds > 0 ? 0 : 1); back < 400; back++) {
            NSDate *day = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-back toDate:NSDate.date options:0];
            if ([days[[dayFormat stringFromDate:day]] doubleValue] > 0) streak++;
            else break;
        }
        NSString *biggestKey = nil;
        double biggestSeconds = 0;
        for (NSString *key in days) {
            double value = [days[key] doubleValue];
            if (value > biggestSeconds) { biggestSeconds = value; biggestKey = key; }
        }
        NSString *biggestText = @"—";
        if (biggestKey) {
            NSDate *day = [dayFormat dateFromString:biggestKey];
            NSDateFormatter *pretty = [NSDateFormatter new];
            pretty.dateFormat = @"MMM d";
            biggestText = [NSString stringWithFormat:@"%@ · %@",
                day ? [pretty stringFromDate:day] : biggestKey, SGStatsFormatTime(biggestSeconds)];
        }
        [sections addObject:SGSection(@"So far", @[
            SGStatRow(@"Time listened", ^NSString *{ return SGStatsFormatTime(total); }),
            SGStatRow(@"Today", ^NSString *{ return SGStatsFormatTime(todaySeconds); }),
            SGStatRow(@"Plays today", ^NSString *{
                return todaySongs > 0 ? [NSString stringWithFormat:@"%ld · %ld songs", (long)todayPlays, (long)todaySongs]
                                      : @(todayPlays).stringValue;
            }),
            SGStatRow(@"Last 7 days", ^NSString *{ return SGStatsFormatTime(weekSeconds); }),
            SGStatRow(@"Day streak", ^NSString *{
                return streak == 1 ? @"1 day" : [NSString stringWithFormat:@"%ld days", (long)streak];
            }),
            SGStatRow(@"Biggest day", ^NSString *{ return biggestText; }),
            SGStatRow(@"Week over week", ^NSString *{ return wowText; }),
            SGStatRow(@"Songs played", ^NSString *{ return @(plays).stringValue; }),
            SGStatRow(@"Different songs", ^NSString *{ return @(tracks.count).stringValue; }),
        ])];
        // Recently played (Batch 39): the same doors as the top songs,
        // in the order they were actually heard. Entries from before the
        // stamp existed simply do not appear. The URI is stamped in as the
        // entries are gathered (Batch 55): the stored entries do not carry
        // their own key, and without it the rows looked like doors but
        // opened nothing.
        NSMutableArray<NSDictionary *> *recent = [NSMutableArray array];
        for (NSString *uri in tracks) {
            NSDictionary *stored = tracks[uri];
            if ([stored[@"lastPlayed"] doubleValue] > 0) {
                NSMutableDictionary *entry = [stored mutableCopy];
                entry[@"uri"] = uri;
                [recent addObject:entry];
            }
        }
        [recent sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"lastPlayed"] compare:a[@"lastPlayed"]];
        }];
        if (recent.count) {
            NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
            for (NSDictionary *entry in [recent subarrayWithRange:NSMakeRange(0, MIN(recent.count, 8))]) {
                NSString *title = [entry[@"title"] length] ? entry[@"title"] : @"Unknown track";
                NSString *detail = [NSString stringWithFormat:@"%@ · %@ plays",
                                    SGStatsFormatTime([entry[@"seconds"] doubleValue]), entry[@"plays"]];
                NSString *uri = entry[@"uri"];
                [rows addObject:SGStatActionRow(title, entry[@"artist"], ^NSString *{ return detail; }, ^{
                    if (uri.length) SGOpenSpotifyURI([NSURL URLWithString:uri]);
                })];
            }
            [sections addObject:SGSection(@"Recently played", rows)];
        }
        // Resurface (Batch 60): old flames — played at least three times
        // but not heard in over a month. The aggregates already keep
        // everything this needs (plays, lastPlayed); the section is just
        // the question asked the other way round from Recently played.
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        NSDateFormatter *dayOnly = [NSDateFormatter new];
        dayOnly.dateFormat = @"MMM d";
        NSMutableArray<NSDictionary *> *dormant = [NSMutableArray array];
        for (NSString *uri in tracks) {
            NSDictionary *stored = tracks[uri];
            double last = [stored[@"lastPlayed"] doubleValue];
            if (last > 0 && now - last > 30 * 86400 && [stored[@"plays"] integerValue] >= 3) {
                NSMutableDictionary *entry = [stored mutableCopy];
                entry[@"uri"] = uri;
                [dormant addObject:entry];
            }
        }
        [dormant sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult byPlays = [b[@"plays"] compare:a[@"plays"]];
            return byPlays != NSOrderedSame ? byPlays : [b[@"seconds"] compare:a[@"seconds"]];
        }];
        if (dormant.count) {
            NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
            for (NSDictionary *entry in [dormant subarrayWithRange:NSMakeRange(0, MIN(dormant.count, 8))]) {
                NSString *title = [entry[@"title"] length] ? entry[@"title"] : @"Unknown track";
                NSString *detail = [NSString stringWithFormat:@"%@ plays · last heard %@",
                    entry[@"plays"], [dayOnly stringFromDate:[NSDate dateWithTimeIntervalSince1970:[entry[@"lastPlayed"] doubleValue]]]];
                NSString *uri = entry[@"uri"];
                [rows addObject:SGStatActionRow(title, entry[@"artist"], ^NSString *{ return detail; }, ^{
                    if (uri.length) SGOpenSpotifyURI([NSURL URLWithString:uri]);
                })];
            }
            [sections addObject:SGSection(@"Resurface", rows)];
        }
        // New discoveries (Batch 60): first heard within the last week,
        // on the firstPlayed stamp Batch 55 started keeping. Tracks from
        // before the stamp have no first hearing to point at and stay out,
        // the same bargain Recently played makes with lastPlayed.
        NSMutableArray<NSDictionary *> *fresh = [NSMutableArray array];
        for (NSString *uri in tracks) {
            NSDictionary *stored = tracks[uri];
            double first = [stored[@"firstPlayed"] doubleValue];
            if (first > 0 && now - first < 7 * 86400) {
                NSMutableDictionary *entry = [stored mutableCopy];
                entry[@"uri"] = uri;
                [fresh addObject:entry];
            }
        }
        [fresh sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"firstPlayed"] compare:a[@"firstPlayed"]];
        }];
        if (fresh.count) {
            NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
            for (NSDictionary *entry in [fresh subarrayWithRange:NSMakeRange(0, MIN(fresh.count, 8))]) {
                NSString *title = [entry[@"title"] length] ? entry[@"title"] : @"Unknown track";
                NSDate *firstDate = [NSDate dateWithTimeIntervalSince1970:[entry[@"firstPlayed"] doubleValue]];
                NSString *when = [NSCalendar.currentCalendar isDateInToday:firstDate]
                    ? @"today" : [dayOnly stringFromDate:firstDate];
                NSString *detail = [NSString stringWithFormat:@"First heard %@ · %@ plays", when, entry[@"plays"]];
                NSString *uri = entry[@"uri"];
                [rows addObject:SGStatActionRow(title, entry[@"artist"], ^NSString *{ return detail; }, ^{
                    if (uri.length) SGOpenSpotifyURI([NSURL URLWithString:uri]);
                })];
            }
            [sections addObject:SGSection(@"New discoveries", rows)];
        }
        // The playback journal (Batch 55): every play as it happened, with
        // how much of it was heard — the diary under the aggregates. A play
        // heard to (nearly) its end says so; one abandoned inside half a
        // minute says that too, and everything between is left plain.
        NSArray<NSDictionary *> *journal = SGStatsJournal();
        if (journal.count) {
            NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
            for (NSDictionary *play in [journal subarrayWithRange:NSMakeRange(0, MIN(journal.count, 12))]) {
                NSString *title = [play[@"title"] length] ? play[@"title"] : @"Unknown track";
                double heard = [play[@"seconds"] doubleValue];
                double duration = [play[@"duration"] doubleValue];
                NSString *detail = [NSString stringWithFormat:@"%@ · %@ heard",
                    journalWhen([play[@"t"] doubleValue]), clockTime(heard)];
                if (duration > 0 && heard >= duration * 0.9)
                    detail = [detail stringByAppendingString:@" · Finished"];
                else if (heard < 30)
                    detail = [detail stringByAppendingString:@" · Skipped"];
                NSString *uri = play[@"uri"];
                [rows addObject:SGStatActionRow(title, play[@"artist"], ^NSString *{ return detail; }, ^{
                    if (uri.length) SGOpenSpotifyURI([NSURL URLWithString:uri]);
                })];
            }
            [sections addObject:SGSection(@"Playback journal", rows)];
        }
        // Listening clock (Batch 60): the journal binned by the hour each
        // play started — when the listening actually happens. Ten plays is
        // the floor for calling it a pattern. The top hour's name is kept
        // for the text export below.
        NSString *peakHourText = nil;
        if (journal.count >= 10) {
            double hourSeconds[24] = {0};
            NSInteger hourPlays[24] = {0};
            NSCalendar *calendar = NSCalendar.currentCalendar;
            for (NSDictionary *play in journal) {
                NSInteger hour = [calendar component:NSCalendarUnitHour
                    fromDate:[NSDate dateWithTimeIntervalSince1970:[play[@"t"] doubleValue]]];
                hourSeconds[hour] += [play[@"seconds"] doubleValue];
                hourPlays[hour]++;
            }
            NSMutableArray<NSNumber *> *hours = [NSMutableArray array];
            for (NSInteger hour = 0; hour < 24; hour++)
                if (hourPlays[hour] > 0) [hours addObject:@(hour)];
            // A block cannot hold the array itself; it holds this pointer
            // to it for the sort, which runs here and now.
            double *secondsByHour = hourSeconds;
            [hours sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
                return [@(secondsByHour[b.integerValue]) compare:@(secondsByHour[a.integerValue])];
            }];
            NSDateFormatter *hourFormat = [NSDateFormatter new];
            hourFormat.dateFormat = @"h a";
            NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
            for (NSNumber *boxed in [hours subarrayWithRange:NSMakeRange(0, MIN(hours.count, 3))]) {
                NSInteger hour = boxed.integerValue;
                NSDate *probe = [calendar dateBySettingHour:hour minute:0 second:0 ofDate:NSDate.date options:0];
                NSString *label = probe ? [hourFormat stringFromDate:probe] : [NSString stringWithFormat:@"%ld:00", (long)hour];
                NSString *detail = [NSString stringWithFormat:@"%@ heard · %ld plays",
                    SGStatsFormatTime(hourSeconds[hour]), (long)hourPlays[hour]];
                if (!peakHourText) peakHourText = label;
                [rows addObject:SGStatRow(label, ^NSString *{ return detail; })];
            }
            if (rows.count) [sections addObject:SGSection(@"Listening clock", rows)];
        }
        NSArray<NSDictionary *> *songs = topTracks(snapshot, 10);
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
        NSArray<NSDictionary *> *artists = topArtists(snapshot, 10);
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
        // Hall of Fame (Batch 58): the tracks the user gave four or five
        // stars, best first. The titles live here in the stats store; a
        // rated track the stats have never counted has no name to show
        // and joins once it has been played with stats on.
        NSDictionary<NSString *, NSNumber *> *ratings = SGAllRatings();
        NSMutableArray<NSDictionary *> *fame = [NSMutableArray array];
        for (NSString *uri in ratings) {
            NSInteger stars = [ratings[uri] integerValue];
            NSDictionary *stored = tracks[uri];
            if (stars >= 4 && stored) {
                NSMutableDictionary *entry = [stored mutableCopy];
                entry[@"uri"] = uri;
                entry[@"stars"] = @(stars);
                [fame addObject:entry];
            }
        }
        [fame sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult byStars = [b[@"stars"] compare:a[@"stars"]];
            return byStars != NSOrderedSame ? byStars : [b[@"seconds"] compare:a[@"seconds"]];
        }];
        if (fame.count) {
            NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
            for (NSDictionary *entry in fame) {
                NSString *title = [entry[@"title"] length] ? entry[@"title"] : @"Unknown track";
                NSString *detail = [NSString stringWithFormat:@"%@ · %@ · %@ plays",
                    SGStarsString([entry[@"stars"] integerValue]),
                    SGStatsFormatTime([entry[@"seconds"] doubleValue]), entry[@"plays"]];
                NSString *uri = entry[@"uri"];
                [rows addObject:SGStatActionRow(title, entry[@"artist"], ^NSString *{ return detail; }, ^{
                    if (uri.length) SGOpenSpotifyURI([NSURL URLWithString:uri]);
                })];
            }
            [sections addObject:SGSection(@"Hall of Fame", rows)];
        }
        // The same report as text (Batch 28): the tops this phone knows,
        // ready to paste anywhere. The snapshot is captured with the rows
        // and never changes under them.
        SGModRow *export = SGStatActionRow(@"Export stats as text", nil, ^NSString *{ return @"Copy"; }, ^{
            NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:@"Listening stats"];
            [lines addObject:[NSString stringWithFormat:@"Time listened: %@", SGStatsFormatTime(total)]];
            [lines addObject:[NSString stringWithFormat:@"Today: %@ (%ld plays%@)", SGStatsFormatTime(todaySeconds), (long)todayPlays,
                todaySongs > 0 ? [NSString stringWithFormat:@", %ld songs", (long)todaySongs] : @""]];
            [lines addObject:[NSString stringWithFormat:@"Last 7 days: %@", SGStatsFormatTime(weekSeconds)]];
            [lines addObject:[NSString stringWithFormat:@"Day streak: %ld days", (long)streak]];
            if (biggestKey) [lines addObject:[NSString stringWithFormat:@"Biggest day: %@", biggestText]];
            [lines addObject:[NSString stringWithFormat:@"Week over week: %@", wowText]];
            if (peakHourText) [lines addObject:[NSString stringWithFormat:@"Peak hour: %@", peakHourText]];
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
            if (recent.count) {
                [lines addObject:@""];
                [lines addObject:@"Recently played"];
                for (NSDictionary *entry in [recent subarrayWithRange:NSMakeRange(0, MIN(recent.count, 8))]) {
                    NSString *title = [entry[@"title"] length] ? entry[@"title"] : @"Unknown track";
                    NSString *artist = [entry[@"artist"] length] ? [@" — " stringByAppendingString:entry[@"artist"]] : @"";
                    [lines addObject:[NSString stringWithFormat:@"· %@%@", title, artist]];
                }
            }
            if (dormant.count) {
                [lines addObject:@""];
                [lines addObject:@"Resurface"];
                for (NSDictionary *entry in [dormant subarrayWithRange:NSMakeRange(0, MIN(dormant.count, 8))]) {
                    NSString *title = [entry[@"title"] length] ? entry[@"title"] : @"Unknown track";
                    NSString *artist = [entry[@"artist"] length] ? [@" — " stringByAppendingString:entry[@"artist"]] : @"";
                    [lines addObject:[NSString stringWithFormat:@"· %@%@", title, artist]];
                }
            }
            if (fresh.count) {
                [lines addObject:@""];
                [lines addObject:@"New discoveries"];
                for (NSDictionary *entry in [fresh subarrayWithRange:NSMakeRange(0, MIN(fresh.count, 8))]) {
                    NSString *title = [entry[@"title"] length] ? entry[@"title"] : @"Unknown track";
                    NSString *artist = [entry[@"artist"] length] ? [@" — " stringByAppendingString:entry[@"artist"]] : @"";
                    [lines addObject:[NSString stringWithFormat:@"· %@%@", title, artist]];
                }
            }
            if (journal.count) {
                [lines addObject:@""];
                [lines addObject:@"Playback journal"];
                for (NSDictionary *play in [journal subarrayWithRange:NSMakeRange(0, MIN(journal.count, 10))]) {
                    NSString *title = [play[@"title"] length] ? play[@"title"] : @"Unknown track";
                    NSString *artist = [play[@"artist"] length] ? [@" — " stringByAppendingString:play[@"artist"]] : @"";
                    [lines addObject:[NSString stringWithFormat:@"· %@%@ (%@ heard)",
                        title, artist, clockTime([play[@"seconds"] doubleValue])]];
                }
            }
            UIPasteboard.generalPasteboard.string = [lines componentsJoinedByString:@"\n"];
        });
        // The same numbers as a picture (Batch 57): the chart card is the
        // shareable form of this page, copied like the lyric card is.
        SGModRow *chart = SGStatActionRow(@"Copy chart card", nil, ^NSString *{ return @"Image"; }, ^{
            UIImage *image = SGChartCardImage();
            if (image) UIPasteboard.generalPasteboard.image = image;
        });
        SGModRow *clear = SGActionRow(@"Clear listening stats", nil, ^{ confirmClear(); });
        clear.color = SGRed();
        [sections addObject:SGSection(nil, @[chart, export, clear])];
    }
    return [[SGModPage alloc] initWithTitle:@"Listening stats" intro:SGRestartNote sections:sections footer:nil];
}

NSString *SGListeningStatsSummary(void) {
    if (!SGFlag(SGKeyListeningStats, NO)) return @"Off";
    double total = [SGStatsSnapshot()[@"totalSeconds"] doubleValue];
    return total >= 60 ? SGStatsFormatTime(total) : @"Nothing yet";
}
