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
    save();
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
