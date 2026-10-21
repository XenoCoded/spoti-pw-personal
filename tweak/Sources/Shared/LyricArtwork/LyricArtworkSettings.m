// The Lyric artwork rows for the Lock screen widget page, and the visual
// style picker (Batch 20): twenty-six styles are a lot to choose from a list
// of names, so the picker shows each one drawn — a thumbnail of the style
// itself, rendered with a sample song (or the playing track's cover).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "LyricArtwork.h"

NSArray<NSString *> *SGLyricArtworkStyleNames(void) {
    return @[@"Poster", @"Plain & bold", @"Aura", @"Record", @"Chat", @"Gradient",
             @"Twitter", @"Cover in letters", @"Magazine", @"Duotone", @"Word collage",
             @"Cyberpunk chat", @"Old TV", @"Matrix", @"Stickers", @"Receipt",
             @"Gig poster", @"Holo", @"RGB split", @"Window", @"Starburst", @"Print",
             @"Tiles", @"Polaroid", @"Subtitles", @"Line number"];
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
        cell.textLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [cell.textLabel.leadingAnchor constraintEqualToAnchor:thumb.trailingAnchor constant:14],
            [cell.textLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
    }
    thumb.image = _thumbs[@(style)];
    if (!thumb.image) {
        // Drawn off the main thread, dropped in when it lands if the cell is
        // still showing this style.
        NSIndexPath *here = [path copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *image = SGLyricArtworkSample(style, CGSizeMake(198, 264));
            if (!image) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                _thumbs[@(style)] = image;
                UITableViewCell *now = [table cellForRowAtIndexPath:here];
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
        @"Saver renders smaller and slower for the battery; Max matches the stills' full size. Changing it re-renders clips at the new quality.",
        SGKeyLyricArtworkClipQuality, @[@"Saver", @"Balanced", @"Max"], 1);
    quality.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO) && SGFlag(SGKeyLyricArtworkAnimated, NO); };
    SGModRow *shuffle = SGSwitchRow(@"Shuffle styles",
        @"A fresh style rolled for every track; the pick above is what plays when this is off.",
        SGKeyLyricArtworkShuffle);
    shuffle.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    return @[
        SGOptionRow(@"Lyric artwork", @"The line being sung as the lock screen's artwork, full screen when the cover is tapped open. Turns the animated lock screen off while it is on.", SGKeyLyricArtwork),
        style,
        shuffle,
        animated,
        quality,
    ];
}
