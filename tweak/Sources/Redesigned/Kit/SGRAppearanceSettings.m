#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "SGRAccent.h"

// Going back to Spotify's green is offered only once a colour of the mod's is set, so a stray tap
// cannot wipe it.
static void chooseAccent(void) {
    if (!SGRAccentColor()) {
        SGRPickAccent();
        return;
    }
    UIViewController *top = SGTopController();
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Accent colour" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Pick a colour" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGRPickAccent(); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Spotify's green" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { SGSetInt(SGRKeyAccent, -1); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = top.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 0, 0);
    sheet.popoverPresentationController.permittedArrowDirections = 0;
    [top presentViewController:sheet animated:YES completion:nil];
}

// Theme presets (personal fork, Batch 73): the famous palettes as one
// tap. Each is only an accent colour — the redesign's blacks stay —
// and picking one turns Match cover art off, or the next track's
// cover would take the accent straight back. The native look keeps
// its own copy of this list under its own keys, as with everything
// else here.
static void choosePreset(void) {
    UIViewController *top = SGTopController();
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Theme presets" message:@"Famous palettes, as the accent colour." preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *presets = @[
        @[@"Catppuccin", @0xCBA6F7],
        @[@"Dracula", @0xFF79C6],
        @[@"Nord", @0x88C0D0],
        @[@"Gruvbox", @0xFE8019],
        @[@"Rosé Pine", @0xC4A7E7],
        @[@"Tokyo Night", @0x7AA2F7],
    ];
    for (NSArray *preset in presets) {
        NSInteger rgb = [preset[1] integerValue];
        [sheet addAction:[UIAlertAction actionWithTitle:preset[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            SGSetInt(SGRKeyAccent, rgb);
            SGSetInt(SGRKeyAccentMatchArtwork, 0);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = top.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 0, 0);
    sheet.popoverPresentationController.permittedArrowDirections = 0;
    [top presentViewController:sheet animated:YES completion:nil];
}

// The redesign's rows of the Appearance card (App/Pages.m). AMOLED has no row: the redesign is always black.
NSArray<SGModRow *> *SGRAppearanceRows(void) {
    return @[
        SGWithSymbol(SGStatActionRow(@"Accent colour", nil, ^NSString *{ return SGRAccentLabel(); }, ^{ chooseAccent(); }), @"paintpalette"),
        SGWithSymbol(SGActionRow(@"Theme presets", @"Catppuccin, Dracula, Nord and friends — as the accent.", ^{ choosePreset(); }), @"swatchpalette"),
        SGWithSymbol(SGOptionRow(@"Match cover art", @"The accent follows the playing song's cover, everywhere the accent would be.", SGRKeyAccentMatchArtwork), @"photo.on.rectangle.angled"),
    ];
}
