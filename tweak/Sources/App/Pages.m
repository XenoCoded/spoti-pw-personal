#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Pages.h"
#import "AppTint.h"
#import "Shared/ArtistBlock/ArtistBlock.h"
#import "Shared/TrackBin/TrackBin.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Lyrics/TVLyrics.h"
#import "Shared/LyricsMeanings/Meanings.h"
#import "Shared/Player/PlayerSettings.h"
#import "Shared/Player/SleepTimer.h"
#import "Shared/Player/HeadGestures.h"
#import "Shared/Player/ABRepeat.h"
#import "Shared/Player/Bookmark.h"
#import "Shared/Player/ScanMode.h"
#import "Shared/Player/Ratings.h"
#import "Native/Appearance/Appearance.h"
#import "Native/Navbar/Navbar.h"
#import "Native/NowPlayingBar/NowPlayingBar.h"
#import "Native/Player/NowPlaying.h"
#import "Shared/Haptics/Haptics.h"
#import "Shared/LiveActivity/LiveActivity.h"
#import "Shared/ListeningStats/ListeningStats.h"
#import "Shared/Fonts/Fonts.h"
#import "Redesigned/Lyrics/LyricsText.h"
#import "Redesigned/Navbar/Navbar.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Redesigned/Kit/SGRAccent.h"
#import "Redesigned/Player/PlayerVinyl.h"

NSString *const SGRedesignedUIInfo = @"The newest version of spoti.pw, leaning towards Apple Music's style. It is not compatible with the legacy look's settings.\n\nThe legacy look gives you more freedom, yet still looks like Spotify.";

void SGSetRedesignedUI(BOOL on) {
    SGSetEnabled(SGKeyRedesign, on);
}

// The whole look changes hands at launch, so the switch asks for the restart straight away rather than
// leaving Spotify half in the old look.
static void offerRestart(BOOL on) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart Spotify"
        message:on ? @"The redesign takes over when Spotify starts again. Spotify closes now; open it again to see it." : @"Spotify's own look comes back when Spotify starts again. Spotify closes now; open it again to see it."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart now" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGRestartSpotify(); }]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// Below iOS 26 the row is not a switch: Liquid Glass is the redesign, and the system draws it from
// that version on, so the row reads out what is missing and the card carries the native look's rows alone.
static SGModRow *unavailableRow(void) {
    SGModRow *row = SGStatActionRow(@"Redesigned UI", nil, ^NSString *{ return @"Needs iOS 26"; }, ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Redesigned UI"
            message:[NSString stringWithFormat:@"The redesign is built on Liquid Glass, which iOS 26 draws and no earlier version can. This phone runs iOS %@, so the mod gives you its legacy look instead: Spotify's own screens with everything else the mod adds on them.", UIDevice.currentDevice.systemVersion]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
    });
    return SGWithSymbol(row, @"sparkles");
}

// A font of the user's own in place of Spotify's, either look (Shared/Fonts).
static SGModRow *appFontRow(void) {
    SGModRow *row = SGPageRow(@"App font", ^{ return SGAppFontSettingsPage(); });
    row.value = ^NSString *{ return SGAppFontSummary(); };
    return SGWithSymbol(row, @"textformat");
}

SGModSection *SGAppearanceSection(void) {
    if (!SGRedesignAvailable()) {
        NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObject:unavailableRow()];
        [rows addObjectsFromArray:SGNativeAppearanceRows()];
        [rows addObject:appFontRow()];
        [rows addObject:SGAppTintRow()];
        return SGNotedSection(@"Appearance", rows, @"Changes apply after you restart Spotify.");
    }
    SGModRow *redesign = SGOptionRow(@"Redesigned UI", nil, SGKeyRedesign);
    redesign.glows = YES;
    redesign.info = SGRedesignedUIInfo;
    redesign.changed = ^(BOOL on) {
        SGSetRedesignedUI(on);
        offerRestart(on);
    };
    NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObject:SGWithSymbol(redesign, @"sparkles")];
    [rows addObjectsFromArray:SGRedesignedUIStored() ? SGRAppearanceRows() : SGNativeAppearanceRows()];
    [rows addObject:appFontRow()];
    [rows addObject:SGAppTintRow()];
    return SGNotedSection(@"Appearance", rows, @"Changes apply after you restart Spotify.");
}

UIViewController *SGNavbarPage(void) {
    return SGRedesignedUIStored() ? SGRNavbarSettingsPage() : SGNavbarSettingsPage();
}

