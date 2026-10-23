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
#import "LyricClip.h"
#import "Shared/LockScreenArtwork/LockScreenArtwork.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"

// The one lock for this file's shared state — the offered artwork, the
// cover, the sample cache. It used to be a plain static created inside
// the %ctor, AFTER that constructor's launch-time flag gate: in any
// session where lyric artwork was off at launch and switched on later,
// the lock was never created, @synchronized (nil) silently did nothing,
// and everything the lock was added to protect raced anyway — the
// picker's concurrent sample renders above all. dispatch_once creates
// it on first use, whichever path gets here first.
static NSObject *sg_lockObject(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
// The frame clock for clip renders: seconds into the line being drawn, or -1
// when a still is being drawn and the player's own position rules.
static double sg_frameTime = -1;
static NSDictionary *sg_info;              // the last now playing info Spotify sent
static MPMediaItemArtwork *sg_cover;       // Spotify's own artwork, the Poster's ground
static MPMediaItemArtwork *sg_artwork;     // the lyric still currently offered
static id sg_clipArtwork;                  // the line's clip as an animated artwork, once rendered
static NSString *sg_clipFor;               // the line key sg_clipArtwork belongs to
static NSString *sg_lineKey;               // track + line the offered still was drawn for

// The cover drawn to fill a frame of `size`, the way `filled` does it in LockScreenArtwork.
static void drawCoverFilled(UIImage *image, CGSize size) {
    CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
    CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
    [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2,
                                  drawn.width, drawn.height)];
}

#pragma mark - the Aura's colours (Batch 4)

static CIContext *ciContext(void) {
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });
    return context;
}

// A cover's frame, breathing (Batch 13): while a clip renders, the rect a
// cover is filled into swells and drifts on a slow sine, so still-looking
// styles move without anything jumping at the loop.
static CGRect breathingRect(CGRect rect, CGFloat grow, CGFloat pan) {
    if (sg_frameTime < 0) return rect;
    CGFloat swell = grow * (0.5 + 0.5 * sin(sg_frameTime * (2 * M_PI / 6)));
    CGFloat dx = pan * sin(sg_frameTime * (2 * M_PI / 7));
    CGFloat gy = swell * rect.size.height / MAX(1, rect.size.width);
    return CGRectMake(rect.origin.x - swell + dx, rect.origin.y - gy,
                      rect.size.width + 2 * swell, rect.size.height + 2 * gy);
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
    CIImage *blurredImage = blur.outputImage;
    if (!blurredImage) return nil;
    CGImageRef cg = [ciContext() createCGImage:blurredImage
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
    // While a clip renders (LyricClip), the position is the frame's, not the
    // player's: the sweep is drawn where the frame sits inside the line.
    NSInteger position = sg_frameTime >= 0 ? line.start + (NSInteger)(sg_frameTime * 1000) : SGKaraokePositionMs();
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

// The record itself, on transparency: vinyl, grooves, the cover as its label
// and the spindle hole. Drawn once and turned by the clip frames.
static UIImage *recordDiscImage(CGFloat diameter, UIImage *cover) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(diameter, diameter) format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect disc = CGRectMake(0, 0, diameter, diameter);
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
        CGRect hole = CGRectMake(diameter / 2 - diameter * 0.018, diameter / 2 - diameter * 0.018,
                                 diameter * 0.036, diameter * 0.036);
        [UIColor.blackColor setFill];
        [[UIBezierPath bezierPathWithOvalInRect:hole] fill];
        [[UIColor colorWithWhite:1 alpha:0.5] setStroke];
        UIBezierPath *rim = [UIBezierPath bezierPathWithOvalInRect:hole];
        rim.lineWidth = 1;
        [rim stroke];
    }];
}

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
        // The disc is its own image so a clip's frames can turn it (below).
        UIImage *discImage = recordDiscImage(diameter, cover);
        if (sg_frameTime >= 0) {
            CGContextSaveGState(context.CGContext);
            CGContextTranslateCTM(context.CGContext, CGRectGetMidX(disc), CGRectGetMidY(disc));
            CGContextRotateCTM(context.CGContext, sg_frameTime * (2 * M_PI / 1.8));   // a record's 33⅓ rpm
            [discImage drawInRect:CGRectMake(-diameter / 2, -diameter / 2, diameter, diameter)];
            CGContextRestoreGState(context.CGContext);
        } else {
            [discImage drawInRect:disc];
        }

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

// An iMessage bubble as one path: the rounded body and the little tail
// that curls out of its bottom corner on the side it answers to. The
// tail is most of what makes a bubble read as iMessage rather than a
// rounded rectangle (Batch 97: the old Chat was dark pills in the
// cover's colour — green by default, which reads as SMS, the opposite
// of the thing it is named after).
static UIBezierPath *bubblePath(CGRect rect, BOOL outgoing, CGFloat radius) {
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
    CGFloat tailW = rect.size.width * 0.05 + 6;
    CGFloat baseY = rect.origin.y + rect.size.height;
    UIBezierPath *tail = [UIBezierPath bezierPath];
    if (outgoing) {
        CGFloat right = rect.origin.x + rect.size.width;
        [tail moveToPoint:CGPointMake(right - radius * 0.9, baseY - 1)];
        [tail addQuadCurveToPoint:CGPointMake(right + tailW * 0.55, baseY + tailW * 0.30)
                     controlPoint:CGPointMake(right + tailW * 0.52, baseY - 1)];
        [tail addQuadCurveToPoint:CGPointMake(right - radius * 0.15, baseY - radius * 0.55)
                     controlPoint:CGPointMake(right + tailW * 0.08, baseY + tailW * 0.10)];
    } else {
        CGFloat left = rect.origin.x;
        [tail moveToPoint:CGPointMake(left + radius * 0.9, baseY - 1)];
        [tail addQuadCurveToPoint:CGPointMake(left - tailW * 0.55, baseY + tailW * 0.30)
                     controlPoint:CGPointMake(left - tailW * 0.52, baseY - 1)];
        [tail addQuadCurveToPoint:CGPointMake(left + radius * 0.15, baseY - radius * 0.55)
                     controlPoint:CGPointMake(left - tailW * 0.08, baseY + tailW * 0.10)];
    }
    [tail closePath];
    [path appendPath:tail];
    return path;
}

// One bubble of the conversation; returns the y under it. Incoming sits
// left in the room's grey with the room's ink; outgoing right, in the
// blue gradient, white words — the attributed text carries the karaoke
// sweep for the line being sung. entranceT is the seconds since the
// line began in a clip (or -1): while it runs, the bubble pops in from
// its tail corner the way a sent message does, springing a touch past
// full size before it settles.
static CGFloat drawBubble(NSAttributedString *text, NSString *plain, CGFloat y, CGSize size,
                          BOOL outgoing, UIFont *font, UIColor *incomingFill, double entranceT) {
    if (!plain.length) return y;
    CGFloat maxText = size.width * 0.66;
    CGRect measured = [plain boundingRectWithSize:CGSizeMake(maxText, CGFLOAT_MAX)
                                          options:NSStringDrawingUsesLineFragmentOrigin
                                       attributes:@{NSFontAttributeName: font} context:nil];
    CGFloat padX = size.width * 0.034, padY = size.height * 0.011;
    CGFloat width = ceil(measured.size.width) + 2 * padX;
    CGFloat height = ceil(measured.size.height) + 2 * padY;
    CGFloat x = outgoing ? size.width * 0.965 - width : size.width * 0.035;
    CGRect bubble = CGRectMake(x, y, width, height);
    CGFloat radius = MIN(height * 0.5, size.width * 0.048);
    UIBezierPath *path = bubblePath(bubble, outgoing, radius);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    BOOL entering = entranceT >= 0 && entranceT < 0.38;
    if (entering) {
        double t = entranceT / 0.38;
        double e = 1 + 2.70158 * pow(t - 1, 3) + 1.70158 * pow(t - 1, 2);
        CGFloat scale = 0.55 + 0.45 * (CGFloat)e;
        CGContextSaveGState(ctx);
        CGContextSetAlpha(ctx, (CGFloat)MIN(1, entranceT / 0.15));
        CGPoint anchor = outgoing ? CGPointMake(CGRectGetMaxX(bubble), CGRectGetMaxY(bubble))
                                  : CGPointMake(bubble.origin.x, CGRectGetMaxY(bubble));
        CGContextTranslateCTM(ctx, anchor.x, anchor.y);
        CGContextScaleCTM(ctx, scale, scale);
        CGContextTranslateCTM(ctx, -anchor.x, -anchor.y);
    }
    if (outgoing) {
        CGContextSaveGState(ctx);
        [path addClip];
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        NSArray *colors = @[(id)[UIColor colorWithRed:0.10 green:0.60 blue:1.0 alpha:1].CGColor,
                            (id)[UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1].CGColor];
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, bubble.origin.y),
                                    CGPointMake(0, bubble.origin.y + bubble.size.height), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        CGContextRestoreGState(ctx);
    } else {
        [incomingFill setFill];
        [path fill];
    }
    [text drawWithRect:CGRectMake(x + padX, y + padY, measured.size.width, measured.size.height)
               options:NSStringDrawingUsesLineFragmentOrigin context:nil];
    if (entering) CGContextRestoreGState(ctx);
    return y + height;
}

// One short string centred in a rect, both ways.
static void drawCenteredAt(NSString *text, CGRect rect, UIFont *font, UIColor *color) {
    NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: color};
    CGSize measured = [text sizeWithAttributes:attrs];
    [text drawInRect:CGRectMake(rect.origin.x + (rect.size.width - measured.width) / 2,
                                rect.origin.y + (rect.size.height - measured.height) / 2,
                                measured.width, measured.height)
      withAttributes:attrs];
}

// The typing indicator: three dots breathing in an incoming bubble,
// the way iMessage shows someone mid-reply. age is the seconds since
// it appeared (clips), or -1 for a posed still, where the dots rest at
// staggered strengths.
static CGFloat drawTypingBubble(CGFloat y, CGSize size, UIColor *fill, UIColor *dotBase, double age) {
    CGFloat H = size.height, W = size.width;
    CGFloat dotD = H * 0.012, gap = H * 0.0095, padX = W * 0.028, padY = H * 0.013;
    CGFloat bw = padX * 2 + dotD * 3 + gap * 2;
    CGFloat bh = padY * 2 + dotD;
    CGRect bubble = CGRectMake(W * 0.035, y, bw, bh);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    if (age >= 0 && age < 0.25) {
        CGContextSetAlpha(ctx, (CGFloat)(age / 0.25));
        CGContextTranslateCTM(ctx, 0, (1 - age / 0.25) * H * 0.008);
    }
    [fill setFill];
    [bubblePath(bubble, NO, MIN(bh * 0.5, W * 0.048)) fill];
    CGFloat cy = y + bh / 2;
    for (int i = 0; i < 3; i++) {
        CGFloat alpha, lift = 0;
        if (age >= 0) {
            double wave = sin(age * 4.4 - i * 0.55);
            alpha = 0.35 + 0.45 * (CGFloat)MAX(0, wave);
            lift = (CGFloat)MAX(0, wave) * H * 0.0035;
        } else {
            alpha = 0.85 - i * 0.25;
        }
        [[dotBase colorWithAlphaComponent:alpha] setFill];
        CGFloat cx = bubble.origin.x + padX + dotD / 2 + i * (dotD + gap);
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx - dotD / 2, cy - lift - dotD / 2, dotD, dotD)] fill];
    }
    CGContextRestoreGState(ctx);
    return y + bh;
}

// The contact's face at the top of the conversation: the cover, round.
static void drawAvatar(UIImage *cover, CGFloat centerX, CGFloat top, CGFloat d, BOOL dark) {
    CGRect rect = CGRectMake(centerX - d / 2, top, d, d);
    if (!cover) {
        [[UIColor colorWithWhite:dark ? 0.30 : 0.78 alpha:1] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:rect] fill];
        drawCenteredAt(@"♪", rect, [UIFont systemFontOfSize:d * 0.52 weight:UIFontWeightSemibold],
                       UIColor.whiteColor);
        return;
    }
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    [[UIBezierPath bezierPathWithOvalInRect:rect] addClip];
    CGContextTranslateCTM(ctx, rect.origin.x, rect.origin.y);
    drawCoverFilled(cover, rect.size);
    CGContextRestoreGState(ctx);
}

// The bar the message was typed into, pinned to the floor of the card:
// a camera at the left, the pill field with its placeholder, and the
// blue send arrow. It does no work; it just makes the room a room.
static void drawComposeBar(CGSize size, BOOL dark) {
    CGFloat W = size.width, H = size.height;
    CGFloat barH = H * 0.078;
    CGFloat top = H - barH;
    [[UIColor colorWithWhite:dark ? 1 : 0 alpha:dark ? 0.22 : 0.20] setFill];
    UIRectFill(CGRectMake(0, top, W, MAX(1, H * 0.0014)));
    [dark ? UIColor.blackColor : UIColor.whiteColor setFill];
    UIRectFill(CGRectMake(0, top, W, barH));
    CGFloat midY = top + barH / 2;
    CGFloat camH = H * 0.024, camW = camH * 1.3;
    CGRect cam = CGRectMake(W * 0.045, midY - camH / 2, camW, camH);
    [[UIColor colorWithWhite:dark ? 0.32 : 0.60 alpha:1] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:cam cornerRadius:camH * 0.30] fill];
    [dark ? UIColor.blackColor : UIColor.whiteColor setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(cam, camW * 0.36, camH * 0.24)] fill];
    CGFloat fieldX = CGRectGetMaxX(cam) + W * 0.028;
    CGFloat fieldH = H * 0.044;
    CGRect field = CGRectMake(fieldX, midY - fieldH / 2, W * 0.955 - fieldX, fieldH);
    UIBezierPath *pill = [UIBezierPath bezierPathWithRoundedRect:field cornerRadius:fieldH / 2];
    [[UIColor colorWithWhite:dark ? 0.30 : 0.78 alpha:1] setStroke];
    pill.lineWidth = MAX(1, H * 0.0016);
    [pill stroke];
    [@"iMessage" drawInRect:CGRectMake(field.origin.x + W * 0.030, midY - H * 0.0125,
                                       field.size.width * 0.55, H * 0.025)
            withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:H * 0.019],
                             NSForegroundColorAttributeName:
                                 [UIColor colorWithWhite:dark ? 0.45 : 0.70 alpha:1]}];
    CGFloat sd = fieldH * 0.80;
    CGRect disc = CGRectMake(CGRectGetMaxX(field) - sd - H * 0.004, midY - sd / 2, sd, sd);
    [[UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:disc] fill];
    drawCenteredAt(@"↑", disc, [UIFont systemFontOfSize:sd * 0.58 weight:UIFontWeightBold],
                   UIColor.whiteColor);
}

// The Chat, rebuilt as the room it is named after (Batch 97): iMessage,
// in the light room or the dark one (Chat theme in the settings). The
// song is the contact (its cover for a face, its name under it), the
// timestamp divider sits under the header, what was sung arrives from
// the left, and the line being sung is sent from the right in the blue
// gradient with the karaoke sweep inside it.
//
// And it behaves like texting someone the lyrics: the next line is
// never on screen early. While the second half of the current line
// plays, the other side is typing — three dots in a bubble — and when
// the song moves on, that line pops in from its corner like a message
// arriving, instead of simply being there.
static UIImage *drawChatArtwork(CGSize size, NSString *prev, NSString *current, NSString *next,
                                UIImage *cover, SGKaraokeLine *line, NSString *title, NSString *artist) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat W = size.width, H = size.height;
        NSInteger theme = SGInt(SGKeyLyricArtworkChatTheme, 0);
        BOOL dark = theme == 1 || (theme == 2 &&
            UIScreen.mainScreen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
        UIColor *ink = dark ? UIColor.whiteColor
                            : [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1];
        UIColor *grey = dark ? [UIColor colorWithWhite:0.62 alpha:1]
                             : [UIColor colorWithRed:0.56 green:0.56 blue:0.58 alpha:1];
        UIColor *hair = dark ? [UIColor colorWithWhite:1 alpha:0.14]
                             : [UIColor colorWithRed:0.90 green:0.90 blue:0.92 alpha:1];
        UIColor *inFill = dark ? [UIColor colorWithRed:0.149 green:0.145 blue:0.165 alpha:1]
                               : [UIColor colorWithRed:0.898 green:0.898 blue:0.918 alpha:1];
        UIColor *inInk = dark ? UIColor.whiteColor : ink;
        UIColor *dotBase = dark ? [UIColor colorWithWhite:0.80 alpha:1]
                                : [UIColor colorWithWhite:0.52 alpha:1];
        [dark ? UIColor.blackColor : UIColor.whiteColor setFill];
        UIRectFill(CGRectMake(0, 0, W, H));
        CGFloat y = H * 0.030;
        [@"‹" drawInRect:CGRectMake(W * 0.030, y - H * 0.006, W * 0.10, H * 0.05)
          withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:H * 0.052
                                                                 weight:UIFontWeightLight],
                           NSForegroundColorAttributeName:
                               [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1]}];
        CGFloat d = W * 0.115;
        drawAvatar(cover, W / 2, y, d, dark);
        y += d + H * 0.007;
        y = drawCentered(title.length ? title : @"♪", y, H, size,
                         [UIFont systemFontOfSize:H * 0.0215 weight:UIFontWeightSemibold], ink);
        if (artist.length) {
            y = drawCentered([artist stringByAppendingString:@" ›"], y, H, size,
                             [UIFont systemFontOfSize:H * 0.0165], grey);
        }
        y += H * 0.014;
        [hair setFill];
        UIRectFill(CGRectMake(0, y, W, MAX(1, H * 0.0014)));
        y += H * 0.020;
        y = drawCentered(@"iMessage", y, H, size,
                         [UIFont systemFontOfSize:H * 0.0145 weight:UIFontWeightSemibold], grey);
        NSString *stamp = [@"Today " stringByAppendingString:
            [NSDateFormatter localizedStringFromDate:NSDate.date
                                           dateStyle:NSDateFormatterNoStyle
                                           timeStyle:NSDateFormatterShortStyle]];
        y = drawCentered(stamp, y, H, size, [UIFont systemFontOfSize:H * 0.0145], grey);
        y += H * 0.022;
        // Where this line stands: the second half of it is when the
        // other side starts typing the reply.
        double fraction = 0, typingAge = -1;
        if (line) {
            double dur = (line.end - line.start) / 1000.0;
            if (sg_frameTime >= 0) {
                fraction = dur > 0 ? MIN(1, sg_frameTime / dur) : 1;
                typingAge = sg_frameTime - 0.5 * dur;
            } else {
                NSInteger pos = SGKaraokePositionMs();
                fraction = (dur > 0 && pos >= line.start)
                    ? MIN(1, (pos - line.start) / 1000.0 / dur) : 0;
            }
        }
        BOOL showTyping = next.length && (line ? fraction >= 0.5 : YES);
        UIFont *font = [UIFont systemFontOfSize:H * 0.030];
        NSAttributedString *pastAttr = [[NSAttributedString alloc]
            initWithString:prev ?: @"" attributes:@{NSFontAttributeName: font,
                                                    NSForegroundColorAttributeName: inInk}];
        y = drawBubble(pastAttr, prev, y, size, NO, font, inFill, -1);
        if (prev.length) y += H * 0.014;
        NSAttributedString *nowAttr = [current isEqualToString:@"♪"]
            ? [[NSAttributedString alloc] initWithString:current
                attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.whiteColor}]
            : sungLine(line, current, font, UIColor.whiteColor,
                       [UIColor colorWithWhite:1 alpha:0.55]);
        y = drawBubble(nowAttr, current, y, size, YES, font, inFill, sg_frameTime);
        y += H * 0.005;
        NSString *delivered = @"Delivered";
        UIFont *deliveredFont = [UIFont systemFontOfSize:H * 0.0135];
        CGSize dSize = [delivered sizeWithAttributes:@{NSFontAttributeName: deliveredFont}];
        [delivered drawInRect:CGRectMake(W * 0.965 - dSize.width, y, dSize.width, dSize.height)
               withAttributes:@{NSFontAttributeName: deliveredFont,
                                NSForegroundColorAttributeName: grey}];
        y += dSize.height + H * 0.014;
        if (showTyping && y < H * 0.86) {
            drawTypingBubble(y, size, inFill, dotBase,
                             (line && sg_frameTime >= 0) ? typingAge : -1);
        }
        drawComposeBar(size, dark);
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

#pragma mark - the Workshop set (Batch 7)

// Original renderers for the style families the chroma.pw Workshop shows, written
// against their public previews: the names and the layouts are the spec, the code
// is this file's. Each draws into the current renderer context from one context
// struct, so a style is a function, not a fork of the whole.

typedef struct {
    CGSize size;
    __unsafe_unretained NSString *prev, *current, *next, *title, *artist;
    __unsafe_unretained UIImage *cover;
    __unsafe_unretained SGKaraokeLine *line;
    NSInteger index, count, prevStart, nextStart;
    double duration;
    __unsafe_unretained UIColor *average, *accent;
} SGWCtx;

static NSString *fmtClock(NSInteger ms) {
    if (ms < 0) ms = 0;
    NSInteger s = ms / 1000;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(s / 60), (long)(s % 60)];
}

static UIFont *monoFont(CGFloat size, UIFontWeight weight) {
    return [UIFont monospacedSystemFontOfSize:size weight:weight];
}

static UIFont *serifFont(CGFloat size, UIFontWeight weight, BOOL italic) {
    UIFontDescriptor *descriptor = [[UIFont systemFontOfSize:size weight:weight] fontDescriptor];
    descriptor = [descriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignSerif];
    if (italic) descriptor = [descriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic];
    return [UIFont fontWithDescriptor:descriptor size:size];
}

static uint64_t sg_randState;
static void seedRand(NSString *key) {
    sg_randState = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < key.length; i++) {
        sg_randState ^= [key characterAtIndex:i];
        sg_randState *= 1099511628211ULL;
    }
    if (!sg_randState) sg_randState = 88172645463325252ULL;
}
static double nextRand(void) {
    sg_randState ^= sg_randState << 13;
    sg_randState ^= sg_randState >> 7;
    sg_randState ^= sg_randState << 17;
    return (sg_randState >> 11) / 9007199254740992.0;
}

