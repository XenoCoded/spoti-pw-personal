// The search index is built once, the first time it is asked for, out of the
// pages themselves: build each page the root offers, read its sections, and
// keep every row with the page it lives on and a way back to a fresh copy.
// Two levels deep — a page's own page rows are followed once — which is
// where everything lives since the great un-burying.
#import "SettingsSearch.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/Player/SleepTimer.h"
#import "Shared/Navigation/Links.h"
#import "Shared/ListeningStats/ChartCard.h"
#import "Shared/ListeningStats/HeatmapCard.h"
#import "Native/Appearance/Appearance.h"
#import "Redesigned/Kit/SGRAccent.h"
#import "Redesigned/Player/PlayerVinyl.h"

#define SGKeyQuickAccess @"spotifyglass.settings.quickAccess"

static NSArray<SGModRow *> *sg_registry;
static UIViewController *(^sg_rootPage)(void);

void SGSettingsSearchSetRegistry(NSArray<SGModRow *> *pageRows, UIViewController *(^rootPage)(void)) {
    sg_registry = pageRows;
    sg_rootPage = rootPage;
}

NSArray<SGModRow *> *SGSettingsSearchRegistry(void) {
    return sg_registry ?: @[];
}

UIViewController *(^SGSettingsRootBuilder(void))(void) {
    return sg_rootPage;
}

NSArray<NSString *> *SGQuickAccessTitles(void) {
    NSArray<NSString *> *stored = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyQuickAccess];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSString *title in stored ?: @[]) {
        for (SGModRow *row in SGSettingsSearchRegistry()) {
            if ([row.title isEqualToString:title]) { [titles addObject:title]; break; }
        }
    }
    return titles;
}

#pragma mark - the index

@interface SGSearchEntry : NSObject
@property (nonatomic, copy) NSString *row, *note, *page;
// For a section entry: `row` is the section's name (what shows and what
// matches), and `target` is the row the page should flash on arrival.
@property (nonatomic, copy) NSString *target;
@property (nonatomic, copy) UIViewController *(^build)(void);
// For an action entry (the command palette, Batch 76): no page to open —
// the tap does this instead, and the search steps aside.
@property (nonatomic, copy) void (^action)(void);
@end

@implementation SGSearchEntry
@end

static NSArray<SGSearchEntry *> *sg_index;
static BOOL sg_indexing;

static void indexPage(NSMutableArray<SGSearchEntry *> *entries, NSMutableSet<NSString *> *seen,
                      NSString *pageTitle, UIViewController *(^build)(void), NSInteger depth) {
    UIViewController *page = build();
    if (![page isKindOfClass:SGModPage.class]) return;
    for (SGModSection *section in [(SGModPage *)page sg_sections]) {
        // The section itself is searchable (Batch 32): "Storage" and
        // "Gestures" are how people think of these places, and no row on
        // the page carries those words. The entry lands on the section's
        // first row.
        if (section.title.length && section.rows.count) {
            NSString *stamp = [pageTitle stringByAppendingFormat:@"\n§%@", section.title];
            if (![seen containsObject:stamp]) {
                [seen addObject:stamp];
                SGSearchEntry *entry = [SGSearchEntry new];
                entry.row = section.title;
                entry.target = section.rows.firstObject.title;
                entry.page = pageTitle;
                entry.build = build;
                [entries addObject:entry];
            }
        }
        for (SGModRow *row in section.rows) {
            NSString *stamp = [pageTitle stringByAppendingFormat:@"\n%@", row.title];
            if (![seen containsObject:stamp]) {
                [seen addObject:stamp];
                SGSearchEntry *entry = [SGSearchEntry new];
                entry.row = row.title;
                entry.note = row.subtitle;
                entry.page = pageTitle;
                entry.build = build;
                [entries addObject:entry];
            }
            if (depth < 2 && row.page && entries.count < 4000) {
                indexPage(entries, seen, row.title, row.page, depth + 1);
            }
        }
    }
}

