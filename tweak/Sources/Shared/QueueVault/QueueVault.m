// The queue vault's store (Batch 86): one defaults array, newest first,
// capped at twenty — the twenty-first snapshot pushes the oldest out.
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Lyrics/Lyrics.h"
#import "QueueVault.h"
#import <objc/runtime.h>

static const NSInteger kVaultCap = 20;

static NSMutableArray *vault(void) {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:SGKeyQueueVault];
    NSMutableArray *list = [NSMutableArray array];
    for (id item in stored) {
        if ([item isKindOfClass:NSDictionary.class]
            && [item[@"tracks"] isKindOfClass:NSArray.class]
            && [item[@"t"] isKindOfClass:NSNumber.class]) [list addObject:item];
    }
    return list;
}

static void saveVault(NSArray *list) {
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:SGKeyQueueVault];
}

NSArray<NSDictionary *> *SGQueueSnapshots(void) {
    return vault();
}

void SGQueueSnapshotNow(void) {
    SPTPlayerState *state = SGPlayerState();
    if (!state.track.trackTitle.length) return;
    NSMutableArray *tracks = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^add)(NSString *, NSString *, NSString *) = ^(NSString *title, NSString *artist, NSString *uri) {
        if (!title.length || !uri.length || [seen containsObject:uri]) return;
        [seen addObject:uri];
        [tracks addObject:@{@"title": title, @"artist": artist ?: @"", @"uri": uri}];
    };
    add(state.track.trackTitle, state.track.artistName, SGURIString(state.track.URI));
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    if ([future isKindOfClass:NSArray.class]) {
        Class trackClass = objc_getClass("SPTPlayerTrack");
        for (id candidate in (NSArray *)future) {
            if (![candidate isKindOfClass:trackClass]) continue;
            SPTPlayerTrack *track = candidate;
            add(track.trackTitle, track.artistName, SGURIString(track.URI));
            if (tracks.count >= 50) break;
        }
    }
    if (!tracks.count) return;
    NSDateFormatter *name = [NSDateFormatter new];
    name.dateFormat = @"MMM d, h:mm a";
    NSDictionary *snapshot = @{
        @"name": [name stringFromDate:NSDate.date],
        @"t": @(NSDate.date.timeIntervalSince1970),
        @"context": SGURIString(state.contextURI) ?: @"",
        @"tracks": tracks,
    };
    NSMutableArray *list = vault();
    [list insertObject:snapshot atIndex:0];
    while (list.count > kVaultCap) [list removeLastObject];
    saveVault(list);
    SGLog(@"queue vault: snapshotted %lu tracks", (unsigned long)tracks.count);
}

void SGQueueSnapshotForget(NSDictionary *snapshot) {
    NSNumber *t = snapshot[@"t"];
    NSMutableArray *list = vault();
    NSPredicate *keep = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, NSDictionary *b) {
        return ![item[@"t"] isEqual:t];
    }];
    [list filterUsingPredicate:keep];
    saveVault(list);
}

void SGQueueVaultClear(void) {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:SGKeyQueueVault];
}

NSString *SGQueueSnapshotText(NSDictionary *snapshot) {
    NSArray *tracks = snapshot[@"tracks"];
    if (![tracks isKindOfClass:NSArray.class] || !tracks.count) return nil;
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"Queue snapshot — %@", snapshot[@"name"] ?: @""]];
    NSString *context = snapshot[@"context"];
    if ([context isKindOfClass:NSString.class] && context.length)
        [lines addObject:[@"From: " stringByAppendingString:context]];
    [lines addObject:@""];
    NSString *firstID = nil;
    for (NSUInteger i = 0; i < tracks.count; i++) {
        NSDictionary *track = tracks[i];
        if (![track isKindOfClass:NSDictionary.class]) continue;
        NSString *title = track[@"title"];
        if (![title isKindOfClass:NSString.class] || !title.length) continue;
        NSString *artist = track[@"artist"];
        NSString *credit = [artist isKindOfClass:NSString.class] && artist.length
            ? [@" — " stringByAppendingString:artist] : @"";
        [lines addObject:[NSString stringWithFormat:@"%@%@%@",
            i == 0 ? @"▶ " : @"· ", title, credit]];
        if (!firstID) {
            NSString *uri = track[@"uri"];
            if ([uri isKindOfClass:NSString.class] && [uri hasPrefix:@"spotify:track:"])
                firstID = [uri substringFromIndex:@"spotify:track:".length];
        }
    }
    // The way back in: whoever gets the list usually wants the first
    // song first, and this link is where rebuilding starts.
    if (firstID.length) {
        [lines addObject:@""];
        [lines addObject:[@"https://open.spotify.com/track/" stringByAppendingString:firstID]];
    }
    return [lines componentsJoinedByString:@"\n"];
}
