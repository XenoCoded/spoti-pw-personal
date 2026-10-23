// Lyric artwork (personal fork): the line being sung, drawn as the now playing artwork,
// so the lock screen's player shows the lyrics small and — tapped open, the way a Canvas
// goes full screen — the lyrics over the whole lock screen. A still per line; the
// animated artwork (Shared/LockScreenArtwork) yields the artwork slot while this is on.
#import <Foundation/Foundation.h>

@class MPMediaItemArtwork;

#define SGKeyLyricArtwork @"spotifyglass.lyricArtwork"
// The styles that move, as a looping clip instead of a still (Batch 8, iOS 26).
#define SGKeyLyricArtworkAnimated @"spotifyglass.lyricArtwork.animated"
// Clip quality: 0 Saver, 1 Balanced, 2 Max (Batch 18).
#define SGKeyLyricArtworkClipQuality @"spotifyglass.lyricArtwork.clipQuality"
// Which drawing, SGLyricArtworkStyle's values.
#define SGKeyLyricArtworkStyle @"spotifyglass.lyricArtwork.style"
// A fresh style rolled for every track (Batch 31); the picked style above is the fallback.
#define SGKeyLyricArtworkShuffle @"spotifyglass.lyricArtwork.shuffle"

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
    // The second research wave (Batch 81): Pulse bars is the waveform
    // card, Warp flow is the cover's colours in motion, OLED stealth
    // is the all-black whisper for always-on lock screens.
    SGLyricArtworkPulseBars,
    SGLyricArtworkWarpFlow,
    SGLyricArtworkOLEDStealth,
};

@class SGModRow;
// The rows for the Lock screen widget page's Artwork section.
NSArray<SGModRow *> *SGLyricArtworkRows(void);
// The styles' picker names, in enum order (Batch 20).
NSArray<NSString *> *SGLyricArtworkStyleNames(void);
// The card the lock screen is showing for the line being sung, drawn at
// full size (Batch 35); nil before any line has been drawn.
UIImage *SGLyricArtworkCurrentCard(void);
// The still object itself, for identity checks by the other
// now-playing hook (Batch 94).
MPMediaItemArtwork *SGLyricArtworkCurrentStill(void);
// One style drawn with sample facts — the picker's thumbnails (Batch 20).
@class UIImage;
UIImage *SGLyricArtworkSample(NSInteger style, CGSize size);
