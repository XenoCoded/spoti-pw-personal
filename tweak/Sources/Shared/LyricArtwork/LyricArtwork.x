// Lyric artwork: a still of the line being sung in place of the cover in the now playing
// info. The lock screen's player draws the artwork small beside the controls and, tapped,
// full screen — the same surface a Canvas plays on — so the still is composed tall (3:4)
// for the full screen, not for the thumbnail: the cover darkened behind (Poster) or plain
// black, the previous line dim at the top, the line itself big, the next under it, and the
// bottom quarter left quiet where the system's own title and controls sit.
//
// The lines and the clock come from Shared/Lyrics, the same source the Live Activity and
// the lock screen lyrics read. A half-second timer watches for a new line; a line is drawn
// only when the system asks the artwork for a size, and a track with no timed lyrics keeps
// its cover. While this is on, Shared/LockScreenArtwork leaves the artwork slot alone.
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "LyricArtwork.h"
#import "Shared/Lyrics/Lyrics.h"

static NSObject *sg_lock;
static NSDictionary *sg_info;              // the last now playing info Spotify sent
static MPMediaItemArtwork *sg_cover;       // Spotify's own artwork, the Poster's ground
static MPMediaItemArtwork *sg_artwork;     // the lyric still currently offered
static NSString *sg_lineKey;               // track + line the offered still was drawn for

// The cover drawn to fill a frame of `size`, the way `filled` does it in LockScreenArtwork.
static void drawCoverFilled(UIImage *image, CGSize size) {
    CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
    CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
    [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2,
                                  drawn.width, drawn.height)];
}

// One line block drawn at `y`, measured first so the next block knows where it starts;
// returns the y under it. Nothing is drawn past `floor`, the quiet bottom quarter.
static CGFloat drawLine(NSString *text, CGFloat y, CGFloat floor, CGSize size,
                        UIFont *font, UIColor *color) {
    if (!text.length || y >= floor) return y;
    CGFloat margin = size.width * 0.08;
    CGRect box = CGRectMake(margin, y, size.width - 2 * margin, floor - y);
    NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: color};
    CGRect measured = [text boundingRectWithSize:box.size
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:attrs context:nil];
    [text drawInRect:CGRectMake(box.origin.x, y, box.size.width, ceil(measured.size.height))
        withAttributes:attrs];
    return y + ceil(measured.size.height);
}

static UIImage *drawLyricArtwork(CGSize size, NSString *prev, NSString *current, NSString *next,
                                 NSInteger style, UIImage *cover) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect full = CGRectMake(0, 0, size.width, size.height);
        if (style == SGLyricArtworkPoster && cover) {
            drawCoverFilled(cover, size);
            [[UIColor colorWithWhite:0 alpha:0.48] setFill];
            UIRectFill(full);
        } else {
            [UIColor.blackColor setFill];
            UIRectFill(full);
        }
        CGFloat floor = size.height * 0.74;
        CGFloat y = size.height * 0.10;
        y = drawLine(prev, y, floor, size,
                     [UIFont systemFontOfSize:size.height * 0.030],
                     [UIColor colorWithWhite:1 alpha:0.38]);
        if (prev.length) y += size.height * 0.02;
        if ([current isEqualToString:@"♪"]) {
            NSDictionary *attrs = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:size.height * 0.20],
                                    NSForegroundColorAttributeName: UIColor.whiteColor};
            CGSize note = [current sizeWithAttributes:attrs];
            [current drawInRect:CGRectMake((size.width - note.width) / 2, y, note.width, note.height)
                 withAttributes:attrs];
            y += note.height;
        } else {
            y = drawLine(current, y, floor, size,
                         [UIFont boldSystemFontOfSize:size.height * 0.052], UIColor.whiteColor);
        }
        y += size.height * 0.025;
        drawLine(next, y, floor, size,
                 [UIFont systemFontOfSize:size.height * 0.034 weight:UIFontWeightSemibold],
                 [UIColor colorWithWhite:1 alpha:0.50]);
    }];
}

// Spotify's info again, so the system picks up the still that has just been drawn; this
// feature's own hook below puts the still in on the way out.
static void resend(void) {
    NSDictionary *info;
    @synchronized (sg_lock) { info = sg_info; }
    if (info.count) MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}

static void clearArtwork(void) {
    if (!sg_artwork) return;
    sg_artwork = nil;
    sg_lineKey = nil;
    SGLog(@"lyric artwork: cleared, the cover is back");
    resend();
}

static void tick(void) {
    NSString *trackID = SGKaraokePlayingTrack();
    NSArray<SGKaraokeLine *> *lines = trackID ? SGKaraokeLinesForTrack(trackID) : nil;
    if (!lines) {
        if (trackID) SGKaraokeRequestLyrics(trackID);
        clearArtwork();
        return;
    }
    if (SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) {
        clearArtwork();
        return;
    }
    NSInteger position = SGKaraokePositionMs();
    NSInteger index = SGKaraokeLeadLine(lines, position);
    NSString *key = [NSString stringWithFormat:@"%@/%ld", trackID, (long)index];
    if ([key isEqualToString:sg_lineKey]) return;
    sg_lineKey = key;

    NSString *current = index >= 0 ? SGKaraokeLineText(lines[index]) : @"♪";
    NSString *prev = index > 0 ? SGKaraokeLineText(lines[index - 1]) : @"";
    NSString *next = index + 1 < (NSInteger)lines.count ? SGKaraokeLineText(lines[index + 1]) : @"";
    NSInteger style = SGInt(SGKeyLyricArtworkStyle, SGLyricArtworkPoster);
    MPMediaItemArtwork *cover;
    @synchronized (sg_lock) { cover = sg_cover; }
    sg_artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:CGSizeMake(900, 1200)
        requestHandler:^UIImage *(CGSize size) {
            UIImage *coverImage = cover ? [cover imageWithSize:size] : nil;
            return drawLyricArtwork(size, prev, current, next, style, coverImage);
        }];
    SGLog(@"lyric artwork: %@ — %@", trackID, current);
    resend();
}

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    MPMediaItemArtwork *artwork;
    @synchronized (sg_lock) {
        id theirs = info[MPMediaItemPropertyArtwork];
        if (theirs && theirs != sg_artwork) sg_cover = theirs;
        sg_info = info;
        artwork = sg_artwork;
    }
    if (artwork && info[MPMediaItemPropertyArtwork] != artwork) {
        NSMutableDictionary *swapped = [info mutableCopy];
        swapped[MPMediaItemPropertyArtwork] = artwork;
        %orig(swapped);
        return;
    }
    %orig;
}
%end

%ctor {
    if (!SGFlag(SGKeyLyricArtwork, NO)) return;
    sg_lock = [NSObject new];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { tick(); }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
    %init;
    SGRequireClasses(@[@"MPNowPlayingInfoCenter"]);
    SGLog(@"lyric artwork: on");
}
