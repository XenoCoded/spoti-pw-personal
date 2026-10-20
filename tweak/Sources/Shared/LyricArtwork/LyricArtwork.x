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
#import <CoreImage/CoreImage.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
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

#pragma mark - the Aura's colours (Batch 4)

static CIContext *sg_ciContext;
static CIContext *ciContext(void) {
    if (!sg_ciContext) sg_ciContext = [CIContext contextWithOptions:nil];
    return sg_ciContext;
}

// The cover's own average colour, the accent the Aura draws from.
static UIColor *averageColor(UIImage *image) {
    if (!image.CGImage) return nil;
    CIFilter *average = [CIFilter filterWithName:@"CIAreaAverage"];
    [average setValue:[CIImage imageWithCGImage:image.CGImage] forKey:kCIInputImageKey];
    [average setValue:[CIVector vectorWithX:0 Y:0 Z:image.size.width W:image.size.height] forKey:@"inputExtent"];
    if (!average.outputImage) return nil;
    uint8_t rgba[4] = {0, 0, 0, 0};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [ciContext() render:average.outputImage toBitmap:rgba rowBytes:4 bounds:CGRectMake(0, 0, 1, 1)
                 format:kCIFormatRGBA8 colorSpace:space];
    CGColorSpaceRelease(space);
    return [UIColor colorWithRed:rgba[0] / 255.0 green:rgba[1] / 255.0 blue:rgba[2] / 255.0 alpha:1];
}

// The cover softened past recognition: its colours, none of its detail.
static UIImage *blurred(UIImage *image, CGFloat radius) {
    if (!image.CGImage) return nil;
    CIImage *input = [[CIImage imageWithCGImage:image.CGImage] imageByClampingToExtent];
    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:input forKey:kCIInputImageKey];
    [blur setValue:@(radius) forKey:kCIInputRadiusKey];
    CGImageRef cg = [ciContext() createCGImage:blur.outputImage
                                      fromRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIImage *result = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    return result;
}

// The cover's colour lifted until it can sit beside white text: the accent.
static UIColor *lifted(UIColor *color) {
    CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 0;
    if (!color || ![color getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha]) return UIColor.whiteColor;
    return [UIColor colorWithHue:hue saturation:MIN(saturation, 0.55) brightness:MIN(1, brightness + 0.35) alpha:1];
}

// A fall of darkness down the frame, light at the top where the header sits.
static void drawScrim(CGSize size, CGFloat top, CGFloat bottom) {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat components[] = {0, 0, 0, top, 0, 0, 0, bottom};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, NULL, 2);
    CGContextDrawLinearGradient(context, gradient, CGPointZero, CGPointMake(0, size.height), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
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

// The line being sung, in two tones: what has been sung at full strength, what is
// still to come dim — the karaoke sweep, held in a still. Timed words are coloured by
// their own starts; a line timed only as a whole is swept by where the position
// falls inside it. The position is read as the still is drawn, not when it was
// offered, so a cover tapped open mid-line shows the sweep where the song is.
static NSAttributedString *sungLine(SGKaraokeLine *line, NSString *text, UIFont *font,
                                    UIColor *sung, UIColor *pending) {
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:text ?: @""];
    [out addAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: pending}
                 range:NSMakeRange(0, out.length)];
    if (!line || !out.length) return out;
    NSInteger position = SGKaraokePositionMs();
    if (position < line.start) return out;
    if (position >= line.end && line.end > line.start) {
        [out addAttribute:NSForegroundColorAttributeName value:sung range:NSMakeRange(0, out.length)];
        return out;
    }
    NSUInteger location = 0;
    for (SGKaraokeWord *word in line.words) {
        NSUInteger length = (word.text ?: @"").length;
        if (location + length <= (NSUInteger)out.length && word.start <= position) {
            [out addAttribute:NSForegroundColorAttributeName value:sung range:NSMakeRange(location, length)];
        }
        location += length + (word.joined ? 0 : 1);
    }
    if (!line.words.count && line.end > line.start) {
        CGFloat fraction = (CGFloat)(position - line.start) / (CGFloat)(line.end - line.start);
        NSUInteger cut = (NSUInteger)(out.length * MIN(1, MAX(0, fraction)));
        if (cut) [out addAttribute:NSForegroundColorAttributeName value:sung range:NSMakeRange(0, cut)];
    }
    return out;
}

