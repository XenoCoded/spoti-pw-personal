// Star ratings: the store, the Player page's row and its star picker, and
// the gesture's cycle. Everything reads the playing track at tap time
// from the shared player state, like the bookmarks beside it.
#import "Ratings.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"

static NSMutableDictionary<NSString *, NSNumber *> *ratings(void) {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyRatings];
    // Only numbers come back (Batch 90): every reader does arithmetic on
    // these values, and a store written by anything else — an import, an
    // older build — is not promised to hold numbers.
    NSMutableDictionary<NSString *, NSNumber *> *clean = [NSMutableDictionary dictionary];
    for (NSString *uri in stored)
        if ([stored[uri] isKindOfClass:NSNumber.class]) clean[uri] = stored[uri];
    return clean;
}

NSInteger SGRatingForURI(NSString *uri) {
    return uri.length ? [ratings()[uri] integerValue] : 0;
}

void SGSetRating(NSString *uri, NSInteger stars) {
    if (!uri.length) return;
    NSMutableDictionary *all = ratings();
    if (stars <= 0) [all removeObjectForKey:uri];
    else all[uri] = @(MIN(stars, 5));
    [NSUserDefaults.standardUserDefaults setObject:all forKey:SGKeyRatings];
    SGLog(@"ratings: %@ → %ld", uri, (long)stars);
}

NSDictionary<NSString *, NSNumber *> *SGAllRatings(void) {
    return ratings();
}

NSString *SGStarsString(NSInteger stars) {
    stars = MAX(0, MIN(stars, 5));
    NSMutableString *text = [NSMutableString string];
    for (NSInteger i = 0; i < 5; i++) [text appendString:i < stars ? @"★" : @"☆"];
    return text;
}

static NSString *playingURI(void) {
    SPTPlayerState *state = SGPlayerState();
    return state ? SGURIString(state.track.URI) : nil;
}

void SGRateUpCurrent(void) {
    NSString *uri = playingURI();
    if (!uri.length) return;
    SGSetRating(uri, (SGRatingForURI(uri) + 1) % 6);
}

// The picker: an action sheet of star rows, five down to one, with the
// clear below when there is something to clear. An action sheet rather
// than a custom control — it is Spotify's own idiom for a one-off choice,
// and it costs no new row type.
static void presentRatingSheet(void) {
    SPTPlayerState *state = SGPlayerState();
    NSString *uri = state ? SGURIString(state.track.URI) : nil;
    if (!uri.length) return;
    NSString *title = state.track.trackTitle.length ? state.track.trackTitle : @"This track";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
        message:@"Your rating, kept on this phone only." preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger stars = 5; stars >= 1; stars--) {
        [sheet addAction:[UIAlertAction actionWithTitle:SGStarsString(stars) style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) { SGSetRating(uri, stars); }]];
    }
    if (SGRatingForURI(uri) > 0) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Clear the rating" style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *action) { SGSetRating(uri, 0); }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:sheet animated:YES completion:nil];
}

NSArray<SGModRow *> *SGRatingsRows(void) {
    SGModRow *rate = SGStatActionRow(@"Rate this track", @"Your own stars, kept on this phone. Spotify's heart is untouched.",
        ^NSString *{
            NSInteger stars = SGRatingForURI(playingURI());
            return stars > 0 ? SGStarsString(stars) : @"—";
        }, ^{
            presentRatingSheet();
        });
    return @[rate];
}