static void drawText(NSString *text, CGRect rect, UIFont *font, UIColor *color, NSTextAlignment align) {
    if (!text.length) return;
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = align;
    [text drawInRect:rect withAttributes:@{NSFontAttributeName: font,
                                           NSForegroundColorAttributeName: color,
                                           NSParagraphStyleAttributeName: paragraph}];
}

static CGFloat textHeight(NSString *text, UIFont *font, CGFloat width) {
    if (!text.length) return 0;
    return ceil([text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin
                                 attributes:@{NSFontAttributeName: font} context:nil].size.height);
}

static void fillRect(CGRect rect, UIColor *color) {
    [color setFill];
    UIRectFill(rect);
}

static UIImage *ciResult(UIImage *image, CIFilter *filter) {
    if (!image.CGImage || !filter) return nil;
    CIImage *output = filter.outputImage;
    if (!output) return nil;
    CGImageRef cg = [ciContext() createCGImage:output
                                      fromRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIImage *result = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    return result;
}

static UIImage *knockoutImage(CGSize size, void (^drawMask)(void)) {
    // An opaque black image with the mask's shapes cut out of it: drawn over
    // something else, only the shapes let it through. All inside UIKit contexts,
    // so nothing arrives flipped the way a raw Quartz mask would.
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *maskContext) {
        fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
        CGContextSetBlendMode(maskContext.CGContext, kCGBlendModeDestinationOut);
        drawMask();
    }];
}

// The words of a line stacked one per row, each as large as the frame allows:
// the Cover in letters and Gig poster layouts share the stacking.
static CGFloat stackedFontSize(NSArray<NSString *> *words, CGSize size, CGFloat target) {
    CGFloat fontSize = size.height * 0.17;
    UIFont *font = [UIFont boldSystemFontOfSize:fontSize];
    CGFloat widest = 0;
    for (NSString *word in words) widest = MAX(widest, [word sizeWithAttributes:@{NSFontAttributeName: font}].width);
    if (widest > 0) fontSize *= (size.width * target) / widest;
    return MIN(fontSize, size.height * 0.20);
}

static void drawStackedWords(NSArray<NSString *> *words, CGFloat fontSize, CGFloat y, CGSize size,
                             BOOL centered, UIColor *color) {
    UIFont *font = [UIFont boldSystemFontOfSize:fontSize];
    CGFloat x = centered ? 0 : size.width * 0.07;
    CGFloat width = centered ? size.width : size.width * 0.86;
    for (NSString *word in words) {
        drawText(word, CGRectMake(x, y, width, fontSize * 1.2), font, color,
                 centered ? NSTextAlignmentCenter : NSTextAlignmentLeft);
        y += fontSize * 0.94;
    }
}

// A small round avatar of the cover at (x, y), d wide.
static void drawRoundAvatar(SGWCtx *c, CGFloat x, CGFloat y, CGFloat d) {
    if (!c->cover) {
        [[UIColor colorWithWhite:1 alpha:0.15] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(x, y, d, d)] fill];
        return;
    }
    CGContextSaveGState(UIGraphicsGetCurrentContext());
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(x, y, d, d)] addClip];
    drawCoverInRect(c->cover, CGRectMake(x, y, d, d));
    CGContextRestoreGState(UIGraphicsGetCurrentContext());
}

// The verified tick: a small blue disc with a check, after a name.
static void drawVerifiedTick(CGFloat x, CGFloat y, CGFloat d) {
    CGRect tick = CGRectMake(x, y, d, d);
    [[UIColor colorWithRed:0.11 green:0.61 blue:0.94 alpha:1] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:tick] fill];
    drawText(@"✓", CGRectInset(tick, 1, -1), [UIFont boldSystemFontOfSize:d * 0.72],
             UIColor.whiteColor, NSTextAlignmentCenter);
}

// Twitter, rebuilt as a thread (Batch 97): the previous line is its own
// smaller post above, joined to this one by the thread line real threads
// draw between avatars; the line being sung is the main post; views get
// their own row with the number bold; and the action row is four evenly
// spaced stroke icons with grey counts — no emoji at mismatched sizes,
// and the composition runs to a reply pill at the foot instead of dying
// at half height over a black void.
static void drawTwitter(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    UIColor *grey = [UIColor colorWithWhite:1 alpha:0.45];
    drawText(@"Post", CGRectMake(0, size.height * 0.045, size.width, size.height * 0.03),
             [UIFont boldSystemFontOfSize:size.height * 0.024], UIColor.whiteColor, NSTextAlignmentCenter);
    // The "···" affordance, top right: three small filled circles.
    CGFloat dotD = size.height * 0.006, dotY = size.height * 0.056;
    [[UIColor colorWithWhite:1 alpha:0.55] setFill];
    for (int i = 0; i < 3; i++) {
        CGFloat dx = size.width * 0.90 + i * size.height * 0.016;
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(dx, dotY, dotD, dotD)] fill];
    }
    NSString *handle = [[c->artist.lowercaseString componentsSeparatedByCharactersInSet:
        [[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
    if (!handle.length) handle = @"artist";
    CGFloat y = size.height * 0.115;
    // The earlier post in the thread: smaller, one size down in every way.
    if (c->prev.length) {
        CGFloat small = size.width * 0.072;
        drawRoundAvatar(c, margin, y, small);
        CGFloat tx = margin + small + size.width * 0.025;
        UIFont *miniName = [UIFont boldSystemFontOfSize:size.height * 0.019];
        drawText(c->artist, CGRectMake(tx, y - size.height * 0.002, width - small, size.height * 0.026),
                 miniName, UIColor.whiteColor, NSTextAlignmentLeft);
        CGFloat nameW = [c->artist sizeWithAttributes:@{NSFontAttributeName: miniName}].width;
        drawVerifiedTick(tx + nameW + 5, y + size.height * 0.002, size.height * 0.016);
        drawText([NSString stringWithFormat:@"@%@ · 2h", handle],
                 CGRectMake(tx + nameW + size.height * 0.026, y - size.height * 0.002, width, size.height * 0.026),
                 [UIFont systemFontOfSize:size.height * 0.018], grey, NSTextAlignmentLeft);
        UIFont *miniFont = [UIFont systemFontOfSize:size.height * 0.021];
        CGFloat miniH = textHeight(c->prev, miniFont, width - small - size.width * 0.025);
        drawText(c->prev, CGRectMake(tx, y + size.height * 0.026, width - small - size.width * 0.025, miniH + 4),
                 miniFont, [UIColor colorWithWhite:1 alpha:0.88], NSTextAlignmentLeft);
        CGFloat miniBottom = y + size.height * 0.026 + miniH + size.height * 0.016;
        // The thread line, avatar centre to avatar centre.
        fillRect(CGRectMake(margin + small / 2 - 1, y + small + 3, 2, miniBottom - y - small - 6),
                 [UIColor colorWithWhite:1 alpha:0.25]);
        y = miniBottom;
    }
    // The main post.
    CGFloat avatar = size.width * 0.105;
    drawRoundAvatar(c, margin, y, avatar);
    CGFloat textX = margin + avatar + size.width * 0.03;
    UIFont *nameFont = [UIFont boldSystemFontOfSize:size.height * 0.023];
    drawText(c->artist, CGRectMake(textX, y, width - avatar, size.height * 0.03),
             nameFont, UIColor.whiteColor, NSTextAlignmentLeft);
    CGFloat nameWidth = [c->artist sizeWithAttributes:@{NSFontAttributeName: nameFont}].width;
    drawVerifiedTick(textX + nameWidth + 6, y + size.height * 0.004, size.height * 0.02);
    drawText([NSString stringWithFormat:@"@%@", handle],
             CGRectMake(textX, y + size.height * 0.028, width - avatar, size.height * 0.025),
             [UIFont systemFontOfSize:size.height * 0.019], grey, NSTextAlignmentLeft);
    y += avatar + size.height * 0.018;
    UIFont *postFont = [UIFont boldSystemFontOfSize:size.height * 0.037];
    CGFloat postH = textHeight(c->current, postFont, width);
    drawText(c->current, CGRectMake(margin, y, width, postH + 4), postFont, UIColor.whiteColor,
             NSTextAlignmentLeft);
    y += postH + size.height * 0.028;
    NSDateFormatter *clock = [NSDateFormatter new];
    clock.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    clock.dateFormat = @"h:mm a";
    NSDateFormatter *day = [NSDateFormatter new];
    day.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    day.dateFormat = @"MMMM d, yyyy";
    NSDate *now = [NSDate date];
    seedRand(c->title);
    drawText([NSString stringWithFormat:@"%@ · %@", [clock stringFromDate:now], [day stringFromDate:now]],
             CGRectMake(margin, y, width, size.height * 0.025),
             [UIFont systemFontOfSize:size.height * 0.018], grey, NSTextAlignmentLeft);
    y += size.height * 0.030;
    // Views on their own row: the number bold white, the word grey.
    NSInteger views = 12 + (NSInteger)(nextRand() * 880) + (sg_frameTime >= 0 ? (NSInteger)(sg_frameTime * 2.5) : 0);
    NSMutableAttributedString *viewsLine = [[NSMutableAttributedString alloc] init];
    [viewsLine appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%ldK", (long)views]
            attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:size.height * 0.018],
                         NSForegroundColorAttributeName: UIColor.whiteColor}]];
    [viewsLine appendAttributedString:[[NSAttributedString alloc]
        initWithString:@" Views"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:size.height * 0.018],
                         NSForegroundColorAttributeName: grey}]];
    [viewsLine drawInRect:CGRectMake(margin, y, width, size.height * 0.025)];
    y += size.height * 0.032;
    fillRect(CGRectMake(margin, y, width, 1), [UIColor colorWithWhite:1 alpha:0.15]);
    y += size.height * 0.020;
    // The action row: four stroke icons, evenly spread, counts in grey.
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    [[UIColor colorWithWhite:1 alpha:0.5] setStroke];
    [[UIColor colorWithWhite:1 alpha:0.5] setFill];
    CGFloat icon = size.height * 0.024, slot = width / 4;
    UIFont *countFont = [UIFont systemFontOfSize:size.height * 0.018];
    NSArray<NSString *> *counts = @[[NSString stringWithFormat:@"%ld", (long)(40 + (NSInteger)(nextRand() * 400))],
                                    [NSString stringWithFormat:@"%ld", (long)(80 + (NSInteger)(nextRand() * 900))],
                                    [NSString stringWithFormat:@"%.1fK", 1 + nextRand() * 9],
                                    [NSString stringWithFormat:@"%ld", (long)(5 + (NSInteger)(nextRand() * 60))]];
    for (NSInteger i = 0; i < 4; i++) {
        CGFloat ix = margin + slot * i, iy = y;
        UIBezierPath *iconPath = [UIBezierPath bezierPath];
        if (i == 0) {            // reply: a speech balloon with a tail
            CGRect b = CGRectMake(ix, iy, icon * 1.15, icon * 0.88);
            [iconPath appendPath:[UIBezierPath bezierPathWithRoundedRect:b cornerRadius:icon * 0.3]];
            [iconPath moveToPoint:CGPointMake(ix + icon * 0.28, iy + icon * 0.88)];
            [iconPath addLineToPoint:CGPointMake(ix + icon * 0.28, iy + icon * 1.12)];
            [iconPath addLineToPoint:CGPointMake(ix + icon * 0.55, iy + icon * 0.88)];
        } else if (i == 1) {     // retweet: two bent arrows chasing
            [iconPath moveToPoint:CGPointMake(ix + icon * 0.15, iy + icon * 0.30)];
            [iconPath addLineToPoint:CGPointMake(ix + icon * 0.85, iy + icon * 0.30)];
            [iconPath addLineToPoint:CGPointMake(ix + icon * 0.85, iy + icon * 0.62)];
            [iconPath moveToPoint:CGPointMake(ix + icon * 0.66, iy + icon * 0.10)];
            [iconPath addLineToPoint:CGPointMake(ix + icon * 0.88, iy + icon * 0.30)];
            [iconPath addLineToPoint:CGPointMake(ix + icon * 0.66, iy + icon * 0.50)];
            [iconPath moveToPoint:CGPointMake(ix + icon * 0.85, iy + icon * 0.78)];
            [iconPath addLineToPoint:CGPointMake(ix + icon * 0.15, iy + icon * 0.78)];
            [iconPath addLineToPoint:CGPointMake(ix + icon * 0.15, iy + icon * 0.46)];
            [iconPath moveToPoint:CGPointMake(ix + icon * 0.34, iy + icon * 0.98)];
            [iconPath addLineToPoint:CGPointMake(ix + icon * 0.12, iy + icon * 0.78)];
            [iconPath addLineToPoint:CGPointMake(ix + icon * 0.34, iy + icon * 0.58)];
        } else if (i == 2) {     // heart
            CGFloat hx = ix + icon * 0.55, hy = iy + icon * 0.16, r = icon * 0.30;
            [iconPath moveToPoint:CGPointMake(hx, iy + icon * 0.98)];
            [iconPath addCurveToPoint:CGPointMake(hx - r * 2, hy + r * 0.6)
                        controlPoint1:CGPointMake(hx - r * 1.6, iy + icon * 0.55)
                        controlPoint2:CGPointMake(hx - r * 1.9, hy - r * 0.5)];
            [iconPath addCurveToPoint:CGPointMake(hx, hy + r * 0.55)
                        controlPoint1:CGPointMake(hx - r * 0.7, hy - r * 0.75)
                        controlPoint2:CGPointMake(hx, hy - r * 0.1)];
            [iconPath addCurveToPoint:CGPointMake(hx + r * 2, hy + r * 0.6)
                        controlPoint1:CGPointMake(hx, hy - r * 0.1)
                        controlPoint2:CGPointMake(hx + r * 0.7, hy - r * 0.75)];
            [iconPath addCurveToPoint:CGPointMake(hx, iy + icon * 0.98)
                        controlPoint1:CGPointMake(hx + r * 1.9, hy - r * 0.5)
                        controlPoint2:CGPointMake(hx + r * 1.6, iy + icon * 0.55)];
        } else {                 // views: three bars, rising
            for (int b = 0; b < 3; b++) {
                CGFloat bh = icon * (0.45 + 0.27 * b);
                CGRect bar = CGRectMake(ix + icon * 0.16 + b * icon * 0.34, iy + icon - bh, icon * 0.20, bh);
                [iconPath appendPath:[UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:icon * 0.06]];
            }
            [iconPath fill];
        }
        if (i != 3) { iconPath.lineWidth = MAX(1.2, size.height * 0.0016); [iconPath stroke]; }
        drawText(counts[i], CGRectMake(ix + icon * 1.35, y + size.height * 0.002, slot - icon * 1.4, size.height * 0.025),
                 countFont, grey, NSTextAlignmentLeft);
    }
    CGContextRestoreGState(ctx);
    y += size.height * 0.052;
    fillRect(CGRectMake(margin, y, width, 1), [UIColor colorWithWhite:1 alpha:0.15]);
    // The reply pill closes the card.
    CGFloat pillY = size.height * 0.885;
    UIBezierPath *pill = [UIBezierPath bezierPathWithRoundedRect:
        CGRectMake(margin, pillY, width, size.height * 0.052) cornerRadius:size.height * 0.026];
    [[UIColor colorWithWhite:1 alpha:0.35] setStroke];
    pill.lineWidth = 1;
    [pill stroke];
    drawRoundAvatar(c, margin + size.width * 0.018, pillY + size.height * 0.009, size.height * 0.034);
    drawText(@"Post your reply…", CGRectMake(margin + size.width * 0.075, pillY + size.height * 0.014,
                                             width * 0.7, size.height * 0.028),
             [UIFont systemFontOfSize:size.height * 0.019], grey, NSTextAlignmentLeft);
}

// Cover in letters: the line enormous and stacked, the cover showing through
// the letterforms and fading as it falls.
static void drawCoverInLetters(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    NSArray<NSString *> *words = [c->current.uppercaseString
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (!words.count) words = @[@"♪"];
    CGFloat fontSize = stackedFontSize(words, size, 0.88);
    // Fit the stack to the height too, not just the width (Batch 97):
    // a long line used to be able to stack clean off the card.
    while (words.count * fontSize * 0.94 > size.height * 0.78 && fontSize > size.height * 0.04) {
        fontSize *= 0.94;
    }
    UIImage *mask = knockoutImage(size, ^{
        drawStackedWords(words, fontSize, size.height * 0.05, size, YES, UIColor.whiteColor);
    });
    if (c->cover) {
        // Outside the letters, the cover sits dim under a gathering
        // scrim; inside them it burns at full strength (Batch 97: the
        // scrim used to be laid over the whole cover BEFORE the letters
        // cut in, so the letters revealed a pre-darkened photo and the
        // poster read as dim text on a dark picture).
        if (sg_frameTime >= 0) drawCoverInRect(c->cover, breathingRect(CGRectMake(0, 0, size.width, size.height), size.width * 0.03, size.width * 0.008));
        else drawCoverFilled(c->cover, size);
        drawScrim(size, 0.35, 0.80);
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = 1;
        format.opaque = NO;
        UIImage *coverImage = c->cover;
        UIImage *letters = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
            imageWithActions:^(UIGraphicsImageRendererContext *letterContext) {
            if (sg_frameTime >= 0) drawCoverInRect(coverImage, breathingRect(CGRectMake(0, 0, size.width, size.height), size.width * 0.03, size.width * 0.008));
            else drawCoverFilled(coverImage, size);
            [mask drawInRect:CGRectMake(0, 0, size.width, size.height)];
        }];
        [letters drawInRect:CGRectMake(0, 0, size.width, size.height)];
    } else {
        [mask drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }
    CGFloat creditY = size.height * 0.05 + fontSize * 0.94 * words.count + size.height * 0.03;
    NSString *credit = [NSString stringWithFormat:@"%@ — %@", c->title.uppercaseString, c->artist.uppercaseString];
    drawText(credit, CGRectMake(0, MIN(creditY, size.height * 0.88), size.width, size.height * 0.025),
             [UIFont systemFontOfSize:size.height * 0.017 weight:UIFontWeightMedium],
             [UIColor colorWithWhite:1 alpha:0.75], NSTextAlignmentCenter);
}

// Magazine: the song as a glossy cover — masthead, cover lines, the lyric as
// the headline and its translation as the standfirst.
static void drawMagazine(SGWCtx *c) {
    CGSize size = c->size;
    if (c->cover) {
        if (sg_frameTime >= 0) drawCoverInRect(c->cover, breathingRect(CGRectMake(0, 0, size.width, size.height), size.width * 0.025, size.width * 0.006));
        else drawCoverFilled(c->cover, size);
    }
    else fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0.1 alpha:1]);
    drawScrim(size, 0.35, 0.45);
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    CGFloat y = size.height * 0.045;
    drawText(c->artist.uppercaseString, CGRectMake(margin, y, width, size.height * 0.06),
             serifFont(size.height * 0.048, UIFontWeightBold, NO), UIColor.whiteColor, NSTextAlignmentCenter);
    y += size.height * 0.065;
    NSDateFormatter *month = [NSDateFormatter new];
    month.dateFormat = @"MMMM yyyy";
    // The furniture line, split the way covers split it (Batch 97):
    // the date at the left edge, the issue number at the right.
    UIFont *furniture = [UIFont systemFontOfSize:size.height * 0.013 weight:UIFontWeightSemibold];
    UIColor *furnitureInk = [UIColor colorWithWhite:1 alpha:0.85];
    drawText([[month stringFromDate:[NSDate date]] uppercaseString],
             CGRectMake(margin, y, width, size.height * 0.02), furniture, furnitureInk, NSTextAlignmentLeft);
    drawText([NSString stringWithFormat:@"Nº %ld", (long)(c->index + 1)],
             CGRectMake(margin, y, width, size.height * 0.02), furniture, furnitureInk, NSTextAlignmentRight);
    if (c->prev.length) {
        // A cover line with the classic colour block behind it.
        UIFont *teaser = serifFont(size.height * 0.019, UIFontWeightRegular, YES);
        CGFloat teaserH = textHeight(c->prev, teaser, width * 0.55);
        CGRect block = CGRectMake(margin - size.width * 0.012, size.height * 0.295,
                                  MIN(width * 0.58, [c->prev sizeWithAttributes:@{NSFontAttributeName: teaser}].width + size.width * 0.024),
                                  teaserH + size.height * 0.016);
        fillRect(block, c->accent ?: [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1]);
        drawText(c->prev, CGRectMake(margin, size.height * 0.30, width * 0.55, size.height * 0.08),
                 teaser, [UIColor colorWithWhite:0.05 alpha:1], NSTextAlignmentLeft);
    }
    // A second cover line down the right edge: the song's name, shouted
    // in bold sans in the accent — covers mix their treatments.
    if (c->title.length) {
        drawText(c->title.uppercaseString, CGRectMake(margin, size.height * 0.30, width, size.height * 0.03),
                 [UIFont boldSystemFontOfSize:size.height * 0.020],
                 c->accent ?: [UIColor colorWithWhite:1 alpha:0.9], NSTextAlignmentRight);
    }
    UIFont *headline = serifFont(size.height * 0.048, UIFontWeightBold, NO);
    CGFloat headlineY = size.height * 0.46;
    drawText(c->current, CGRectMake(margin, headlineY, width, size.height * 0.17), headline, UIColor.whiteColor, NSTextAlignmentLeft);
    CGFloat y2 = headlineY + textHeight(c->current, headline, width) + size.height * 0.012;
    if (c->line.translation.length) {
        drawText(c->line.translation, CGRectMake(margin, y2, width, size.height * 0.05),
                 serifFont(size.height * 0.020, UIFontWeightRegular, YES),
                 [UIColor colorWithWhite:1 alpha:0.85], NSTextAlignmentLeft);
    }
    if (c->next.length) {
        drawText(c->next, CGRectMake(margin, size.height * 0.90, width, size.height * 0.03),
                 serifFont(size.height * 0.016, UIFontWeightRegular, YES),
                 [UIColor colorWithWhite:1 alpha:0.75], NSTextAlignmentRight);
    }
    // The barcode, bottom-left — the most recognisable object on any
    // real cover (Batch 97): white block, seeded bars, the small print.
    CGRect barcode = CGRectMake(margin, size.height * 0.885, size.width * 0.17, size.height * 0.072);
    fillRect(barcode, UIColor.whiteColor);
    seedRand(c->title);
    CGFloat bx = barcode.origin.x + size.width * 0.008;
    while (bx < CGRectGetMaxX(barcode) - size.width * 0.008) {
        CGFloat bw = 1 + nextRand() * 3;
        if (nextRand() > 0.35) {
            fillRect(CGRectMake(bx, barcode.origin.y + size.height * 0.006, bw, size.height * 0.042),
                     [UIColor colorWithWhite:0.05 alpha:1]);
        }
        bx += bw + 1 + nextRand() * 2;
    }
    drawText([NSString stringWithFormat:@"£%.2f · Nº %ld", 5 + nextRand() * 8, (long)(c->index + 1)],
             CGRectMake(barcode.origin.x, barcode.origin.y + size.height * 0.050, barcode.size.width, size.height * 0.018),
             monoFont(size.height * 0.0105, UIFontWeightRegular), [UIColor colorWithWhite:0.10 alpha:1],
             NSTextAlignmentCenter);
}

