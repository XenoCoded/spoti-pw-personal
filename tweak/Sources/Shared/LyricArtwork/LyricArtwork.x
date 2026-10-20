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

// The same, centred — the Record style sets its type down the middle.
static CGFloat drawAttributedCentered(NSAttributedString *text, CGFloat y, CGFloat floor, CGSize size) {
    if (!text.length || y >= floor) return y;
    NSMutableAttributedString *centred = [text mutableCopy];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    [centred addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, centred.length)];
    CGRect box = CGRectMake(size.width * 0.06, y, size.width * 0.88, floor - y);
    CGRect measured = [centred boundingRectWithSize:box.size
                                             options:NSStringDrawingUsesLineFragmentOrigin context:nil];
    [centred drawWithRect:CGRectMake(box.origin.x, y, box.size.width, ceil(measured.size.height))
                  options:NSStringDrawingUsesLineFragmentOrigin context:nil];
    return y + ceil(measured.size.height);
}

static CGFloat drawCentered(NSString *text, CGFloat y, CGFloat floor, CGSize size, UIFont *font, UIColor *color) {
    if (!text.length || y >= floor) return y;
    return drawAttributedCentered(
        [[NSAttributedString alloc] initWithString:text
                                        attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}],
        y, floor, size);
}

// An image drawn to fill a rect, the cover's way, centred on the overflow.
static void drawCoverInRect(UIImage *image, CGRect rect) {
    CGFloat scale = MAX(rect.size.width / image.size.width, rect.size.height / image.size.height);
    CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
    [image drawInRect:CGRectMake(rect.origin.x + (rect.size.width - drawn.width) / 2,
                                  rect.origin.y + (rect.size.height - drawn.height) / 2,
                                  drawn.width, drawn.height)];
}

#pragma mark - Record and Chat (Batch 6)

// The Record: black, a wash of the cover's colour, and the cover pressed as the
// label of a vinyl disc — grooves, spindle hole and all — with the lines set
// centred under it. A still cannot spin; the record is the look, not the motion.
static UIImage *drawRecordArtwork(CGSize size, NSString *prev, NSString *current, NSString *next,
                                  UIImage *cover, SGKaraokeLine *line, NSString *title, NSString *artist) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.blackColor setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        UIColor *average = averageColor(cover);
        if (average) {
            [[average colorWithAlphaComponent:0.13] setFill];
            UIRectFill(CGRectMake(0, 0, size.width, size.height));
        }
        CGFloat diameter = size.width * 0.60;
        CGRect disc = CGRectMake((size.width - diameter) / 2, size.height * 0.06, diameter, diameter);
        [[UIColor colorWithWhite:0.06 alpha:1] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:disc] fill];
        [[UIColor colorWithWhite:1 alpha:0.08] setStroke];
        for (CGFloat inset = diameter * 0.05; inset < diameter * 0.28; inset += diameter * 0.032) {
            UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(disc, inset, inset)];
            ring.lineWidth = 1.2;
            [ring stroke];
        }
        if (cover) {
            CGRect label = CGRectInset(disc, diameter * 0.295, diameter * 0.295);
            CGContextSaveGState(context.CGContext);
            [[UIBezierPath bezierPathWithOvalInRect:label] addClip];
            drawCoverInRect(cover, label);
            CGContextRestoreGState(context.CGContext);
        }
        CGRect hole = CGRectMake(size.width / 2 - diameter * 0.018, disc.origin.y + diameter / 2 - diameter * 0.018,
                                 diameter * 0.036, diameter * 0.036);
        [UIColor.blackColor setFill];
        [[UIBezierPath bezierPathWithOvalInRect:hole] fill];
        [[UIColor colorWithWhite:1 alpha:0.5] setStroke];
        UIBezierPath *rim = [UIBezierPath bezierPathWithOvalInRect:hole];
        rim.lineWidth = 1;
        [rim stroke];

        CGFloat floor = size.height * 0.97;
        CGFloat y = CGRectGetMaxY(disc) + size.height * 0.035;
        y = drawCentered(title, y, floor, size,
                         [UIFont systemFontOfSize:size.height * 0.025 weight:UIFontWeightSemibold],
                         [UIColor colorWithWhite:1 alpha:0.9]);
        if (artist.length) {
            y = drawCentered(artist, y, floor, size,
                             [UIFont systemFontOfSize:size.height * 0.021],
                             [UIColor colorWithWhite:1 alpha:0.5]);
        }
        y += size.height * 0.03;
        y = drawCentered(prev, y, floor, size,
                         [UIFont systemFontOfSize:size.height * 0.027],
                         [UIColor colorWithWhite:1 alpha:0.35]);
        if (prev.length) y += size.height * 0.012;
        if ([current isEqualToString:@"♪"]) {
            y = drawCentered(current, y, floor, size,
                             [UIFont boldSystemFontOfSize:size.height * 0.10], UIColor.whiteColor);
        } else {
            y = drawAttributedCentered(sungLine(line, current,
                                                [UIFont boldSystemFontOfSize:size.height * 0.044],
                                                UIColor.whiteColor, [UIColor colorWithWhite:1 alpha:0.38]),
                                       y, floor, size);
        }
        y += size.height * 0.012;
        drawCentered(next, y, floor, size,
                     [UIFont systemFontOfSize:size.height * 0.030 weight:UIFontWeightSemibold],
                     [UIColor colorWithWhite:1 alpha:0.5]);
    }];
}

