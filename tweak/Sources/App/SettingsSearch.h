// Settings search, quick access and recents (Batch 22): the Mod Settings
// root registers its page rows here; the search page indexes every row of
// every page those rows open (two levels deep), and a tap on a result
// pushes the page and asks it to flash the row itself.
#import <UIKit/UIKit.h>

@class SGModRow;

// The search page: a live-filtered list of every setting there is.
UIViewController *SGSettingsSearchPage(void);
// The checklist that chooses which pages sit at the top of Mod Settings.
UIViewController *SGQuickAccessPage(void);

// Called by the Mod Settings root as it builds: every page row it shows,
// in order, and how to build a fresh root.
void SGSettingsSearchSetRegistry(NSArray<SGModRow *> *pageRows, UIViewController *(^rootPage)(void));
// The registered page rows, for the root's quick access and recent rows.
NSArray<SGModRow *> *SGSettingsSearchRegistry(void);
UIViewController *(^SGSettingsRootBuilder(void))(void);
// The page titles the user pinned, still on offer.
NSArray<NSString *> *SGQuickAccessTitles(void);