// Duotone: the cover in two tones of its own — its darkest colour and its
// lightest — with the lines kept low and quiet.
static void drawDuotone(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    UIColor *inkBand = nil;
    if (c->cover) {
        // Two inks, printed properly (Batch 97): shadows in the dark ink,
        // highlights landing on PAPER — the accent blended most of the
        // way to white — with a mid mix between them. The accent used to
        // be the highlight itself, which solarised everything candy.
        UIColor *dark = [UIColor colorWithWhite:0.04 alpha:1];
        UIColor *base = c->accent ?: [UIColor colorWithRed:0.95 green:0.75 blue:0.35 alpha:1];
        CGFloat pr, pg, pb, pa;
        [base getRed:&pr green:&pg blue:&pb alpha:&pa];
        UIColor *light = [UIColor colorWithRed:pr + (1 - pr) * 0.82 green:pg + (1 - pg) * 0.82
                                          blue:pb + (1 - pb) * 0.82 alpha:1];
        UIColor *mid = [UIColor colorWithRed:pr + (1 - pr) * 0.38 green:pg + (1 - pg) * 0.38
                                        blue:pb + (1 - pb) * 0.38 alpha:1];
        if (c->average) {
            CGFloat h = 0, s = 0, b = 0;
            [c->average getHue:&h saturation:&s brightness:&b alpha:NULL];
            dark = [UIColor colorWithHue:h saturation:MIN(0.75, s + 0.2) brightness:0.16 alpha:1];
        }
        inkBand = dark;
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = 1;
        format.opaque = YES;
        UIImage *strip = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(256, 1) format:format]
            imageWithActions:^(UIGraphicsImageRendererContext *stripContext) {
            CGContextRef ctx = stripContext.CGContext;
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            NSArray *colors = @[(id)dark.CGColor, (id)mid.CGColor, (id)light.CGColor];
            CGFloat stops[] = {0, 0.55, 1};
            CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, stops);
            CGContextDrawLinearGradient(ctx, gradient, CGPointZero, CGPointMake(256, 0), 0);
            CGGradientRelease(gradient);
            CGColorSpaceRelease(space);
        }];
        CIFilter *map = [CIFilter filterWithName:@"CIColorMap"];
        [map setValue:[CIImage imageWithCGImage:c->cover.CGImage] forKey:kCIInputImageKey];
        [map setValue:[CIImage imageWithCGImage:strip.CGImage] forKey:@"inputGradientImage"];
        UIImage *toned = ciResult(c->cover, map);
        if (sg_frameTime >= 0) {
            drawCoverInRect(toned ?: c->cover, breathingRect(CGRectMake(0, 0, size.width, size.height), size.width * 0.02, size.width * 0.012));
        } else if (toned) drawCoverFilled(toned, size);
        else drawCoverFilled(c->cover, size);
    }
    // The words sit on a solid band of the ink — a printed caption band,
    // which guarantees they read over any photograph (Batch 97).
    if (inkBand) {
        fillRect(CGRectMake(0, size.height * 0.78, size.width, size.height * 0.22),
                 [inkBand colorWithAlphaComponent:0.92]);
    } else {
        drawScrim(size, 0.0, 0.35);
    }
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    UIFont *nowFont = [UIFont boldSystemFontOfSize:size.height * 0.034];
    CGFloat y = size.height * 0.805;
    drawText(c->current, CGRectMake(margin, y, width, size.height * 0.10), nowFont, UIColor.whiteColor, NSTextAlignmentLeft);
    y += textHeight(c->current, nowFont, width) + size.height * 0.01;
    drawText(c->next, CGRectMake(margin, y, width, size.height * 0.05),
             [UIFont systemFontOfSize:size.height * 0.022], [UIColor colorWithWhite:1 alpha:0.55], NSTextAlignmentLeft);
}

// Word collage: the song's words as ransom-note strips over red, the line
// itself set plain in a grey panel in the middle. The chaos is seeded by the
// song, so a given line always lands the same way.
// One cut-paper strip: a word on its own scrap, in one of the collage's
// typefaces, at its own angle, lifted off the board by its shadow.
static void drawStrip(SGWCtx *c, NSString *word, CGFloat fontSize, NSInteger variant,
                      CGPoint centre, CGFloat angle, BOOL hero) {
    CGSize size = c->size;
    UIFont *font;
    switch (variant % 5) {
        case 0: font = [UIFont boldSystemFontOfSize:fontSize]; break;
        case 1: font = serifFont(fontSize, UIFontWeightBold, NO); break;
        case 2: font = monoFont(fontSize, UIFontWeightBold); break;
        case 3: font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightBlack]; break;
        default: font = serifFont(fontSize, UIFontWeightRegular, YES); break;
    }
    NSString *shown = word;
    NSInteger casing = (NSInteger)(nextRand() * 3);
    if (casing == 0) shown = word.uppercaseString;
    else if (casing == 1) shown = word.lowercaseString;
    CGSize wordSize = [shown sizeWithAttributes:@{NSFontAttributeName: font}];
    CGFloat w = wordSize.width + size.width * (hero ? 0.045 : 0.032);
    CGFloat h = wordSize.height + size.height * (hero ? 0.018 : 0.013);
    NSArray<UIColor *> *papers = @[UIColor.whiteColor,
                                   [UIColor colorWithRed:0.96 green:0.93 blue:0.85 alpha:1],
                                   [UIColor colorWithWhite:0.10 alpha:1],
                                   [UIColor colorWithWhite:0.80 alpha:1],
                                   c->accent ?: [UIColor colorWithRed:0.95 green:0.80 blue:0.20 alpha:1]];
    NSUInteger pick = (NSUInteger)(nextRand() * papers.count) % papers.count;
    UIColor *paper = papers[pick];
    BOOL darkPaper = pick == 2;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, centre.x, centre.y);
    CGContextRotateCTM(ctx, angle);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, size.height * 0.003), size.height * 0.006,
                                [UIColor colorWithWhite:0 alpha:0.35].CGColor);
    fillRect(CGRectMake(-w / 2, -h / 2, w, h), paper);
    CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
    UIBezierPath *edge = [UIBezierPath bezierPathWithRect:CGRectMake(-w / 2, -h / 2, w, h)];
    [[UIColor colorWithWhite:0 alpha:0.18] setStroke];
    edge.lineWidth = 0.75;
    [edge stroke];
    drawText(shown, CGRectMake(-w / 2, -h / 2 + size.height * 0.003, w, h), font,
             darkPaper ? UIColor.whiteColor : [UIColor colorWithWhite:0.07 alpha:1],
             NSTextAlignmentCenter);
    CGContextRestoreGState(ctx);
}

static void drawWordCollage(SGWCtx *c) {
    CGSize size = c->size;
    // The board: a deep red, darkened toward the corners (Batch 97: the
    // old collage glued whole sentences down as strips and printed the
    // line neatly in a panel in the middle. Now every strip is a single
    // cut word, the furniture is gone, and the line being sung is built
    // out of the biggest strips in the middle of the board.)
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithRed:0.48 green:0.05 blue:0.06 alpha:1]);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSArray *shades = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                        (id)[UIColor colorWithWhite:0 alpha:0.28].CGColor];
    CGGradientRef vignette = CGGradientCreateWithColors(space, (__bridge CFArrayRef)shades, NULL);
    CGContextDrawRadialGradient(ctx, vignette, CGPointMake(size.width / 2, size.height / 2),
                                size.height * 0.25, CGPointMake(size.width / 2, size.height / 2),
                                size.height * 0.85, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(vignette);
    CGColorSpaceRelease(space);
    seedRand([NSString stringWithFormat:@"%@%ld", c->title, (long)c->index]);
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    // The scatter: single words from the lines around this one and the
    // song's name, anywhere on the board, overlapping as they fall.
    NSMutableArray<NSString *> *scatter = [NSMutableArray array];
    for (NSString *word in [c->prev componentsSeparatedByCharactersInSet:spaces]) if (word.length) [scatter addObject:word];
    for (NSString *word in [c->next componentsSeparatedByCharactersInSet:spaces]) if (word.length) [scatter addObject:word];
    for (NSString *word in [c->title componentsSeparatedByCharactersInSet:spaces]) if (word.length) [scatter addObject:word];
    for (NSString *word in [c->artist componentsSeparatedByCharactersInSet:spaces]) if (word.length) [scatter addObject:word];
    NSInteger shown = 0;
    for (NSString *word in scatter) {
        if (shown++ >= 16) break;
        CGFloat fs = size.height * (0.019 + nextRand() * 0.016);
        CGPoint at = CGPointMake(size.width * (0.10 + nextRand() * 0.80),
                                 size.height * (0.06 + nextRand() * 0.88));
        drawStrip(c, word, fs, (NSInteger)(nextRand() * 5), at, (nextRand() - 0.5) * 0.30, NO);
    }
    // The hero cluster: the line being sung, word by word, big, flowing
    // across the middle of the board and drawn last, on top of the mess.
    NSArray<NSString *> *hero = [c->current componentsSeparatedByCharactersInSet:spaces];
    CGFloat x = size.width * 0.08, y = size.height * 0.40;
    NSInteger variant = 0;
    for (NSString *word in hero) {
        if (!word.length) continue;
        CGFloat fs = size.height * (0.042 + nextRand() * 0.016);
        UIFont *probe = [UIFont boldSystemFontOfSize:fs];
        CGFloat w = [word sizeWithAttributes:@{NSFontAttributeName: probe}].width + size.width * 0.055;
        if (x + w > size.width * 0.94) { x = size.width * (0.08 + nextRand() * 0.05); y += size.height * 0.105; }
        CGFloat slide = 0;
        if (sg_frameTime >= 0) {
            double k = MIN(1, MAX(0, (sg_frameTime - variant * 0.06) / 0.3));
            slide = (1 - (1 - pow(1 - k, 3))) * size.height * 0.03 * ((variant % 2) ? 1 : -1);
        }
        drawStrip(c, word, fs, variant, CGPointMake(x + w / 2, y + slide), (nextRand() - 0.5) * 0.16, YES);
        x += w + size.width * 0.018;
        variant++;
    }
}

// Cyberpunk chat: the Chat's neon sibling — a red-ruled frame, the song as the
// thread's name, the line being sung in a filled green bubble, the rest in
// dark outlined ones.
static void drawCyberpunk(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0.03 alpha:1]);
    UIColor *neon = [UIColor colorWithRed:1 green:0.16 blue:0.32 alpha:1];
    UIColor *green = [UIColor colorWithRed:0.15 green:0.95 blue:0.45 alpha:1];
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    // Neon glows (Batch 97): a bright core with a blurred halo, laid as
    // three strokes of falling alpha — the flat 2pt lines read as arcade.
    CGRect frameOuter = CGRectMake(size.width * 0.03, size.height * 0.025, size.width * 0.94, size.height * 0.95);
    CGContextSetStrokeColorWithColor(ctx, [neon colorWithAlphaComponent:0.16].CGColor);
    CGContextSetLineWidth(ctx, 7);
    CGContextStrokeRect(ctx, frameOuter);
    CGContextSetStrokeColorWithColor(ctx, [neon colorWithAlphaComponent:0.35].CGColor);
    CGContextSetLineWidth(ctx, 3.5);
    CGContextStrokeRect(ctx, frameOuter);
    CGContextSetStrokeColorWithColor(ctx, neon.CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeRect(ctx, frameOuter);
    CGContextSetLineWidth(ctx, 1);
    CGContextStrokeRect(ctx, CGRectMake(size.width * 0.045, size.height * 0.037, size.width * 0.91, size.height * 0.926));
    if (sg_frameTime >= 0) {
        // Neon flicker: the outer frame re-strokes at a wavering alpha.
        CGFloat hum = 0.55 + 0.45 * sin(sg_frameTime * 23) * sin(sg_frameTime * 7.3 + 1.7);
        CGContextSetStrokeColorWithColor(ctx, [neon colorWithAlphaComponent:MAX(0.25, hum)].CGColor);
        CGContextSetLineWidth(ctx, 2);
        CGContextStrokeRect(ctx, CGRectMake(size.width * 0.03, size.height * 0.025, size.width * 0.94, size.height * 0.95));
    }
    CGFloat margin = size.width * 0.09, width = size.width - 2 * margin;
    CGFloat y = size.height * 0.065;
    drawText([NSString stringWithFormat:@"%@ — %@", c->title.uppercaseString, c->artist.uppercaseString],
             CGRectMake(margin, y, width, size.height * 0.025), monoFont(size.height * 0.018, UIFontWeightBold),
             green, NSTextAlignmentLeft);
    y += size.height * 0.045;
    // The chat speaks mono, like its header (Batch 97).
    UIFont *font = monoFont(size.height * 0.027, UIFontWeightRegular);
    UIFont *nowFont = monoFont(size.height * 0.030, UIFontWeightBold);
    NSInteger starts[3] = {c->prevStart, c->line.start, c->nextStart};
    // Incoming outlined bubbles for what was sung, a filled one for the line,
    // an outlined one for what is next.
    struct { __unsafe_unretained NSString *text; __unsafe_unretained UIFont *font; __unsafe_unretained UIColor *fill; __unsafe_unretained UIColor *stroke; __unsafe_unretained UIColor *ink; BOOL right; } rows[3] = {
        {c->prev, font, nil, neon, [UIColor colorWithWhite:1 alpha:0.75], NO},
        {c->current, nowFont, green, nil, [UIColor colorWithWhite:0.02 alpha:1], YES},
        {c->next, font, nil, neon, [UIColor colorWithWhite:1 alpha:0.55], NO},
    };
    for (int i = 0; i < 3; i++) {
        if (!rows[i].text.length) continue;
        // The sender tag over each side's first bubble.
        if (i == 0 || i == 1) {
            drawText(i == 0 ? @"▶ THEM" : @"▶ YOU",
                     CGRectMake(margin, y, width, size.height * 0.018),
                     monoFont(size.height * 0.013, UIFontWeightBold),
                     [green colorWithAlphaComponent:0.55],
                     i == 0 ? NSTextAlignmentLeft : NSTextAlignmentRight);
            y += size.height * 0.024;
        }
        CGFloat maxText = size.width * 0.62;
        CGRect measured = [rows[i].text boundingRectWithSize:CGSizeMake(maxText, CGFLOAT_MAX)
                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                  attributes:@{NSFontAttributeName: rows[i].font} context:nil];
        CGFloat padX = size.width * 0.035, padY = size.height * 0.011;
        CGFloat w = ceil(measured.size.width) + 2 * padX, h = ceil(measured.size.height) + 2 * padY;
        CGFloat x = rows[i].right ? size.width * 0.91 - w : margin;
        CGRect bubble = CGRectMake(x, y, w, h);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bubble cornerRadius:h * 0.30];
        if (rows[i].fill) {
            // The sent bubble glows like the frame does.
            [[green colorWithAlphaComponent:0.18] setStroke];
            path.lineWidth = 6;
            [path stroke];
            [[green colorWithAlphaComponent:0.35] setStroke];
            path.lineWidth = 3;
            [path stroke];
            [rows[i].fill setFill];
            [path fill];
        }
        if (rows[i].stroke) { [rows[i].stroke setStroke]; path.lineWidth = 1.5; [path stroke]; }
        drawText(rows[i].text, CGRectMake(x + padX, y + padY, measured.size.width, measured.size.height),
                 rows[i].font, rows[i].ink, NSTextAlignmentLeft);
        y += h + size.height * 0.006;
        // The timestamp under the bubble, the way chats stamp them.
        drawText(fmtClock(starts[i]), CGRectMake(x, y, w, size.height * 0.016),
                 monoFont(size.height * 0.012, UIFontWeightRegular),
                 [green colorWithAlphaComponent:0.45],
                 rows[i].right ? NSTextAlignmentRight : NSTextAlignmentLeft);
        y += size.height * 0.026;
    }
    // The input bar along the frame's foot: a chat client is dense to
    // its bottom edge, and this closes the old empty lower half.
    CGFloat barY = size.height * 0.885;
    UIBezierPath *bar = [UIBezierPath bezierPathWithRoundedRect:
        CGRectMake(margin, barY, width, size.height * 0.045) cornerRadius:size.height * 0.022];
    [green setStroke];
    bar.lineWidth = 1.5;
    [bar stroke];
    drawText(@"> _", CGRectMake(margin + size.width * 0.03, barY + size.height * 0.011, width * 0.5, size.height * 0.025),
             monoFont(size.height * 0.018, UIFontWeightBold), green, NSTextAlignmentLeft);
    UIBezierPath *send = [UIBezierPath bezierPath];
    CGPoint tip = CGPointMake(size.width * 0.875, barY + size.height * 0.0225);
    [send moveToPoint:CGPointMake(tip.x - size.width * 0.014, tip.y - size.height * 0.008)];
    [send addLineToPoint:CGPointMake(tip.x + size.width * 0.014, tip.y)];
    [send addLineToPoint:CGPointMake(tip.x - size.width * 0.014, tip.y + size.height * 0.008)];
    [send closePath];
    [green setFill];
    [send fill];
}

