// Settings: a Mod Settings row at the end of Spotify's settings list opens the mod's own page: the
// Appearance card with Redesigned UI, then a page per part of Spotify, each holding what that part
// offers in the stored look (App/Pages.m: Navbar, Player, and Home & Library for the native look), Audio
// effects (Shared/AudioEffects, in either look and applying straight away), Privacy & clutter
// and Labs, All flags, a searchable list of every flag with an override per flag, and Mod, the
// build, its updates and links. The same row leads the side drawer's list (trees/test6.txt), above
// Your plan, so the page is a tap from Home, and holding Home on the tab bar opens it too. The tweaks read the switches when they run, so a change
// shows after Spotify restarts; the tab editor on the Navbar page applies as soon as the bar lays
// out again.
//
// Tree (trees/settings.txt): SettingsListViewController.view > SettingsListCollectionView of
//   Element_List cells 402x56: 24pt icon at x 12, 13pt white title and 11pt grey subtitle at
//   x 48, 12pt chevron on the right. A pushed page (trees/settings notifications opened.txt) is a
//   UITableView bg #121212: header with an 11pt grey description at (16, 24), 53pt cells with the
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Settings/SGModPage.h"
#import "Native/Home/Home.h"
#import "Shared/Privacy/Privacy.h"
#import "Shared/Flags/Flags.h"
#import "Shared/AudioEffects/AudioEffectsPage.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/LiveActivity/LiveActivity.h"
#import "Shared/Player/PlayerSettings.h"
#import "Shared/ListeningStats/ListeningStats.h"
#import "App/About/About.h"
#import "SettingsSearch.h"
#import "App/Donate/Donate.h"
#import "Pages.h"

static const CGFloat kRowHeight = 56;
static char kRowKey, kInsetKey;

static SGModRow *pageRow(NSString *title, NSString *symbol, UIViewController *(^page)(void)) {
    return SGWithSymbol(SGPageRow(title, page), symbol);
}