// The command palette (Batch 76): the search stops being only a way to
// FIND settings and becomes a way to DO things — every gesture action by
// name, the sleep timer's useful spans, the three tabs, and the two
// copy-as-image cards. Each is an entry whose page reads "Actions" and
// whose tap performs instead of navigating. The list is curated on
// purpose: things a person would type ("next", "sleep 30", "home").
static void indexActions(NSMutableArray<SGSearchEntry *> *entries, NSMutableSet<NSString *> *seen) {
    void (^add)(NSString *, void (^)(void)) = ^(NSString *title, void (^run)(void)) {
        NSString *stamp = [@"Actions" stringByAppendingFormat:@"\n%@", title];
        if ([seen containsObject:stamp]) return;
        [seen addObject:stamp];
        SGSearchEntry *entry = [SGSearchEntry new];
        entry.row = title;
        entry.page = @"Actions";
        entry.action = run;
        [entries addObject:entry];
    };
    NSArray<NSString *> *gestures = SGGestureActionNames();
    for (NSUInteger i = 0; i < gestures.count; i++) {
        SGGestureAction action = (SGGestureAction)i;
        add(gestures[i], ^{ SGGesturePerform(action); });
    }
    add(@"Sleep timer · 15 minutes", ^{ SGSleepTimerChoose(1); });
    add(@"Sleep timer · 30 minutes", ^{ SGSleepTimerChoose(2); });
    add(@"Sleep timer · 1 hour", ^{ SGSleepTimerChoose(4); });
    add(@"Sleep timer · End of track", ^{ SGSleepTimerChoose(5); });
    add(@"Sleep timer · Off", ^{ SGSleepTimerChoose(0); });
    add(@"Open Home", ^{ SGOpenSpotifyURI([NSURL URLWithString:@"spotify:home"]); });
    add(@"Open Search", ^{ SGOpenSpotifyURI([NSURL URLWithString:@"spotify:search"]); });
    add(@"Open Your Library", ^{ SGOpenSpotifyURI([NSURL URLWithString:@"spotify:collection"]); });
    add(@"Copy chart card", ^{
        UIImage *image = SGChartCardImage();
        if (image) UIPasteboard.generalPasteboard.image = image;
    });
    add(@"Copy year heatmap", ^{
        UIImage *image = SGHeatmapCardImage();
        if (image) UIPasteboard.generalPasteboard.image = image;
    });
    // Theme presets as actions (Batch 83): the same six accents the
    // Appearance card offers, applied straight to whichever look is
    // active — and Match cover art off, or the next track would take
    // the accent straight back.
    NSArray *presets = @[@[@"Catppuccin", @0xCBA6F7], @[@"Dracula", @0xFF79C6],
                         @[@"Nord", @0x88C0D0], @[@"Gruvbox", @0xFE8019],
                         @[@"Rosé Pine", @0xC4A7E7], @[@"Tokyo Night", @0x7AA2F7]];
    BOOL redesign = SGRedesignedUIStored();
    for (NSArray *preset in presets) {
        NSString *name = preset[0];
        NSInteger rgb = [preset[1] integerValue];
        add([@"Theme · " stringByAppendingString:name], ^{
            if (redesign) {
                SGSetInt(SGRKeyAccent, rgb);
                SGSetInt(SGRKeyAccentMatchArtwork, 0);
            } else {
                SGSetInt(SGKeyAccent, rgb);
                SGSetInt(SGKeyAccentMatchArtwork, 0);
            }
        });
    }
    // Vinyl reads its switch live, so the palette can flip it with no
    // restart — redesign only, where the player hook lives.
    if (redesign) add(@"Vinyl mode · Toggle", ^{
        SGSetInt(SGKeyVinyl, !SGFlag(SGKeyVinyl, NO));
    });
}

static NSArray<SGSearchEntry *> *searchIndex(void) {
    if (sg_index) return sg_index;
    sg_indexing = YES;
    NSMutableArray<SGSearchEntry *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (sg_rootPage) indexPage(entries, seen, @"Mod Settings", sg_rootPage, 1);
    for (SGModRow *row in SGSettingsSearchRegistry()) {
        if (row.page) indexPage(entries, seen, row.title, row.page, 1);
    }
    indexActions(entries, seen);
    sg_indexing = NO;
    sg_index = entries;
    SGLog(@"settings search: indexed %lu settings", (unsigned long)entries.count);
    return sg_index;
}

// A builder for a recent or a result: the page it names, fresh.
static UIViewController *(^builderForPage(NSString *pageTitle))(void) {
    if ([pageTitle isEqualToString:@"Mod Settings"]) return sg_rootPage;
    for (SGModRow *row in SGSettingsSearchRegistry()) {
        if ([row.title isEqualToString:pageTitle]) return row.page;
    }
    // A page one level down (a Player sub-page, say): the index knows it.
    // While the index itself is being built this would circle back into the
    // root page it is built from, so it answers nothing then.
    if (!sg_indexing) {
        for (SGSearchEntry *entry in searchIndex()) {
            if ([entry.page isEqualToString:pageTitle]) return entry.build;
        }
    }
    return nil;
}

#pragma mark - the search page

@interface SGSearchSettingsPage : SGPage <UISearchBarDelegate>
@end

