// The stats file: one JSON document, read whole and written whole on each change. The
// counts move at most once per player state change, so there is nothing to gain from
// anything cleverer, and a file a person can find beats a store no one can read.
#import "Core/SGCore.h"
#import "ListeningStats.h"

static NSString *statsPath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[support stringByAppendingPathComponent:@"spoti.pw"] stringByAppendingPathComponent:@"listening-stats.json"];
}

static NSMutableDictionary *sg_stats;

static NSMutableDictionary *stats(void) {
    if (sg_stats) return sg_stats;
    NSData *data = [NSData dataWithContentsOfFile:statsPath()];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    sg_stats = [parsed isKindOfClass:NSMutableDictionary.class] ? parsed : [NSMutableDictionary dictionary];
    if (![sg_stats[@"tracks"] isKindOfClass:NSMutableDictionary.class])
        sg_stats[@"tracks"] = [NSMutableDictionary dictionary];
    if (![sg_stats[@"totalSeconds"] isKindOfClass:NSNumber.class])
        sg_stats[@"totalSeconds"] = @0;
    return sg_stats;
}

static void save(void) {
    NSString *path = statsPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:sg_stats options:0 error:nil];
    [data writeToFile:path atomically:YES];
}

static NSMutableDictionary *entryFor(NSString *uri, NSString *title, NSString *artist) {
    NSMutableDictionary *tracks = stats()[@"tracks"];
    NSMutableDictionary *entry = tracks[uri];
    if (![entry isKindOfClass:NSMutableDictionary.class]) {
        entry = [@{@"title": @"", @"artist": @"", @"plays": @0, @"seconds": @0} mutableCopy];
        tracks[uri] = entry;
    }
    if (title.length) entry[@"title"] = title;
    if (artist.length) entry[@"artist"] = artist;
    return entry;
}

// The day a stretch of listening belongs to, in the phone's own calendar.
static NSString *todayKey(void) {
    static NSDateFormatter *format;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        format = [NSDateFormatter new];
        format.dateFormat = @"yyyy-MM-dd";
    });
    return [format stringFromDate:NSDate.date];
}

void SGStatsCountPlay(NSString *uri, NSString *title, NSString *artist) {
    if (!uri.length) return;
    NSMutableDictionary *entry = entryFor(uri, title, artist);
    entry[@"plays"] = @([entry[@"plays"] doubleValue] + 1);
    // When it was first played (Batch 55), stamped once: the discoveries
    // list the research asked for is "first played this week", and the
    // aggregate store could not answer it from lastPlayed alone.
    if (![entry[@"firstPlayed"] isKindOfClass:NSNumber.class])
        entry[@"firstPlayed"] = @(NSDate.date.timeIntervalSince1970);
    // When it was last played (Batch 39), for the stats page's Recently
    // played: the tops are all-time, but what someone opens the page for
    // is usually "what was that song from earlier".
    entry[@"lastPlayed"] = @(NSDate.date.timeIntervalSince1970);
    // Plays per day (Batch 38), beside the seconds per day: "Today" on the
    // stats page gets its count as well as its time.
    NSMutableDictionary *all = stats();
    NSMutableDictionary *plays = all[@"daysPlays"];
    if (![plays isKindOfClass:NSMutableDictionary.class]) {
        plays = [NSMutableDictionary dictionary];
        all[@"daysPlays"] = plays;
    }
    NSString *today = todayKey();
    plays[today] = @([plays[today] doubleValue] + 1);
    if (plays.count > 35) {
        NSArray<NSString *> *sorted = [plays.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *old in [sorted subarrayWithRange:NSMakeRange(0, sorted.count - 35)]) {
            [plays removeObjectForKey:old];
        }
    }
    // Which different songs the day held (Batch 42): plays count repeats,
    // this set does not. Pruned on the same five-week horizon.
    NSMutableDictionary *daysTracks = all[@"daysTracks"];
    if (![daysTracks isKindOfClass:NSMutableDictionary.class]) {
        daysTracks = [NSMutableDictionary dictionary];
        all[@"daysTracks"] = daysTracks;
    }
    NSMutableArray *todays = daysTracks[today];
    if (![todays isKindOfClass:NSMutableArray.class]) {
        todays = [NSMutableArray array];
        daysTracks[today] = todays;
    }
    if (![todays containsObject:uri]) [todays addObject:uri];
    if (daysTracks.count > 35) {
        NSArray<NSString *> *sorted = [daysTracks.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *old in [sorted subarrayWithRange:NSMakeRange(0, sorted.count - 35)]) {
            [daysTracks removeObjectForKey:old];
        }
    }
    save();
}

