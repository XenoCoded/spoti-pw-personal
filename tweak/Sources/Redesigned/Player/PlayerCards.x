// Player redesign: nothing is kept under the player. Every card (about the artist, videos, SongDNA,
// events, explore, credits, merch, the lyrics card, anything Spotify adds later) reports no height, so
// the list closes up around it and the player is one screen; PlayerScroll.x closes off the gaps the
// list leaves between them, and the lyrics come to the player itself (PlayerLyrics.x) instead of
// waiting on a card below it.
//
// A block on everything rather than a list of what to drop: the server decides which cards a track
// gets, and a new kind should not turn up under a redesigned player. The collapse is the one
// Native/Player/PlayerDeclutter.x has shipped.
//
// Tree (trees/clean/player/01.txt:385, lyrics/01.txt:996-999): every card is an Element_List.CollectionViewCell
// whose first subview is an ElementContentView naming NowPlaying_ScrollAPI, then an ElementView, then
// the card's own root: CreatorBiographyCardLayout, song-dna-npv-card, Lyrics_CardElementImpl.CardView
// id=lyrics-card-view and so on (all ten player snapshots). The cells of lists inside a card
// (WatchFeed's) name WatchFeed_ComponentAPI instead, so they are left to their card.
//
// The name test alone broke once already (Batch 99): the cards are server-built, and a server-side
// reshuffle — an extra wrapper around the content, new card kinds like podcast recommendations —
// left the top class no longer naming the ScrollAPI while the cards rendered at full height under
// the player. The collapse now also fires by position: a cell whose nearest collection view is the
// now-playing list (scrolling_npv_collection_view) is a card by construction.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"

// Whether the cell's content is the player's card list, remembered per content class.
static BOOL isPlayerCard(UIView *content) {
    static NSMutableSet<Class> *yes, *no;
    if (!yes) {
        yes = [NSMutableSet set];
        no = [NSMutableSet set];
    }
    Class cls = object_getClass(content);
    if (!cls || [no containsObject:cls]) return NO;
    if ([yes containsObject:cls]) return YES;
    BOOL player = [NSStringFromClass(cls) containsString:@"NowPlaying_ScrollAPI"];
    [(player ? yes : no) addObject:cls];
    return player;
}

// The same test down the first-subview chain: the server can wrap a
// card's content in an extra container without asking the binary, and
// then the class at the top no longer names the ScrollAPI (Batch 99 —
// credits, podcast and lyrics cards came back under the player).
static BOOL chainNamesPlayerCard(UIView *cell) {
    UIView *view = cell.subviews.firstObject;
    for (NSInteger depth = 0; view && depth < 4; depth++) {
        if (isPlayerCard(view)) return YES;
        view = view.subviews.firstObject;
    }
    return NO;
}

// Position instead of names: the now-playing list holds only cards
// (the player itself is fixed chrome around it), so any cell whose
// nearest list is that list is a card whatever the server calls it.
// A card's own inner list (WatchFeed's) is the nearest list for its
// cells, so those are still left to their card.
static BOOL inNowPlayingList(UIView *cell) {
    for (UIView *view = cell.superview; view; view = view.superview) {
        if ([view isKindOfClass:UICollectionView.class]) {
            NSString *identifier = ((UICollectionView *)view).accessibilityIdentifier;
            return [identifier containsString:@"scrolling_npv_collection_view"];
        }
    }
    return NO;
}

%hook _TtC12Element_List18CollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    UIView *cell = (UIView *)self;
    UIView *content = cell.subviews.firstObject;
    if (!content) return result;
    BOOL byName = chainNamesPlayerCard(cell);
    if (!byName && !inNowPlayingList(cell)) return result;
    result.size = CGSizeMake(result.size.width, 0);
    cell.clipsToBounds = YES;

    static NSMutableSet<NSString *> *logged;
    if (!logged) logged = [NSMutableSet set];
    UIView *root = content.subviews.firstObject.subviews.firstObject;
    NSString *name = root ? NSStringFromClass(root.class) : @"nothing yet";
    if (![logged containsObject:name]) {
        [logged addObject:name];
        SGLog(@"redesign player: collapsed card root %@ (%lu kinds so far, %@)", name,
              (unsigned long)logged.count, byName ? @"by name" : @"by list");
    }
    return result;
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC12Element_List18CollectionViewCell"]);
}