// Old TV: the song on a CRT in a dark room — rabbit ears, knobs, scanlines, a
// green PLAY tag and the line glowing on curved glass.
static void drawOldTV(SGWCtx *c) {
    CGSize size = c->size;
    // A room for the set to sit in (Batch 97): wall above, floor below,
    // instead of the void it used to float in.
    CGContextRef roomCtx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef roomSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSArray *room = @[(id)[UIColor colorWithWhite:0.055 alpha:1].CGColor,
                      (id)[UIColor colorWithWhite:0.105 alpha:1].CGColor,
                      (id)[UIColor colorWithWhite:0.028 alpha:1].CGColor];
    CGFloat roomStops[] = {0, 0.72, 1};
    CGGradientRef roomGrad = CGGradientCreateWithColors(roomSpace, (__bridge CFArrayRef)room, roomStops);
    CGContextDrawLinearGradient(roomCtx, roomGrad, CGPointZero, CGPointMake(0, size.height), 0);
    CGGradientRelease(roomGrad);
    CGColorSpaceRelease(roomSpace);
    if (c->average) fillRect(CGRectMake(0, 0, size.width, size.height), [c->average colorWithAlphaComponent:0.08]);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect body = CGRectMake(size.width * 0.08, size.height * 0.20, size.width * 0.84, size.height * 0.46);
    // Its shadow on the floor, and two feet.
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, size.height * 0.010), size.height * 0.018,
                                [UIColor colorWithWhite:0 alpha:0.5].CGColor);
    [[UIColor colorWithWhite:0.02 alpha:1] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(body.origin.x + size.width * 0.03,
                                                       CGRectGetMaxY(body) + size.height * 0.018,
                                                       body.size.width - size.width * 0.06,
                                                       size.height * 0.030)] fill];
    CGContextRestoreGState(ctx);
    fillRect(CGRectMake(body.origin.x + size.width * 0.07, CGRectGetMaxY(body) - 2, size.width * 0.07, size.height * 0.024),
             [UIColor colorWithWhite:0.09 alpha:1]);
    fillRect(CGRectMake(CGRectGetMaxX(body) - size.width * 0.14, CGRectGetMaxY(body) - 2, size.width * 0.07, size.height * 0.024),
             [UIColor colorWithWhite:0.09 alpha:1]);
    // Rabbit ears, out of a little mount on the set's top.
    CGRect mount = CGRectMake(CGRectGetMidX(body) - size.width * 0.035, body.origin.y - size.height * 0.012,
                              size.width * 0.07, size.height * 0.014);
    fillRect(mount, [UIColor colorWithWhite:0.22 alpha:1]);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.55].CGColor);
    CGContextSetLineWidth(ctx, 3);
    CGPoint top = CGPointMake(CGRectGetMidX(body), body.origin.y - size.height * 0.010);
    CGPoint earL = CGPointMake(size.width * 0.22, size.height * 0.055), earR = CGPointMake(size.width * 0.78, size.height * 0.055);
    CGContextMoveToPoint(ctx, top.x, top.y);
    CGContextAddLineToPoint(ctx, earL.x, earL.y);
    CGContextMoveToPoint(ctx, top.x, top.y);
    CGContextAddLineToPoint(ctx, earR.x, earR.y);
    CGContextStrokePath(ctx);
    for (int i = 0; i < 2; i++) {
        CGPoint ear = i == 0 ? earL : earR;
        [[UIColor colorWithWhite:1 alpha:0.55] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(ear.x - 5, ear.y - 5, 10, 10)] fill];
    }
    fillRect(body, [UIColor colorWithWhite:0.14 alpha:1]);
    UIBezierPath *bodyPath = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:size.height * 0.025];
    [bodyPath fill];
    // A lit top edge on the body, so the box has depth.
    CGContextSaveGState(ctx);
    [bodyPath addClip];
    fillRect(CGRectMake(body.origin.x, body.origin.y, body.size.width, 2.5),
             [UIColor colorWithWhite:1 alpha:0.18]);
    CGContextRestoreGState(ctx);
    CGRect screen = CGRectMake(body.origin.x + size.width * 0.035, body.origin.y + size.height * 0.035,
                               body.size.width * 0.76, body.size.height - size.height * 0.07);
    // The bezel ring first, then the glass inside it.
    UIBezierPath *screenPath = [UIBezierPath bezierPathWithRoundedRect:screen cornerRadius:size.height * 0.045];
    [[UIColor colorWithWhite:0.20 alpha:1] setFill];
    [screenPath fill];
    CGRect glass = CGRectInset(screen, size.width * 0.008, size.height * 0.008);
    UIBezierPath *glassPath = [UIBezierPath bezierPathWithRoundedRect:glass cornerRadius:size.height * 0.040];
    [[UIColor colorWithWhite:0.05 alpha:1] setFill];
    [glassPath fill];
    CGContextSaveGState(ctx);
    [glassPath addClip];
    if (c->cover) {
        drawCoverInRect(c->cover, screen);
        fillRect(screen, [UIColor colorWithWhite:0 alpha:0.45]);
    }
    // Finer scanlines, and the slow bright band that rolls up a CRT.
    [[UIColor colorWithWhite:0 alpha:0.07] setFill];
    for (CGFloat ly = screen.origin.y; ly < CGRectGetMaxY(screen); ly += 3) UIRectFill(CGRectMake(screen.origin.x, ly, screen.size.width, 1));
    CGFloat rollY = sg_frameTime >= 0
        ? screen.origin.y + fmod(sg_frameTime * screen.size.height * 0.22, screen.size.height)
        : screen.origin.y + screen.size.height * 0.30;
    fillRect(CGRectMake(screen.origin.x, rollY, screen.size.width, screen.size.height * 0.16),
             [UIColor colorWithWhite:1 alpha:0.04]);
    CGFloat sx = screen.origin.x + size.width * 0.03, sw = screen.size.width - size.width * 0.06;
    drawText(@"▶ PLAY", CGRectMake(sx, screen.origin.y + size.height * 0.015, sw * 0.5, size.height * 0.022),
             monoFont(size.height * 0.016, UIFontWeightBold), [UIColor colorWithRed:0.3 green:1 blue:0.4 alpha:1], NSTextAlignmentLeft);
    drawText(fmtClock(c->line.start), CGRectMake(sx, screen.origin.y + size.height * 0.015, sw, size.height * 0.022),
             monoFont(size.height * 0.016, UIFontWeightBold), [UIColor colorWithWhite:1 alpha:0.8], NSTextAlignmentRight);
    UIFont *lineFont = [UIFont boldSystemFontOfSize:size.height * 0.030];
    NSMutableAttributedString *glow = [[NSMutableAttributedString alloc] initWithString:c->current ?: @""];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [UIColor colorWithWhite:1 alpha:0.85];
    shadow.shadowBlurRadius = 14;
    shadow.shadowOffset = CGSizeZero;
    [glow addAttributes:@{NSFontAttributeName: lineFont, NSForegroundColorAttributeName: UIColor.whiteColor,
                          NSShadowAttributeName: shadow}
                  range:NSMakeRange(0, glow.length)];
    CGFloat lineY = screen.origin.y + size.height * 0.10;
    CGRect measured = [glow boundingRectWithSize:CGSizeMake(sw, screen.size.height * 0.5)
                                         options:NSStringDrawingUsesLineFragmentOrigin context:nil];
    [glow drawWithRect:CGRectMake(sx, lineY, sw, ceil(measured.size.height))
               options:NSStringDrawingUsesLineFragmentOrigin context:nil];
    if (c->line.translation.length) {
        drawText(c->line.translation, CGRectMake(sx, lineY + ceil(measured.size.height) + size.height * 0.012, sw, size.height * 0.03),
                 [UIFont systemFontOfSize:size.height * 0.018], [UIColor colorWithRed:0.62 green:0.80 blue:1 alpha:1], NSTextAlignmentLeft);
    }
    CGContextRestoreGState(ctx);
    // The glass itself: a diagonal reflection across the top and the
    // corners falling dark, the way a curved tube reads in a photo.
    CGContextSaveGState(ctx);
    [glassPath addClip];
    CGColorSpaceRef glassSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSArray *sheen = @[(id)[UIColor colorWithWhite:1 alpha:0.10].CGColor,
                       (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
    CGGradientRef sheenGrad = CGGradientCreateWithColors(glassSpace, (__bridge CFArrayRef)sheen, NULL);
    CGContextDrawLinearGradient(ctx, sheenGrad, CGPointMake(glass.origin.x, glass.origin.y),
                                CGPointMake(CGRectGetMaxX(glass), glass.origin.y + glass.size.height * 0.55), 0);
    CGGradientRelease(sheenGrad);
    NSArray *vignetteCols = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                              (id)[UIColor colorWithWhite:0 alpha:0.35].CGColor];
    CGGradientRef vigGrad = CGGradientCreateWithColors(glassSpace, (__bridge CFArrayRef)vignetteCols, NULL);
    CGPoint glassCentre = CGPointMake(CGRectGetMidX(glass), CGRectGetMidY(glass));
    CGContextDrawRadialGradient(ctx, vigGrad, glassCentre, glass.size.height * 0.36,
                                glassCentre, glass.size.width * 0.72, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(vigGrad);
    CGColorSpaceRelease(glassSpace);
    CGContextRestoreGState(ctx);
    // Knobs down the right side.
    CGFloat knobX = CGRectGetMaxX(screen) + body.size.width * 0.075;
    for (int i = 0; i < 2; i++) {
        CGRect knob = CGRectMake(knobX - size.width * 0.028, body.origin.y + size.height * (0.06 + i * 0.10),
                                 size.width * 0.056, size.width * 0.056);
        [[UIColor colorWithWhite:0.30 alpha:1] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:knob] fill];
        [[UIColor colorWithWhite:1 alpha:0.5] setFill];
        UIRectFill(CGRectMake(CGRectGetMidX(knob) - 1, knob.origin.y + 3, 2, knob.size.height * 0.35));
    }
    // The speaker slots under the knobs.
    [[UIColor colorWithWhite:1 alpha:0.22] setFill];
    for (int s = 0; s < 5; s++) {
        CGRect slot = CGRectMake(CGRectGetMaxX(screen) + body.size.width * 0.028,
                                 body.origin.y + size.height * (0.295 + s * 0.026),
                                 body.size.width * 0.145, size.height * 0.009);
        [[UIBezierPath bezierPathWithRoundedRect:slot cornerRadius:size.height * 0.0045] fill];
    }
    // The plate under the set.
    CGRect plate = CGRectMake(size.width * 0.22, CGRectGetMaxY(body) + size.height * 0.03, size.width * 0.56, size.height * 0.038);
    fillRect(plate, [UIColor colorWithWhite:0.12 alpha:1]);
    drawText([NSString stringWithFormat:@"%@ · %@", c->title.uppercaseString, c->artist.uppercaseString],
             plate, monoFont(size.height * 0.015, UIFontWeightMedium), [UIColor colorWithWhite:1 alpha:0.75], NSTextAlignmentCenter);
}

// Matrix: digital rain behind a terminal. The rain is seeded by the song, so
// it falls the same way every time that line is drawn.
static void drawMatrix(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    seedRand(c->title);
    NSString *glyphs = @"ﾊﾐﾋｳｼﾅﾓﾆｻﾜﾂｵﾘｱﾎﾃﾏｹﾒｴｶｷﾑﾕﾗｾﾈｽﾀﾇﾎ0123456789";
    UIFont *rainFont = monoFont(size.height * 0.017, UIFontWeightRegular);
    // Denser rain (Batch 97): half the old column width, glyphs nearly
    // touching, and the brightness ramp the films use — the head glyph
    // at the foot of each column is near-white hot and the trail decays
    // behind it, instead of a flat ramp that read as green wallpaper.
    CGFloat column = size.width * 0.030;
    CGContextRef rainCtx = UIGraphicsGetCurrentContext();
    for (CGFloat x = size.width * 0.015; x < size.width; x += column) {
        CGFloat startY = -nextRand() * size.height * 0.5;
        if (sg_frameTime >= 0) {
            // The rain falls while a clip renders: each column at its own pace.
            CGFloat fall = sg_frameTime * size.height * (0.07 + nextRand() * 0.11);
            startY += fmod(fall, size.height * 1.2);
        }
        NSInteger length = 8 + (NSInteger)(nextRand() * 15);
        for (NSInteger i = 0; i < length; i++) {
            unichar ch = [glyphs characterAtIndex:(NSUInteger)(nextRand() * glyphs.length) % glyphs.length];
            NSString *glyph = [NSString stringWithCharacters:&ch length:1];
            CGRect cell = CGRectMake(x, startY + i * size.height * 0.019, column, size.height * 0.019);
            if (i == length - 1) {
                // The head, twice: once bloomed, once hot.
                CGContextSaveGState(rainCtx);
                CGContextSetShadowWithColor(rainCtx, CGSizeZero, size.height * 0.006,
                                            [UIColor colorWithRed:0.2 green:1 blue:0.4 alpha:0.9].CGColor);
                drawText(glyph, cell, rainFont, [UIColor colorWithRed:0.80 green:1 blue:0.86 alpha:0.95],
                         NSTextAlignmentLeft);
                CGContextRestoreGState(rainCtx);
                drawText(glyph, cell, rainFont, [UIColor colorWithRed:0.80 green:1 blue:0.86 alpha:0.95],
                         NSTextAlignmentLeft);
            } else {
                CGFloat alpha = MAX(0.05, 0.80 * pow(0.84, length - 1 - i));
                drawText(glyph, cell, rainFont, [UIColor colorWithRed:0.1 green:1 blue:0.35 alpha:alpha],
                         NSTextAlignmentLeft);
            }
        }
    }
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0 alpha:0.18]);
    // The terminal sits on its own dark panel so the rain stays bright
    // around it instead of being washed flat.
    UIBezierPath *panel = [UIBezierPath bezierPathWithRoundedRect:
        CGRectMake(size.width * 0.04, size.height * 0.075, size.width * 0.92, size.height * 0.60)
                                                     cornerRadius:size.height * 0.012];
    [[UIColor colorWithWhite:0 alpha:0.55] setFill];
    [panel fill];
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    CGFloat y = size.height * 0.10;
    UIColor *green = [UIColor colorWithRed:0.25 green:1 blue:0.45 alpha:1];
    UIColor *dim = [UIColor colorWithRed:0.15 green:0.65 blue:0.28 alpha:1];
    drawText([NSString stringWithFormat:@"%@ — %@", c->title, c->artist],
             CGRectMake(margin, y, width, size.height * 0.025), monoFont(size.height * 0.017, UIFontWeightRegular), dim, NSTextAlignmentLeft);
    y += size.height * 0.055;
    if (c->prev.length) {
        drawText([NSString stringWithFormat:@"[%@] %@", fmtClock(c->prevStart), c->prev],
                 CGRectMake(margin, y, width, size.height * 0.05), monoFont(size.height * 0.019, UIFontWeightRegular), dim, NSTextAlignmentLeft);
        y += size.height * 0.045;
    }
    UIFont *nowFont = monoFont(size.height * 0.032, UIFontWeightBold);
    NSString *prompt = [NSString stringWithFormat:@"> %@ ▮", c->current];
    drawText(prompt, CGRectMake(margin, y, width, size.height * 0.14), nowFont, green, NSTextAlignmentLeft);
    y += textHeight(prompt, nowFont, width) + size.height * 0.015;
    if (c->line.translation.length) {
        drawText([NSString stringWithFormat:@"│ %@", c->line.translation],
                 CGRectMake(margin, y, width, size.height * 0.04), monoFont(size.height * 0.018, UIFontWeightRegular), dim, NSTextAlignmentLeft);
        y += size.height * 0.04;
    }
    drawText(c->next, CGRectMake(margin, y, width, size.height * 0.05),
             monoFont(size.height * 0.019, UIFontWeightRegular), dim, NSTextAlignmentLeft);
}

// Stickers: the line as single-word labels, black on white and white on black
// by turns, each tipped a little, over the cover gone soft.
static void drawStickers(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    if (c->cover) {
        UIImage *soft = blurred(c->cover, MAX(24, size.width * 0.08));
        if (soft) drawCoverFilled(soft, size);
        fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0 alpha:0.25]);
    }
    seedRand([NSString stringWithFormat:@"%@%ld", c->title, (long)c->index]);
    NSArray<NSString *> *words = [c->current.lowercaseString
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    UIFont *font = [UIFont boldSystemFontOfSize:size.height * 0.034];
    CGFloat padX = size.width * 0.028, padY = size.height * 0.010, gap = size.width * 0.025;
    CGFloat maxRow = size.width * 0.88;
    // Size the rows first, then draw the cluster centred as a block.
    NSMutableArray<NSArray *> *rows = [NSMutableArray array];
    NSMutableArray *row = [NSMutableArray array];
    CGFloat rowWidth = 0;
    for (NSString *word in words) {
        CGFloat w = [word sizeWithAttributes:@{NSFontAttributeName: font}].width + 2 * padX;
        if (row.count && rowWidth + gap + w > maxRow) {
            [rows addObject:row];
            row = [NSMutableArray array];
            rowWidth = 0;
        }
        [row addObject:@[word, @(w)]];
        rowWidth += (row.count > 1 ? gap : 0) + w;
    }
    if (row.count) [rows addObject:row];
    CGFloat rowHeight = size.height * 0.034 + 2 * padY;
    CGFloat totalHeight = rows.count * (rowHeight + gap);
    CGFloat y = (size.height - totalHeight) / 2;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    BOOL blackLabel = nextRand() > 0.5;
    NSInteger labelAt = 0;
    for (NSArray *aRow in rows) {
        CGFloat widthOfRow = 0;
        for (NSArray *item in aRow) widthOfRow += [item[1] doubleValue] + gap;
        widthOfRow -= gap;
        // Collected, not gridded (Batch 97): the row starts a little off
        // centre, and the rows lean into each other.
        CGFloat x = (size.width - widthOfRow) / 2 + (nextRand() - 0.5) * size.width * 0.06;
        for (NSArray *item in aRow) {
            CGFloat w = [item[1] doubleValue];
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, x + w / 2, y + rowHeight / 2);
            CGContextRotateCTM(ctx, (nextRand() - 0.5) * 0.24);
            CGFloat sizeJitter = 0.88 + nextRand() * 0.27;
            CGContextScaleCTM(ctx, sizeJitter, sizeJitter);
            if (sg_frameTime >= 0) {
                // The labels pop in one by one while a clip renders, with a
                // little overshoot as each lands (an ease-out-back).
                double local = MIN(1, MAX(0, (sg_frameTime - labelAt * 0.07) / 0.22));
                double back = 1 + 2.7 * pow(local - 1, 3) + 1.7 * pow(local - 1, 2);
                CGFloat scale = local <= 0 ? 0.001 : (CGFloat)back;
                CGContextScaleCTM(ctx, scale, scale);
            }
            // A die-cut sticker, not a label: a white halo following the
            // shape, lifted off the surface by its shadow, and every
            // sixth sticker loud in the accent.
            BOOL loud = (labelAt % 6 == 4);
            CGRect labelRect = CGRectMake(-w / 2, -rowHeight / 2, w, rowHeight);
            CGContextSetShadowWithColor(ctx, CGSizeMake(0, size.height * 0.004), size.height * 0.006,
                                        [UIColor colorWithWhite:0 alpha:0.35].CGColor);
            UIBezierPath *halo = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(labelRect, -5, -5)
                                                            cornerRadius:rowHeight * 0.30];
            [UIColor.whiteColor setFill];
            [halo fill];
            CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
            UIColor *face = loud ? (c->accent ?: [UIColor colorWithRed:0.9 green:0.3 blue:0.25 alpha:1])
                                 : (blackLabel ? [UIColor colorWithWhite:0.05 alpha:1] : UIColor.whiteColor);
            UIBezierPath *facePath = [UIBezierPath bezierPathWithRoundedRect:labelRect
                                                                cornerRadius:rowHeight * 0.22];
            [face setFill];
            [facePath fill];
            labelAt++;
            drawText(item[0], CGRectMake(-w / 2, -rowHeight / 2 + padY * 0.7, w, rowHeight), font,
                     (loud || blackLabel) ? UIColor.whiteColor : [UIColor colorWithWhite:0.05 alpha:1],
                     NSTextAlignmentCenter);
            CGContextRestoreGState(ctx);
            blackLabel = !blackLabel;
            x += w + gap;
        }
        y += rowHeight * 0.88 + gap * 0.5;
    }
}

// Receipt: the lines as timed items on a paper slip, barcode and all.
static void drawReceipt(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0.05 alpha:1]);
    if (c->cover) {
        UIImage *soft = blurred(c->cover, MAX(24, size.width * 0.08));
        if (soft) drawCoverFilled(soft, size);
        fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0 alpha:0.55]);
    }
    CGFloat paperW = size.width * 0.76;
    CGRect paper = CGRectMake((size.width - paperW) / 2, size.height * 0.06, paperW, size.height * 0.80);
    // The slip as a path with a torn bottom edge, lifted off the ground
    // by its shadow (Batch 97: it used to be a straight-cut rectangle
    // floating on the void).
    UIBezierPath *slip = [UIBezierPath bezierPath];
    [slip moveToPoint:paper.origin];
    [slip addLineToPoint:CGPointMake(CGRectGetMaxX(paper), paper.origin.y)];
    [slip addLineToPoint:CGPointMake(CGRectGetMaxX(paper), CGRectGetMaxY(paper) - size.height * 0.008)];
    CGFloat tooth = size.width * 0.011;
    for (CGFloat tx = CGRectGetMaxX(paper) - tooth; tx > paper.origin.x; tx -= tooth) {
        [slip addLineToPoint:CGPointMake(tx + tooth / 2, CGRectGetMaxY(paper))];
        [slip addLineToPoint:CGPointMake(MAX(tx, paper.origin.x), CGRectGetMaxY(paper) - size.height * 0.008)];
    }
    [slip closePath];
    CGContextRef slipCtx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(slipCtx);
    CGContextSetShadowWithColor(slipCtx, CGSizeMake(0, size.height * 0.006), size.height * 0.012,
                                [UIColor colorWithWhite:0 alpha:0.40].CGColor);
    [[UIColor colorWithRed:0.96 green:0.945 blue:0.91 alpha:1] setFill];
    [slip fill];
    CGContextRestoreGState(slipCtx);
    CGFloat inner = paperW * 0.86, ix = paper.origin.x + paperW * 0.07;
    CGFloat y = paper.origin.y + size.height * 0.026;
    UIColor *ink = [UIColor colorWithWhite:0.08 alpha:1], *grey = [UIColor colorWithWhite:0.45 alpha:1];
    drawText(c->title.uppercaseString, CGRectMake(ix, y, inner, size.height * 0.03),
             monoFont(size.height * 0.021, UIFontWeightBold), ink, NSTextAlignmentCenter);
    y += size.height * 0.032;
    drawText(c->artist.uppercaseString, CGRectMake(ix, y, inner, size.height * 0.025),
             monoFont(size.height * 0.018, UIFontWeightRegular), ink, NSTextAlignmentCenter);
    y += size.height * 0.030;
    // The shop's small print, the way a real slip opens.
    UIFont *smallMono = monoFont(size.height * 0.0135, UIFontWeightRegular);
    drawText(@"12 CHORUS LANE · SIDE B", CGRectMake(ix, y, inner, size.height * 0.02),
             smallMono, grey, NSTextAlignmentCenter);
    y += size.height * 0.020;
    drawText(@"TEL 555-0142 · CASHIER: MUSE", CGRectMake(ix, y, inner, size.height * 0.02),
             smallMono, grey, NSTextAlignmentCenter);
    y += size.height * 0.032;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    void (^dashed)(CGFloat yy) = ^(CGFloat yy) {
        CGContextSaveGState(ctx);
        CGContextSetStrokeColorWithColor(ctx, grey.CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGFloat dashes[] = {6, 5};
        CGContextSetLineDash(ctx, 0, dashes, 2);
        CGContextMoveToPoint(ctx, ix, yy);
        CGContextAddLineToPoint(ctx, ix + inner, yy);
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    };
    dashed(y);
    y += size.height * 0.02;
    struct { __unsafe_unretained NSString *text; NSInteger start; __unsafe_unretained UIFont *font; __unsafe_unretained UIColor *color; } items[3] = {
        {c->prev, c->prevStart, monoFont(size.height * 0.017, UIFontWeightRegular), grey},
        {c->current, c->line.start, monoFont(size.height * 0.019, UIFontWeightBold), ink},
        {c->next, c->nextStart, monoFont(size.height * 0.017, UIFontWeightRegular), grey},
    };
    for (int i = 0; i < 3; i++) {
        if (!items[i].text.length) continue;
        // The receipt's signature row: the item at the left, its time at
        // the right, a dotted leader joining them (Batch 97).
        NSString *text = items[i].text.uppercaseString;
        NSString *clock = fmtClock(items[i].start);
        UIFont *font = items[i].font;
        CGFloat clockW = [clock sizeWithAttributes:@{NSFontAttributeName: font}].width;
        CGFloat textW = inner - clockW - size.width * 0.05;
        CGFloat h = textHeight(text, font, textW);
        drawText(text, CGRectMake(ix, y, textW, h + 4), font, items[i].color, NSTextAlignmentLeft);
        drawText(clock, CGRectMake(ix, y, inner, size.height * 0.024), font, items[i].color,
                 NSTextAlignmentRight);
        CGFloat lineW = MIN([text sizeWithAttributes:@{NSFontAttributeName: font}].width, textW);
        CGFloat dotSize = size.height * 0.016;
        drawText(@"· · · · · · · · · · · · · · · · · · · ·",
                 CGRectMake(ix + lineW + size.width * 0.012, y, MAX(0, inner - clockW - lineW - size.width * 0.026), dotSize + 4),
                 font, grey, NSTextAlignmentLeft);
        y += h + size.height * 0.018;
    }
    y += size.height * 0.01;
    dashed(y);
    y += size.height * 0.016;
    // Every receipt has a TOTAL: here, the whole song.
    UIFont *totalFont = monoFont(size.height * 0.019, UIFontWeightBold);
    drawText(@"TOTAL", CGRectMake(ix, y, inner, size.height * 0.026), totalFont, ink, NSTextAlignmentLeft);
    drawText(fmtClock((NSInteger)(c->duration * 1000)), CGRectMake(ix, y, inner, size.height * 0.026),
             totalFont, ink, NSTextAlignmentRight);
    y += size.height * 0.034;
    dashed(y);
    y += size.height * 0.016;
    drawText([NSString stringWithFormat:@"#%ld OF %ld", (long)(c->index + 1), (long)MAX(c->count, c->index + 1)],
             CGRectMake(ix, y, inner, size.height * 0.025), monoFont(size.height * 0.017, UIFontWeightRegular), ink, NSTextAlignmentCenter);
    // The barcode: seeded bars at the foot, its digits printed under it,
    // and the thank-you every till prints above it.
    seedRand(c->title);
    NSMutableString *digits = [NSMutableString string];
    for (int d = 0; d < 12; d++) [digits appendFormat:@"%ld", (long)(nextRand() * 10)];
    seedRand(c->title);
    CGFloat barcodeY = paper.origin.y + paper.size.height - size.height * 0.115;
    drawText(@"THANK YOU", CGRectMake(ix, barcodeY - size.height * 0.030, inner, size.height * 0.022),
             monoFont(size.height * 0.016, UIFontWeightBold), ink, NSTextAlignmentCenter);
    CGFloat bx = ix + inner * 0.08;
    while (bx < ix + inner * 0.9) {
        CGFloat bw = 1.5 + nextRand() * 4.5;
        if (nextRand() > 0.35) fillRect(CGRectMake(bx, barcodeY, bw, size.height * 0.045), ink);
        bx += bw + 1.5 + nextRand() * 3;
    }
    drawText(digits, CGRectMake(ix, barcodeY + size.height * 0.050, inner, size.height * 0.02),
             monoFont(size.height * 0.013, UIFontWeightRegular), ink, NSTextAlignmentCenter);
    if (sg_frameTime >= 0 && sg_frameTime < 1.5) {
        // Still printing: below the frontier there is only the black the
        // slip sits on, so the page reads as paper arriving line by line.
        CGFloat frontier = paper.origin.y + paper.size.height * MIN(1, sg_frameTime / 1.5);
        fillRect(CGRectMake(paper.origin.x, frontier, paper.size.width,
                            paper.origin.y + paper.size.height - frontier), UIColor.blackColor);
    }
}

