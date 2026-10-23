// QQ Music (personal fork): the Chinese catalogue the other sources do not reach, and a
// second opinion on everything else. Its search answers plain JSON when asked, its
// lyrics come as an LRC sheet in the reply itself (nobase64=1 spares the decoding),
// and the lines are timed by line and not by word, so it sits at the end of the order
// with LRCLIB: the chain keeps a word-timed answer over either of them. No key, no
// account; the endpoints ask only for a Referer of y.qq.com.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static NSString *const kSearch = @"https://c.y.qq.com/soso/fcgi-bin/client_search_cp";
static NSString *const kLyric = @"https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg";
// QQ's lengths are rounded harder than LRCLIB's, so the agreement asked for is looser.
static const NSInteger kLengthSlack = 8;

static NSDictionary<NSString *, NSString *> *headers(void) {
    return @{@"User-Agent": @"spoti.pw " @SG_VERSION @" (https://github.com/skopevoj/spoti.pw)",
             @"Referer": @"https://y.qq.com"};
}

// The same LRC reading LRCLIB does, kept in this file so a source stands alone: stamps
// at a line's head only, hundredths or thousandths, sorted, the empty rows kept as the
// breaks they are. (LrcLib.m linesFromLRC is the same reading; the two agree on purpose.)
static NSArray<SGKaraokeLine *> *linesFromLRC(NSString *lrc) {
    static NSRegularExpression *stamp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stamp = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]" options:0 error:nil];
    });
    NSMutableArray<NSDictionary *> *stamped = [NSMutableArray array];
    for (NSString *row in [lrc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSTextCheckingResult *> *found = [stamp matchesInString:row options:0 range:NSMakeRange(0, row.length)];
        NSUInteger end = 0;
        NSMutableArray<NSNumber *> *at = [NSMutableArray array];
        for (NSTextCheckingResult *match in found) {
            if (match.range.location != end) break;
            end = NSMaxRange(match.range);
            NSInteger minutes = [row substringWithRange:[match rangeAtIndex:1]].integerValue;
            NSInteger seconds = [row substringWithRange:[match rangeAtIndex:2]].integerValue;
            NSInteger fraction = 0;
            NSRange part = [match rangeAtIndex:3];
            if (part.location != NSNotFound) {
                NSString *digits = [row substringWithRange:part];
                fraction = digits.integerValue * (digits.length == 1 ? 100 : digits.length == 2 ? 10 : 1);
            }
            [at addObject:@((minutes * 60 + seconds) * 1000 + fraction)];
        }
        if (!at.count) continue;
        NSString *text = [[row substringFromIndex:end] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        for (NSNumber *ms in at) [stamped addObject:@{@"ms": ms, @"text": text}];
    }
    if (!stamped.count) return nil;
    [stamped sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"ms"] compare:b[@"ms"]];
    }];
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *row in stamped) {
        [starts addObject:row[@"ms"]];
        [texts addObject:row[@"text"]];
    }
    return SGKaraokeEstimatedLines(starts, texts);
}

// The recording of the search's list that is the track: a title that matches outright
// first, then the closest length, with the slack above as the gate when a length is
// known. A live or karaoke namesake is a last resort the title test keeps out on its own.
static NSDictionary *bestOf(id found, SGLyricsQuery *query) {
    id qqData = [found isKindOfClass:NSDictionary.class] ? found[@"data"] : nil;
    id qqSongs = [qqData isKindOfClass:NSDictionary.class] ? qqData[@"song"] : nil;
    NSArray *list = [qqSongs isKindOfClass:NSDictionary.class] ? qqSongs[@"list"] : nil;
    NSDictionary *best = nil;
    NSInteger bestScore = NSIntegerMax;
    for (NSDictionary *item in [list isKindOfClass:NSArray.class] ? list : @[]) {
        if (![item isKindOfClass:NSDictionary.class] || ![item[@"songmid"] isKindOfClass:NSString.class]) continue;
        NSInteger off = query.seconds > 0 ? labs((NSInteger)SGCoerceDouble(item[@"interval"], 0) - query.seconds) : 0;
        if (query.seconds > 0 && off > kLengthSlack) continue;
        BOOL titled = [item[@"songname"] isKindOfClass:NSString.class]
            && [item[@"songname"] caseInsensitiveCompare:query.title] == NSOrderedSame;
        NSInteger score = (titled ? 0 : 1000) + off;
        if (score < bestScore) {
            bestScore = score;
            best = item;
        }
    }
    return best;
}

SGLyricsAsk SGQQMusicAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    if (!query.title.length || !query.artist.length) {
        SGLog(@"qq: nothing to search with for %@", query.trackID);
        done(nil);
        return;
    }
    NSDictionary<NSString *, NSString *> *search = @{
        @"aggr": @"1", @"cr": @"1", @"flag_qc": @"0", @"p": @"1", @"n": @"10", @"format": @"json",
        @"w": [NSString stringWithFormat:@"%@ %@", query.title, query.artist],
    };
    SGLyricsGetJSON(SGLyricsURL(kSearch, search), headers(), ^(id found) {
        NSDictionary *item = bestOf(found, query);
        if (!item) {
            SGLog(@"qq: no recording of %@ by %@ fits", query.title, query.artist);
            done(nil);
            return;
        }
        NSDictionary<NSString *, NSString *> *ask = @{
            @"songmid": item[@"songmid"], @"format": @"json", @"nobase64": @"1",
        };
        SGLyricsGetJSON(SGLyricsURL(kLyric, ask), headers(), ^(id reply) {
            NSString *lrc = [reply isKindOfClass:NSDictionary.class] ? reply[@"lyric"] : nil;
            NSArray<SGKaraokeLine *> *lines = [lrc isKindOfClass:NSString.class] ? linesFromLRC(lrc) : nil;
            if (!lines) {
                SGLog(@"qq: %@ has no timed sheet for %@ by %@", item[@"songmid"], query.title, query.artist);
                done(nil);
                return;
            }
            SGLyricsResult *result = [SGLyricsResult new];
            result.synced = YES;
            result.karaokeLines = lines;
            NSArray<NSNumber *> *starts;
            NSArray<NSString *> *texts;
            SGLyricsPageLines(lines, &starts, &texts);
            result.starts = starts;
            result.texts = texts;
            SGLog(@"qq: %lu timed lines for %@ by %@", (unsigned long)lines.count, query.title, query.artist);
            done(result);
        });
    });
};
