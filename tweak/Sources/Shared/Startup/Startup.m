// Opens to: the choice row and where it points. The tab URIs are the ones the
// mod's own navbar editor already offers (Native/Navbar/NavbarSettings.m) —
// home, search and the library are Spotify's own doors, opened through the
// link dispatcher like any other spotify: URI in the mod.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Startup.h"

SGModRow *SGStartupRow(void) {
    return SGChoiceRow(@"Opens to",
        @"Where Spotify goes when it starts. Last place is the page you were last on, or what was playing when it was last open.",
        SGKeyStartup,
        @[@"Spotify decides", @"Last place", @"Home", @"Search", @"Your Library"],
        SGStartupSpotifyDecides);
}

NSString *SGStartupTargetURI(void) {
    switch (SGInt(SGKeyStartup, SGStartupSpotifyDecides)) {
        case SGStartupLastPlace: {
            NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyStartupLastURI];
            return last.length ? last : nil;
        }
        case SGStartupHome: return @"spotify:home";
        case SGStartupSearch: return @"spotify:search";
        case SGStartupLibrary: return @"spotify:collection";
        default: return nil;
    }
}
