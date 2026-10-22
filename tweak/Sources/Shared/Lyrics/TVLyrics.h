// The lyric page for a big screen (Batch 67): a tiny web server in the
// tweak, bound to this phone only (127.0.0.1 — nothing on the network can
// reach it), serving one page that shows the line being sung, large, and
// asks the server twice a second what changed. For a browser on the
// phone itself, or whatever the phone's screen is mirrored to.
#import <Foundation/Foundation.h>

#define SGKeyTVLyrics @"spotifyglass.tvLyrics"
#define SGTVLyricsPort 8931

@class SGModRow;
// The Lyrics page's row: the switch, with the address in its subtitle.
SGModRow *SGTVLyricsRow(void);
// The page itself and the state it polls, as data.
NSString *SGTVLyricsPageHTML(void);
NSData *SGTVLyricsStateJSON(void);
NSData *SGTVLyricsCoverJPEG(void);
