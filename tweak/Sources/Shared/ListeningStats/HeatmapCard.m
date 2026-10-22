// The heatmap card's drawing, a sibling of the chart card's: same
// near-black ground, same accent (the playing cover's colour, Spotify
// green until the palette has one), same idea — the picture can never
// disagree with the stats page because both read the one snapshot.
// The grid is the last 53 weeks ending this week; days still to come
// in the current week are left undrawn, the way GitHub leaves them.
#import "Core/SGCore.h"
#import "HeatmapCard.h"
#import "ListeningStats.h"
#import "Shared/ArtworkPalette/ArtworkPalette.h"

static UIColor *heatmapAccent(void) {
    uint32_t rgb = 0;
    if (SGArtworkPaletteRGB(&rgb)) {
        return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0 alpha:1];
    }
    return [UIColor colorWithRed:0x1D / 255.0 green:0xB9 / 255.0 blue:0x54 / 255.0 alpha:1];
}

static void heatmapText(NSString *text, CGRect rect, UIFont *font, UIColor *color) {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByClipping;
    [text drawInRect:rect withAttributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: style,
    }];
}

UIImage *SGHeatmapCardImage(void) {
    NSDictionary *snapshot = SGStatsSnapshot();
    NSDictionary *days = [snapshot[@"days"] isKindOfClass:NSDictionary.class] ? snapshot[@"days"] : @{};
    if (!days.count) return nil;

    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDateFormatter *dayFormat = [NSDateFormatter new];
    dayFormat.dateFormat = @"yyyy-MM-dd";
    NSDate *today = [calendar startOfDayForDate:NSDate.date];
    // This week's Sunday, then back 52 more weeks: the grid's first day.
    NSInteger weekday = [calendar component:NSCalendarUnitWeekday fromDate:today]; // 1 = Sunday
    NSDate *start = [calendar dateByAddingUnit:NSCalendarUnitDay
                                         value:-(weekday - 1) - 52 * 7 toDate:today options:0];

    // Read the whole grid first: the deepest green is scaled to the
    // biggest day on it, so the drawing pass needs the max up front.
    double seconds[53][7];
    double maxDay = 0;
    NSInteger activeDays = 0;
    double rangeTotal = 0;
    for (NSInteger col = 0; col < 53; col++) {
        for (NSInteger row = 0; row < 7; row++) {
            NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay
                                                 value:col * 7 + row toDate:start options:0];
            double value = [day compare:today] == NSOrderedDescending
                ? -1 : [days[[dayFormat stringFromDate:day]] doubleValue];
            seconds[col][row] = value;
            if (value > 0) { activeDays++; rangeTotal += value; }
            if (value > maxDay) maxDay = value;
        }
    }
    if (maxDay <= 0) return nil;
    // The drawing block below cannot capture a C array (the Batch 60
    // lesson) — it takes this pointer to the grid instead.
    double (*grid)[7] = seconds;

    UIColor *accent = heatmapAccent();
    UIColor *ink = UIColor.whiteColor;
    UIColor *dim = [UIColor colorWithWhite:1 alpha:0.55];
    UIColor *empty = [UIColor colorWithWhite:1 alpha:0.08];
    CGSize size = CGSizeMake(1040, 430);
    const CGFloat pitch = 16.5, cell = 13.5, gridX = 64, gridY = 196;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor colorWithRed:0x10 / 255.0 green:0x10 / 255.0 blue:0x10 / 255.0 alpha:1] setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        [accent setFill];
        UIRectFill(CGRectMake(64, 52, 56, 8));

        heatmapText(@"LISTENING YEAR", CGRectMake(64, 80, 700, 34),
                    [UIFont systemFontOfSize:27 weight:UIFontWeightBold], dim);
        heatmapText([NSString stringWithFormat:@"%ld active days · %@ in the last year",
                         (long)activeDays, SGStatsFormatTime(rangeTotal)],
                    CGRectMake(64, 122, 912, 44),
                    [UIFont systemFontOfSize:32 weight:UIFontWeightSemibold], ink);

        // Month names over the column where each month first appears.
        NSDateFormatter *monthFormat = [NSDateFormatter new];
        monthFormat.dateFormat = @"MMM";
        NSInteger lastMonth = 0;
        for (NSInteger col = 0; col < 53; col++) {
            NSDate *sunday = [calendar dateByAddingUnit:NSCalendarUnitDay
                                                  value:col * 7 toDate:start options:0];
            NSInteger month = [calendar component:NSCalendarUnitMonth fromDate:sunday];
            if (month != lastMonth) {
                lastMonth = month;
                heatmapText([monthFormat stringFromDate:sunday],
                            CGRectMake(gridX + col * pitch, gridY - 30, 60, 24),
                            [UIFont systemFontOfSize:19 weight:UIFontWeightMedium], dim);
            }
        }

        // The cells: a resting day is a faint tile; a listening day is
        // the accent in four depths, quartered against the biggest day.
        for (NSInteger col = 0; col < 53; col++) {
            for (NSInteger row = 0; row < 7; row++) {
                double value = grid[col][row];
                if (value < 0) continue; // still to come this week
                UIColor *fill = empty;
                if (value > 0) {
                    double depth = value / maxDay;
                    fill = [accent colorWithAlphaComponent:depth <= 0.25 ? 0.3 : depth <= 0.5 ? 0.5 : depth <= 0.75 ? 0.75 : 1.0];
                }
                [fill setFill];
                CGRect rect = CGRectMake(gridX + col * pitch, gridY + row * pitch, cell, cell);
                [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:3] fill];
            }
        }

        // The legend, and the footer the chart card signs with.
        CGFloat legendY = gridY + 7 * pitch + 18;
        heatmapText(@"Less", CGRectMake(gridX, legendY - 4, 60, 24),
                    [UIFont systemFontOfSize:19 weight:UIFontWeightMedium], dim);
        for (NSInteger step = 0; step < 5; step++) {
            UIColor *fill = step == 0 ? empty
                : [accent colorWithAlphaComponent:step == 1 ? 0.3 : step == 2 ? 0.5 : step == 3 ? 0.75 : 1.0];
            [fill setFill];
            CGRect rect = CGRectMake(gridX + 52 + step * (cell + 3.5), legendY, cell, cell);
            [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:3] fill];
        }
        heatmapText(@"More", CGRectMake(gridX + 52 + 5 * (cell + 3.5) + 6, legendY - 4, 60, 24),
                    [UIFont systemFontOfSize:19 weight:UIFontWeightMedium], dim);

        NSDateFormatter *pretty = [NSDateFormatter new];
        pretty.dateFormat = @"MMMM d, yyyy";
        heatmapText([pretty stringFromDate:NSDate.date], CGRectMake(64, 372, 500, 36),
                    [UIFont systemFontOfSize:24 weight:UIFontWeightMedium], dim);
        NSString *brand = @"spoti.pw";
        CGSize brandSize = [brand sizeWithAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold]}];
        heatmapText(brand, CGRectMake(size.width - 64 - brandSize.width, 372, brandSize.width + 4, 36),
                    [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold], dim);
    }];
}
