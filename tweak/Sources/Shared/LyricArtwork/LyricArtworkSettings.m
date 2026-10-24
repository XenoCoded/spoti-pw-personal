// The Lyric artwork rows for the Lock screen widget page, and the visual
// style picker (Batch 20): twenty-six styles are a lot to choose from a list
// of names, so the picker shows each one drawn — a thumbnail of the style
// itself, rendered with a sample song (or the playing track's cover).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "LyricArtwork.h"
#import "Shared/Lyrics/Lyrics.h"

NSArray<NSString *> *SGLyricArtworkStyleNames(void) {
    return @[@"Poster", @"Plain & bold", @"Aura", @"Record", @"Chat", @"Gradient",
             @"Twitter", @"Cover in letters", @"Magazine", @"Duotone", @"Word collage",
             @"Cyberpunk chat", @"Old TV", @"Matrix", @"Stickers", @"Receipt",
             @"Gig poster", @"Holo", @"RGB split", @"Window", @"Starburst", @"Print",
             @"Tiles", @"Polaroid", @"Subtitles", @"Line number",
             @"Pulse bars", @"Warp flow", @"OLED stealth"];
}

// The thumbnails render one at a time on a serial queue (Batch 89): the
// sample renderer serialises on its lock anyway, so a concurrent burst
// bought nothing but contention — and, before the lock itself was fixed,
// raced the state the renders share.
static dispatch_queue_t SGSampleRenderQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("pw.spoti.lyricartwork.samples", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@interface SGLyricStylePage : SGPage
@end

@implementation SGLyricStylePage {
    NSMutableDictionary<NSNumber *, UIImage *> *_thumbs;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Lyric artwork style";
    _thumbs = [NSMutableDictionary dictionary];
    return self;
}

// Two sections (Batch 29): the six the fork draws itself, and the twenty
// from the Workshop catalogue — twenty-six rows read as a list, but scan
// as two shelves.
static NSInteger styleForRow(NSInteger section, NSInteger row) {
    return section == 0 ? row : row + 6;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return 2;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 6 : (NSInteger)SGLyricArtworkStyleNames().count - 6;
}

- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Ours" : @"Workshop";
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    return 104;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"style");
    NSInteger style = styleForRow(path.section, path.row);
    SGFillCell(cell, SGLyricArtworkStyleNames()[style], nil, nil, nil);
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryView = nil;
    if (style == SGInt(SGKeyLyricArtworkStyle, SGLyricArtworkAura)) {
        UIImageView *tick = SGSymbolView(@"checkmark", 13, UIImageSymbolWeightSemibold, 16);
        tick.tintColor = SGGreen();
        cell.accessoryView = tick;
    }
    UIImageView *thumb = (UIImageView *)[cell.contentView viewWithTag:77];
    if (!thumb) {
        thumb = [[UIImageView alloc] initWithFrame:CGRectMake(14, 8, 66, 88)];
        thumb.tag = 77;
        thumb.contentMode = UIViewContentModeScaleAspectFill;
        thumb.clipsToBounds = YES;
        thumb.layer.cornerRadius = 6;
        thumb.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
        [cell.contentView addSubview:thumb];
    }
    // The room for the thumbnail comes out of the configuration's leading
    // margin, on EVERY fill: SGFillCell installs a fresh configuration
    // each time a cell is filled, so setting the margin only when the
    // thumb is created leaves reused cells at the stock margin with the
    // title slid back under the picture. (The Batch 87 crash lived here
    // too: the cell's textLabel is nil under a content configuration,
    // and the constraints that used to anchor to it put nil into an
    // array literal.)
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    NSDirectionalEdgeInsets margins = content.directionalLayoutMargins;
    margins.leading = 94;   // 14 margin + 66 thumbnail + 14 gap
    content.directionalLayoutMargins = margins;
    cell.contentConfiguration = content;
    thumb.image = _thumbs[@(style)];
    if (!thumb.image) {
        // Drawn off the main thread, dropped in when it lands if the cell
        // is still showing this style.
        NSIndexPath *here = [path copy];
        dispatch_async(SGSampleRenderQueue(), ^{
            UIImage *image = SGLyricArtworkSample(style, CGSizeMake(198, 264));
            if (!image) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                _thumbs[@(style)] = image;
                UITableViewCell *now = [table cellForRowAtIndexPath:here];
                if (![[table indexPathForCell:now] isEqual:here]) return;
                UIImageView *view = (UIImageView *)[now.contentView viewWithTag:77];
                if (view) view.image = image;
            });
        });
    }
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];
    SGSetInt(SGKeyLyricArtworkStyle, styleForRow(path.section, path.row));
    [table reloadData];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