// One chat bubble; returns the y under it. Outgoing sits right, in the accent;
// incoming left, in grey.
static CGFloat drawBubble(NSString *text, CGFloat y, CGSize size, BOOL outgoing,
                          UIColor *fill, UIColor *textColor, UIFont *font) {
    if (!text.length) return y;
    CGFloat maxText = size.width * 0.68;
    CGRect measured = [text boundingRectWithSize:CGSizeMake(maxText, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:@{NSFontAttributeName: font} context:nil];
    CGFloat padX = size.width * 0.038, padY = size.height * 0.012;
    CGFloat width = ceil(measured.size.width) + 2 * padX, height = ceil(measured.size.height) + 2 * padY;
    CGFloat x = outgoing ? size.width * 0.94 - width : size.width * 0.06;
    CGRect bubble = CGRectMake(x, y, width, height);
    [fill setFill];
    [[UIBezierPath bezierPathWithRoundedRect:bubble cornerRadius:height * 0.36] fill];
    [text drawInRect:CGRectMake(x + padX, y + padY, measured.size.width, measured.size.height)
      withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: textColor}];
    return y + height;
}

// The Chat: the lines as a conversation — what was sung on the left in grey, the
// line being sung on the right in the cover's colour, what is next waiting on
// the left, and the song named at the top the way a chat names its person.
static UIImage *drawChatArtwork(CGSize size, NSString *prev, NSString *current, NSString *next,
                                UIImage *cover, NSString *title, NSString *artist) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.blackColor setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        UIColor *average = averageColor(cover);
        UIColor *accent = average ? lifted(average) : [UIColor colorWithRed:0.11 green:0.85 blue:0.38 alpha:1];
        CGFloat floor = size.height * 0.97;
        CGFloat y = size.height * 0.055;
        y = drawCentered(title.length ? title : @"♪", y, floor, size,
                         [UIFont systemFontOfSize:size.height * 0.027 weight:UIFontWeightSemibold],
                         [UIColor colorWithWhite:1 alpha:0.92]);
        if (artist.length) {
            y = drawCentered(artist, y, floor, size,
                             [UIFont systemFontOfSize:size.height * 0.020],
                             [UIColor colorWithWhite:1 alpha:0.45]);
        }
        y += size.height * 0.012;
        [[UIColor colorWithWhite:1 alpha:0.14] setFill];
        UIRectFill(CGRectMake(size.width * 0.06, y, size.width * 0.88, 1));
        y += size.height * 0.05;
        UIFont *pastFont = [UIFont systemFontOfSize:size.height * 0.031];
        UIFont *nowFont = [UIFont systemFontOfSize:size.height * 0.036 weight:UIFontWeightMedium];
        y = drawBubble(prev, y, size, NO, [UIColor colorWithWhite:1 alpha:0.13],
                       [UIColor colorWithWhite:1 alpha:0.65], pastFont);
        if (prev.length) y += size.height * 0.016;
        y = drawBubble(current, y, size, YES, accent, UIColor.whiteColor, nowFont);
        y += size.height * 0.016;
        drawBubble(next, y, size, NO, [UIColor colorWithWhite:1 alpha:0.09],
                   [UIColor colorWithWhite:1 alpha:0.5], pastFont);
    }];
}