static UIViewController *modSettingsPage(void) {
    // Opening the page is the only thing that asks; the cache keeps it to once every six hours.
    SGCheckForUpdate(NO);
    NSMutableArray<SGModSection *> *sections = [NSMutableArray array];
    // A build the lock screen cannot open leads the page, above the tweaks: it is the one thing here
    // that no switch can put right, and it is worth reading before anything else.
    SGModRow *signing = SGSigningWarningRow();
    if (signing) [sections addObject:SGSection(nil, @[signing])];
    // No credits on this page (personal fork): upstream led with its donate row and
    // Discord; the page is the user's settings, not a billboard.
    SGModRow *mod = pageRow(@"Mod", @"info.circle", ^UIViewController *{ return SGAboutPage(); });
    mod.value = ^NSString *{ return @(SG_VERSION); };
    // The audio effects work on the sound, so both looks have them, with what they are doing beside the chevron.
    SGModRow *audioEffects = pageRow(@"Audio effects", @"slider.vertical.3", ^UIViewController *{ return SGDSPSettingsPage(); });
    audioEffects.value = ^NSString *{ return SGDSPSummary(); };
    // Home & Library holds only the native look's switches, so the redesign has no such page; the
    // Live Activity works under both, and only where ActivityKit's card does.
    // Batch 9: one tap from here to everything. Lyrics, Gestures and the Lock
    // screen used to sit inside Player (the lock screen's artwork two pages
    // down); they are first-class pages now, and the Live Activity lives on
    // the Lock screen page with the rest of what the lock screen shows.
    NSMutableArray<SGModRow *> *parts = [NSMutableArray arrayWithArray:@[
        pageRow(@"Navbar", @"dock.rectangle", ^UIViewController *{ return SGNavbarPage(); }),
        pageRow(@"Player", @"play.circle", ^UIViewController *{ return SGPlayerSettingsPage(); }),
        pageRow(@"Lyrics", @"quote.bubble", ^UIViewController *{ return SGLyricsSettingsPage(); }),
        pageRow(@"Gestures", @"hand.tap", ^UIViewController *{ return SGGesturesSettingsPage(); }),
        pageRow(@"Lock screen", @"lock", ^UIViewController *{ return SGLockScreenSettingsPage(); }),
        audioEffects,
    ]];
    if (!SGRedesignedUIStored()) [parts addObject:pageRow(@"Home & Library", @"house", ^UIViewController *{ return SGHomeSettingsPage(); })];
    NSArray<SGModRow *> *privacy = @[
        pageRow(@"Privacy & clutter", @"hand.raised", ^UIViewController *{ return SGPrivacySettingsPage(); }),
        pageRow(@"Labs", @"testtube.2", ^UIViewController *{ return SGLabsPage(); }),
    ];
    NSArray<SGModRow *> *system = @[
        pageRow(@"All flags", @"flag", ^UIViewController *{ return SGAllFlagsPage(); }),
        mod,
    ];
    // Batch 22: the root registers every page it offers, then leads with the
    // ways back to a setting — search, the pages the user pinned, and the
    // ones they touched last — before the full list.
    NSMutableArray<SGModRow *> *registry = [NSMutableArray arrayWithArray:parts];
    [registry addObjectsFromArray:privacy];
    [registry addObjectsFromArray:system];
    SGSettingsSearchSetRegistry(registry, ^UIViewController *{ return modSettingsPage(); });
    [sections addObject:SGSection(nil, @[
        pageRow(@"Search settings", @"magnifyingglass", ^UIViewController *{ return SGSettingsSearchPage(); }),
        pageRow(@"Customise quick access", @"pin", ^UIViewController *{ return SGQuickAccessPage(); }),
    ])];
    NSMutableArray<SGModRow *> *quick = [NSMutableArray array];
    for (NSString *title in SGQuickAccessTitles()) {
        for (SGModRow *row in registry) {
            if ([row.title isEqualToString:title]) { [quick addObject:pageRow(title, row.symbol, row.page)]; break; }
        }
    }
    if (quick.count) [sections addObject:SGSection(@"Quick access", quick)];
    NSMutableArray<SGModRow *> *recent = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *entry in SGRecentSettings()) {
        NSString *page = entry[@"page"], *rowTitle = entry[@"row"];
        UIViewController *(^build)(void) = nil;
        if ([page isEqualToString:@"Mod Settings"]) build = ^UIViewController *{ return modSettingsPage(); };
        else for (SGModRow *row in registry) if ([row.title isEqualToString:page]) { build = row.page; break; }
        if (!build) continue;
        SGModRow *r = SGPageRow(rowTitle ?: page, ^UIViewController *{
            if (rowTitle) SGModPageFocus(page, rowTitle);
            return build();
        });
        r.subtitle = rowTitle ? [@"in " stringByAppendingString:page] : @"Page";
        [recent addObject:SGWithSymbol(r, @"clock.arrow.circlepath")];
    }
    if (recent.count) [sections addObject:SGSection(@"Recent", recent)];
    [sections addObjectsFromArray:@[
        SGAppearanceSection(),
        SGSection(nil, parts),
        SGSection(nil, privacy),
        SGSection(nil, system),
    ]];
    return [[SGModPage alloc] initWithTitle:@"Mod Settings" intro:nil sections:sections footer:nil];
}

#pragma mark - row in the settings list and the side drawer

// The last row of Spotify's settings list, chevron and all, or the first of the side drawer's,
// drawn like the drawer's own rows: no chevron, icon and title 4pt further in.
@interface SGModSettingsRow : UIControl
@property (nonatomic) BOOL drawer;
// What the row opens, where it is not Mod Settings itself (personal fork): the side
// drawer also carries a Listening stats row, the page being three taps deep otherwise.
@property (nonatomic, copy) NSString *pageTitle;
@property (nonatomic, copy) UIViewController *(^pageBlock)(void);
- (void)applyTitle:(NSString *)title symbol:(NSString *)symbol page:(UIViewController *(^)(void))page;
@end

@implementation SGModSettingsRow {
    UIImageView *_icon;
    UILabel *_title;
    UIImageView *_chevron;
}

