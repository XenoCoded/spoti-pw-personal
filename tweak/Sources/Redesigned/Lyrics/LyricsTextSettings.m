// Drag the three texts of a line into size order, largest first.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "LyricsText.h"

@interface SGRLyricsTextPage : SGPage
@end

@implementation SGRLyricsTextPage {
    NSMutableArray<NSNumber *> *_order;
    UIView *_footer;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Text sizes";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _order = [SGRLyricsTextOrder() mutableCopy];
    self.tableView.editing = YES;
    _footer = SGNote(@"Pronunciation and translation are turned on from the button in the lyrics' corner.");
    self.tableView.tableFooterView = _footer;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _footer, 16, 24);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_order.count;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    return SGSectionHeader(table, @"Largest first");
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return SGSectionHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"text");
    SGRLyricsText text = _order[(NSUInteger)path.row].integerValue;
    NSArray<NSString *> *sizes = @[@"Largest", @"Smaller", @"Smallest"];
    NSString *symbol = text == SGRLyricsTextLyrics ? @"music.mic" : text == SGRLyricsTextPronunciation ? @"character.phonetic" : @"character.bubble";
    SGFillCell(cell, SGRLyricsTextName(text), sizes[MIN((NSUInteger)path.row, sizes.count - 1)], nil, symbol);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (BOOL)tableView:(UITableView *)table canMoveRowAtIndexPath:(NSIndexPath *)path {
    return YES;
}

- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)table shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)path {
    return NO;
}

- (void)tableView:(UITableView *)table moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSNumber *text = _order[(NSUInteger)from.row];
    [_order removeObjectAtIndex:(NSUInteger)from.row];
    [_order insertObject:text atIndex:(NSUInteger)to.row];
    SGRSetLyricsTextOrder(_order);
    [table reloadData];   // the sizes under the names have all moved
}

@end

SGModRow *SGRLandscapeLyricsRow(void) {
    return SGOptionRow(@"Landscape lyrics",
        @"With the phone sideways, the full screen lyrics move to the right and the cover takes the left, instead of the lines stretching the whole width.",
        SGRKeyLandscapeLyrics);
}

// The word being sung, and how hard it stands out (Batch 61): two pickers
// over the same action-sheet idiom as the star ratings. Choosing posts the
// text-did-change notice, and the lyrics view restyles the song at once —
// these two are live, no restart, no waiting for the next track.
static void pickWordSetting(NSString *title, NSString *key, NSArray<NSString *> *names) {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
        NSInteger choice = i;
        [sheet addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                SGSetInt(key, choice);
                [NSNotificationCenter.defaultCenter postNotificationName:SGRLyricsTextDidChangeNotification object:nil];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:sheet animated:YES completion:nil];
}

static NSString *wordSettingName(NSString *key, NSArray<NSString *> *names, NSInteger fallback) {
    NSInteger value = SGInt(key, fallback);
    return names[(NSUInteger)MIN(MAX(value, 0), (NSInteger)names.count - 1)];
}

SGModRow *SGRLyricsWordStyleRow(void) {
    NSArray<NSString *> *names = @[@"Float", @"Grow", @"Pop", @"Glow"];
    return SGStatActionRow(@"Current word style",
        @"How the word being sung stands out from its line: rises, swells, pops, or lights up behind.",
        ^NSString *{ return wordSettingName(SGRKeyLyricsWordStyle, names, 0); },
        ^{ pickWordSetting(@"Current word style", SGRKeyLyricsWordStyle, names); });
}

SGModRow *SGRLyricsWordIntensityRow(void) {
    NSArray<NSString *> *names = @[@"Gentle", @"Normal", @"Bold"];
    return SGStatActionRow(@"Word emphasis",
        @"How far the current word's style goes.",
        ^NSString *{ return wordSettingName(SGRKeyLyricsWordIntensity, names, 1); },
        ^{ pickWordSetting(@"Word emphasis", SGRKeyLyricsWordIntensity, names); });
}

SGModRow *SGRLyricsTextSizesRow(void) {
    return SGPageRow(@"Text sizes", ^UIViewController *{ return [SGRLyricsTextPage new]; });
}
