// The chart card's drawing: typographic, no covers — the store keeps names
// and counts, not artwork, and a clean list reads better at a glance than
// five stretched thumbnails would. Everything on it comes from the one
// stats snapshot, so the card can never disagree with the page behind it.
#import "Core/SGCore.h"
#import "ChartCard.h"
#import "ListeningStats.h"
#import "Shared/ArtworkPalette/ArtworkPalette.h"

static UIColor *accentColor(void) {
    uint32_t rgb = 0;
    if (SGArtworkPaletteRGB(&rgb)) {
        return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0 alpha:1];
    }
    return [UIColor colorWithRed:0x1D / 255.0 green:0xB9 / 255.0 blue:0x54 / 255.0 alpha:1];
}

static void drawText(NSString *text, CGRect rect, UIFont *font, UIColor *color,
                     NSTextAlignment alignment, BOOL tail) {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = alignment;
    style.lineBreakMode = tail ? NSLineBreakByTruncatingTail : NSLineBreakByClipping;
    [text drawInRect:rect withAttributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: style,
    }];
}

// One ranked list — songs or artists — and where its next line would go.
static CGFloat drawList(NSString *header, NSArray<NSDictionary *> *entries,
                        CGFloat y, UIColor *accent, UIColor *ink, UIColor *dim) {
    drawText(header.uppercaseString, CGRectMake(64, y, 772, 30),
             [UIFont systemFontOfSize:24 weight:UIFontWeightBold], dim, NSTextAlignmentLeft, NO);
    y += 44;
    NSInteger rank = 1;
    for (NSDictionary *entry in entries) {
        NSString *left = [NSString stringWithFormat:@"%ld.  %@", (long)rank++, entry[@"name"]];
        drawText(left, CGRectMake(64, y, 560, 40),
                 [UIFont systemFontOfSize:31 weight:UIFontWeightSemibold], ink, NSTextAlignmentLeft, YES);
        drawText(SGStatsFormatTime([entry[@"seconds"] doubleValue]), CGRectMake(640, y + 3, 196, 40),
                 [UIFont systemFontOfSize:27 weight:UIFontWeightMedium], accent, NSTextAlignmentRight, NO);
        y += 52;
    }
    return y;
}

UIImage *SGChartCardImage(void) {
    NSDictionary *snapshot = SGStatsSnapshot();
    double total = [snapshot[@"totalSeconds"] doubleValue];
    if (total < 60) return nil;
    NSDictionary *tracks = snapshot[@"tracks"];

    // The tops, the same way the page ranks them: songs by their own time,
    // artists by the sum of their songs'.
    NSArray<NSString *> *byTime = [tracks keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"seconds"] compare:a[@"seconds"]];
    }];
    NSMutableArray<NSDictionary *> *songs = [NSMutableArray array];
    for (NSString *uri in byTime) {
        if (songs.count == 5) break;
        NSDictionary *entry = tracks[uri];
        if ([entry[@"seconds"] doubleValue] < 1) continue;
        NSString *title = [entry[@"title"] length] ? entry[@"title"] : @"Unknown track";
        NSString *artist = [entry[@"artist"] length] ? entry[@"artist"] : @"Unknown artist";
        [songs addObject:@{@"name": [NSString stringWithFormat:@"%@ — %@", title, artist],
                           @"seconds": entry[@"seconds"]}];
    }
    NSMutableDictionary<NSString *, NSMutableDictionary *> *byArtist = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in tracks.allValues) {
        NSString *name = [entry[@"artist"] length] ? entry[@"artist"] : @"Unknown artist";
        NSMutableDictionary *sum = byArtist[name] ?: [@{@"name": name, @"seconds": @0} mutableCopy];
        sum[@"seconds"] = @([sum[@"seconds"] doubleValue] + [entry[@"seconds"] doubleValue]);
        byArtist[name] = sum;
    }
    NSArray<NSDictionary *> *artists = [[byArtist.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"seconds"] compare:a[@"seconds"]];
    }] subarrayWithRange:NSMakeRange(0, MIN(byArtist.count, 5))];

    // The streak, counted the page's way: back from today, or from
    // yesterday when today has not got going yet.
    NSDictionary *days = [snapshot[@"days"] isKindOfClass:NSDictionary.class] ? snapshot[@"days"] : @{};
    NSDateFormatter *dayFormat = [NSDateFormatter new];
    dayFormat.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dayFormat.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    dayFormat.dateFormat = @"yyyy-MM-dd";
    NSInteger streak = 0;
    for (NSInteger back = ([days[[dayFormat stringFromDate:NSDate.date]] doubleValue] > 0 ? 0 : 1); back < 400; back++) {
        NSDate *day = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-back toDate:NSDate.date options:0];
        if ([days[[dayFormat stringFromDate:day]] doubleValue] > 0) streak++;
        else break;
    }

    UIColor *accent = accentColor();
    UIColor *ink = UIColor.whiteColor;
    UIColor *dim = [UIColor colorWithWhite:1 alpha:0.55];
    CGSize size = CGSizeMake(900, 1200);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor colorWithRed:0x10 / 255.0 green:0x10 / 255.0 blue:0x10 / 255.0 alpha:1] setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        [accent setFill];
        UIRectFill(CGRectMake(64, 72, 56, 8));

        drawText(@"LISTENING", CGRectMake(64, 108, 772, 34),
                 [UIFont systemFontOfSize:27 weight:UIFontWeightBold], dim, NSTextAlignmentLeft, NO);
        drawText(SGStatsFormatTime(total), CGRectMake(64, 148, 772, 96),
                 [UIFont systemFontOfSize:84 weight:UIFontWeightHeavy], ink, NSTextAlignmentLeft, NO);
        NSInteger plays = 0;
        for (NSDictionary *entry in tracks.allValues) plays += [entry[@"plays"] integerValue];
        drawText([NSString stringWithFormat:@"%ld plays · %lu songs · %ld-day streak",
                      (long)plays, (unsigned long)tracks.count, (long)streak],
                 CGRectMake(64, 252, 772, 40),
                 [UIFont systemFontOfSize:29 weight:UIFontWeightMedium], accent, NSTextAlignmentLeft, NO);

        CGFloat y = 356;
        if (songs.count) y = drawList(@"Top songs", songs, y, accent, ink, dim) + 36;
        if (artists.count) y = drawList(@"Top artists", artists, y, accent, ink, dim);

        NSDateFormatter *pretty = [NSDateFormatter new];
        pretty.dateFormat = @"MMMM d, yyyy";
        drawText([pretty stringFromDate:NSDate.date], CGRectMake(64, 1096, 500, 36),
                 [UIFont systemFontOfSize:26 weight:UIFontWeightMedium], dim, NSTextAlignmentLeft, NO);
        drawText(@"spoti.pw", CGRectMake(564, 1096, 272, 36),
                 [UIFont systemFontOfSize:26 weight:UIFontWeightSemibold], dim, NSTextAlignmentRight, NO);
    }];
}