@implementation SGSearchSettingsPage {
    UISearchBar *_bar;
    NSArray<SGSearchEntry *> *_shown;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Search settings";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 56)];
    _bar.placeholder = @"Try “lyrics”, “next track”, “sleep”…";
    _bar.delegate = self;
    _bar.autocorrectionType = UITextAutocorrectionTypeNo;
    _bar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.tableView.tableHeaderView = _bar;
    [self refilter];
    [_bar becomeFirstResponder];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (void)refilter {
    NSString *query = [_bar.text lowercaseString];
    if (!query.length) {
        // An empty search shows where you have just been.
        NSMutableArray<SGSearchEntry *> *recents = [NSMutableArray array];
        for (NSDictionary<NSString *, NSString *> *recent in SGRecentSettings()) {
            UIViewController *(^build)(void) = builderForPage(recent[@"page"]);
            if (!build) continue;
            SGSearchEntry *entry = [SGSearchEntry new];
            entry.row = recent[@"row"] ?: recent[@"page"];
            entry.page = recent[@"page"];
            entry.build = build;
            [recents addObject:entry];
        }
        _shown = recents;
        return;
    }
    NSMutableArray<SGSearchEntry *> *prefix = [NSMutableArray array], *inside = [NSMutableArray array];
    for (SGSearchEntry *entry in searchIndex()) {
        NSString *title = [entry.row lowercaseString];
        if ([title hasPrefix:query]) [prefix addObject:entry];
        else if ([title containsString:query] || [entry.note.lowercaseString containsString:query]
                 || [entry.page.lowercaseString containsString:query]) [inside addObject:entry];
    }
    [prefix addObjectsFromArray:inside];
    _shown = prefix;
}

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    [self refilter];
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)bar {
    [bar resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_shown.count;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"result");
    SGSearchEntry *entry = _shown[(NSUInteger)path.row];
    SGFillCell(cell, entry.row, [@"in " stringByAppendingString:entry.page], nil, nil);
    // The match lights up (Batch 35), the way every system search does it.
    NSString *query = _bar.text;
    if (query.length) {
        NSRange hit = [entry.row.lowercaseString rangeOfString:query.lowercaseString];
        if (hit.location != NSNotFound) {
            NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:entry.row
                attributes:@{NSFontAttributeName: cell.textLabel.font}];
            [text addAttribute:NSFontAttributeName
                         value:[UIFont boldSystemFontOfSize:cell.textLabel.font.pointSize] range:hit];
            cell.textLabel.attributedText = text;
        }
    }
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryView = entry.action ? SGSymbolView(@"bolt.fill", 13, UIImageSymbolWeightSemibold, 16)
                                      : SGSymbolView(@"chevron.right", 13, UIImageSymbolWeightSemibold, 16);
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    SGSearchEntry *entry = _shown[(NSUInteger)path.row];
    // An action does its thing and the search steps aside — back to the
    // root, where what it did (a skip, a tab, a timer) can be seen.
    if (entry.action) {
        entry.action();
        [self.navigationController popToRootViewControllerAnimated:YES];
        return;
    }
    UIViewController *page = entry.build();
    if (!page) return;
    // A recent for a page itself carries the page's name as its row; asking
    // the page to flash its own title would find nothing, so only a real
    // row title is focused.
    NSString *focus = entry.target ?: entry.row;
    if (![focus isEqualToString:entry.page]) SGModPageFocus(entry.page, focus);
    [self.navigationController pushViewController:page animated:YES];
}

@end

UIViewController *SGSettingsSearchPage(void) {
    return [SGSearchSettingsPage new];
}

#pragma mark - quick access

@interface SGQuickAccessSettingsPage : SGPage
@end

@implementation SGQuickAccessSettingsPage

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Quick access";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIView *note = SGNote(@"Pages picked here sit at the top of Mod Settings, above everything else.");
    self.tableView.tableFooterView = note;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (self.tableView.tableFooterView) SGFitNote(self.tableView, self.tableView.tableFooterView, 16, 24);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)SGSettingsSearchRegistry().count;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"quick");
    SGModRow *row = SGSettingsSearchRegistry()[(NSUInteger)path.row];
    SGFillCell(cell, row.title, nil, nil, nil);
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryView = nil;
    if ([SGQuickAccessTitles() containsObject:row.title]) {
        UIImageView *tick = SGSymbolView(@"checkmark", 13, UIImageSymbolWeightSemibold, 16);
        tick.tintColor = SGGreen();
        cell.accessoryView = tick;
    }
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];
    NSString *title = SGSettingsSearchRegistry()[(NSUInteger)path.row].title;
    NSMutableArray<NSString *> *stored = [[NSUserDefaults.standardUserDefaults arrayForKey:SGKeyQuickAccess] mutableCopy] ?: [NSMutableArray array];
    if ([stored containsObject:title]) [stored removeObject:title];
    else [stored addObject:title];
    [NSUserDefaults.standardUserDefaults setObject:stored forKey:SGKeyQuickAccess];
    [table reloadData];
}

@end

UIViewController *SGQuickAccessPage(void) {
    return [SGQuickAccessSettingsPage new];
}