- (void)applyTitle:(NSString *)title symbol:(NSString *)symbol page:(UIViewController *(^)(void))page {
    self.pageTitle = title;
    self.pageBlock = page;
    _title.text = title;
    [_icon removeFromSuperview];
    _icon = SGSymbolView(symbol, 20, UIImageSymbolWeightRegular, 24);
    [self insertSubview:_icon atIndex:0];
    [self setNeedsLayout];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _icon = SGSymbolView(@"slider.horizontal.3", 20, UIImageSymbolWeightRegular, 24);
    _title = [UILabel new];
    _title.text = @"Mod Settings";
    _title.textColor = UIColor.whiteColor;
    _chevron = SGSymbolView(@"chevron.right", 11, UIImageSymbolWeightSemibold, 12);
    for (UIView *v in @[_icon, _title, _chevron]) [self addSubview:v];
    [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _title.font = SGTitleFont();
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height, lead = self.drawer ? 4 : 0;
    _icon.frame = CGRectMake(12 + lead, (height - 24) / 2, 24, 24);
    _title.frame = CGRectMake(48 + lead, 0, width - 96, height);
    _chevron.frame = CGRectMake(width - 24, (height - 12) / 2, 12, 12);
    _chevron.hidden = self.drawer;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.5 : 1;
}

static UINavigationController *navigationIn(UIViewController *page) {
    if ([page isKindOfClass:UINavigationController.class]) return (UINavigationController *)page;
    for (UIViewController *child in page.childViewControllers) {
        UINavigationController *found = navigationIn(child);
        if (found) return found;
    }
    return nil;
}

// The drawer is presented over the app, so its row closes it first and pushes onto the stack it
// was covering, the way the drawer's own rows open their pages.
- (void)open {
    UIViewController *owner = nil;
    for (UIResponder *r = self; r && !owner; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
    }
    UIViewController *page = self.pageBlock ? self.pageBlock() : modSettingsPage();
    UIViewController *presenting = self.drawer ? owner.presentingViewController : nil;
    if (!presenting) {
        SGShowPage(owner, page);
        return;
    }
    [presenting dismissViewControllerAnimated:YES completion:^{
        SGShowPage(navigationIn(presenting).topViewController ?: presenting, page);
    }];
}

@end

// The tab bar's controller holds no stack itself; the selected tab's sits among its parent's children.
void SGOpenModSettings(UIView *source) {
    UIViewController *owner = nil;
    for (UIResponder *r = source; r && !owner; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
    }
    UINavigationController *nav = nil;
    for (UIViewController *page = owner; page && !nav; page = page.parentViewController) nav = navigationIn(page);
    SGShowPage(nav.topViewController ?: SGTopController(), modSettingsPage());
}

// At the end of the settings list, or above the first row of the drawer's, with the inset for them
// added again whenever Spotify resets the inset. The drawer carries two rows (personal fork):
// Mod Settings, then Listening stats and the Lock screen page under it.
static void placeRow(UICollectionView *list, NSArray<SGModSettingsRow *> *rows) {
    CGFloat bottom = list.contentSize.height;
    [rows enumerateObjectsUsingBlock:^(SGModSettingsRow *row, NSUInteger i, BOOL *stop) {
        SGAdoptFonts(list, row);
        row.hidden = !row.drawer && bottom <= 0;
        CGFloat y = row.drawer ? -(CGFloat)(rows.count - i) * kRowHeight : bottom + (CGFloat)i * kRowHeight;
        row.frame = CGRectMake(0, y, list.bounds.size.width, kRowHeight);
    }];

    UIEdgeInsets inset = list.contentInset;
    NSValue *applied = objc_getAssociatedObject(list, &kInsetKey);
    if (applied && UIEdgeInsetsEqualToEdgeInsets(inset, applied.UIEdgeInsetsValue)) return;
    if (rows.firstObject.drawer) inset.top += kRowHeight * rows.count;
    else inset.bottom += kRowHeight * rows.count;
    objc_setAssociatedObject(list, &kInsetKey, [NSValue valueWithUIEdgeInsets:inset], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    list.contentInset = inset;
}

static SGModSettingsRow *statsRow(void) {
    SGModSettingsRow *row = [[SGModSettingsRow alloc] initWithFrame:CGRectZero];
    row.drawer = YES;
    [row applyTitle:@"Listening stats" symbol:@"chart.bar.fill" page:^UIViewController *{ return SGListeningStatsPage(); }];
    return row;
}

// The Lock screen page joins the drawer too (Batch 19): it is the page this
// fork's work keeps landing on — artwork style, clips, Live Activity — and
// it was three taps deep from here before it was promoted.
static SGModSettingsRow *lockScreenRow(void) {
    SGModSettingsRow *row = [[SGModSettingsRow alloc] initWithFrame:CGRectZero];
    row.drawer = YES;
    [row applyTitle:@"Lock screen" symbol:@"lock.fill" page:^UIViewController *{ return SGLockScreenSettingsPage(); }];
    return row;
}

// Media quality, Playback, Account and most of the rest of settings are the same controller class
// as the list they were opened from, which is why the row turned up at the end of all of them.
// What is on the navigation stack is not that controller though: every page in the app is wrapped
// in a MusicAppPageHostingViewController (trees/settings notifications opened.txt), and Spotify
// pushes a settings sub page as a page of its own, leaving the list it came from on the stack
// underneath. So the settings list inside the lowest wrapper that holds one is the list the row
// belongs at the end of, and a controller with no stack to be found on keeps the row rather than
// losing it.
static UIViewController *settingsListIn(UIViewController *page, Class kind) {
    if ([page isKindOfClass:kind]) return page;
    for (UIViewController *child in page.childViewControllers) {
        UIViewController *found = settingsListIn(child, kind);
        if (found) return found;
    }
    return nil;
}

static BOOL isSettingsRoot(UIViewController *list) {
    for (UIViewController *page in list.navigationController.viewControllers) {
        UIViewController *found = settingsListIn(page, list.class);
        if (found) return found == list;
    }
    return YES;
}

%hook _TtC21Settings_PlatformImpl26SettingsListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    BOOL root = isSettingsRoot((UIViewController *)self);
    for (UIView *sub in ((UIViewController *)self).view.subviews) {
        if (![sub isKindOfClass:UICollectionView.class]) continue;
        NSArray<SGModSettingsRow *> *rows = objc_getAssociatedObject(sub, &kRowKey);
        // A page that laid itself out before it was on the stack looked like the list for as long
        // as that took; the row goes again as soon as it can be seen for what it is.
        if (!root) {
            for (SGModSettingsRow *row in rows) [row removeFromSuperview];
            objc_setAssociatedObject(sub, &kRowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }
        if (rows) continue;
        SGModSettingsRow *row = [[SGModSettingsRow alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(sub, &kRowKey, @[row], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sub addSubview:row];
    }
}
%end

// The drawer's list (trees/test6.txt: SideDrawerListCollectionView under the profile header, Your
// plan its first cell) is one of several collection views on the page, so it is found by name.
%hook _TtC23SideDrawer_ListPageImpl18ListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    SGForEachView(((UIViewController *)self).view, ^(UIView *v) {
        if (![v isKindOfClass:UICollectionView.class] || ![NSStringFromClass(v.class) containsString:@"SideDrawerListCollectionView"]) return;
        if (objc_getAssociatedObject(v, &kRowKey)) return;
        SGModSettingsRow *row = [[SGModSettingsRow alloc] initWithFrame:CGRectZero];
        row.drawer = YES;
        SGModSettingsRow *stats = statsRow();
        SGModSettingsRow *lock = lockScreenRow();
        objc_setAssociatedObject(v, &kRowKey, @[row, stats, lock], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [v addSubview:row];
        [v addSubview:stats];
        [v addSubview:lock];
    });
}
%end

// The lists lay out after their controllers and again whenever their content changes.
%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    NSArray<SGModSettingsRow *> *rows = objc_getAssociatedObject(self, &kRowKey);
    if (rows) placeRow(self, rows);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC21Settings_PlatformImpl26SettingsListViewController", @"_TtC23SideDrawer_ListPageImpl18ListViewController"]);
    SGRegisterPages();
    SGCheckSigningOnce();
    SGWatchForUpdates();
    SGWatchForDonate();
}
