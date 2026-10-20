// Lyric artwork (personal fork): the line being sung, drawn as the now playing artwork,
// so the lock screen's player shows the lyrics small and — tapped open, the way a Canvas
// goes full screen — the lyrics over the whole lock screen. A still per line; the
// animated artwork (Shared/LockScreenArtwork) yields the artwork slot while this is on.
#import <Foundation/Foundation.h>

#define SGKeyLyricArtwork @"spotifyglass.lyricArtwork"
// The styles that move, as a looping clip instead of a still (Batch 8, iOS 26).
#define SGKeyLyricArtworkAnimated @"spotifyglass.lyricArtwork.animated"
// Which drawing, SGLyricArtworkStyle's values.
#define SGKeyLyricArtworkStyle @"spotifyglass.lyricArtwork.style"

typedef NS_ENUM(NSInteger, SGLyricArtworkStyle) {
    SGLyricArtworkPoster = 0,   // the cover behind, darkened, the lines over it
    SGLyricArtworkPlain,        // plain black, the line big and bold
    SGLyricArtworkAura,         // the cover blurred into an aura of its own colours (Batch 4)
    SGLyricArtworkRecord,       // the cover pressed as a record, the lines under it (Batch 6)
    SGLyricArtworkChat,         // the lines as chat bubbles (Batch 6)
    SGLyricArtworkGradient,     // the line in a gradient of the cover's colours (Batch 6)
    // The Workshop set (Batch 7): original renderers written to the style
    // families the chroma.pw Workshop shows — names after theirs, code ours.
    SGLyricArtworkTwitter,
    SGLyricArtworkCoverInLetters,
    SGLyricArtworkMagazine,
    SGLyricArtworkDuotone,
    SGLyricArtworkWordCollage,
    SGLyricArtworkCyberpunk,
    SGLyricArtworkOldTV,
    SGLyricArtworkMatrix,
    SGLyricArtworkStickers,
    SGLyricArtworkReceipt,
    SGLyricArtworkGigPoster,
    SGLyricArtworkHolo,
    SGLyricArtworkRGBSplit,
    SGLyricArtworkWindow,
    SGLyricArtworkStarburst,
    SGLyricArtworkPrint,
    SGLyricArtworkTiles,
    SGLyricArtworkPolaroid,
    SGLyricArtworkSubtitles,
    SGLyricArtworkLineNumber,
};

@class SGModRow;
// The rows for the Lock screen widget page's Artwork section.
NSArray<SGModRow *> *SGLyricArtworkRows(void);