// Pronunciation, translation, word sweeping and line meanings exist only in the redesign's lyrics view.
static UIViewController *lyricsPage(void) {
    BOOL redesigned = SGRedesignedUIStored();
    NSMutableArray<SGModRow *> *more = [NSMutableArray arrayWithObject:SGLockScreenLyricsRow()];
    if (!redesigned) [more insertObject:SGGlassLyricsRow() atIndex:0];
    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObject:SGLyricsSourcesSection(redesigned)];
    if (redesigned) {
        [sections addObject:SGSection(@"Display", @[SGLyricsWordTimingRow(), SGRLyricsWordStyleRow(), SGRLyricsWordIntensityRow(), SGRLyricsTextSizesRow(), SGLyricsTranslationLanguageRow(), SGLyricsMeaningsRow(), SGRLandscapeLyricsRow(), SGRLandscapePaneRow(), SGRLandscapeSwapRow(), SGRLandscapeShareRow()])];
    }
    [sections addObject:SGSection(nil, more)];
    [sections addObject:SGSection(@"Big screen", @[SGTVLyricsRow()])];
    return [[SGModPage alloc] initWithTitle:@"Lyrics" intro:SGMixedNote sections:sections footer:nil];
}

// The Lyrics page, linked from the Mod Settings root since Batch 9 (it sat
// inside Player before, a page deeper than it deserved).
UIViewController *SGLyricsSettingsPage(void) {
    return lyricsPage();
}

UIViewController *SGPlayerSettingsPage(void) {
    SGModRow *blocked = SGPageRow(@"Blocked artists", ^UIViewController *{ return SGArtistBlockSettingsPage(); });
    blocked.value = ^NSString *{
        return SGFlag(SGKeyArtistBlock, NO) ? @(SGBlockedArtists().count).stringValue : @"Off";
    };
    SGModRow *bin = SGPageRow(@"Trash bin", ^UIViewController *{ return SGTrackBinSettingsPage(); });
    bin.value = ^NSString *{
        return SGFlag(SGKeyTrackBin, NO) ? @(SGBinnedTracks().count).stringValue : @"Off";
    };
    SGModRow *stats = SGPageRow(@"Listening stats", ^UIViewController *{ return SGListeningStatsPage(); });
    stats.value = ^NSString *{ return SGListeningStatsSummary(); };
    BOOL native = !SGRedesignedUIStored();

    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObject:SGSection(nil, @[
        SGWithSymbol(blocked, @"person.crop.circle.badge.xmark"),
        SGWithSymbol(bin, @"trash"),
        SGWithSymbol(stats, @"chart.bar"),
    ])];
    NSMutableArray<SGModRow *> *pages = [NSMutableArray array];
    if (native) {
        [pages addObject:SGWithSymbol(SGPageRow(@"Now playing bar", ^UIViewController *{ return SGNowPlayingBarSettingsPage(); }), @"rectangle.bottomthird.inset.filled")];
        [pages addObject:SGWithSymbol(SGPageRow(@"Queue & devices", ^UIViewController *{ return SGQueueSettingsPage(); }), @"text.line.first.and.arrowtriangle.forward")];
    } else {
        [pages addObject:SGWithSymbol(SGPageRow(@"Now playing", ^UIViewController *{ return SGRNowPlayingBarSettingsPage(); }), @"rectangle.bottomthird.inset.filled")];
    }
    [sections addObject:SGSection(nil, pages)];
    if (native) [sections addObjectsFromArray:SGNativePlayerScreenSections()];
    // Vibrations hook Spotify's own controls and its audio, so they answer under either look.
    [sections addObjectsFromArray:SGVibrationsSections()];
    [sections addObject:SGSection(@"Sleep", SGSleepTimerRows())];
    [sections addObject:SGSection(@"Scan mode", SGScanModeRows())];
    if (!native) [sections addObject:SGSection(@"Vinyl", SGRVinylRows())];
    [sections addObject:SGSection(@"Head gestures", SGHeadGestureRows())];
    [sections addObject:SGSection(@"Repeat", SGABRepeatRows())];
    [sections addObject:SGSection(@"Rating", SGRatingsRows())];
    [sections addObject:SGSection(@"Bookmarks", SGBookmarkRows())];
    [sections addObject:SGSection(@"Queue", SGQueueShareRows())];

    return [[SGModPage alloc] initWithTitle:@"Player" intro:SGMixedNote sections:sections footer:nil];
}
