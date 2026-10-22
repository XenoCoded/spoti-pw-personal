// The big screen lyric page: its words and its state. The state is the
// karaoke system's — the same lines, the same clock — so the page and
// the phone never disagree about what is being sung.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "TVLyrics.h"
#import "Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"

SGModRow *SGTVLyricsRow(void) {
    return SGOptionRow(@"Lyrics on the big screen",
        @"Serves a lyric page at http://127.0.0.1:8931 — this phone only, nothing leaves the device. Open it in this phone's browser, or wherever its screen is mirrored.",
        SGKeyTVLyrics);
}

NSData *SGTVLyricsStateJSON(void) {
    SPTPlayerState *state = SGPlayerState();
    NSString *trackID = SGKaraokePlayingTrack();
    NSArray<SGKaraokeLine *> *lines = trackID ? SGKaraokeLinesForTrack(trackID) : nil;
    NSInteger ms = SGKaraokePositionMs();
    NSInteger lead = lines.count ? SGKaraokeLeadLine(lines, ms) : -1;
    NSString *line = @"", *next = @"";
    if (lead >= 0 && lead < (NSInteger)lines.count) {
        line = SGKaraokeLineText(lines[(NSUInteger)lead]) ?: @"";
        if (lead + 1 < (NSInteger)lines.count)
            next = SGKaraokeLineText(lines[(NSUInteger)lead + 1]) ?: @"";
    }
    NSDictionary *body = @{
        @"title": state.track.trackTitle ?: @"",
        @"artist": state.track.artistName ?: @"",
        @"line": line,
        @"next": next,
        @"position": @(MAX(ms, 0) / 1000.0),
        @"duration": @(state.duration),
        @"playing": @(!state.isPaused && state.track != nil),
        @"hasLyrics": @(lines.count > 0),
    };
    return [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
}

NSData *SGTVLyricsCoverJPEG(void) {
    static NSString *servedTrack;
    static NSData *servedJPEG;
    NSString *trackID = SGKaraokePlayingTrack();
    if ([trackID isEqualToString:servedTrack]) return servedJPEG;
    servedTrack = [trackID copy];
    servedJPEG = nil;
    MPMediaItemArtwork *artwork = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyArtwork];
    UIImage *image = [artwork imageWithSize:CGSizeMake(600, 600)];
    if (image) servedJPEG = UIImageJPEGRepresentation(image, 0.8);
    return servedJPEG;
}

NSString *SGTVLyricsPageHTML(void) {
    return @"<!DOCTYPE html>\n"
    "<html lang=\"en\"><head><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    "<title>Lyrics</title><style>"
    "html,body{margin:0;height:100%;background:#0a0a0a;color:#fff;"
    "font-family:-apple-system,'Helvetica Neue',Arial,sans-serif;overflow:hidden}"
    "#wrap{height:100%;display:flex;flex-direction:column;justify-content:center;"
    "align-items:center;text-align:center;padding:4vmin;box-sizing:border-box}"
    "#cover{width:22vmin;height:22vmin;border-radius:2vmin;object-fit:cover;"
    "box-shadow:0 2vmin 6vmin rgba(0,0,0,.6);margin-bottom:4vmin}"
    "#title{font-size:3.4vmin;font-weight:600;opacity:.95}"
    "#artist{font-size:2.6vmin;opacity:.55;margin-top:.6vmin}"
    "#line{font-size:6.4vmin;font-weight:700;line-height:1.25;margin-top:5vmin;max-width:88vw}"
    "#next{font-size:3.8vmin;font-weight:500;opacity:.38;margin-top:2.4vmin;max-width:88vw}"
    "#bar{position:fixed;left:0;bottom:0;height:.7vmin;background:#1db954;width:0%}"
    "</style></head><body><div id=\"wrap\">"
    "<img id=\"cover\" alt=\"\">"
    "<div id=\"title\"></div><div id=\"artist\"></div>"
    "<div id=\"line\" dir=\"auto\" aria-live=\"polite\">♪</div><div id=\"next\" dir=\"auto\"></div>"
    "</div><div id=\"bar\"></div><script>"
    "var coverFor='';"
    "function tick(){fetch('/state').then(function(r){return r.json()}).then(function(s){"
    "document.getElementById('title').textContent=s.title;"
    "document.getElementById('artist').textContent=s.artist;"
    "document.getElementById('line').textContent=s.hasLyrics?(s.line||'♪'):'No synced lyrics for this track';"
    "document.getElementById('next').textContent=s.next||'';"
    "if(s.duration>0)document.getElementById('bar').style.width=(100*s.position/s.duration)+'%';"
    "var want=s.title+'|'+s.artist;"
    "if(want!==coverFor){coverFor=want;document.getElementById('cover').src='/cover.jpg?t='+Date.now();}"
    "}).catch(function(){});}"
    "tick();setInterval(tick,700);"
    "</script></body></html>";
}