void SGStatsAddListening(NSString *uri, NSTimeInterval seconds) {
    if (!uri.length || seconds < 1) return;
    NSMutableDictionary *all = stats();
    all[@"totalSeconds"] = @([all[@"totalSeconds"] doubleValue] + seconds);
    // Per-day totals (Batch 31): how much of the listening was today, this
    // week. Buckets older than five weeks are dropped as they age out.
    NSMutableDictionary *days = all[@"days"];
    if (![days isKindOfClass:NSMutableDictionary.class]) {
        days = [NSMutableDictionary dictionary];
        all[@"days"] = days;
    }
    NSString *today = todayKey();
    BOOL newDay = !days[today];
    days[today] = @([days[today] doubleValue] + seconds);
    if (newDay && days.count > 35) {
        NSArray<NSString *> *sorted = [days.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *old in [sorted subarrayWithRange:NSMakeRange(0, sorted.count - 35)]) {
            [days removeObjectForKey:old];
        }
    }
    NSMutableDictionary *entry = entryFor(uri, nil, nil);
    entry[@"seconds"] = @([entry[@"seconds"] doubleValue] + seconds);
    // The same stretch lands on the journal entry it belongs to (Batch 55):
    // plays are journaled as they start and the watcher flushes a stretch
    // before the next play is counted, so the newest entry with this URI is
    // the one that was playing. A stretch for a track with no entry (stats
    // switched on mid-song) simply has nowhere to land.
    NSMutableArray *journal = stats()[@"journal"];
    if ([journal isKindOfClass:NSMutableArray.class]) {
        for (NSMutableDictionary *play in journal.reverseObjectEnumerator) {
            if ([play[@"uri"] isEqualToString:uri]) {
                play[@"seconds"] = @([play[@"seconds"] doubleValue] + seconds);
                break;
            }
        }
    }
    save();
}

// One journal entry per counted play, newest kept to a cap: past a couple of
// thousand plays the diary's beginning is archaeology, and the file is read
// and written whole on every change, so its size is a real cost.
static const NSUInteger kJournalCap = 2000;

void SGStatsJournalPlay(NSString *uri, NSString *title, NSString *artist, NSTimeInterval duration) {
    if (!uri.length) return;
    NSMutableDictionary *all = stats();
    NSMutableArray *journal = all[@"journal"];
    if (![journal isKindOfClass:NSMutableArray.class]) {
        journal = [NSMutableArray array];
        all[@"journal"] = journal;
    }
    [journal addObject:[@{@"t": @(NSDate.date.timeIntervalSince1970),
                          @"uri": uri,
                          @"title": title ?: @"",
                          @"artist": artist ?: @"",
                          @"duration": @(duration),
                          @"seconds": @0} mutableCopy]];
    if (journal.count > kJournalCap)
        [journal removeObjectsInRange:NSMakeRange(0, journal.count - kJournalCap)];
    save();
}

NSArray<NSDictionary *> *SGStatsJournal(void) {
    NSArray *journal = stats()[@"journal"];
    if (![journal isKindOfClass:NSArray.class]) return @[];
    return [journal reverseObjectEnumerator].allObjects;
}

NSDictionary *SGStatsSnapshot(void) {
    return [stats() copy];
}

void SGStatsClear(void) {
    sg_stats = [NSMutableDictionary dictionary];
    sg_stats[@"tracks"] = [NSMutableDictionary dictionary];
    sg_stats[@"totalSeconds"] = @0;
    save();
    SGLog(@"listening stats: cleared");
}

NSString *SGStatsFormatTime(NSTimeInterval seconds) {
    NSInteger total = (NSInteger)seconds;
    if (total < 60) return @"Under a minute";
    if (total < 3600) return [NSString stringWithFormat:@"%ld min", (long)(total / 60)];
    NSInteger hours = total / 3600, minutes = (total % 3600) / 60;
    return minutes ? [NSString stringWithFormat:@"%ld h %ld min", (long)hours, (long)minutes]
                   : [NSString stringWithFormat:@"%ld h", (long)hours];
}