// Gig poster: the light twin of Cover in letters — pale paper, the line
// stacked in capitals, black and white taking turns.
static void drawGigPoster(SGWCtx *c) {
    CGSize size = c->size;
    // Black paper, two inks (Batch 97): the old poster alternated black
    // and white words on cream, so every other word vanished into the
    // paper. On black, white and the accent read at full strength — and
    // the billing furniture a gig poster actually has is all here: the
    // artist as headliner, a rule, the lyric as the show, the song as
    // the support act, and venue / date / doors along the foot.
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0.04 alpha:1]);
    UIColor *accent = c->accent ?: [UIColor colorWithRed:0.95 green:0.25 blue:0.20 alpha:1];
    UIColor *paper = [UIColor colorWithWhite:0.96 alpha:1];
    CGFloat margin = size.width * 0.07, width = size.width * 0.86;
    NSArray<NSString *> *billing = [c->artist.uppercaseString
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    billing = [billing filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (!billing.count) billing = @[c->artist.uppercaseString ?: @"♪"];
    NSArray<NSString *> *words = [c->current.uppercaseString
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (!words.count) words = @[@"♪"];
    CGFloat lyricSize = stackedFontSize(words, size, 0.86);
    CGFloat billingSize = lyricSize * 0.52;
    // Fit the whole stack above the footer before drawing any of it.
    CGFloat stackH = billing.count * billingSize * 0.94 + size.height * 0.055
                   + words.count * lyricSize * 0.94;
    while (stackH > size.height * 0.74 && lyricSize > size.height * 0.05) {
        lyricSize *= 0.92;
        billingSize = lyricSize * 0.52;
        stackH = billing.count * billingSize * 0.94 + size.height * 0.055
               + words.count * lyricSize * 0.94;
    }
    CGFloat y = size.height * 0.055;
    UIFont *billingFont = [UIFont boldSystemFontOfSize:billingSize];
    for (NSString *word in billing) {
        drawText(word, CGRectMake(margin, y, width, billingSize * 1.2), billingFont, accent,
                 NSTextAlignmentLeft);
        y += billingSize * 0.94;
    }
    y += size.height * 0.018;
    fillRect(CGRectMake(margin, y, width, MAX(2, size.height * 0.004)), paper);
    y += size.height * 0.030;
    UIFont *font = [UIFont boldSystemFontOfSize:lyricSize];
    BOOL white = YES;
    NSInteger wordAt = 0;
    for (NSString *word in words) {
        CGRect wordRect = CGRectMake(margin, y, width, lyricSize * 1.2);
        UIColor *inkColor = white ? paper : accent;
        if (sg_frameTime >= 0) {
            // Each word stamps down in turn, a touch large, then settles.
            double k = MIN(1, MAX(0, (sg_frameTime - wordAt * 0.07) / 0.25));
            double e = 1 - pow(1 - k, 3);
            CGContextRef ctx = UIGraphicsGetCurrentContext();
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, CGRectGetMidX(wordRect), CGRectGetMidY(wordRect));
            CGFloat scale = 1 + 0.13 * (1 - (CGFloat)e);
            CGContextScaleCTM(ctx, scale, scale);
            CGContextTranslateCTM(ctx, -CGRectGetMidX(wordRect), -CGRectGetMidY(wordRect));
            drawText(word, wordRect, font, inkColor, NSTextAlignmentLeft);
            CGContextRestoreGState(ctx);
        } else {
            drawText(word, wordRect, font, inkColor, NSTextAlignmentLeft);
        }
        y += lyricSize * 0.94;
        white = !white;
        wordAt++;
    }
    if (c->title.length) {
        y += size.height * 0.016;
        drawText([NSString stringWithFormat:@"PLUS: %@", c->title.uppercaseString],
                 CGRectMake(margin, y, width, size.height * 0.025),
                 [UIFont systemFontOfSize:size.height * 0.016 weight:UIFontWeightMedium],
                 [UIColor colorWithWhite:0.55 alpha:1], NSTextAlignmentLeft);
    }
    // The footer every gig poster has: venue, date, doors — between rules.
    CGFloat fy = size.height * 0.885;
    fillRect(CGRectMake(margin, fy, width, MAX(2, size.height * 0.003)), paper);
    NSDateFormatter *day = [NSDateFormatter new];
    day.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    day.dateFormat = @"EEE d MMM yyyy";
    NSString *date = [day stringFromDate:NSDate.date].uppercaseString;
    UIFont *footFont = monoFont(size.height * 0.0155, UIFontWeightMedium);
    CGRect footRow = CGRectMake(margin, fy + size.height * 0.012, width, size.height * 0.022);
    drawText(@"AT THE WORKSHOP HALL", footRow, footFont, paper, NSTextAlignmentLeft);
    drawText(date, footRow, footFont, paper, NSTextAlignmentCenter);
    drawText(@"DOORS 8PM · £5 OTD", footRow, footFont, paper, NSTextAlignmentRight);
    fillRect(CGRectMake(margin, fy + size.height * 0.042, width, MAX(2, size.height * 0.003)), paper);
    // Photocopy roughness: two soft multiply passes and a few scratches.
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeMultiply);
    fillRect(CGRectMake(0, 0, size.width * 0.55, size.height), [UIColor colorWithWhite:0.94 alpha:1]);
    fillRect(CGRectMake(size.width * 0.6, 0, size.width * 0.4, size.height),
             [UIColor colorWithWhite:0.97 alpha:1]);
    CGContextRestoreGState(ctx);
    seedRand(c->title);
    [[UIColor colorWithWhite:1 alpha:0.05] setFill];
    for (int i = 0; i < 3; i++) {
        CGFloat sx = nextRand() * size.width;
        UIRectFill(CGRectMake(sx, nextRand() * size.height * 0.4, 1.5,
                              size.height * (0.1 + nextRand() * 0.2)));
    }
}

// Holo: the song as a holographic trading card — frosted panel, picture
// window, the line with a glitch edge.
static void drawHolo(SGWCtx *c) {
    CGSize size = c->size;
    // The room first: a dim wash of the cover, dark enough that the
    // card's foil is the brightest thing in it (Batch 97: the old card
    // was a flat white panel with nothing holographic about it — the
    // foil is the entire point of the style, so now it leads).
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0.13 alpha:1]);
    if (c->cover) {
        UIImage *soft = blurred(c->cover, MAX(24, size.width * 0.08));
        if (soft) drawCoverFilled(soft, size);
        fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0 alpha:0.45]);
    }
    // A real card's proportions (63 × 88 mm), centred, lifted off the
    // ground on its own shadow.
    CGFloat cardW = size.width * 0.80;
    CGFloat cardH = cardW / 0.716;
    CGRect card = CGRectMake((size.width - cardW) / 2, (size.height - cardH) / 2, cardW, cardH);
    UIBezierPath *cardPath = [UIBezierPath bezierPathWithRoundedRect:card cornerRadius:cardW * 0.045];
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, size.height * 0.012), size.height * 0.022,
                                [UIColor colorWithWhite:0 alpha:0.45].CGColor);
    [[UIColor colorWithWhite:0.97 alpha:1] setFill];
    [cardPath fill];
    CGContextRestoreGState(ctx);
    // The foil: a rainbow wash over the whole card, and a brighter band
    // where the light catches — it travels while a clip plays.
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSArray *rainbow = @[(id)[UIColor colorWithRed:1 green:0.35 blue:0.45 alpha:1].CGColor,
                         (id)[UIColor colorWithRed:1 green:0.75 blue:0.30 alpha:1].CGColor,
                         (id)[UIColor colorWithRed:0.98 green:0.95 blue:0.35 alpha:1].CGColor,
                         (id)[UIColor colorWithRed:0.40 green:0.95 blue:0.50 alpha:1].CGColor,
                         (id)[UIColor colorWithRed:0.35 green:0.70 blue:1 alpha:1].CGColor,
                         (id)[UIColor colorWithRed:0.70 green:0.45 blue:1 alpha:1].CGColor];
    CGGradientRef foil = CGGradientCreateWithColors(space, (__bridge CFArrayRef)rainbow, NULL);
    CGContextSaveGState(ctx);
    [cardPath addClip];
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeOverlay);
    CGContextSetAlpha(ctx, 0.35);
    CGContextDrawLinearGradient(ctx, foil, CGPointMake(card.origin.x, card.origin.y),
                                CGPointMake(CGRectGetMaxX(card), CGRectGetMaxY(card)), 0);
    CGContextRestoreGState(ctx);
    double sweepT = sg_frameTime >= 0 ? (0.5 + 0.5 * sin(sg_frameTime * 1.4)) : 0.30;
    CGFloat bandX = card.origin.x - cardW * 0.4 + (CGFloat)sweepT * cardW * 1.8;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, bandX, card.origin.y - cardH * 0.3);
    CGContextRotateCTM(ctx, 0.35);
    fillRect(CGRectMake(0, 0, cardW * 0.22, cardH * 1.8), [UIColor colorWithWhite:1 alpha:0.20]);
    CGContextRestoreGState(ctx);
    CGContextRestoreGState(ctx);
    // A thin inner border, the way the foil layer sits framed on the card.
    UIBezierPath *inner = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(card, cardW * 0.018, cardW * 0.018)
                                                     cornerRadius:cardW * 0.038];
    [[UIColor colorWithWhite:0 alpha:0.15] setStroke];
    inner.lineWidth = 1;
    [inner stroke];
    CGFloat ix = card.origin.x + cardW * 0.065, iw = cardW * 0.87;
    CGFloat y = card.origin.y + cardH * 0.028;
    UIColor *ink = [UIColor colorWithWhite:0.10 alpha:1];
    // Name left, hit points right — labelled, and in ink.
    drawText(c->title, CGRectMake(ix, y, iw * 0.72, cardH * 0.035),
             [UIFont boldSystemFontOfSize:cardH * 0.026], ink, NSTextAlignmentLeft);
    NSString *hp = [NSString stringWithFormat:@"HP %ld", (long)(c->duration > 0 ? c->duration : 380)];
    drawText(hp, CGRectMake(ix, y, iw, cardH * 0.035),
             [UIFont boldSystemFontOfSize:cardH * 0.026], ink, NSTextAlignmentRight);
    y += cardH * 0.048;
    // The picture window, where the foil lives strongest.
    CGRect window = CGRectMake(ix, y, iw, cardH * 0.34);
    if (c->cover) {
        CGContextSaveGState(ctx);
        [[UIBezierPath bezierPathWithRoundedRect:window cornerRadius:6] addClip];
        drawCoverInRect(c->cover, window);
        CGContextSaveGState(ctx);
        CGContextSetBlendMode(ctx, kCGBlendModeOverlay);
        CGContextSetAlpha(ctx, 0.30);
        CGContextDrawLinearGradient(ctx, foil, CGPointMake(window.origin.x, window.origin.y),
                                    CGPointMake(CGRectGetMaxX(window), CGRectGetMaxY(window)), 0);
        CGContextRestoreGState(ctx);
        CGContextRestoreGState(ctx);
    }
    CGGradientRelease(foil);
    CGColorSpaceRelease(space);
    y += cardH * 0.355;
    drawText([NSString stringWithFormat:@"%@ · %@", c->artist, c->title],
             CGRectMake(ix, y, iw * 0.85, cardH * 0.025), [UIFont systemFontOfSize:cardH * 0.0145],
             [UIColor colorWithWhite:0.35 alpha:1], NSTextAlignmentLeft);
    drawText(@"★", CGRectMake(ix, y - cardH * 0.004, iw, cardH * 0.03),
             [UIFont systemFontOfSize:cardH * 0.02], [UIColor colorWithRed:0.85 green:0.62 blue:0.10 alpha:1],
             NSTextAlignmentRight);
    y += cardH * 0.038;
    // The text box: a defined panel at the card's foot holding the words,
    // the way a card puts its attack text in a box.
    CGRect box = CGRectMake(ix, y, iw, card.origin.y + cardH * 0.955 - y);
    UIBezierPath *boxPath = [UIBezierPath bezierPathWithRoundedRect:box cornerRadius:6];
    [[UIColor colorWithWhite:0 alpha:0.055] setFill];
    [boxPath fill];
    [[UIColor colorWithWhite:0 alpha:0.12] setStroke];
    boxPath.lineWidth = 1;
    [boxPath stroke];
    CGFloat bx = box.origin.x + cardW * 0.035, bw = box.size.width - cardW * 0.07;
    CGFloat by = box.origin.y + cardH * 0.018;
    UIFont *lineFont = [UIFont boldSystemFontOfSize:cardH * 0.024];
    CGFloat lineH = textHeight(c->current, lineFont, bw);
    drawText(c->current, CGRectMake(bx, by, bw, lineH + 4), lineFont, ink, NSTextAlignmentLeft);
    by += lineH + cardH * 0.010;
    NSString *meta = [NSString stringWithFormat:@"%@  ·  up next: %@", fmtClock(c->line.start),
                      c->next.length ? c->next : @"—"];
    drawText(meta, CGRectMake(bx, by, bw, cardH * 0.022),
             monoFont(cardH * 0.0135, UIFontWeightRegular), [UIColor colorWithWhite:0.45 alpha:1],
             NSTextAlignmentLeft);
    if (c->line.translation.length) {
        by += cardH * 0.026;
        drawText(c->line.translation, CGRectMake(bx, by, bw, cardH * 0.03),
                 serifFont(cardH * 0.015, UIFontWeightRegular, YES),
                 [UIColor colorWithWhite:0.30 alpha:1], NSTextAlignmentLeft);
        by += cardH * 0.030;
    }
    // A second entry in the box, under a hairline: the next line, the
    // way a card lists a second attack — it also keeps the box from
    // standing mostly empty under one short lyric.
    if (c->next.length) {
        by += cardH * 0.016;
        fillRect(CGRectMake(bx, by, bw, 1), [UIColor colorWithWhite:0 alpha:0.12]);
        by += cardH * 0.014;
        UIFont *nextFont = [UIFont boldSystemFontOfSize:cardH * 0.019];
        CGFloat nextH = textHeight(c->next, nextFont, bw);
        drawText(c->next, CGRectMake(bx, by, bw, nextH + 4), nextFont,
                 [UIColor colorWithWhite:0.30 alpha:1], NSTextAlignmentLeft);
        by += nextH + cardH * 0.008;
        drawText(fmtClock(c->nextStart), CGRectMake(bx, by, bw, cardH * 0.02),
                 monoFont(cardH * 0.0135, UIFontWeightRegular), [UIColor colorWithWhite:0.45 alpha:1],
                 NSTextAlignmentLeft);
    }
}

// RGB split: the line pulled apart into red and cyan copies over the cover
// smeared with light.
static void drawRGBSplit(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    if (c->cover) {
        UIImage *soft = blurred(c->cover, MAX(30, size.width * 0.11));
        if (soft) drawCoverFilled(soft, size);
        fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0 alpha:0.30]);
        // Glitch slices (Batch 97): thin bands of the cover torn sideways
        // — the defect applied to the picture, not just the words.
        if (c->cover.CGImage) {
            seedRand([NSString stringWithFormat:@"%@%ld", c->title, (long)c->index]);
            CGFloat px = CGImageGetWidth(c->cover.CGImage), py = CGImageGetHeight(c->cover.CGImage);
            for (int s = 0; s < 3; s++) {
                CGFloat fy = 0.12 + nextRand() * 0.65, fh = 0.018 + nextRand() * 0.035;
                CGRect crop = CGRectMake(0, py * fy, px, py * fh);
                CGImageRef slice = CGImageCreateWithImageInRect(c->cover.CGImage, crop);
                if (!slice) continue;
                UIImage *band = [UIImage imageWithCGImage:slice];
                CGImageRelease(slice);
                CGFloat shift = (nextRand() - 0.3) * size.width * 0.022;
                [band drawInRect:CGRectMake(shift, size.height * fy, size.width, size.height * fh)];
            }
        }
    }
    // VHS furniture: the recording dot and the timecode.
    drawText(@"● REC", CGRectMake(size.width * 0.07, size.height * 0.045, size.width * 0.4, size.height * 0.025),
             monoFont(size.height * 0.016, UIFontWeightBold), [UIColor colorWithRed:1 green:0.25 blue:0.25 alpha:1],
             NSTextAlignmentLeft);
    drawText(fmtClock(c->line.start), CGRectMake(size.width * 0.53, size.height * 0.045, size.width * 0.4, size.height * 0.025),
             monoFont(size.height * 0.016, UIFontWeightRegular), [UIColor colorWithWhite:1 alpha:0.65],
             NSTextAlignmentRight);
    NSString *shout = c->current;
    UIFont *font = [UIFont boldSystemFontOfSize:size.height * 0.036];
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    CGFloat h = textHeight(shout, font, width);
    CGFloat y = size.height * 0.42;
    CGFloat off = size.width * 0.012 * (sg_frameTime >= 0 ? 0.6 + 0.6 * sin(sg_frameTime * 3.9) : 1);
    // The fringe: red and cyan copies in Screen behind one whole white
    // copy (Batch 97: the old middle copy was 55% white, which is not a
    // thing chromatic aberration does — it softened the line into a glow).
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeScreen);
    drawText(shout, CGRectMake(margin - off, y, width, h + 4), font, [UIColor colorWithRed:1 green:0.15 blue:0.2 alpha:0.85], NSTextAlignmentLeft);
    drawText(shout, CGRectMake(margin + off, y, width, h + 4), font, [UIColor colorWithRed:0.1 green:0.9 blue:1 alpha:0.85], NSTextAlignmentLeft);
    CGContextRestoreGState(ctx);
    drawText(shout, CGRectMake(margin, y, width, h + 4), font, UIColor.whiteColor, NSTextAlignmentLeft);
    drawText(c->next, CGRectMake(margin, y + h + size.height * 0.025, width, size.height * 0.04),
             [UIFont systemFontOfSize:size.height * 0.020], [UIColor colorWithWhite:1 alpha:0.55], NSTextAlignmentLeft);
}

