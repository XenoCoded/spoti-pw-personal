// Lyric artwork (personal fork): the line being sung, drawn as the now playing artwork,
// so the lock screen's player shows the lyrics small and — tapped open, the way a Canvas
// goes full screen — the lyrics over the whole lock screen. A still per line; the
// animated artwork (Shared/LockScreenArtwork) yields the artwork slot while this is on.
#import <Foundation/Foundation.h>

#define SGKeyLyricArtwork @"spotifyglass.lyricArtwork"
// Which drawing, SGLyricArtworkStyle's values.
#define SGKeyLyricArtworkStyle @"spotifyglass.lyricArtwork.style"

typedef NS_ENUM(NSInteger, SGLyricArtworkStyle) {
    SGLyricArtworkPoster = 0,   // the cover behind, darkened, the lines over it
    SGLyricArtworkPlain,        // plain black, the line big and bold
    SGLyricArtworkAura,         // the cover blurred into an aura of its own colours (Batch 4)
};

@class SGModRow;
// The rows for the Lock screen widget page's Artwork section.
NSArray<SGModRow *> *SGLyricArtworkRows(void);