// The line as gradient text: rendered alone, its glyphs cut out of a wash of the
// cover's colours (destination-in keeps the wash only where the type is).
static CGFloat drawGradientLine(NSAttributedString *text, CGFloat y, CGFloat floor, CGSize size,
                                UIColor *top, UIColor *bottom) {
    if (!text.length || y >= floor) return y;
    CGFloat margin = size.width * 0.08;
    CGRect box = CGRectMake(margin, y, size.width - 2 * margin, floor - y);
    CGRect measured = [text boundingRectWithSize:box.size
                                         options:NSStringDrawingUsesLineFragmentOrigin context:nil];
    CGRect target = CGRectMake(box.origin.x, y, box.size.width, ceil(measured.size.height));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    UIImage *cut = [[[UIGraphicsImageRenderer alloc] initWithSize:target.size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *cutContext) {
        CGContextRef ctx = cutContext.CGContext;
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat topC[4], bottomC[4];
        [top getRed:&topC[0] green:&topC[1] blue:&topC[2] alpha:&topC[3]];
        [bottom getRed:&bottomC[0] green:&bottomC[1] blue:&bottomC[2] alpha:&bottomC[3]];
        CGFloat components[] = {topC[0], topC[1], topC[2], 1, bottomC[0], bottomC[1], bottomC[2], 1};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, NULL, 2);
        CGContextDrawLinearGradient(ctx, gradient, CGPointZero, CGPointMake(0, target.size.height), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        CGContextSetBlendMode(ctx, kCGBlendModeDestinationIn);
        [text drawWithRect:CGRectMake(0, 0, target.size.width, target.size.height)
                   options:NSStringDrawingUsesLineFragmentOrigin context:nil];
    }];
    [cut drawInRect:target];
    return y + target.size.height;
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
        if (style == SGLyricArtworkAura || style == SGLyricArtworkGradient) {
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
        if ((style == SGLyricArtworkAura || style == SGLyricArtworkGradient) && title.length) {
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
        } else if (style == SGLyricArtworkGradient) {
            // The wash runs from the cover's colour, lifted, down to its deep shade;
            // the sweep survives as alpha — unsung words take less of the wash.
            UIFont *font = [UIFont boldSystemFontOfSize:size.height * 0.056];
            UIColor *top = accent ?: [UIColor colorWithRed:0.11 green:0.85 blue:0.38 alpha:1];
            CGFloat hue = 0, saturation = 0, brightness = 0;
            [top getHue:&hue saturation:&saturation brightness:&brightness alpha:NULL];
            UIColor *bottom = [UIColor colorWithHue:hue saturation:MIN(1, saturation + 0.1)
                                         brightness:brightness * 0.45 alpha:1];
            y = drawGradientLine(sungLine(line, current, font, UIColor.whiteColor,
                                          [UIColor colorWithWhite:1 alpha:0.38]),
                                 y, floor, size, top, bottom);
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
            if (style == SGLyricArtworkRecord) {
                return drawRecordArtwork(size, prev, current, next, coverImage, line, title, artist);
            }
            if (style == SGLyricArtworkChat) {
                return drawChatArtwork(size, prev, current, next, coverImage, title, artist);
            }
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