// An attributed line block, drawLine's measure-and-draw with the string as given.
static CGFloat drawAttributed(NSAttributedString *text, CGFloat y, CGFloat floor, CGSize size) {
    if (!text.length || y >= floor) return y;
    CGFloat margin = size.width * 0.08;
    CGRect box = CGRectMake(margin, y, size.width - 2 * margin, floor - y);
    CGRect measured = [text boundingRectWithSize:box.size
                                         options:NSStringDrawingUsesLineFragmentOrigin context:nil];
    [text drawWithRect:CGRectMake(box.origin.x, y, box.size.width, ceil(measured.size.height))
               options:NSStringDrawingUsesLineFragmentOrigin context:nil];
    return y + ceil(measured.size.height);
}

static UIImage *drawLyricArtwork(CGSize size, NSString *prev, NSString *current, NSString *next,
                                 NSInteger style, UIImage *cover, SGKaraokeLine *line,
                                 NSString *title, NSString *artist) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect full = CGRectMake(0, 0, size.width, size.height);
        UIColor *accent = nil;
        if (style == SGLyricArtworkAura) {
            // The rice (Batch 4): the cover blurred into an aura of its own colours,
            // a wash of its average over that, and darkness falling toward the words,
            // so cover, type and accent all come from the same song.
            UIImage *aura = cover ? blurred(cover, MAX(24, size.width * 0.08)) : nil;
            if (aura) drawCoverFilled(aura, size);
            else { [UIColor.blackColor setFill]; UIRectFill(full); }
            UIColor *average = averageColor(cover);
            if (average) {
                [[average colorWithAlphaComponent:0.25] setFill];
                UIRectFill(full);
                accent = lifted(average);
            }
            drawScrim(size, 0.05, 0.55);
        } else if (style == SGLyricArtworkPoster && cover) {
            drawCoverFilled(cover, size);
            [[UIColor colorWithWhite:0 alpha:0.48] setFill];
            UIRectFill(full);
            drawScrim(size, 0.10, 0.45);
        } else {
            [UIColor.blackColor setFill];
            UIRectFill(full);
        }
        CGFloat floor = size.height * 0.74;
        CGFloat y = size.height * 0.10;
        if (style == SGLyricArtworkAura && title.length) {
            y = size.height * 0.06;
            y = drawLine(title, y, floor, size,
                         [UIFont systemFontOfSize:size.height * 0.026 weight:UIFontWeightSemibold],
                         [UIColor colorWithWhite:1 alpha:0.92]);
            if (artist.length) {
                y = drawLine(artist, y, floor, size,
                             [UIFont systemFontOfSize:size.height * 0.023],
                             accent ?: [UIColor colorWithWhite:1 alpha:0.55]);
            }
            y = size.height * 0.17;
        }
        y = drawLine(prev, y, floor, size,
                     [UIFont systemFontOfSize:size.height * 0.030],
                     [UIColor colorWithWhite:1 alpha:0.38]);
        if (prev.length) y += size.height * 0.02;
        if ([current isEqualToString:@"♪"]) {
            NSDictionary *attrs = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:size.height * 0.20],
                                    NSForegroundColorAttributeName: accent ?: UIColor.whiteColor};
            CGSize note = [current sizeWithAttributes:attrs];
            [current drawInRect:CGRectMake((size.width - note.width) / 2, y, note.width, note.height)
                 withAttributes:attrs];
            y += note.height;
        } else {
            UIFont *font = [UIFont boldSystemFontOfSize:size.height * (style == SGLyricArtworkAura ? 0.056 : 0.052)];
            y = drawAttributed(sungLine(line, current, font, UIColor.whiteColor,
                                         [UIColor colorWithWhite:1 alpha:0.38]), y, floor, size);
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
    SGKaraokeLine *line = index >= 0 ? lines[index] : nil;
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerTrack *track = player.state.track;
    NSString *title = track.trackTitle ?: @"", *artist = track.artistName ?: @"";
    NSInteger style = SGInt(SGKeyLyricArtworkStyle, SGLyricArtworkAura);
    MPMediaItemArtwork *cover;
    @synchronized (sg_lock) { cover = sg_cover; }
    sg_artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:CGSizeMake(900, 1200)
        requestHandler:^UIImage *(CGSize size) {
            UIImage *coverImage = cover ? [cover imageWithSize:size] : nil;
            return drawLyricArtwork(size, prev, current, next, style, coverImage, line, title, artist);
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