NSArray<SGModRow *> *SGLyricArtworkRows(void) {
    SGModRow *style = SGPageRow(@"Lyric artwork style", ^UIViewController *{ return [SGLyricStylePage new]; });
    style.value = ^NSString *{
        NSInteger picked = SGInt(SGKeyLyricArtworkStyle, SGLyricArtworkAura);
        NSArray<NSString *> *names = SGLyricArtworkStyleNames();
        return picked >= 0 && picked < (NSInteger)names.count ? names[picked] : @"Aura";
    };
    style.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    SGModRow *animated = SGOptionRow(@"Animated artwork",
        @"On iOS 26, the styles that move — most styles — play as a looping clip instead of a still. Renders once per line, then kept on the phone.",
        SGKeyLyricArtworkAnimated);
    animated.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    SGModRow *quality = SGChoiceRow(@"Clip quality",
        @"Saver animates at fewer frames per second for the battery; Max is the smoothest. The picture is the stills' full size at every level, so the lock screen never resizes it. Changing it re-renders clips at the new quality.",
        SGKeyLyricArtworkClipQuality, @[@"Saver", @"Balanced", @"Max"], 1);
    quality.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO) && SGFlag(SGKeyLyricArtworkAnimated, NO); };
    SGModRow *chatTheme = SGChoiceRow(@"Chat theme",
        @"For the Chat style: the room the conversation sits in — iMessage's light room, its dark one, or whichever the phone is using.",
        SGKeyLyricArtworkChatTheme, @[@"Light", @"Dark", @"System"], 0);
    chatTheme.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    SGModRow *wordTiming = SGChoiceRow(@"Word timing",
        @"How the sung words light up. Smooth follows every word; Standard updates when the system asks; Off lights the whole line and updates the least — the battery choice.",
        SGKeyLyricArtworkWordTiming, @[@"Smooth", @"Standard", @"Off"], 0);
    wordTiming.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    SGModRow *finish = SGChoiceRow(@"Finish (built-in styles)",
        @"For Poster, Plain & bold, Aura and Record: the original look, a darkened one, or washed in the accent gradient the app puts on its accents.",
        SGKeyLyricArtworkFinish, @[@"Original", @"Dark", @"Accent gradient"], 0);
    finish.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    SGModRow *artworkSize = SGChoiceRow(@"Artwork size",
        @"Compact keeps the lock-screen artwork at the smaller size, steady. Full is the biggest picture; the lock screen animates more when it changes. Changing it re-renders clips at the new size.",
        SGKeyLyricArtworkSize, @[@"Compact", @"Full"], 0);
    artworkSize.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    SGModRow *shuffle = SGSwitchRow(@"Shuffle styles",
        @"A fresh style rolled for every track; the pick above is what plays when this is off.",
        SGKeyLyricArtworkShuffle);
    shuffle.defaultOn = NO;   // its reader defaults OFF (Batch 93): the switch showed ON while nothing shuffled
    shuffle.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    // The card and the words, out of the app (Batch 35): the lock screen's
    // picture is the shareable thing players like Apple Music make of a
    // lyric, and the full text is the other half of that.
    SGModRow *card = SGStatActionRow(@"Copy lyric card",
        @"The line on your lock screen right now, as a picture, ready to paste anywhere.",
        ^NSString *{
            NSInteger picked = SGInt(SGKeyLyricArtworkStyle, SGLyricArtworkAura);
            NSArray<NSString *> *names = SGLyricArtworkStyleNames();
            return picked >= 0 && picked < (NSInteger)names.count ? names[picked] : @"Aura";
        }, ^{
            UIImage *image = SGLyricArtworkCurrentCard();
            if (image) UIPasteboard.generalPasteboard.image = image;
        });
    card.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    SGModRow *words = SGStatActionRow(@"Copy lyrics",
        @"The playing track's lyrics as plain text.",
        ^NSString *{
            NSArray *lines = SGKaraokeLinesForTrack(SGKaraokePlayingTrack());
            return lines ? [NSString stringWithFormat:@"%lu lines", (unsigned long)lines.count] : @"Not loaded";
        }, ^{
            NSArray *lines = SGKaraokeLinesForTrack(SGKaraokePlayingTrack());
            if (!lines.count) return;
            NSMutableArray<NSString *> *texts = [NSMutableArray array];
            for (id line in lines) [texts addObject:SGKaraokeLineText(line)];
            UIPasteboard.generalPasteboard.string = [texts componentsJoinedByString:@"\n"];
        });
    return @[
        SGOptionRow(@"Lyric artwork", @"The line being sung as the lock screen's artwork, full screen when the cover is tapped open. Turns the animated lock screen off while it is on.", SGKeyLyricArtwork),
        style,
        shuffle,
        chatTheme,
        wordTiming,
        finish,
        artworkSize,
        animated,
        quality,
        card,
        words,
    ];
}