// Window: a gallery piece — the cover in an arched frame on cream, the line
// in italic serif beneath.
static void drawWindow(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithRed:0.955 green:0.937 blue:0.885 alpha:1]);
    CGRect frame = CGRectMake(size.width * 0.215, size.height * 0.075, size.width * 0.57, size.height * 0.50);
    CGFloat radius = frame.size.width / 2;
    UIBezierPath *arch = [UIBezierPath new];
    [arch moveToPoint:CGPointMake(frame.origin.x, CGRectGetMaxY(frame))];
    [arch addLineToPoint:CGPointMake(frame.origin.x, frame.origin.y + radius)];
    [arch addArcWithCenter:CGPointMake(CGRectGetMidX(frame), frame.origin.y + radius) radius:radius
                startAngle:M_PI endAngle:0 clockwise:YES];
    [arch addLineToPoint:CGPointMake(CGRectGetMaxX(frame), CGRectGetMaxY(frame))];
    [arch closePath];
    // The mat the piece is mounted on, and the shadow it casts on the
    // wall (Batch 97: a bare 2pt outline read as a diagram).
    CGFloat exp = size.width * 0.016;
    CGRect matRect = CGRectInset(frame, -exp, -exp);
    CGFloat matRadius = matRect.size.width / 2;
    UIBezierPath *mat = [UIBezierPath new];
    [mat moveToPoint:CGPointMake(matRect.origin.x, CGRectGetMaxY(matRect))];
    [mat addLineToPoint:CGPointMake(matRect.origin.x, matRect.origin.y + matRadius)];
    [mat addArcWithCenter:CGPointMake(CGRectGetMidX(matRect), matRect.origin.y + matRadius) radius:matRadius
               startAngle:M_PI endAngle:0 clockwise:YES];
    [mat addLineToPoint:CGPointMake(CGRectGetMaxX(matRect), CGRectGetMaxY(matRect))];
    [mat closePath];
    CGContextRef matCtx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(matCtx);
    CGContextSetShadowWithColor(matCtx, CGSizeMake(0, size.height * 0.007), size.height * 0.012,
                                [UIColor colorWithWhite:0 alpha:0.18].CGColor);
    [[UIColor colorWithRed:0.90 green:0.885 blue:0.845 alpha:1] setFill];
    [mat fill];
    CGContextRestoreGState(matCtx);
    if (c->cover) {
        CGContextSaveGState(UIGraphicsGetCurrentContext());
        [arch addClip];
        drawCoverInRect(c->cover, breathingRect(CGRectMake(frame.origin.x, frame.origin.y, frame.size.width, frame.size.height + radius * 0.4), size.width * 0.02, size.width * 0.006));
        CGContextRestoreGState(UIGraphicsGetCurrentContext());
    }
    [[UIColor colorWithWhite:0.15 alpha:1] setStroke];
    arch.lineWidth = 2;
    [arch stroke];
    // The little wall label beside the piece, the way galleries label.
    CGFloat labelX = CGRectGetMaxX(frame) + size.width * 0.032;
    CGFloat labelY = CGRectGetMidY(frame) - size.height * 0.030;
    UIFont *labelFont = [UIFont systemFontOfSize:size.height * 0.0115];
    UIColor *labelInk = [UIColor colorWithWhite:0.40 alpha:1];
    drawText(c->title, CGRectMake(labelX, labelY, size.width * 0.15, size.height * 0.018),
             [UIFont boldSystemFontOfSize:size.height * 0.0115], labelInk, NSTextAlignmentLeft);
    drawText(c->artist, CGRectMake(labelX, labelY + size.height * 0.017, size.width * 0.15, size.height * 0.018),
             labelFont, labelInk, NSTextAlignmentLeft);
    drawText(@"2026", CGRectMake(labelX, labelY + size.height * 0.034, size.width * 0.15, size.height * 0.018),
             labelFont, labelInk, NSTextAlignmentLeft);
    CGFloat y = CGRectGetMaxY(frame) + size.height * 0.045;
    UIFont *lineFont = serifFont(size.height * 0.032, UIFontWeightRegular, YES);
    drawText(c->current, CGRectMake(size.width * 0.08, y, size.width * 0.84, size.height * 0.10),
             lineFont, [UIColor colorWithWhite:0.12 alpha:1], NSTextAlignmentCenter);
    y += textHeight(c->current, lineFont, size.width * 0.84) + size.height * 0.02;
    NSString *credit = [NSString stringWithFormat:@"%@ · %@", c->title.uppercaseString, c->artist.uppercaseString];
    NSMutableAttributedString *spaced = [[NSMutableAttributedString alloc] initWithString:credit];
    NSMutableParagraphStyle *centre = [NSMutableParagraphStyle new];
    centre.alignment = NSTextAlignmentCenter;
    [spaced addAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:size.height * 0.014],
                            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.45 alpha:1],
                            NSKernAttributeName: @2.5,
                            NSParagraphStyleAttributeName: centre}
                    range:NSMakeRange(0, spaced.length)];
    [spaced drawInRect:CGRectMake(0, y, size.width, size.height * 0.02)];
}

// Starburst: the cover clipped into a retro burst badge over its own blur,
// the lines centred beneath.
static void drawStarburst(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    if (c->cover) {
        UIImage *soft = blurred(c->cover, MAX(24, size.width * 0.08));
        if (soft) drawCoverFilled(soft, size);
        fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0 alpha:0.35]);
    }
    // A real burst badge (Batch 97): spiky (inner 0.68, 24 points), one
    // flat poster red with a white edge and a single hard shadow — the
    // pink/blue offset doubles were vaporwave, not a price badge. The
    // cover sits in a circle inside it, and the badge carries a word:
    // the longest word of the line, in outlined caps, tilted.
    CGRect burst = CGRectMake(size.width * 0.16, size.height * 0.06, size.width * 0.68, size.width * 0.68);
    CGPoint centre = CGPointMake(CGRectGetMidX(burst), CGRectGetMidY(burst));
    CGFloat outer = burst.size.width / 2, inner = outer * 0.68;
    UIBezierPath *star = [UIBezierPath new];
    NSInteger points = 24;
    for (NSInteger i = 0; i < points * 2; i++) {
        CGFloat r = i % 2 == 0 ? outer : inner;
        CGFloat angle = -M_PI_2 + i * M_PI / points;
        CGPoint p = CGPointMake(centre.x + r * cos(angle), centre.y + r * sin(angle));
        if (i == 0) [star moveToPoint:p];
        else [star addLineToPoint:p];
    }
    [star closePath];
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, size.width * 0.008, size.height * 0.008);
    [[UIColor colorWithWhite:0 alpha:0.35] setFill];
    [star fill];
    CGContextRestoreGState(ctx);
    [[UIColor colorWithRed:0.92 green:0.16 blue:0.13 alpha:1] setFill];
    [star fill];
    [[UIColor whiteColor] setStroke];
    star.lineWidth = MAX(2, size.width * 0.003);
    [star stroke];
    if (c->cover) {
        CGFloat discR = outer * 0.58;
        CGRect disc = CGRectMake(centre.x - discR, centre.y - discR, discR * 2, discR * 2);
        CGContextSaveGState(ctx);
        [[UIBezierPath bezierPathWithOvalInRect:disc] addClip];
        drawCoverInRect(c->cover, disc);
        CGContextRestoreGState(ctx);
        [[UIColor whiteColor] setStroke];
        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:disc];
        ring.lineWidth = MAX(2, size.width * 0.003);
        [ring stroke];
    }
    // The badge's word: the longest word of the line being sung.
    NSString *badgeWord = @"";
    for (NSString *word in [c->current componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (word.length > badgeWord.length) badgeWord = word;
    }
    if (badgeWord.length) {
        CGFloat fs = size.height * 0.034;
        UIFont *badgeFont = [UIFont boldSystemFontOfSize:fs];
        while (fs > size.height * 0.016 &&
               [badgeWord.uppercaseString sizeWithAttributes:@{NSFontAttributeName: badgeFont}].width > burst.size.width * 0.72) {
            fs *= 0.9;
            badgeFont = [UIFont boldSystemFontOfSize:fs];
        }
        NSMutableAttributedString *badge = [[NSMutableAttributedString alloc]
            initWithString:badgeWord.uppercaseString];
        [badge addAttributes:@{NSFontAttributeName: badgeFont,
                               NSForegroundColorAttributeName: UIColor.whiteColor,
                               NSStrokeColorAttributeName: [UIColor colorWithWhite:0.05 alpha:1],
                               NSStrokeWidthAttributeName: @(-5)}
                        range:NSMakeRange(0, badge.length)];
        NSMutableParagraphStyle *centred = [NSMutableParagraphStyle new];
        centred.alignment = NSTextAlignmentCenter;
        [badge addAttribute:NSParagraphStyleAttributeName value:centred range:NSMakeRange(0, badge.length)];
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, centre.x, centre.y + outer * 0.60);
        CGContextRotateCTM(ctx, -0.14);
        [badge drawWithRect:CGRectMake(-burst.size.width * 0.45, -fs * 0.7, burst.size.width * 0.9, fs * 1.4)
                    options:NSStringDrawingUsesLineFragmentOrigin context:nil];
        CGContextRestoreGState(ctx);
    }
    CGFloat y = CGRectGetMaxY(burst) + size.height * 0.045;
    UIFont *nowFont = [UIFont boldSystemFontOfSize:size.height * 0.032];
    drawText(c->current, CGRectMake(size.width * 0.07, y, size.width * 0.86, size.height * 0.10),
             nowFont, UIColor.whiteColor, NSTextAlignmentCenter);
    y += textHeight(c->current, nowFont, size.width * 0.86) + size.height * 0.012;
    drawText(c->next, CGRectMake(size.width * 0.07, y, size.width * 0.86, size.height * 0.05),
             [UIFont systemFontOfSize:size.height * 0.021], [UIColor colorWithWhite:1 alpha:0.55], NSTextAlignmentCenter);
    drawText([NSString stringWithFormat:@"%@ — %@", c->title ?: @"", c->artist ?: @""],
             CGRectMake(size.width * 0.07, size.height * 0.93, size.width * 0.86, size.height * 0.03),
             [UIFont systemFontOfSize:size.height * 0.016], [UIColor colorWithWhite:1 alpha:0.45],
             NSTextAlignmentCenter);
}

// Print: newsprint — the cover as halftone dots dissolving into paper, a red
// tag, and the line in serif over black marker bars.
static UIImage *halftoneOf(UIImage *cover) {
    // Keyed on the CGImage, not the UIImage (Batch 21 audit): the same
    // bitmap arrives in a fresh wrapper on many draws, and a wrapper key
    // missed every time, re-filtering the dearest draw in the set.
    static UIImage *memo;
    static CGImageRef memoFor;
    if (memo && memoFor == cover.CGImage) return memo;
    CIFilter *dots = [CIFilter filterWithName:@"CIDotScreen"];
    [dots setValue:[CIImage imageWithCGImage:cover.CGImage] forKey:kCIInputImageKey];
    [dots setValue:@(4.2) forKey:@"inputWidth"];
    [dots setValue:@(0.6) forKey:@"inputSharpness"];
    UIImage *fresh = ciResult(cover, dots);
    // The key is retained (Batch 89): an unretained CGImageRef dangles the
    // moment its bitmap goes, and a new bitmap at the same address would
    // have been served the dead one's halftone.
    CGImageRef key = CGImageRetain(cover.CGImage);
    if (memoFor) CGImageRelease(memoFor);
    memoFor = key;
    memo = fresh;
    return memo;
}

static void drawPrint(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithRed:0.86 green:0.84 blue:0.78 alpha:1]);
    // The front page's furniture (Batch 97): the artist as the masthead
    // name at the left, the date at the right, a heavy rule under both —
    // then the photograph below it.
    UIFont *mastFont = serifFont(size.height * 0.017, UIFontWeightBold, NO);
    UIColor *mastInk = [UIColor colorWithWhite:0.08 alpha:1];
    drawText(c->artist.uppercaseString, CGRectMake(size.width * 0.06, size.height * 0.020, size.width * 0.55, size.height * 0.024),
             mastFont, mastInk, NSTextAlignmentLeft);
    NSDateFormatter *dayFmt = [NSDateFormatter new];
    dayFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dayFmt.dateFormat = @"MMMM d, yyyy";
    drawText([dayFmt stringFromDate:NSDate.date].uppercaseString,
             CGRectMake(size.width * 0.39, size.height * 0.020, size.width * 0.55, size.height * 0.024),
             mastFont, mastInk, NSTextAlignmentRight);
    fillRect(CGRectMake(size.width * 0.06, size.height * 0.050, size.width * 0.88, MAX(2, size.height * 0.0028)),
             mastInk);
    if (c->cover) {
        UIImage *halftone = halftoneOf(c->cover);
        if (halftone) drawCoverInRect(halftone, breathingRect(CGRectMake(0, size.height * 0.058, size.width, size.height * 0.49), size.width * 0.015, size.width * 0.005));
        // The dissolve: paper colour gathered from the middle down.
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = 1;
        format.opaque = NO;
        UIImage *fade = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
            imageWithActions:^(UIGraphicsImageRendererContext *fadeContext) {
            CGContextRef ctx = fadeContext.CGContext;
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            UIColor *paper = [UIColor colorWithRed:0.86 green:0.84 blue:0.78 alpha:1];
            CGFloat r, g, b;
            [paper getRed:&r green:&g blue:&b alpha:NULL];
            CGFloat components[] = {r, g, b, 0, r, g, b, 1};
            CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, NULL, 2);
            CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, size.height * 0.30), CGPointMake(0, size.height * 0.55), 0);
            CGGradientRelease(gradient);
            CGColorSpaceRelease(space);
        }];
        [fade drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }
    CGRect tag = CGRectMake(size.width * 0.06, size.height * 0.078, 0, size.height * 0.034);
    UIFont *tagFont = [UIFont boldSystemFontOfSize:size.height * 0.016];
    CGFloat tagWidth = [c->title.uppercaseString sizeWithAttributes:@{NSFontAttributeName: tagFont}].width + size.width * 0.03;
    tag.size.width = tagWidth;
    fillRect(tag, [UIColor colorWithRed:0.82 green:0.12 blue:0.10 alpha:1]);
    drawText(c->title.uppercaseString, tag, tagFont, UIColor.whiteColor, NSTextAlignmentCenter);
    // The line, word-wrapped by hand so each row can wear its black bar.
    UIFont *font = serifFont(size.height * 0.036, UIFontWeightBold, NO);
    CGFloat maxWidth = size.width * 0.84, x0 = size.width * 0.08;
    NSMutableArray<NSString *> *rowsText = [NSMutableArray array];
    NSString *rowSoFar = @"";
    for (NSString *word in [c->current componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (!word.length) continue;
        NSString *candidate = rowSoFar.length ? [rowSoFar stringByAppendingFormat:@" %@", word] : word;
        if ([candidate sizeWithAttributes:@{NSFontAttributeName: font}].width > maxWidth && rowSoFar.length) {
            [rowsText addObject:rowSoFar];
            rowSoFar = word;
        } else rowSoFar = candidate;
    }
    if (rowSoFar.length) [rowsText addObject:rowSoFar];
    CGFloat y = size.height * 0.60, rowH = size.height * 0.052;
    seedRand([NSString stringWithFormat:@"%@%ld", c->title, (long)c->index]);
    for (NSString *rowText in rowsText) {
        CGFloat w = [rowText sizeWithAttributes:@{NSFontAttributeName: font}].width + size.width * 0.04;
        // A marker stroke, not a rectangle (Batch 97): ragged right end,
        // a hair of vertical jitter, overshooting the words slightly.
        CGFloat j = (nextRand() - 0.5) * size.height * 0.003;
        CGFloat bx = x0 - size.width * 0.012;
        UIBezierPath *bar = [UIBezierPath bezierPath];
        [bar moveToPoint:CGPointMake(bx, y + j)];
        [bar addLineToPoint:CGPointMake(bx + w + size.width * 0.006, y + j + size.height * 0.003)];
        [bar addLineToPoint:CGPointMake(bx + w, y + rowH + j)];
        [bar addLineToPoint:CGPointMake(bx, y + rowH + j)];
        [bar closePath];
        [[UIColor colorWithWhite:0.05 alpha:1] setFill];
        [bar fill];
        drawText(rowText, CGRectMake(x0, y + size.height * 0.006 + j, w, rowH), font, UIColor.whiteColor, NSTextAlignmentLeft);
        y += rowH + size.height * 0.008;
    }
    // The byline under the last bar: the page names its song.
    drawText([NSString stringWithFormat:@"%@ — %@", c->title, c->artist],
             CGRectMake(x0, y + size.height * 0.012, size.width * 0.84, size.height * 0.025),
             serifFont(size.height * 0.016, UIFontWeightRegular, YES),
             [UIColor colorWithWhite:0.25 alpha:1], NSTextAlignmentLeft);
}

// Tiles: the cover in a mosaic of twelve, the lines beneath.
static void drawTiles(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0.03 alpha:1]);
    if (c->cover.CGImage) {
        // A mosaic, not a photo grid (Batch 97): warm grout under wider
        // gaps, a 2x2 feature tile in the middle, two flat accent tiles
        // among the picture ones, and a whisper of per-tile tonal jitter
        // so the set reads as handmade.
        CGFloat gridW = size.width * 0.90, gridH = size.height * 0.52;
        CGFloat gx = (size.width - gridW) / 2, gy = size.height * 0.045, gap = size.width * 0.016;
        fillRect(CGRectMake(gx - gap, gy - gap, gridW + 2 * gap, gridH + 2 * gap),
                 [UIColor colorWithRed:0.72 green:0.68 blue:0.60 alpha:1]);
        CGFloat tileW = (gridW - 3 * gap) / 4, tileH = (gridH - 2 * gap) / 3;
        CGFloat px = CGImageGetWidth(c->cover.CGImage), py = CGImageGetHeight(c->cover.CGImage);
        seedRand([NSString stringWithFormat:@"%@%ld", c->title, (long)c->index]);
        // The single tiles: every cell except the centre 2x2.
        int cells[8][2] = {{0,0},{3,0},{0,1},{3,1},{0,2},{1,2},{2,2},{3,2}};
        NSInteger flatA = (NSInteger)(nextRand() * 8), flatB = (flatA + 3 + (NSInteger)(nextRand() * 4)) % 8;
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        for (int i = 0; i < 8; i++) {
            int col = cells[i][0], row = cells[i][1];
            CGRect tileRect = CGRectMake(gx + col * (tileW + gap), gy + row * (tileH + gap), tileW, tileH);
            double stagger = (row * 4 + col) * 0.045;
            CGContextSaveGState(ctx);
            if (sg_frameTime >= 0) {
                double k = MIN(1, MAX(0, (sg_frameTime - stagger) / 0.3));
                double e = 1 - pow(1 - k, 3);
                CGContextTranslateCTM(ctx, CGRectGetMidX(tileRect), CGRectGetMidY(tileRect));
                CGContextScaleCTM(ctx, MAX(0.001, e), 1);
                CGContextTranslateCTM(ctx, -CGRectGetMidX(tileRect), -CGRectGetMidY(tileRect));
            }
            if (i == flatA || i == flatB) {
                UIColor *flat = i == flatA ? (c->accent ?: [UIColor colorWithRed:0.9 green:0.3 blue:0.25 alpha:1])
                                           : [UIColor colorWithWhite:0.92 alpha:1];
                fillRect(tileRect, flat);
            } else {
                CGRect crop = CGRectMake(px * col / 4, py * row / 3, px / 4, py / 3);
                CGImageRef piece = CGImageCreateWithImageInRect(c->cover.CGImage, crop);
                if (piece) {
                    UIImage *tile = [UIImage imageWithCGImage:piece];
                    CGImageRelease(piece);
                    [tile drawInRect:tileRect];
                    CGFloat jitter = nextRand() * 0.08;
                    if (jitter > 0.01) fillRect(tileRect, [UIColor colorWithWhite:nextRand() > 0.5 ? 1 : 0 alpha:jitter]);
                }
            }
            CGContextRestoreGState(ctx);
        }
        // The feature tile: the cover's centre, at 2x2.
        CGRect feature = CGRectMake(gx + (tileW + gap), gy, tileW * 2 + gap, tileH * 2 + gap);
        CGRect fcrop = CGRectMake(px * 0.25, py * 0.08, px * 0.5, py * 0.58);
        CGImageRef fpiece = CGImageCreateWithImageInRect(c->cover.CGImage, fcrop);
        if (fpiece) {
            UIImage *ftile = [UIImage imageWithCGImage:fpiece];
            CGImageRelease(fpiece);
            [ftile drawInRect:feature];
        }
    }
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    CGFloat y = size.height * 0.615;
    UIFont *nowFont = [UIFont boldSystemFontOfSize:size.height * 0.032];
    drawText(c->current, CGRectMake(margin, y, width, size.height * 0.10), nowFont, UIColor.whiteColor, NSTextAlignmentLeft);
    y += textHeight(c->current, nowFont, width) + size.height * 0.012;
    drawText(c->next, CGRectMake(margin, y, width, size.height * 0.05),
             [UIFont systemFontOfSize:size.height * 0.021], [UIColor colorWithWhite:1 alpha:0.5], NSTextAlignmentLeft);
    drawText([NSString stringWithFormat:@"%@ — %@", c->title ?: @"", c->artist ?: @""],
             CGRectMake(margin, size.height * 0.925, width, size.height * 0.03),
             [UIFont systemFontOfSize:size.height * 0.016], [UIColor colorWithWhite:1 alpha:0.4], NSTextAlignmentLeft);
}

