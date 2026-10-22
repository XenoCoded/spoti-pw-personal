// The queue vault's page (Batch 86): snapshot the queue now, and the
// saved snapshots — each opens an action sheet to copy the manifest,
// play its first track, or forget it.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Navigation/Links.h"
#import "QueueVault.h"

static void snapshotSheet(NSDictionary *snapshot) {
    UIViewController *top = SGTopController();
    NSArray *tracks = snapshot[@"tracks"];
    NSString *title = [NSString stringWithFormat:@"%@ · %lu tracks",
        snapshot[@"name"] ?: @"Snapshot", (unsigned long)tracks.count];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
        message:@"A manifest of the queue as it was — Spotify can't take a queue back, so this is the way to keep one."
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy the list" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            NSString *text = SGQueueSnapshotText(snapshot);
            if (text.length) UIPasteboard.generalPasteboard.string = text;
        }]];
    NSString *firstURI = nil;
    for (NSDictionary *track in tracks) {
        if (![track isKindOfClass:NSDictionary.class]) continue;
        NSString *uri = track[@"uri"];
        if ([uri isKindOfClass:NSString.class] && uri.length) { firstURI = uri; break; }
    }
    if (firstURI.length) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Play the first track" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                SGOpenSpotifyURI([NSURL URLWithString:firstURI]);
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Forget this snapshot" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) { SGQueueSnapshotForget(snapshot); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = top.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 0, 0);
    sheet.popoverPresentationController.permittedArrowDirections = 0;
    [top presentViewController:sheet animated:YES completion:nil];
}

static void confirmClearVault(void) {
    UIViewController *top = SGTopController();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear the vault?"
        message:@"Every saved queue snapshot is deleted. Spotify's own queue is untouched."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) { SGQueueVaultClear(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

UIViewController *SGQueueVaultPage(void) {
    SGModRow *snap = SGActionRow(@"Snapshot the queue now",
        @"The playing track and what's up next, kept as a list.",
        ^{ SGQueueSnapshotNow(); });
    snap.visible = ^BOOL { return SGPlayerState().track != nil; };

    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    for (NSDictionary *snapshot in SGQueueSnapshots()) {
        NSArray *tracks = snapshot[@"tracks"];
        NSString *subtitle = [NSString stringWithFormat:@"%lu tracks", (unsigned long)tracks.count];
        [rows addObject:SGActionRow(snapshot[@"name"] ?: @"Snapshot", subtitle, ^{
            snapshotSheet(snapshot);
        })];
    }

    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObject:SGSection(nil, @[snap])];
    if (rows.count) [sections addObject:SGSection(@"Snapshots", rows)];
    SGModRow *clear = SGActionRow(@"Clear the vault", nil, ^{ confirmClearVault(); });
    clear.color = SGRed();
    [sections addObject:SGSection(nil, @[clear])];
    return [[SGModPage alloc] initWithTitle:@"Queue vault" intro:SGRestartNote sections:sections footer:nil];
}
