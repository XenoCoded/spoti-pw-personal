// The App font page: the library's fonts to pick from, Spotify's own at the top, and
// the import. A pick is stored and applies at the next launch, the way the mod's
// switches do; the restart is offered on the spot.
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Fonts.h"

static void sayRestart(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart Spotify?"
        message:@"The font is read when Spotify starts, so the change shows after a restart."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart now" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) { SGRestartSpotify(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static void sayImported(NSString *name, NSString *problem) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:problem ? @"That font would not go in" : @"Font imported"
                         message:problem ?: [NSString stringWithFormat:@"%@ is in the library. Reopen this page to pick it.", name]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

@interface SGFontPicker : NSObject <UIDocumentPickerDelegate>
@end

@implementation SGFontPicker
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *name = url.lastPathComponent;
    NSString *to = [SGFontsDirectory() stringByAppendingPathComponent:name];
    // Staged, then swapped (Batch 93): the old import deleted the
    // existing font first and copied onto the final path, so a failed
    // copy lost the good font and could leave a partial in its place.
    NSString *staged = [to stringByAppendingString:@".importing"];
    [NSFileManager.defaultManager removeItemAtPath:staged error:nil];
    NSError *error = nil;
    BOOL copied = [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:staged] error:&error];
    if (copied) {
        [NSFileManager.defaultManager removeItemAtPath:to error:nil];
        copied = [NSFileManager.defaultManager moveItemAtPath:staged toPath:to error:&error];
    } else {
        [NSFileManager.defaultManager removeItemAtPath:staged error:nil];
    }
    if (scoped) [url stopAccessingSecurityScopedResource];
    sayImported(SGFontDisplayName(name), copied ? nil : (error.localizedDescription ?: @"The file could not be copied."));
}
@end

static void importFont(void) {
    static SGFontPicker *delegate;
    if (!delegate) delegate = [SGFontPicker new];
    NSArray<UTType *> *types = @[[UTType typeWithFilenameExtension:@"ttf"], [UTType typeWithFilenameExtension:@"otf"]];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = delegate;
    [SGTopController() presentViewController:picker animated:YES completion:nil];
}

UIViewController *SGAppFontSettingsPage(void) {
    NSString *chosen = SGChosenFontFile();
    NSMutableArray<SGModRow *> *picks = [NSMutableArray array];
    SGModRow *stock = SGActionRow(@"Spotify's own", nil, ^{ SGSetChosenFontFile(nil); sayRestart(); });
    stock.value = ^NSString *{ return chosen ? nil : @"In use"; };
    [picks addObject:stock];
    for (NSString *file in SGFontFiles()) {
        SGModRow *row = SGActionRow(SGFontDisplayName(file), nil, ^{ SGSetChosenFontFile(file); sayRestart(); });
        row.value = ^NSString *{ return [file isEqualToString:chosen] ? @"In use" : nil; };
        [picks addObject:row];
    }
    return [[SGModPage alloc] initWithTitle:@"App font" intro:SGRestartNote sections:@[
        SGSection(@"Use", picks),
        SGSection(@"Size", @[
            SGChoiceRow(@"Text size", @"Scales all text, with the font picked above or Spotify's own.", SGKeyFontScale,
                        @[@"90%", @"95%", @"100%", @"105%", @"110%", @"120%"], 2),
        ]),
        SGSection(nil, @[SGActionRow(@"Import a font…", @"A .ttf or .otf file, kept in Documents/spoti.pw/Fonts", ^{ importFont(); })]),
    ] footer:@"Text Spotify draws without UIFont — some of its Encore labels — keeps Spotify's own face. Everything else takes the font picked here."];
}