// Polaroid: an instant print, taped and tipped, the line handwritten in the
// white strip.
static void drawPolaroid(SGWCtx *c) {
    CGSize size = c->size;
    // The surface: a warm gradient, darker at the foot (Batch 97: the
    // print used to lie flat-filled on a flat ground, and read as a card
    // in the app rather than a photo on a desk).
    CGContextRef groundCtx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef gSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSArray *ground = @[(id)[UIColor colorWithRed:0.20 green:0.145 blue:0.105 alpha:1].CGColor,
                        (id)[UIColor colorWithRed:0.11 green:0.075 blue:0.05 alpha:1].CGColor];
    CGGradientRef groundGrad = CGGradientCreateWithColors(gSpace, (__bridge CFArrayRef)ground, NULL);
    CGContextDrawLinearGradient(groundCtx, groundGrad, CGPointZero,
                                CGPointMake(0, size.height), 0);
    CGGradientRelease(groundGrad);
    CGColorSpaceRelease(gSpace);
    if (c->average) fillRect(CGRectMake(0, 0, size.width, size.height), [c->average colorWithAlphaComponent:0.10]);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGPoint centre = CGPointMake(size.width / 2, size.height * 0.415);
    CGContextTranslateCTM(ctx, centre.x, centre.y);
    CGContextRotateCTM(ctx, -0.045 + (sg_frameTime >= 0 ? sin(sg_frameTime * (2 * M_PI / 5)) * 0.012 : 0));
    CGContextTranslateCTM(ctx, -centre.x, -centre.y);
    CGRect print = CGRectMake(size.width * 0.12, size.height * 0.115, size.width * 0.76, size.height * 0.60);
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, size.height * 0.012), size.height * 0.020,
                                [UIColor colorWithWhite:0 alpha:0.45].CGColor);
    fillRect(print, [UIColor colorWithRed:0.97 green:0.96 blue:0.94 alpha:1]);
    CGContextRestoreGState(ctx);
    CGRect photo = CGRectMake(print.origin.x + size.width * 0.038, print.origin.y + size.height * 0.030,
                              print.size.width - size.width * 0.076, print.size.height - size.height * 0.155);
    if (c->cover) {
        drawCoverInRect(c->cover, photo);
        // Instant-film softness: a warm wash and a gentle falloff.
        fillRect(photo, [UIColor colorWithRed:1 green:0.95 blue:0.85 alpha:0.06]);
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, photo);
        CGColorSpaceRef pSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        NSArray *fade = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                          (id)[UIColor colorWithWhite:0 alpha:0.10].CGColor];
        CGGradientRef fadeGrad = CGGradientCreateWithColors(pSpace, (__bridge CFArrayRef)fade, NULL);
        CGContextDrawLinearGradient(ctx, fadeGrad, CGPointMake(0, photo.origin.y + photo.size.height * 0.55),
                                    CGPointMake(0, CGRectGetMaxY(photo)), 0);
        CGGradientRelease(fadeGrad);
        CGColorSpaceRelease(pSpace);
        CGContextRestoreGState(ctx);
    }
    UIFont *hand = [UIFont fontWithName:@"Bradley Hand" size:size.height * 0.034]
        ?: [UIFont systemFontOfSize:size.height * 0.030 weight:UIFontWeightMedium];
    CGFloat captionY = CGRectGetMaxY(photo) + size.height * 0.018;
    CGFloat fontSize = size.height * 0.034;
    while (fontSize > size.height * 0.018 &&
           [c->current sizeWithAttributes:@{NSFontAttributeName: hand}].width > print.size.width * 0.88) {
        fontSize *= 0.9;
        hand = [UIFont fontWithName:@"Bradley Hand" size:fontSize] ?: hand;
    }
    drawText(c->current, CGRectMake(print.origin.x, captionY, print.size.width, size.height * 0.06),
             hand, [UIColor colorWithWhite:0.13 alpha:1], NSTextAlignmentCenter);
    // The tape rides the print now (it is drawn inside the rotation),
    // translucent, with torn ends (Batch 97).
    CGFloat tapeW = print.size.width * 0.34, tapeH = size.height * 0.030;
    CGFloat tapeX = print.origin.x + (print.size.width - tapeW) / 2;
    CGFloat tapeY = print.origin.y - tapeH * 0.42;
    UIBezierPath *tape = [UIBezierPath bezierPath];
    [tape moveToPoint:CGPointMake(tapeX, tapeY + tapeH * 0.15)];
    [tape addLineToPoint:CGPointMake(tapeX + tapeW * 0.012, tapeY + tapeH * 0.55)];
    [tape addLineToPoint:CGPointMake(tapeX, tapeY + tapeH * 0.9)];
    [tape addLineToPoint:CGPointMake(tapeX + tapeW, tapeY + tapeH)];
    [tape addLineToPoint:CGPointMake(tapeX + tapeW * 0.99, tapeY + tapeH * 0.5)];
    [tape addLineToPoint:CGPointMake(tapeX + tapeW, tapeY)];
    [tape closePath];
    [[UIColor colorWithRed:0.93 green:0.88 blue:0.71 alpha:0.55] setFill];
    [tape fill];
    CGContextRestoreGState(ctx);
}

// Subtitles: a letterboxed film frame, the cover in greyscale, the line as a
// yellow subtitle with its translation under it.
static void drawSubtitles(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    // A film frame, in colour (Batch 97: the old frame was desaturated
    // to grey, which read as a B&W photo filter, and its yellow mono
    // subtitle was fansub-meme, not cinema).
    CGRect frame = CGRectMake(0, size.height * 0.16, size.width, size.height * 0.68);
    if (c->cover) {
        CIFilter *grade = [CIFilter filterWithName:@"CIColorControls"];
        [grade setValue:[CIImage imageWithCGImage:c->cover.CGImage] forKey:kCIInputImageKey];
        [grade setValue:@0.85 forKey:@"inputSaturation"];
        [grade setValue:@1.04 forKey:@"inputContrast"];
        UIImage *graded = ciResult(c->cover, grade);
        drawCoverInRect(graded ?: c->cover, frame);
        if (c->average) {
            CGContextRef gctx = UIGraphicsGetCurrentContext();
            CGContextSaveGState(gctx);
            CGContextClipToRect(gctx, frame);
            CGContextSetBlendMode(gctx, kCGBlendModeOverlay);
            fillRect(frame, [c->average colorWithAlphaComponent:0.10]);
            CGContextRestoreGState(gctx);
        }
    }
    // Cinema subtitles: a humanist sans, white, with the black outline
    // that keeps them readable over any frame.
    UIFont *font = [UIFont systemFontOfSize:size.height * 0.026 weight:UIFontWeightSemibold];
    NSMutableAttributedString *sub = [[NSMutableAttributedString alloc] initWithString:c->current ?: @""];
    [sub addAttributes:@{NSFontAttributeName: font,
                         NSForegroundColorAttributeName: UIColor.whiteColor,
                         NSStrokeColorAttributeName: UIColor.blackColor,
                         NSStrokeWidthAttributeName: @(-4)}
                range:NSMakeRange(0, sub.length)];
    NSMutableParagraphStyle *centre = [NSMutableParagraphStyle new];
    centre.alignment = NSTextAlignmentCenter;
    [sub addAttribute:NSParagraphStyleAttributeName value:centre range:NSMakeRange(0, sub.length)];
    CGFloat subH = ceil([sub boundingRectWithSize:CGSizeMake(size.width * 0.86, frame.size.height * 0.4)
                                          options:NSStringDrawingUsesLineFragmentOrigin context:nil].size.height);
    BOOL hasTranslation = c->line.translation.length > 0;
    CGFloat transH = hasTranslation ? size.height * 0.026 : 0;
    CGFloat blockBottom = CGRectGetMaxY(frame) - size.height * 0.032;
    CGFloat subY = blockBottom - transH - (hasTranslation ? size.height * 0.008 : 0) - subH;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    if (sg_frameTime >= 0) {
        double k = MIN(1, sg_frameTime / 0.3);
        CGContextTranslateCTM(ctx, 0, (1 - (1 - pow(1 - k, 3))) * size.height * 0.012);
    }
    [sub drawWithRect:CGRectMake(size.width * 0.07, subY, size.width * 0.86, subH)
              options:NSStringDrawingUsesLineFragmentOrigin context:nil];
    if (hasTranslation) {
        drawText(c->line.translation, CGRectMake(size.width * 0.07, blockBottom - transH, size.width * 0.86, transH),
                 [UIFont systemFontOfSize:size.height * 0.016], [UIColor colorWithWhite:1 alpha:0.85],
                 NSTextAlignmentCenter);
    }
    CGContextRestoreGState(ctx);
}

// Line number: editorial cream, the line's number enormous and pale behind
// its words, a slim progress rule under them.
static void drawLineNumber(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithRed:0.955 green:0.945 blue:0.915 alpha:1]);
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    // The colophon header: the page names its song (Batch 97 — the card
    // used to be anonymous), small caps, letterspaced, over the ghost.
    NSString *colophon = [NSString stringWithFormat:@"%@ — %@", c->title.uppercaseString, c->artist.uppercaseString];
    NSMutableAttributedString *head = [[NSMutableAttributedString alloc] initWithString:colophon];
    [head addAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:size.height * 0.013 weight:UIFontWeightMedium],
                          NSForegroundColorAttributeName: [UIColor colorWithWhite:0.45 alpha:1],
                          NSKernAttributeName: @1.5}
                  range:NSMakeRange(0, head.length)];
    [head drawInRect:CGRectMake(margin, size.height * 0.032, width, size.height * 0.02)];
    // The ghost numeral in a thin weight — bold at 7% still read chunky.
    drawText([NSString stringWithFormat:@"%ld", (long)(c->index + 1)],
             CGRectMake(margin, size.height * 0.015, width, size.height * 0.30),
             [UIFont systemFontOfSize:size.height * 0.26 weight:UIFontWeightThin],
             [UIColor colorWithWhite:0 alpha:0.07], NSTextAlignmentLeft);
    CGFloat y = size.height * 0.36;
    UIFont *nowFont = [UIFont boldSystemFontOfSize:size.height * 0.036];
    UIColor *ink = [UIColor colorWithWhite:0.07 alpha:1];
    drawText(c->current, CGRectMake(margin, y, width, size.height * 0.12), nowFont, ink, NSTextAlignmentLeft);
    y += textHeight(c->current, nowFont, width) + size.height * 0.015;
    drawText(c->next, CGRectMake(margin, y, width, size.height * 0.05),
             [UIFont systemFontOfSize:size.height * 0.021], [UIColor colorWithWhite:0.45 alpha:1], NSTextAlignmentLeft);
    y += size.height * 0.06;
    fillRect(CGRectMake(margin, y, width, 3), [UIColor colorWithWhite:0 alpha:0.15]);
    double fraction = 0;
    if (c->duration > 0) {
        NSInteger position = sg_frameTime >= 0 && c->line
            ? c->line.start + (NSInteger)(sg_frameTime * 1000) : SGKaraokePositionMs();
        fraction = position >= 0 ? MIN(1, position / 1000.0 / c->duration) : 0;
    } else if (c->count > 0) {
        fraction = (c->index + 1) / (double)c->count;
    }
    fillRect(CGRectMake(margin, y, width * fraction, 3), c->accent ?: ink);
    // The footer colophon: where this line sits in the song.
    drawText([NSString stringWithFormat:@"%ld / %ld", (long)(c->index + 1), (long)MAX(c->count, c->index + 1)],
             CGRectMake(margin, size.height * 0.93, width, size.height * 0.02),
             [UIFont systemFontOfSize:size.height * 0.013 weight:UIFontWeightMedium],
             [UIColor colorWithWhite:0.45 alpha:1], NSTextAlignmentRight);
}

// The second research wave (Batch 81): three more original renderers,
// same SGWCtx contract as the Batch 7 set.

// Pulse bars: the current line over a fake waveform — seeded per track so
// the still is stable, and the bars breathe while a clip renders.
static void drawPulseBars(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0.045 alpha:1]);
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    UIFont *nowFont = [UIFont boldSystemFontOfSize:size.height * 0.040];
    CGFloat y = size.height * 0.10;
    drawText(c->title, CGRectMake(margin, y, width, size.height * 0.05),
             [UIFont boldSystemFontOfSize:size.height * 0.022], [UIColor colorWithWhite:0.85 alpha:1], NSTextAlignmentLeft);
    drawText(c->artist, CGRectMake(margin, y + size.height * 0.032, width, size.height * 0.05),
             [UIFont systemFontOfSize:size.height * 0.020], [UIColor colorWithWhite:0.55 alpha:1], NSTextAlignmentLeft);
    y = size.height * 0.24;
    drawText(c->current, CGRectMake(margin, y, width, size.height * 0.16), nowFont,
             UIColor.whiteColor, NSTextAlignmentLeft);
    y += textHeight(c->current, nowFont, width) + size.height * 0.012;
    drawText(c->next, CGRectMake(margin, y, width, size.height * 0.06),
             [UIFont systemFontOfSize:size.height * 0.024], [UIColor colorWithWhite:0.5 alpha:1], NSTextAlignmentLeft);
    // The waveform field: bars seeded from the title so every still of a
    // track looks the same; clips add a slow sine so they pulse.
    seedRand(c->title ?: c->current ?: @"x");
    NSInteger bars = 36;
    CGFloat gap = 2, barW = (width - gap * (bars - 1)) / bars;
    CGFloat fieldY = size.height * 0.58, fieldH = size.height * 0.32;
    double bases[36];
    for (NSInteger i = 0; i < bars; i++) bases[i] = 0.15 + nextRand() * 0.7;
    UIColor *barColor = c->accent ?: [UIColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:1];
    // The waveform tells time (Batch 97): bars behind the playhead burn
    // full, bars ahead of it sit dim — and every bar is round-capped,
    // over a hairline through the field's centre.
    double fraction = 0;
    if (c->duration > 0) {
        NSInteger position = sg_frameTime >= 0 && c->line
            ? c->line.start + (NSInteger)(sg_frameTime * 1000) : SGKaraokePositionMs();
        fraction = position >= 0 ? MIN(1, position / 1000.0 / c->duration) : 0;
    } else if (c->count > 0) {
        fraction = (c->index + 1) / (double)c->count;
    }
    fillRect(CGRectMake(margin, fieldY + fieldH / 2, width, 1), [UIColor colorWithWhite:1 alpha:0.10]);
    UIColor *dimBar = [barColor colorWithAlphaComponent:0.35];
    for (NSInteger i = 0; i < bars; i++) {
        double h = bases[i];
        if (sg_frameTime >= 0) h = 0.15 + 0.7 * (0.5 + 0.5 * sin(sg_frameTime * 2.4 + i * 0.65 + bases[i] * 4));
        CGFloat bh = fieldH * h;
        CGRect barRect = CGRectMake(margin + i * (barW + gap), fieldY + (fieldH - bh) / 2, barW, bh);
        UIBezierPath *barPath = [UIBezierPath bezierPathWithRoundedRect:barRect cornerRadius:barW / 2];
        [((i + 0.5) / bars <= fraction ? barColor : dimBar) setFill];
        [barPath fill];
    }
}

// Warp flow: the cover's colours poured down the card in bands, a bright
// band drifting through them while a clip renders, the line held on a
// scrim so it stays readable.
static void drawWarpFlow(SGWCtx *c) {
    CGSize size = c->size;
    // Two colours in motion (Batch 97): the old flow was one hue walking
    // a straight ramp to black in even steps — a posterised gradient,
    // nothing warped. Now the bands pour: their heights ease as they
    // fall, the colour path bends average → accent → black, and a sine
    // wobbles the interpolation so the slices read as liquid, not steps.
    UIColor *avg = c->average ?: [UIColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:1];
    UIColor *acc = c->accent ?: [UIColor colorWithRed:0.2 green:0.6 blue:1 alpha:1];
    CGFloat ar, ag, ab, aa, cr, cg, cb, ca;
    [avg getRed:&ar green:&ag blue:&ab alpha:&aa];
    [acc getRed:&cr green:&cg blue:&cb alpha:&ca];
    double phase = sg_frameTime >= 0 ? sg_frameTime * 0.9 : 0.6;
    NSInteger bands = 30;
    CGFloat heights[30], totalH = 0;
    for (NSInteger i = 0; i < bands; i++) {
        CGFloat t = i / (CGFloat)(bands - 1);
        heights[i] = 0.020 + 0.020 * t;
        totalH += heights[i];
    }
    CGFloat y = 0;
    for (NSInteger i = 0; i < bands; i++) {
        CGFloat t = i / (CGFloat)(bands - 1);
        CGFloat bandH = size.height * heights[i] / totalH;
        CGFloat tt = MIN(1, MAX(0, t + 0.08 * sin(t * M_PI * 2 + phase)));
        CGFloat r, g, b;
        if (tt < 0.62) {
            CGFloat k = tt / 0.62;
            r = ar + (cr - ar) * k; g = ag + (cg - ag) * k; b = ab + (cb - ab) * k;
        } else {
            CGFloat k = (tt - 0.62) / 0.38;
            r = cr * (1 - k); g = cg * (1 - k); b = cb * (1 - k);
        }
        fillRect(CGRectMake(0, y, size.width, bandH + 1), [UIColor colorWithRed:r green:g blue:b alpha:1]);
        y += bandH;
    }
    if (sg_frameTime >= 0) {
        // One bright band drifting down the card, soft at both edges.
        CGFloat travel = fmod(sg_frameTime * size.height * 0.22, size.height * 1.3);
        CGFloat bandY = travel - size.height * 0.15, bandH = size.height * 0.11;
        CGContextRef bctx = UIGraphicsGetCurrentContext();
        CGColorSpaceRef bSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat stops[] = {0, 0.5, 1};
        NSArray *bandCols = @[(id)[UIColor colorWithWhite:1 alpha:0].CGColor,
                              (id)[UIColor colorWithWhite:1 alpha:0.10].CGColor,
                              (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
        CGGradientRef bandGrad = CGGradientCreateWithColors(bSpace, (__bridge CFArrayRef)bandCols, stops);
        CGContextDrawLinearGradient(bctx, bandGrad, CGPointMake(0, bandY), CGPointMake(0, bandY + bandH), 0);
        CGGradientRelease(bandGrad);
        CGColorSpaceRelease(bSpace);
    }
    // The scrim feathers in instead of cutting the flow with a hard edge.
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat locs[] = {0, 0.55, 1};
    NSArray *scrimCols = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                           (id)[UIColor colorWithWhite:0 alpha:0.62].CGColor,
                           (id)[UIColor colorWithWhite:0 alpha:0.62].CGColor];
    CGGradientRef scrim = CGGradientCreateWithColors(space, (__bridge CFArrayRef)scrimCols, locs);
    CGContextDrawLinearGradient(ctx, scrim, CGPointMake(0, size.height * 0.44),
                                CGPointMake(0, size.height), 0);
    CGGradientRelease(scrim);
    CGColorSpaceRelease(space);
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    UIFont *nowFont = [UIFont boldSystemFontOfSize:size.height * 0.042];
    CGFloat ty = size.height * 0.62;
    drawText(c->current, CGRectMake(margin, ty, width, size.height * 0.18), nowFont,
             UIColor.whiteColor, NSTextAlignmentLeft);
    ty += textHeight(c->current, nowFont, width) + size.height * 0.012;
    drawText(c->next, CGRectMake(margin, ty, width, size.height * 0.06),
             [UIFont systemFontOfSize:size.height * 0.024], [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentLeft);
    drawText([NSString stringWithFormat:@"%@ — %@", c->title ?: @"", c->artist ?: @""],
             CGRectMake(margin, size.height * 0.925, width, size.height * 0.05),
             [UIFont systemFontOfSize:size.height * 0.020], [UIColor colorWithWhite:0.8 alpha:1], NSTextAlignmentLeft);
}

// OLED stealth: pure black, small type, nothing to burn in — the quiet
// card for always-on lock screens.
static void drawOLEDStealth(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    CGFloat margin = size.width * 0.08, width = size.width - 2 * margin;
    drawText(c->title, CGRectMake(margin, size.height * 0.06, width, size.height * 0.05),
             [UIFont systemFontOfSize:size.height * 0.022], [UIColor colorWithWhite:0.55 alpha:1], NSTextAlignmentLeft);
    drawText(c->artist, CGRectMake(margin, size.height * 0.092, width, size.height * 0.05),
             [UIFont systemFontOfSize:size.height * 0.020], [UIColor colorWithWhite:0.38 alpha:1], NSTextAlignmentLeft);
    UIFont *nowFont = [UIFont boldSystemFontOfSize:size.height * 0.038];
    // A whisper of what just played, at the same weight as what's next.
    if (c->prev.length) {
        drawText(c->prev, CGRectMake(margin, size.height * 0.325, width, size.height * 0.05),
                 [UIFont systemFontOfSize:size.height * 0.023], [UIColor colorWithWhite:0.30 alpha:1],
                 NSTextAlignmentLeft);
    }
    CGFloat y = size.height * 0.38;
    drawText(c->current, CGRectMake(margin, y, width, size.height * 0.16), nowFont,
             [(c->accent ?: UIColor.whiteColor) colorWithAlphaComponent:0.88], NSTextAlignmentLeft);
    y += textHeight(c->current, nowFont, width) + size.height * 0.014;
    drawText(c->next, CGRectMake(margin, y, width, size.height * 0.06),
             [UIFont systemFontOfSize:size.height * 0.023], [UIColor colorWithWhite:0.42 alpha:1], NSTextAlignmentLeft);
    // A hairline of progress, barely there.
    double fraction = 0;
    if (c->duration > 0) {
        NSInteger position = sg_frameTime >= 0 && c->line
            ? c->line.start + (NSInteger)(sg_frameTime * 1000) : SGKaraokePositionMs();
        fraction = position >= 0 ? MIN(1, position / 1000.0 / c->duration) : 0;
    } else if (c->count > 0) {
        fraction = (c->index + 1) / (double)c->count;
    }
    fillRect(CGRectMake(margin, size.height * 0.90, width, 1.5), [UIColor colorWithWhite:1 alpha:0.14]);
    fillRect(CGRectMake(margin, size.height * 0.90, width * fraction, 1.5), c->accent ?: [UIColor colorWithWhite:0.7 alpha:1]);
}

static UIImage *drawWorkshopArtwork(NSInteger style, CGSize size, NSString *prev, NSString *current, NSString *next,
                                    UIImage *cover, SGKaraokeLine *line, NSString *title, NSString *artist,
                                    NSInteger index, NSInteger count, NSInteger prevStart, NSInteger nextStart,
                                    double duration) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
        // The two colours are the only values in the context with no
        // other owner, and its fields are __unsafe_unretained: an
        // autoreleased colour stored straight into the struct is fair
        // game for the optimiser to release before a draw reads it.
        // The style picker's sample renders died exactly there (crash
        // log 2026-10-22 21:38:58: objc_msgSend to a freed object,
        // inside a draw, on the samples queue). Strong locals hold
        // both colours for the whole draw (Batch 96).
        UIColor *average = averageColor(cover);
        UIColor *accent = average ? lifted(average) : nil;
        SGWCtx c = {size, prev, current, next, title, artist, cover, line, index, count,
                    prevStart, nextStart, duration, average, accent};
        switch (style) {
            case SGLyricArtworkTwitter: drawTwitter(&c); break;
            case SGLyricArtworkCoverInLetters: drawCoverInLetters(&c); break;
            case SGLyricArtworkMagazine: drawMagazine(&c); break;
            case SGLyricArtworkDuotone: drawDuotone(&c); break;
            case SGLyricArtworkWordCollage: drawWordCollage(&c); break;
            case SGLyricArtworkCyberpunk: drawCyberpunk(&c); break;
            case SGLyricArtworkOldTV: drawOldTV(&c); break;
            case SGLyricArtworkMatrix: drawMatrix(&c); break;
            case SGLyricArtworkStickers: drawStickers(&c); break;
            case SGLyricArtworkReceipt: drawReceipt(&c); break;
            case SGLyricArtworkGigPoster: drawGigPoster(&c); break;
            case SGLyricArtworkHolo: drawHolo(&c); break;
            case SGLyricArtworkRGBSplit: drawRGBSplit(&c); break;
            case SGLyricArtworkWindow: drawWindow(&c); break;
            case SGLyricArtworkStarburst: drawStarburst(&c); break;
            case SGLyricArtworkPrint: drawPrint(&c); break;
            case SGLyricArtworkTiles: drawTiles(&c); break;
            case SGLyricArtworkPolaroid: drawPolaroid(&c); break;
            case SGLyricArtworkSubtitles: drawSubtitles(&c); break;
            case SGLyricArtworkLineNumber: drawLineNumber(&c); break;
            case SGLyricArtworkPulseBars: drawPulseBars(&c); break;
            case SGLyricArtworkWarpFlow: drawWarpFlow(&c); break;
            case SGLyricArtworkOLEDStealth: drawOLEDStealth(&c); break;
            default: fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor); break;
        }
    }];
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
            if (sg_frameTime >= 0) drawCoverInRect(cover, breathingRect(full, size.width * 0.03, size.width * 0.008));
            else drawCoverFilled(cover, size);
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

