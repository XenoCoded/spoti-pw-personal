// What the redesign's lyrics show of a line besides its words: the pronunciation and the translation a
// source has for it (Shared/Lyrics/Lyrics.h), each switched on from the lyrics' own menu, and the order
// of sizes the three are set in, from the Lyrics page. The switches apply at once, to every lyrics
// view there is, and are kept for the next song and the next launch.
#import <UIKit/UIKit.h>

// A line's three texts. The order puts them largest first; the lyrics are always among them.
typedef NS_ENUM(NSInteger, SGRLyricsText) {
    SGRLyricsTextLyrics = 0,
    SGRLyricsTextPronunciation,
    SGRLyricsTextTranslation,
};

#define SGRKeyLyricsPronunciation @"spotifyglass.redesign.lyricsPronunciation"   // off until switched on
#define SGRKeyLyricsTranslation @"spotifyglass.redesign.lyricsTranslation"       // off until switched on
// The three as the words "lyrics", "pronunciation" and "translation", largest first.
#define SGRKeyLyricsTextOrder @"spotifyglass.redesign.lyricsTextOrder"
// Turned sideways, the lyrics share the screen with the cover (Batch 24).
#define SGRKeyLandscapeLyrics @"spotifyglass.redesign.landscapeLyrics"
// How the word being sung stands out, and how hard it stands out (Batch 61): the styles are
// float (rise as it starts), grow (swell to a held size), pop (an overshoot as the word lands)
// and glow (a highlight blooming behind it); the emphasis is gentle, normal or bold. The words
// read both as they are laid out, so a change restyles the song on the spot.
#define SGRKeyLyricsWordStyle @"spotifyglass.redesign.lyricsWordStyle"
#define SGRKeyLyricsWordIntensity @"spotifyglass.redesign.lyricsWordIntensity"

// Posted on the main queue when either switch or the order changes.
extern NSNotificationName const SGRLyricsTextDidChangeNotification;

// The order, SGRLyricsText values largest first; unset is Apple Music's: lyrics, pronunciation, translation.
NSArray<NSNumber *> *SGRLyricsTextOrder(void);
void SGRSetLyricsTextOrder(NSArray<NSNumber *> *order);
NSString *SGRLyricsTextName(SGRLyricsText text);
void SGRSetLyricsTextShown(SGRLyricsText text, BOOL shown);

// LyricsTextSettings.m: the Lyrics page's row for the order, which opens a list of the three to drag.
@class SGModRow;
SGModRow *SGRLyricsTextSizesRow(void);
// The landscape lyrics switch, for the Lyrics page's Display section.
SGModRow *SGRLandscapeLyricsRow(void);
// The word style and emphasis rows (Batch 61), for the same section.
SGModRow *SGRLyricsWordStyleRow(void);
SGModRow *SGRLyricsWordIntensityRow(void);
