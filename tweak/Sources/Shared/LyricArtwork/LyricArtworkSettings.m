// The Lyric artwork rows, put on the Lock screen widget page by Shared/Player/PlayerSettings.m.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "LyricArtwork.h"

NSArray<SGModRow *> *SGLyricArtworkRows(void) {
    SGModRow *style = SGChoiceRow(@"Lyric artwork style", nil, SGKeyLyricArtworkStyle,
                                  @[@"Poster", @"Plain & bold"], SGLyricArtworkPoster);
    style.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    return @[
        SGOptionRow(@"Lyric artwork", @"The line being sung as the lock screen's artwork, full screen when the cover is tapped open. Turns the animated lock screen off while it is on.", SGKeyLyricArtwork),
        style,
    ];
}
