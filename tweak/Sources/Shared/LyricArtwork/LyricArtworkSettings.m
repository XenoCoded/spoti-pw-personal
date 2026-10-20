// The Lyric artwork rows, put on the Lock screen widget page by Shared/Player/PlayerSettings.m.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "LyricArtwork.h"

NSArray<SGModRow *> *SGLyricArtworkRows(void) {
    SGModRow *style = SGChoiceRow(@"Lyric artwork style", nil, SGKeyLyricArtworkStyle,
                                  @[@"Poster", @"Plain & bold", @"Aura", @"Record", @"Chat", @"Gradient",
                                    @"Twitter", @"Cover in letters", @"Magazine", @"Duotone", @"Word collage",
                                    @"Cyberpunk chat", @"Old TV", @"Matrix", @"Stickers", @"Receipt",
                                    @"Gig poster", @"Holo", @"RGB split", @"Window", @"Starburst", @"Print",
                                    @"Tiles", @"Polaroid", @"Subtitles", @"Line number"],
                                  SGLyricArtworkAura);
    style.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    SGModRow *animated = SGOptionRow(@"Animated artwork",
        @"On iOS 26, the styles that move — most styles — play as a looping clip instead of a still. Renders once per line, then kept on the phone.",
        SGKeyLyricArtworkAnimated);
    animated.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO); };
    SGModRow *quality = SGChoiceRow(@"Clip quality",
        @"Saver renders smaller and slower for the battery; Max matches the stills' full size. Changing it re-renders clips at the new quality.",
        SGKeyLyricArtworkClipQuality, @[@"Saver", @"Balanced", @"Max"], 1);
    quality.visible = ^BOOL { return SGFlag(SGKeyLyricArtwork, NO) && SGFlag(SGKeyLyricArtworkAnimated, NO); };
    return @[
        SGOptionRow(@"Lyric artwork", @"The line being sung as the lock screen's artwork, full screen when the cover is tapped open. Turns the animated lock screen off while it is on.", SGKeyLyricArtwork),
        style,
        animated,
        quality,
    ];
}
