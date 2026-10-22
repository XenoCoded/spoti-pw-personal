// The offline cache (personal fork): the lyrics a walk already fetched, kept on the
// phone and asked last, so a track played once keeps its lyrics in a tunnel, on a
// plane, wherever the sources cannot be reached. Files live in
// Documents/spoti.pw/Lyrics, one JSON per track, the newest 400 kept.
//
// A line is kept whole — its words and their times, and its translation — so a
// word-timed answer replays word-timed. The backing voice and the pronunciation
// are not kept; the cache is a floor to stand on offline, not a second archive.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static const NSUInteger kKeptFiles = 400;

static NSString *cacheDirectory(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = [[documents stringByAppendingPathComponent:@"spoti.pw"] stringByAppendingPathComponent:@"Lyrics"];
    if (![NSFileManager.defaultManager fileExistsAtPath:directory]) {
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return directory;
}

unsigned long long SGLyricsCacheBytes(void) {
    unsigned long long total = 0;
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:cacheDirectory() error:nil]) {
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:
            [cacheDirectory() stringByAppendingPathComponent:name] error:nil];
        total += [attrs[NSFileSize] unsignedLongLongValue];
    }
    return total;
}

void SGLyricsCacheClear(void) {
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:cacheDirectory() error:nil]) {
        [NSFileManager.defaultManager removeItemAtPath:[cacheDirectory() stringByAppendingPathComponent:name] error:nil];
    }
}

static NSString *pathFor(NSString *trackID) {
    // A track id is base62, but the file name does not take the chain's word for it.
    NSString *safe = [trackID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [[cacheDirectory() stringByAppendingPathComponent:safe] stringByAppendingPathExtension:@"json"];
}

static void prune(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *name in [files contentsOfDirectoryAtPath:cacheDirectory() error:nil]) {
        if ([name.pathExtension isEqualToString:@"json"]) {
            [urls addObject:[NSURL fileURLWithPath:[cacheDirectory() stringByAppendingPathComponent:name]]];
        }
    }
    if (urls.count <= kKeptFiles) return;
    [urls sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da = [a resourceValuesForKeys:@[NSURLContentModificationDateKey] error:nil][NSURLContentModificationDateKey];
        NSDate *db = [b resourceValuesForKeys:@[NSURLContentModificationDateKey] error:nil][NSURLContentModificationDateKey];
        return [da compare:db];
    }];
    for (NSUInteger i = 0; i < urls.count - kKeptFiles; i++) [files removeItemAtURL:urls[i] error:nil];
}

void SGLyricsCacheSave(NSString *trackID, SGLyricsResult *result) {
    if (!trackID.length || !result.karaokeLines.count) return;
    NSMutableArray *lines = [NSMutableArray array];
    for (SGKaraokeLine *line in result.karaokeLines) {
        NSMutableArray *words = [NSMutableArray array];
        for (SGKaraokeWord *word in line.words) {
            [words addObject:@{@"text": word.text ?: @"", @"start": @(word.start), @"end": @(word.end),
                               @"joined": @(word.joined)}];
        }
        NSMutableDictionary *entry = [@{@"start": @(line.start), @"end": @(line.end), @"words": words} mutableCopy];
        if (line.translation.length) entry[@"translation"] = line.translation;
        [lines addObject:entry];
    }
    NSDictionary *sheet = @{@"provider": result.provider ?: @"", @"wordTimed": @(result.wordTimed),
                            @"title": result.title ?: @"", @"artist": result.artist ?: @"", @"lines": lines};
    NSData *data = [NSJSONSerialization dataWithJSONObject:sheet options:0 error:nil];
    if (![data writeToFile:pathFor(trackID) atomically:YES]) return;
    SGLog(@"lyrics cache: kept %@ (%lu lines, from %@)", trackID, (unsigned long)lines.count, result.provider);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ prune(); });
}

SGLyricsAsk SGLyricsCacheAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    NSData *data = [NSData dataWithContentsOfFile:pathFor(query.trackID)];
    NSDictionary *sheet = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![sheet isKindOfClass:NSDictionary.class] || ![sheet[@"lines"] isKindOfClass:NSArray.class]) {
        done(nil);
        return;
    }
    BOOL wordTimed = [sheet[@"wordTimed"] boolValue];
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    // The file is not trusted (Batch 90): it outlives the build that
    // wrote it, across every sideload, and the readers downstream join
    // the words' text with KVC — a missing or non-string text came back
    // as NSNull and threw there. Every field is kind-checked here, the
    // way the writer guards its own side.
    for (NSDictionary *entry in sheet[@"lines"]) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        SGKaraokeLine *line = [SGKaraokeLine new];
        line.start = [entry[@"start"] integerValue];
        line.end = [entry[@"end"] integerValue];
        id translation = entry[@"translation"];
        line.translation = [translation isKindOfClass:NSString.class] ? translation : nil;
        line.timing = wordTimed ? SGKaraokeTimingWords : SGKaraokeTimingLine;
        NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
        id wordEntries = entry[@"words"];
        if ([wordEntries isKindOfClass:NSArray.class]) {
            for (NSDictionary *wordEntry in wordEntries) {
                if (![wordEntry isKindOfClass:NSDictionary.class]) continue;
                SGKaraokeWord *word = [SGKaraokeWord new];
                id text = wordEntry[@"text"];
                word.text = [text isKindOfClass:NSString.class] ? text : @"";
                word.start = [wordEntry[@"start"] integerValue];
                word.end = [wordEntry[@"end"] integerValue];
                word.joined = [wordEntry[@"joined"] boolValue];
                [words addObject:word];
            }
        }
        line.words = words;
        [lines addObject:line];
    }
    if (!lines.count) {
        done(nil);
        return;
    }
    SGLyricsResult *result = [SGLyricsResult new];
    result.provider = @"cache";
    result.synced = YES;
    result.wordTimed = wordTimed;
    result.karaokeLines = lines;
    result.title = sheet[@"title"];
    result.artist = sheet[@"artist"];
    NSArray<NSNumber *> *starts;
    NSArray<NSString *> *texts;
    SGLyricsPageLines(lines, &starts, &texts);
    result.starts = starts;
    result.texts = texts;
    SGLog(@"lyrics cache: %@ answered from the phone (%lu lines)", query.trackID, (unsigned long)lines.count);
    done(result);
};