#pragma mark - the moving version (Batch 8)

// The styles that move, and how long a loop each wants: the ambient ones loop
// every three seconds; the sweep styles take their line's own length, so the
// words fill at the speed they are sung.
// The quality actually rendered at (Batch 23): the user's choice, stepped
// down a notch while the phone is hot — a clip rendered smaller under heat
// is tagged with the quality it really is, so nothing is served under a
// false name later.
static NSInteger effectiveQuality(void) {
    NSInteger quality = SGInt(SGKeyLyricArtworkClipQuality, 1);
    if (NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious) quality -= 1;
    return MAX(quality, 0);
}

// True when the phone is asking for mercy: Low Power Mode, or real heat.
// Warming (work nobody asked for yet) yields to it; the line on screen
// never does.
static BOOL powerThrifty(void) {
    NSProcessInfo *info = NSProcessInfo.processInfo;
    return info.lowPowerModeEnabled || info.thermalState >= NSProcessInfoThermalStateSerious;
}

// The clip's size and rate, from the quality choice: Saver for the battery,
// Max for the full 900x1200 the stills use, Balanced between.
static void clipSpec(CGSize *size, NSInteger *fps) {
    switch (effectiveQuality()) {
        case 0: *size = CGSizeMake(540, 720); *fps = 15; break;
        case 2: *size = CGSizeMake(900, 1200); *fps = 24; break;
        default: *size = CGSizeMake(720, 960); *fps = 20; break;
    }
}

static BOOL styleAnimates(NSInteger style) {
    switch (style) {
        case SGLyricArtworkPoster:
        case SGLyricArtworkPlain:
        case SGLyricArtworkAura:
        case SGLyricArtworkGradient:
        case SGLyricArtworkRecord:
        case SGLyricArtworkMatrix:
        case SGLyricArtworkStickers:
        case SGLyricArtworkRGBSplit:
        case SGLyricArtworkOldTV:
        case SGLyricArtworkHolo:
        case SGLyricArtworkStarburst:
        case SGLyricArtworkChat:
        case SGLyricArtworkCoverInLetters:
        case SGLyricArtworkWordCollage:
        case SGLyricArtworkCyberpunk:
        case SGLyricArtworkWindow:
        case SGLyricArtworkTiles:
        case SGLyricArtworkPolaroid:
        case SGLyricArtworkLineNumber:
        case SGLyricArtworkReceipt:
        case SGLyricArtworkTwitter:
        case SGLyricArtworkMagazine:
        case SGLyricArtworkDuotone:
        case SGLyricArtworkGigPoster:
        case SGLyricArtworkPrint:
        case SGLyricArtworkPulseBars:
        case SGLyricArtworkWarpFlow:
        case SGLyricArtworkOLEDStealth:
            return YES;
        default:
            return NO;
    }
}

static double clipSeconds(NSInteger style, SGKaraokeLine *line) {
    if ((style == SGLyricArtworkAura || style == SGLyricArtworkGradient) && line && line.end > line.start) {
        return MIN(5, MAX(2, (line.end - line.start) / 1000.0));
    }
    return 3;
}

// One frame of a clip: the same draws as the stills, under the frame clock.
static UIImage *drawClipFrame(NSInteger style, CGSize size, NSString *prev, NSString *current, NSString *next,
                              UIImage *coverImage, SGKaraokeLine *line, NSString *title, NSString *artist,
                              NSInteger index, NSInteger count, NSInteger prevStart, NSInteger nextStart,
                              double duration, double t) {
    UIImage *image;
    @synchronized (sg_lockObject()) {
        sg_frameTime = t;
        if (style == SGLyricArtworkRecord) {
            image = drawRecordArtwork(size, prev, current, next, coverImage, line, title, artist);
        } else if (style == SGLyricArtworkChat) {
            image = drawChatArtwork(size, prev, current, next, coverImage, line, title, artist);
        } else if (style >= SGLyricArtworkTwitter) {
            image = drawWorkshopArtwork(style, size, prev, current, next, coverImage, line, title, artist,
                                        index, count, prevStart, nextStart, duration);
        } else {
            image = drawLyricArtwork(size, prev, current, next, style, coverImage, line, title, artist);
        }
        sg_frameTime = -1;
    }
    return image;
}

// The clip as the system takes it, the base's own construction (LockScreenArtwork.x):
// a preview image it can show at once and the file it plays.
static id clipArtworkFor(NSString *artworkID, NSURL *file, MPMediaItemArtwork *still) {
    if (@available(iOS 26.0, *)) {
        return [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:artworkID
            previewImageRequestHandler:^(CGSize size, void (^done)(UIImage *image)) {
                done(still ? [still imageWithSize:size] : nil);
            }
            videoAssetFileURLRequestHandler:^(CGSize size, void (^done)(NSURL *url)) {
                done(file);
            }];
    }
    return nil;
}

static void resend(void);

// Called from the tick for every new line: publish the line's clip if one is
// rendered or cached, and set the render going if not. The still is up either
// way, so a line is never waiting on its clip to show something.
static void offerClip(NSString *lineKey, NSInteger style, SGKaraokeLine *line,
                      NSString *prev, NSString *current, NSString *next,
                      MPMediaItemArtwork *cover, NSString *title, NSString *artist,
                      NSInteger index, NSInteger count, NSInteger prevStart, NSInteger nextStart,
                      double duration) {
    if (!SGFlag(SGKeyLyricArtworkAnimated, NO) || !SGAnimatedArtworkAvailable() || !styleAnimates(style)
        || UIAccessibilityIsReduceMotionEnabled()) {
        if (sg_clipArtwork) {
            sg_clipArtwork = nil;
            sg_clipFor = nil;
        }
        return;
    }
    NSString *clipKey = [NSString stringWithFormat:@"%@-%ld-%ld", lineKey, (long)style,
                         (long)effectiveQuality()];
    if ([clipKey isEqualToString:sg_clipFor]) return;
    sg_clipFor = clipKey;
    sg_clipArtwork = nil;
    MPMediaItemArtwork *still = sg_artwork;
    void (^publish)(NSURL *) = ^(NSURL *file) {
        if (!file) return;
        id clip = clipArtworkFor(clipKey, file, still);
        if (!clip) return;
        SGLyricClipSetProtected(clipKey);
        @synchronized (sg_lockObject()) { sg_clipArtwork = clip; }
        SGLog(@"lyric artwork: clip up for %@", clipKey);
        resend();
    };
    NSURL *cached = SGLyricClipCachedFile(clipKey);
    if (cached) {
        publish(cached);
        return;
    }
    CGSize specSize;
    NSInteger specFps;
    clipSpec(&specSize, &specFps);
    // The same artwork object the sample path reads under the lock: its
    // request handler is not promised reentrant, so the reads serialise.
    UIImage *coverImage;
    @synchronized (sg_lockObject()) { coverImage = cover ? [cover imageWithSize:specSize] : nil; }
    SGLyricClipRender(clipKey, specSize, specFps, clipSeconds(style, line), YES,
        ^UIImage *(double t) {
            return drawClipFrame(style, specSize, prev, current, next, coverImage, line,
                                 title, artist, index, count, prevStart, nextStart, duration, t);
        },
        ^(NSURL *file) {
            if ([sg_clipFor isEqualToString:clipKey]) publish(file);
        });
}

// Warm the clips of the lines ahead (Batch 11): rendering is the slow part of
// an animated line change, so the next two lines render while this one plays
// and the change itself is instant. The render queue is serial and the line
// being sung was asked first, so warming never jumps the queue.
static void warmClips(NSString *trackID, NSArray<SGKaraokeLine *> *lines, NSInteger index, NSInteger style,
                      MPMediaItemArtwork *cover, NSString *title, NSString *artist, double duration) {
    if (!SGFlag(SGKeyLyricArtworkAnimated, NO) || !SGAnimatedArtworkAvailable() || !styleAnimates(style)
        || UIAccessibilityIsReduceMotionEnabled()) return;
    // Under real heat there is no warming at all (Batch 23); under Low
    // Power or lesser heat, one line ahead instead of two.
    if (NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateCritical) return;
    NSInteger warmDepth = powerThrifty() ? 1 : 2;
    CGSize specSize;
    NSInteger specFps;
    clipSpec(&specSize, &specFps);
    UIImage *coverImage = nil;
    for (NSInteger ahead = 1; ahead <= warmDepth; ahead++) {
        NSInteger j = index + ahead;
        if (j < 0 || j >= (NSInteger)lines.count) continue;
        // The key the offer itself will build for this line — the
        // line key (track/index/style) plus style and quality again —
        // or the warmed file is never found and the warming was waste
        // heat (Batch 91).
        NSString *clipKey = [NSString stringWithFormat:@"%@/%ld/%ld-%ld-%ld", trackID, (long)j, (long)style,
                             (long)style, (long)effectiveQuality()];
        if (SGLyricClipCachedFile(clipKey)) continue;
        if (!coverImage) {
            @synchronized (sg_lockObject()) { coverImage = cover ? [cover imageWithSize:specSize] : nil; }
        }
        NSString *jPrev = j > 0 ? SGKaraokeLineText(lines[j - 1]) : @"";
        NSString *jCurrent = SGKaraokeLineText(lines[j]);
        NSString *jNext = j + 1 < (NSInteger)lines.count ? SGKaraokeLineText(lines[j + 1]) : @"";
        SGKaraokeLine *jLine = lines[j];
        NSInteger jPrevStart = j > 0 ? lines[j - 1].start : 0;
        NSInteger jNextStart = j + 1 < (NSInteger)lines.count ? lines[j + 1].start : 0;
        NSInteger count = lines.count;
        SGLyricClipRender(clipKey, specSize, specFps, clipSeconds(style, jLine), NO,
            ^UIImage *(double t) {
                return drawClipFrame(style, specSize, jPrev, jCurrent, jNext, coverImage, jLine,
                                     title, artist, j, count, jPrevStart, jNextStart, duration, t);
            },
            ^(NSURL *file) {});
    }
}

// Spotify's info again, so the system picks up the still that has just been drawn; this
// feature's own hook below puts the still in on the way out.
static void resend(void) {
    NSDictionary *info;
    @synchronized (sg_lockObject()) { info = sg_info; }
    if (info.count) MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}

UIImage *SGLyricArtworkCurrentCard(void) {
    MPMediaItemArtwork *artwork;
    @synchronized (sg_lockObject()) { artwork = sg_artwork; }
    return artwork ? [artwork imageWithSize:CGSizeMake(900, 1200)] : nil;
}

MPMediaItemArtwork *SGLyricArtworkCurrentStill(void) {
    @synchronized (sg_lockObject()) { return sg_artwork; }
}

static void clearArtwork(void) {
    if (!sg_artwork && !sg_clipArtwork) return;
    sg_artwork = nil;
    sg_clipArtwork = nil;
    sg_clipFor = nil;
    sg_lineKey = nil;
    SGLog(@"lyric artwork: cleared, the cover is back");
    resend();
}

// The next track's lyrics, fetched while this one still plays (Batch 18):
// when the skip lands, its lines — and with them its first clips — are
// already here. The queue is the player state's `future`, the same list the
// Live Activity reads its up-next from.
static NSString *sg_prefetched;
static void prefetchNext(void) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = player.state;
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    if (![future isKindOfClass:NSArray.class]) return;
    for (id candidate in (NSArray *)future) {
        if (![candidate isKindOfClass:objc_getClass("SPTPlayerTrack")]) continue;
        NSString *uri = SGURIString(((SPTPlayerTrack *)candidate).URI);
        if (![uri hasPrefix:@"spotify:track:"]) continue;
        NSString *nextID = [uri substringFromIndex:14];
        if ([nextID isEqualToString:sg_prefetched]) return;
        // Hysteresis (Batch 21 audit): skipping around changes `future`
        // every few hundred milliseconds, and a fetch per flicker is waste.
        // A candidate has to still be next a tick later (one second on)
        // before anything is fetched for it.
        static NSString *candidate;
        static NSInteger candidateTicks;
        if ([nextID isEqualToString:candidate]) candidateTicks++;
        else { candidate = nextID; candidateTicks = 1; }
        if (candidateTicks < 2) return;
        sg_prefetched = nextID;
        if (!SGKaraokeLinesForTrack(nextID)) {
            SGKaraokeRequestLyrics(nextID);
            SGLog(@"lyric artwork: prefetched the next track's lyrics");
        }
        return;
    }
}

static void tick(void) {
    prefetchNext();
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
    // The style is part of the change key (Batch 89): it used to be read
    // only after the key check, so picking a new style changed nothing
    // on the lock screen until the next lyric line arrived.
    NSInteger style = SGInt(SGKeyLyricArtworkStyle, SGLyricArtworkAura);
    // Shuffle styles (Batch 31): one roll per track, kept for the track's
    // whole run, so a session tours the shelf instead of living in one
    // look. The roll is over every style the picker offers.
    if (SGFlag(SGKeyLyricArtworkShuffle, NO)) {
        static NSString *rolledFor;
        static NSInteger rolled;
        if (![trackID isEqualToString:rolledFor]) {
            rolledFor = [trackID copy];
            rolled = arc4random_uniform((uint32_t)SGLyricArtworkStyleNames().count);
            SGLog(@"lyric artwork: shuffled to %@ for %@", SGLyricArtworkStyleNames()[rolled], trackID);
        }
        style = rolled;
    }
    NSString *key = [NSString stringWithFormat:@"%@/%ld/%ld", trackID, (long)index, (long)style];
    if ([key isEqualToString:sg_lineKey]) return;
    sg_lineKey = key;

    NSString *current = index >= 0 ? SGKaraokeLineText(lines[index]) : @"♪";
    NSString *prev = index > 0 ? SGKaraokeLineText(lines[index - 1]) : @"";
    NSString *next = index + 1 < (NSInteger)lines.count ? SGKaraokeLineText(lines[index + 1]) : @"";
    SGKaraokeLine *line = index >= 0 ? lines[index] : nil;
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerTrack *track = player.state.track;
    NSString *title = track.trackTitle ?: @"", *artist = track.artistName ?: @"";
    // The Workshop styles' facts: where this line sits in the song, its
    // neighbours' starts, and how long the track runs.
    NSInteger lineIndex = MAX(index, 0), lineCount = lines.count;
    NSInteger prevStart = index > 0 ? lines[index - 1].start : 0;
    NSInteger nextStart = index + 1 < (NSInteger)lines.count ? lines[index + 1].start : 0;
    double duration = [player.state respondsToSelector:@selector(duration)] ? player.state.duration : 0;
    MPMediaItemArtwork *cover;
    @synchronized (sg_lockObject()) { cover = sg_cover; }
    // Built aside and stored under the lock (Batch 90): the strong static
    // used to be assigned bare here while the now playing hook and the
    // card reader take it under the lock — the same storeStrong race the
    // picker fixes removed elsewhere in this file.
    MPMediaItemArtwork *fresh = [[MPMediaItemArtwork alloc] initWithBoundsSize:CGSizeMake(900, 1200)
        requestHandler:^UIImage *(CGSize size) {
            @synchronized (sg_lockObject()) {
                UIImage *coverImage = cover ? [cover imageWithSize:size] : nil;
                if (style == SGLyricArtworkRecord) {
                    return drawRecordArtwork(size, prev, current, next, coverImage, line, title, artist);
                }
                if (style == SGLyricArtworkChat) {
                    return drawChatArtwork(size, prev, current, next, coverImage, line, title, artist);
                }
                if (style >= SGLyricArtworkTwitter) {
                    return drawWorkshopArtwork(style, size, prev, current, next, coverImage, line, title, artist,
                                               lineIndex, lineCount, prevStart, nextStart, duration);
                }
                return drawLyricArtwork(size, prev, current, next, style, coverImage, line, title, artist);
            }
        }];
    @synchronized (sg_lockObject()) { sg_artwork = fresh; }
    offerClip(key, style, line, prev, current, next, cover, title, artist,
              lineIndex, lineCount, prevStart, nextStart, duration);
    warmClips(trackID, lines, index, style, cover, title, artist, duration);
    SGLog(@"lyric artwork: %@ — %@", trackID, current);
    resend();
}

// A style drawn once with sample facts, for the picker's thumbnails: the
// playing track's cover when one has been seen, else a painted stand-in — a
// violet-to-amber gradient with a soft disc of light, song-shaped enough for
// every style to show what it does.
// The painted stand-in, drawn once: it used to live in a bare static in
// sampleCover below, checked and stored with no lock at all while the
// picker fired a render per visible cell at once. On a launch where no
// cover had been seen yet, every one of those threads took the painted
// path and raced the strong static's assignment — an over-release
// waiting for the picker's first open (Batch 89).
static UIImage *paintedCover(void) {
    static UIImage *painted;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = 1;
        format.opaque = YES;
        painted = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(600, 600) format:format]
            imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGContextRef ctx = context.CGContext;
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            NSArray *colors = @[(id)[UIColor colorWithRed:0.16 green:0.08 blue:0.35 alpha:1].CGColor,
                                (id)[UIColor colorWithRed:0.85 green:0.35 blue:0.15 alpha:1].CGColor];
            CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
            CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, 0), CGPointMake(600, 600), 0);
            CGGradientRelease(gradient);
            CGColorSpaceRelease(space);
            [[UIColor colorWithWhite:1 alpha:0.85] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(190, 140, 220, 220)] fill];
            [[UIColor colorWithWhite:0 alpha:0.75] setFill];
            UIRectFill(CGRectMake(0, 470, 600, 130));
        }];
    });
    return painted;
}

static UIImage *sampleCover(CGSize size) {
    @synchronized (sg_lockObject()) {
        if (sg_cover) {
            UIImage *real = [sg_cover imageWithSize:CGSizeMake(600, 600)];
            if (real) return real;
        }
    }
    return paintedCover();
}

UIImage *SGLyricArtworkSample(NSInteger style, CGSize size) {
    // The picker's thumbnails, cached per cover (Batch 21 audit): reopening
    // the page used to re-render all twenty-six from nothing.
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    static MPMediaItemArtwork *cacheCover;
    MPMediaItemArtwork *coverNow;
    @synchronized (sg_lockObject()) { coverNow = sg_cover; }
    // The picker asks for its thumbnails from a concurrent queue, one per
    // cell, so the cache's check, reset and store all sit under the same
    // lock as the draw: outside it, two cells could grow the dictionary at
    // once.
    NSString *cacheKey = [NSString stringWithFormat:@"%ld@%.0fx%.0f", (long)style, size.width, size.height];
    @synchronized (sg_lockObject()) {
        // With no cover seen yet both sides of the old test were nil, so
        // the dictionary was never created and every store below silently
        // did nothing — the whole shelf re-rendered on every open.
        if (!cache || cacheCover != coverNow) {
            cache = [NSMutableDictionary dictionary];
            cacheCover = coverNow;
        }
        if (cache[cacheKey]) return cache[cacheKey];
    }
    NSString *prev = @"we were running out of time";
    NSString *current = @"drive through the night with the windows down";
    NSString *next = @"till the city turns to light";
    NSString *title = @"Midnight Run";
    NSString *artist = @"The Night Drivers";
    UIImage *cover = sampleCover(size);
    UIImage *drawn;
    @synchronized (sg_lockObject()) {
        if (style == SGLyricArtworkRecord) {
            drawn = drawRecordArtwork(size, prev, current, next, cover, nil, title, artist);
        } else if (style == SGLyricArtworkChat) {
            drawn = drawChatArtwork(size, prev, current, next, cover, nil, title, artist);
        } else if (style >= SGLyricArtworkTwitter) {
            drawn = drawWorkshopArtwork(style, size, prev, current, next, cover, nil, title, artist,
                                        11, 38, 0, 0, 214);
        } else {
            drawn = drawLyricArtwork(size, prev, current, next, style, cover, nil, title, artist);
        }
    }
    if (drawn) {
        @synchronized (sg_lockObject()) { cache[cacheKey] = drawn; }
    }
    return drawn;
}

// The animated artwork's key in the info dictionary, computed once
// rather than lazily inside the hook, whose threads are not one.
static NSString *sg_animatedKey(void) {
    static NSString *key;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ key = SGAnimatedArtworkKey(NULL); });
    return key;
}

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    MPMediaItemArtwork *artwork;
    id clip;
    @synchronized (sg_lockObject()) {
        id theirs = info[MPMediaItemPropertyArtwork];
        if (theirs && theirs != sg_artwork) sg_cover = theirs;
        sg_info = info;
        artwork = sg_artwork;
        clip = sg_clipArtwork;
    }
    // The lock screen priority (Batch 65), the Lock screen page's choice:
    // the plain cover winning means this hook changes nothing at all; a
    // Canvas winning means the still stays the lyric art's but the
    // animated slot is the Canvas's, so the clip stays home.
    NSInteger priority = SGLockScreenPriority();
    NSDictionary *shown = info;
    if (priority != 2 && artwork && shown[MPMediaItemPropertyArtwork] != artwork) {
        NSMutableDictionary *swapped = [shown mutableCopy];
        swapped[MPMediaItemPropertyArtwork] = artwork;
        shown = swapped;
    }
    if (priority == 0 && clip) {
        shown = SGArtworkInInfo(shown, clip, sg_animatedKey());
    }
    %orig(shown);
}
%end

%ctor {
    if (!SGFlag(SGKeyLyricArtwork, NO)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { tick(); }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
    %init;
    SGRequireClasses(@[@"MPNowPlayingInfoCenter"]);
    SGLog(@"lyric artwork: on");
}
