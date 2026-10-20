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

static NSObject *sg_lock;
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

static CIContext *sg_ciContext;
static CIContext *ciContext(void) {
    if (!sg_ciContext) sg_ciContext = [CIContext contextWithOptions:nil];
    return sg_ciContext;
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
        if (sg_frameTime >= 0) {
            double k = MIN(1, sg_frameTime / 0.35);
            y += (1 - (1 - pow(1 - k, 3))) * size.height * 0.03;
        }
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
    CGImageRef cg = [ciContext() createCGImage:filter.outputImage
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

// Twitter: the song as a post. The artist posts, the last line was an earlier
// post, the line being sung is the big one, and the counts are the song's own
// numbers dressed up — no service was consulted for them.
static void drawTwitter(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    drawText(@"Post", CGRectMake(0, size.height * 0.045, size.width, size.height * 0.03),
             [UIFont boldSystemFontOfSize:size.height * 0.024], UIColor.whiteColor, NSTextAlignmentCenter);
    CGFloat y = size.height * 0.105;
    // The poster's avatar is the cover, round.
    CGFloat avatar = size.width * 0.105;
    if (c->cover) {
        CGContextSaveGState(UIGraphicsGetCurrentContext());
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(margin, y, avatar, avatar)] addClip];
        drawCoverInRect(c->cover, CGRectMake(margin, y, avatar, avatar));
        CGContextRestoreGState(UIGraphicsGetCurrentContext());
    }
    CGFloat textX = margin + avatar + size.width * 0.03;
    drawText(c->artist, CGRectMake(textX, y, width - avatar, size.height * 0.03),
             [UIFont boldSystemFontOfSize:size.height * 0.023], UIColor.whiteColor, NSTextAlignmentLeft);
    // The verified tick: a small blue disc with a check.
    CGFloat nameWidth = [c->artist sizeWithAttributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:size.height * 0.023]}].width;
    CGRect tick = CGRectMake(textX + nameWidth + 6, y + size.height * 0.004, size.height * 0.02, size.height * 0.02);
    [[UIColor colorWithRed:0.11 green:0.61 blue:0.94 alpha:1] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:tick] fill];
    drawText(@"✓", CGRectInset(tick, 1, -1), [UIFont boldSystemFontOfSize:size.height * 0.014],
             UIColor.whiteColor, NSTextAlignmentCenter);
    NSString *handle = [[c->artist.lowercaseString componentsSeparatedByCharactersInSet:
        [[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
    drawText([NSString stringWithFormat:@"@%@ · 2h", handle.length ? handle : @"artist"],
             CGRectMake(textX, y + size.height * 0.028, width - avatar, size.height * 0.025),
             [UIFont systemFontOfSize:size.height * 0.019], [UIColor colorWithWhite:1 alpha:0.45], NSTextAlignmentLeft);
    y += avatar + size.height * 0.02;
    if (c->prev.length) {
        drawText(c->prev, CGRectMake(margin, y, width, size.height * 0.09),
                 [UIFont systemFontOfSize:size.height * 0.021], [UIColor colorWithWhite:1 alpha:0.45], NSTextAlignmentLeft);
        y += textHeight(c->prev, [UIFont systemFontOfSize:size.height * 0.021], width) + size.height * 0.025;
    }
    UIFont *postFont = [UIFont boldSystemFontOfSize:size.height * 0.037];
    drawText(c->current, CGRectMake(margin, y, width, size.height * 0.22), postFont, UIColor.whiteColor, NSTextAlignmentLeft);
    y += textHeight(c->current, postFont, width) + size.height * 0.03;
    NSDateFormatter *clock = [NSDateFormatter new];
    clock.dateFormat = @"h:mm a";
    NSDateFormatter *day = [NSDateFormatter new];
    day.dateFormat = @"MMMM d, yyyy";
    NSDate *now = [NSDate date];
    seedRand(c->title);
    NSInteger views = 12 + (NSInteger)(nextRand() * 880) + (sg_frameTime >= 0 ? (NSInteger)(sg_frameTime * 2.5) : 0);
    drawText([NSString stringWithFormat:@"%@ · %@ · %ldK Views", [clock stringFromDate:now], [day stringFromDate:now], (long)views],
             CGRectMake(margin, y, width, size.height * 0.025),
             [UIFont systemFontOfSize:size.height * 0.018], [UIColor colorWithWhite:1 alpha:0.45], NSTextAlignmentLeft);
    y += size.height * 0.045;
    fillRect(CGRectMake(margin, y, width, 1), [UIColor colorWithWhite:1 alpha:0.15]);
    y += size.height * 0.018;
    UIFont *countFont = [UIFont systemFontOfSize:size.height * 0.019];
    UIColor *grey = [UIColor colorWithWhite:1 alpha:0.5];
    CGFloat x = margin;
    for (NSString *pair in @[[NSString stringWithFormat:@"💬 %ld", (long)(40 + (NSInteger)(nextRand() * 400))],
                             [NSString stringWithFormat:@"⟳ %ld", (long)(80 + (NSInteger)(nextRand() * 900))]]) {
        CGFloat w = [pair sizeWithAttributes:@{NSFontAttributeName: countFont}].width + size.width * 0.06;
        drawText(pair, CGRectMake(x, y, w, size.height * 0.025), countFont, grey, NSTextAlignmentLeft);
        x += w;
    }
    NSString *hearts = [NSString stringWithFormat:@"♥ %.1fK", 1 + nextRand() * 9];
    drawText(hearts, CGRectMake(x, y, size.width * 0.3, size.height * 0.025), countFont,
             [UIColor colorWithRed:0.98 green:0.35 blue:0.6 alpha:1], NSTextAlignmentLeft);
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
    UIImage *mask = knockoutImage(size, ^{
        drawStackedWords(words, fontSize, size.height * 0.05, size, YES, UIColor.whiteColor);
    });
    if (c->cover) {
        if (sg_frameTime >= 0) drawCoverInRect(c->cover, breathingRect(CGRectMake(0, 0, size.width, size.height), size.width * 0.03, size.width * 0.008));
        else drawCoverFilled(c->cover, size);
    }
    // The fade down: darkness gathered over the cover before the letters cut in.
    drawScrim(size, 0.10, 0.88);
    [mask drawInRect:CGRectMake(0, 0, size.width, size.height)];
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
    NSString *small = [NSString stringWithFormat:@"Nº %ld      %@      %@", (long)(c->index + 1),
                       c->title.uppercaseString, [[month stringFromDate:[NSDate date]] uppercaseString]];
    drawText(small, CGRectMake(margin, y, width, size.height * 0.02),
             [UIFont systemFontOfSize:size.height * 0.014 weight:UIFontWeightMedium],
             [UIColor colorWithWhite:1 alpha:0.85], NSTextAlignmentCenter);
    if (c->prev.length) {
        drawText(c->prev, CGRectMake(margin, size.height * 0.30, width * 0.55, size.height * 0.08),
                 serifFont(size.height * 0.019, UIFontWeightRegular, YES),
                 [UIColor colorWithWhite:1 alpha:0.8], NSTextAlignmentLeft);
    }
    UIFont *headline = serifFont(size.height * 0.044, UIFontWeightBold, NO);
    CGFloat headlineY = size.height * 0.52;
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
}

// Duotone: the cover in two tones of its own — its darkest colour and its
// lightest — with the lines kept low and quiet.
static void drawDuotone(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    if (c->cover) {
        UIColor *dark = [UIColor colorWithWhite:0.04 alpha:1];
        UIColor *light = c->accent ?: [UIColor colorWithRed:0.95 green:0.75 blue:0.35 alpha:1];
        if (c->average) {
            CGFloat h = 0, s = 0, b = 0;
            [c->average getHue:&h saturation:&s brightness:&b alpha:NULL];
            dark = [UIColor colorWithHue:h saturation:MIN(1, s + 0.2) brightness:0.10 alpha:1];
        }
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = 1;
        format.opaque = YES;
        UIImage *strip = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(256, 1) format:format]
            imageWithActions:^(UIGraphicsImageRendererContext *stripContext) {
            CGContextRef ctx = stripContext.CGContext;
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            NSArray *colors = @[(id)dark.CGColor, (id)light.CGColor];
            CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
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
    drawScrim(size, 0.0, 0.35);
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    UIFont *nowFont = [UIFont boldSystemFontOfSize:size.height * 0.034];
    CGFloat y = size.height * 0.78;
    drawText(c->current, CGRectMake(margin, y, width, size.height * 0.10), nowFont, UIColor.whiteColor, NSTextAlignmentLeft);
    y += textHeight(c->current, nowFont, width) + size.height * 0.01;
    drawText(c->next, CGRectMake(margin, y, width, size.height * 0.05),
             [UIFont systemFontOfSize:size.height * 0.022], [UIColor colorWithWhite:1 alpha:0.55], NSTextAlignmentLeft);
}

// Word collage: the song's words as ransom-note strips over red, the line
// itself set plain in a grey panel in the middle. The chaos is seeded by the
// song, so a given line always lands the same way.
static void drawWordCollage(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithRed:0.80 green:0.07 blue:0.09 alpha:1]);
    seedRand([NSString stringWithFormat:@"%@%ld", c->title, (long)c->index]);
    NSMutableArray<NSString *> *strips = [NSMutableArray array];
    for (NSString *word in [c->current componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (word.length) [strips addObject:word];
    }
    for (NSString *extra in @[c->prev, c->title.uppercaseString, c->artist.uppercaseString]) {
        if (extra.length) [strips addObject:extra];
    }
    NSArray<UIColor *> *papers = @[UIColor.whiteColor, [UIColor colorWithWhite:0.08 alpha:1],
                                   [UIColor colorWithWhite:0.82 alpha:1], [UIColor colorWithRed:0.55 green:0.04 blue:0.05 alpha:1]];
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    for (NSUInteger i = 0; i < strips.count; i++) {
        NSString *word = strips[i];
        CGFloat fontSize = size.height * (0.020 + nextRand() * 0.022);
        UIFont *font = [UIFont boldSystemFontOfSize:fontSize];
        CGSize wordSize = [word sizeWithAttributes:@{NSFontAttributeName: font}];
        CGFloat w = wordSize.width + size.width * 0.03, h = wordSize.height + size.height * 0.012;
        CGFloat x = nextRand() * (size.width - w), y = nextRand() * (size.height - h);
        if (y > size.height * 0.38 && y < size.height * 0.62) y += size.height * 0.30;
        NSUInteger pick = (NSUInteger)(nextRand() * papers.count) % papers.count;
        UIColor *paper = papers[pick];
        BOOL darkPaper = pick == 1 || pick == 3;
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, x + w / 2, y + h / 2);
        CGContextRotateCTM(ctx, (nextRand() - 0.5) * 0.35);
        if (sg_frameTime >= 0) {
            double k = MIN(1, MAX(0, (sg_frameTime - i * 0.06) / 0.3));
            double e = 1 - pow(1 - k, 3);
            CGContextTranslateCTM(ctx, 0, (1 - e) * size.height * 0.035 * ((i % 2) ? 1 : -1));
        }
        fillRect(CGRectMake(-w / 2, -h / 2, w, h), paper);
        drawText(word, CGRectMake(-w / 2, -h / 2 + size.height * 0.004, w, h), font,
                 darkPaper ? UIColor.whiteColor : [UIColor colorWithWhite:0.08 alpha:1], NSTextAlignmentCenter);
        CGContextRestoreGState(ctx);
    }
    CGRect panel = CGRectMake(size.width * 0.07, size.height * 0.415, size.width * 0.86, size.height * 0.17);
    fillRect(panel, [UIColor colorWithWhite:0.80 alpha:1]);
    CGFloat fontSize = size.height * 0.034;
    UIFont *font = [UIFont boldSystemFontOfSize:fontSize];
    while (fontSize > size.height * 0.016 &&
           [c->current sizeWithAttributes:@{NSFontAttributeName: font}].width > panel.size.width * 0.9) {
        fontSize *= 0.9;
        font = [UIFont boldSystemFontOfSize:fontSize];
    }
    drawText(c->current, CGRectInset(panel, size.width * 0.03, size.height * 0.02), font,
             [UIColor colorWithWhite:0.06 alpha:1], NSTextAlignmentCenter);
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
    CGContextSetStrokeColorWithColor(ctx, neon.CGColor);
    CGContextSetLineWidth(ctx, 2);
    CGContextStrokeRect(ctx, CGRectMake(size.width * 0.03, size.height * 0.025, size.width * 0.94, size.height * 0.95));
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
    UIFont *font = [UIFont systemFontOfSize:size.height * 0.030];
    UIFont *nowFont = [UIFont systemFontOfSize:size.height * 0.034 weight:UIFontWeightSemibold];
    // Incoming outlined bubbles for what was sung, a filled one for the line,
    // an outlined one for what is next.
    struct { __unsafe_unretained NSString *text; __unsafe_unretained UIFont *font; __unsafe_unretained UIColor *fill; __unsafe_unretained UIColor *stroke; __unsafe_unretained UIColor *ink; BOOL right; } rows[3] = {
        {c->prev, font, nil, neon, [UIColor colorWithWhite:1 alpha:0.75], NO},
        {c->current, nowFont, green, nil, [UIColor colorWithWhite:0.02 alpha:1], YES},
        {c->next, font, nil, neon, [UIColor colorWithWhite:1 alpha:0.55], NO},
    };
    for (int i = 0; i < 3; i++) {
        if (!rows[i].text.length) continue;
        CGFloat maxText = size.width * 0.62;
        CGRect measured = [rows[i].text boundingRectWithSize:CGSizeMake(maxText, CGFLOAT_MAX)
                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                  attributes:@{NSFontAttributeName: rows[i].font} context:nil];
        CGFloat padX = size.width * 0.035, padY = size.height * 0.011;
        CGFloat w = ceil(measured.size.width) + 2 * padX, h = ceil(measured.size.height) + 2 * padY;
        CGFloat x = rows[i].right ? size.width * 0.91 - w : margin;
        CGRect bubble = CGRectMake(x, y, w, h);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bubble cornerRadius:h * 0.30];
        if (rows[i].fill) { [rows[i].fill setFill]; [path fill]; }
        if (rows[i].stroke) { [rows[i].stroke setStroke]; path.lineWidth = 1.5; [path stroke]; }
        drawText(rows[i].text, CGRectMake(x + padX, y + padY, measured.size.width, measured.size.height),
                 rows[i].font, rows[i].ink, NSTextAlignmentLeft);
        y += h + size.height * 0.018;
    }
}

// Old TV: the song on a CRT in a dark room — rabbit ears, knobs, scanlines, a
// green PLAY tag and the line glowing on curved glass.
static void drawOldTV(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0.02 alpha:1]);
    if (c->average) fillRect(CGRectMake(0, 0, size.width, size.height), [c->average colorWithAlphaComponent:0.08]);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect body = CGRectMake(size.width * 0.08, size.height * 0.20, size.width * 0.84, size.height * 0.46);
    // Rabbit ears.
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.55].CGColor);
    CGContextSetLineWidth(ctx, 3);
    CGPoint top = CGPointMake(CGRectGetMidX(body), body.origin.y);
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
    CGRect screen = CGRectMake(body.origin.x + size.width * 0.035, body.origin.y + size.height * 0.035,
                               body.size.width * 0.76, body.size.height - size.height * 0.07);
    UIBezierPath *screenPath = [UIBezierPath bezierPathWithRoundedRect:screen cornerRadius:size.height * 0.045];
    fillRect(screen, [UIColor colorWithWhite:0.05 alpha:1]);
    [screenPath fill];
    CGContextSaveGState(ctx);
    [screenPath addClip];
    if (c->cover) {
        drawCoverInRect(c->cover, screen);
        fillRect(screen, [UIColor colorWithWhite:0 alpha:0.45]);
    }
    [[UIColor colorWithWhite:0 alpha:0.10] setFill];
    for (CGFloat ly = screen.origin.y; ly < CGRectGetMaxY(screen); ly += 5) UIRectFill(CGRectMake(screen.origin.x, ly, screen.size.width, 1.5));
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
    UIFont *rainFont = monoFont(size.height * 0.016, UIFontWeightRegular);
    CGFloat column = size.width * 0.052;
    for (CGFloat x = size.width * 0.02; x < size.width; x += column) {
        CGFloat startY = -nextRand() * size.height * 0.5;
        if (sg_frameTime >= 0) {
            // The rain falls while a clip renders: each column at its own pace.
            CGFloat fall = sg_frameTime * size.height * (0.07 + nextRand() * 0.11);
            startY += fmod(fall, size.height * 1.2);
        }
        NSInteger length = 6 + (NSInteger)(nextRand() * 16);
        for (NSInteger i = 0; i < length; i++) {
            unichar ch = [glyphs characterAtIndex:(NSUInteger)(nextRand() * glyphs.length) % glyphs.length];
            NSString *glyph = [NSString stringWithCharacters:&ch length:1];
            CGFloat alpha = i == length - 1 ? 0.75 : 0.10 + 0.30 * (i / (CGFloat)length);
            drawText(glyph, CGRectMake(x, startY + i * size.height * 0.021, column, size.height * 0.021),
                     rainFont, [UIColor colorWithRed:0.1 green:1 blue:0.35 alpha:alpha], NSTextAlignmentLeft);
        }
    }
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0 alpha:0.30]);
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
        CGFloat x = (size.width - widthOfRow) / 2;
        for (NSArray *item in aRow) {
            CGFloat w = [item[1] doubleValue];
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, x + w / 2, y + rowHeight / 2);
            CGContextRotateCTM(ctx, (nextRand() - 0.5) * 0.13);
            if (sg_frameTime >= 0) {
                // The labels pop in one by one while a clip renders, with a
                // little overshoot as each lands (an ease-out-back).
                double local = MIN(1, MAX(0, (sg_frameTime - labelAt * 0.07) / 0.22));
                double back = 1 + 2.7 * pow(local - 1, 3) + 1.7 * pow(local - 1, 2);
                CGFloat scale = local <= 0 ? 0.001 : (CGFloat)back;
                CGContextScaleCTM(ctx, scale, scale);
            }
            labelAt++;
            fillRect(CGRectMake(-w / 2, -rowHeight / 2, w, rowHeight), blackLabel ? [UIColor colorWithWhite:0.05 alpha:1] : UIColor.whiteColor);
            drawText(item[0], CGRectMake(-w / 2, -rowHeight / 2 + padY * 0.7, w, rowHeight), font,
                     blackLabel ? UIColor.whiteColor : [UIColor colorWithWhite:0.05 alpha:1], NSTextAlignmentCenter);
            CGContextRestoreGState(ctx);
            blackLabel = !blackLabel;
            x += w + gap;
        }
        y += rowHeight + gap;
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
    CGRect paper = CGRectMake((size.width - paperW) / 2, size.height * 0.09, paperW, size.height * 0.68);
    fillRect(paper, [UIColor colorWithRed:0.96 green:0.945 blue:0.91 alpha:1]);
    CGFloat inner = paperW * 0.86, ix = paper.origin.x + paperW * 0.07;
    CGFloat y = paper.origin.y + size.height * 0.03;
    UIColor *ink = [UIColor colorWithWhite:0.08 alpha:1], *grey = [UIColor colorWithWhite:0.45 alpha:1];
    drawText(c->title.uppercaseString, CGRectMake(ix, y, inner, size.height * 0.03),
             monoFont(size.height * 0.021, UIFontWeightBold), ink, NSTextAlignmentCenter);
    y += size.height * 0.032;
    drawText(c->artist.uppercaseString, CGRectMake(ix, y, inner, size.height * 0.025),
             monoFont(size.height * 0.018, UIFontWeightRegular), ink, NSTextAlignmentCenter);
    y += size.height * 0.045;
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
        NSString *row = [NSString stringWithFormat:@"%@  %@", fmtClock(items[i].start), items[i].text.uppercaseString];
        CGFloat h = textHeight(row, items[i].font, inner);
        drawText(row, CGRectMake(ix, y, inner, h + 4), items[i].font, items[i].color, NSTextAlignmentLeft);
        y += h + size.height * 0.018;
    }
    y += size.height * 0.01;
    dashed(y);
    y += size.height * 0.02;
    drawText([NSString stringWithFormat:@"#%ld OF %ld", (long)(c->index + 1), (long)MAX(c->count, c->index + 1)],
             CGRectMake(ix, y, inner, size.height * 0.025), monoFont(size.height * 0.017, UIFontWeightRegular), ink, NSTextAlignmentCenter);
    // The barcode: seeded bars along the foot of the slip.
    seedRand(c->title);
    CGFloat bx = ix + inner * 0.08;
    CGFloat barcodeY = paper.origin.y + paper.size.height - size.height * 0.075;
    while (bx < ix + inner * 0.9) {
        CGFloat bw = 1.5 + nextRand() * 4.5;
        if (nextRand() > 0.35) fillRect(CGRectMake(bx, barcodeY, bw, size.height * 0.045), ink);
        bx += bw + 1.5 + nextRand() * 3;
    }
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
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithRed:0.87 green:0.86 blue:0.83 alpha:1]);
    NSArray<NSString *> *words = [c->current.uppercaseString
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (!words.count) words = @[@"♪"];
    CGFloat fontSize = stackedFontSize(words, size, 0.86);
    UIFont *font = [UIFont boldSystemFontOfSize:fontSize];
    CGFloat y = size.height * 0.06;
    BOOL black = YES;
    NSInteger wordAt = 0;
    for (NSString *word in words) {
        CGRect wordRect = CGRectMake(size.width * 0.07, y, size.width * 0.86, fontSize * 1.2);
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
            drawText(word, wordRect, font,
                     black ? [UIColor colorWithWhite:0.05 alpha:1] : UIColor.whiteColor, NSTextAlignmentLeft);
            CGContextRestoreGState(ctx);
        } else {
            drawText(word, wordRect, font,
                     black ? [UIColor colorWithWhite:0.05 alpha:1] : UIColor.whiteColor, NSTextAlignmentLeft);
        }
        y += fontSize * 0.94;
        black = !black;
        wordAt++;
    }
    NSString *credit = [NSString stringWithFormat:@"%@ — %@", c->title.uppercaseString, c->artist.uppercaseString];
    drawText(credit, CGRectMake(size.width * 0.07, MIN(y + size.height * 0.03, size.height * 0.9), size.width * 0.86, size.height * 0.025),
             [UIFont systemFontOfSize:size.height * 0.016 weight:UIFontWeightMedium],
             [UIColor colorWithWhite:0.25 alpha:1], NSTextAlignmentLeft);
}

// Holo: the song as a holographic trading card — frosted panel, picture
// window, the line with a glitch edge.
static void drawHolo(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:0.85 alpha:1]);
    if (c->cover) {
        UIImage *soft = blurred(c->cover, MAX(24, size.width * 0.08));
        if (soft) drawCoverFilled(soft, size);
        fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithWhite:1 alpha:0.45]);
    }
    CGRect card = CGRectMake(size.width * 0.07, size.height * 0.07, size.width * 0.86, size.height * 0.78);
    UIBezierPath *cardPath = [UIBezierPath bezierPathWithRoundedRect:card cornerRadius:size.height * 0.022];
    [[UIColor colorWithWhite:1 alpha:0.85] setFill];
    [cardPath fill];
    [[UIColor colorWithWhite:1 alpha:0.9] setStroke];
    cardPath.lineWidth = 1.5;
    [cardPath stroke];
    CGFloat ix = card.origin.x + size.width * 0.05, iw = card.size.width - size.width * 0.10;
    CGFloat y = card.origin.y + size.height * 0.025;
    UIColor *ink = [UIColor colorWithWhite:0.10 alpha:1];
    drawText(c->title, CGRectMake(ix, y, iw * 0.75, size.height * 0.03),
             [UIFont boldSystemFontOfSize:size.height * 0.024], ink, NSTextAlignmentLeft);
    drawText([NSString stringWithFormat:@"%ld", (long)(c->duration > 0 ? c->duration : 380)],
             CGRectMake(ix, y, iw, size.height * 0.03), [UIFont boldSystemFontOfSize:size.height * 0.024],
             [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:1], NSTextAlignmentRight);
    y += size.height * 0.045;
    CGRect window = CGRectMake(ix, y, iw, size.height * 0.30);
    if (c->cover) {
        CGContextSaveGState(UIGraphicsGetCurrentContext());
        [[UIBezierPath bezierPathWithRoundedRect:window cornerRadius:8] addClip];
        drawCoverInRect(c->cover, window);
        CGContextRestoreGState(UIGraphicsGetCurrentContext());
    }
    y += size.height * 0.315;
    drawText([NSString stringWithFormat:@"%@ · %@", c->artist, c->title],
             CGRectMake(ix, y, iw, size.height * 0.02), [UIFont systemFontOfSize:size.height * 0.014],
             [UIColor colorWithWhite:0.35 alpha:1], NSTextAlignmentLeft);
    y += size.height * 0.032;
    UIFont *lineFont = [UIFont boldSystemFontOfSize:size.height * 0.028];
    CGFloat lineH = textHeight(c->current, lineFont, iw);
    drawText(c->current, CGRectMake(ix - 1.5, y, iw, lineH + 4), lineFont, [UIColor colorWithRed:1 green:0.2 blue:0.3 alpha:0.45], NSTextAlignmentLeft);
    drawText(c->current, CGRectMake(ix + 1.5, y, iw, lineH + 4), lineFont, [UIColor colorWithRed:0.2 green:0.6 blue:1 alpha:0.45], NSTextAlignmentLeft);
    drawText(c->current, CGRectMake(ix, y, iw, lineH + 4), lineFont, ink, NSTextAlignmentLeft);
    y += lineH + size.height * 0.008;
    drawText(fmtClock(c->line.start), CGRectMake(ix, y, iw, size.height * 0.02),
             monoFont(size.height * 0.014, UIFontWeightRegular), [UIColor colorWithWhite:0.45 alpha:1], NSTextAlignmentLeft);
    y += size.height * 0.028;
    if (c->line.translation.length) {
        drawText(c->line.translation, CGRectMake(ix, y, iw, size.height * 0.035),
                 serifFont(size.height * 0.017, UIFontWeightRegular, YES), [UIColor colorWithWhite:0.30 alpha:1], NSTextAlignmentLeft);
        y += size.height * 0.035;
    }
    fillRect(CGRectMake(ix, y, iw, 1), [UIColor colorWithWhite:0 alpha:0.12]);
    y += size.height * 0.015;
    drawText(c->next, CGRectMake(ix, y, iw, size.height * 0.03),
             [UIFont systemFontOfSize:size.height * 0.017], [UIColor colorWithWhite:0.45 alpha:1], NSTextAlignmentLeft);
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
    }
    fillRect(CGRectMake(0, 0, size.width * 0.05, size.height), [UIColor colorWithRed:1 green:0.1 blue:0.8 alpha:0.20]);
    fillRect(CGRectMake(size.width * 0.95, 0, size.width * 0.05, size.height), [UIColor colorWithRed:1 green:0.85 blue:0.1 alpha:0.16]);
    NSString *shout = c->current.uppercaseString;
    UIFont *font = monoFont(size.height * 0.034, UIFontWeightBold);
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    CGFloat h = textHeight(shout, font, width);
    CGFloat y = size.height * 0.42;
    CGFloat off = size.width * 0.012 * (sg_frameTime >= 0 ? 0.6 + 0.6 * sin(sg_frameTime * 3.9) : 1);
    drawText(shout, CGRectMake(margin - off, y, width, h + 4), font, [UIColor colorWithRed:1 green:0.15 blue:0.2 alpha:0.85], NSTextAlignmentLeft);
    drawText(shout, CGRectMake(margin + off, y, width, h + 4), font, [UIColor colorWithRed:0.1 green:0.9 blue:1 alpha:0.85], NSTextAlignmentLeft);
    drawText(shout, CGRectMake(margin, y, width, h + 4), font, [UIColor colorWithWhite:1 alpha:0.55], NSTextAlignmentLeft);
    drawText(c->next, CGRectMake(margin, y + h + size.height * 0.025, width, size.height * 0.04),
             [UIFont systemFontOfSize:size.height * 0.020], [UIColor colorWithWhite:1 alpha:0.55], NSTextAlignmentLeft);
}

// Window: a gallery piece — the cover in an arched frame on cream, the line
// in italic serif beneath.
static void drawWindow(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithRed:0.955 green:0.937 blue:0.885 alpha:1]);
    CGRect frame = CGRectMake(size.width * 0.235, size.height * 0.06, size.width * 0.53, size.height * 0.47);
    CGFloat radius = frame.size.width / 2;
    UIBezierPath *arch = [UIBezierPath new];
    [arch moveToPoint:CGPointMake(frame.origin.x, CGRectGetMaxY(frame))];
    [arch addLineToPoint:CGPointMake(frame.origin.x, frame.origin.y + radius)];
    [arch addArcWithCenter:CGPointMake(CGRectGetMidX(frame), frame.origin.y + radius) radius:radius
                startAngle:M_PI endAngle:0 clockwise:YES];
    [arch addLineToPoint:CGPointMake(CGRectGetMaxX(frame), CGRectGetMaxY(frame))];
    [arch closePath];
    if (c->cover) {
        CGContextSaveGState(UIGraphicsGetCurrentContext());
        [arch addClip];
        drawCoverInRect(c->cover, breathingRect(CGRectMake(frame.origin.x, frame.origin.y, frame.size.width, frame.size.height + radius * 0.4), size.width * 0.02, size.width * 0.006));
        CGContextRestoreGState(UIGraphicsGetCurrentContext());
    }
    [[UIColor colorWithWhite:0.15 alpha:1] setStroke];
    arch.lineWidth = 2;
    [arch stroke];
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
    CGRect burst = CGRectMake(size.width * 0.19, size.height * 0.07, size.width * 0.62, size.width * 0.62);
    CGPoint centre = CGPointMake(CGRectGetMidX(burst), CGRectGetMidY(burst));
    CGFloat outer = burst.size.width / 2, inner = outer * 0.80;
    UIBezierPath *star = [UIBezierPath new];
    NSInteger points = 18;
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
    CGContextTranslateCTM(ctx, 9, 7);
    [[UIColor colorWithRed:0.95 green:0.45 blue:0.75 alpha:1] setFill];
    [star fill];
    CGContextRestoreGState(ctx);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 4.5, 3.5);
    [[UIColor colorWithRed:0.40 green:0.70 blue:0.95 alpha:1] setFill];
    [star fill];
    CGContextRestoreGState(ctx);
    if (c->cover) {
        CGContextSaveGState(ctx);
        [star addClip];
        drawCoverInRect(c->cover, burst);
        CGContextRestoreGState(ctx);
    }
    CGFloat y = CGRectGetMaxY(burst) + size.height * 0.05;
    UIFont *nowFont = [UIFont boldSystemFontOfSize:size.height * 0.032];
    drawText(c->current, CGRectMake(size.width * 0.07, y, size.width * 0.86, size.height * 0.10),
             nowFont, UIColor.whiteColor, NSTextAlignmentCenter);
    y += textHeight(c->current, nowFont, size.width * 0.86) + size.height * 0.012;
    drawText(c->next, CGRectMake(size.width * 0.07, y, size.width * 0.86, size.height * 0.05),
             [UIFont systemFontOfSize:size.height * 0.021], [UIColor colorWithWhite:1 alpha:0.55], NSTextAlignmentCenter);
}

// Print: newsprint — the cover as halftone dots dissolving into paper, a red
// tag, and the line in serif over black marker bars.
static UIImage *halftoneOf(UIImage *cover) {
    static UIImage *memo, *memoFor;
    if (memo && memoFor == cover) return memo;
    CIFilter *dots = [CIFilter filterWithName:@"CIDotScreen"];
    [dots setValue:[CIImage imageWithCGImage:cover.CGImage] forKey:kCIInputImageKey];
    [dots setValue:@(6.0) forKey:@"inputWidth"];
    [dots setValue:@(0.75) forKey:@"inputSharpness"];
    memo = ciResult(cover, dots);
    memoFor = cover;
    return memo;
}

static void drawPrint(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithRed:0.80 green:0.78 blue:0.72 alpha:1]);
    if (c->cover) {
        UIImage *halftone = halftoneOf(c->cover);
        if (halftone) drawCoverInRect(halftone, breathingRect(CGRectMake(0, 0, size.width, size.height * 0.55), size.width * 0.015, size.width * 0.005));
        // The dissolve: paper colour gathered from the middle down.
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = 1;
        format.opaque = NO;
        UIImage *fade = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
            imageWithActions:^(UIGraphicsImageRendererContext *fadeContext) {
            CGContextRef ctx = fadeContext.CGContext;
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            UIColor *paper = [UIColor colorWithRed:0.80 green:0.78 blue:0.72 alpha:1];
            CGFloat r, g, b;
            [paper getRed:&r green:&g blue:&b alpha:NULL];
            CGFloat components[] = {r, g, b, 0, r, g, b, 1};
            CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, NULL, 2);
            CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, size.height * 0.28), CGPointMake(0, size.height * 0.62), 0);
            CGGradientRelease(gradient);
            CGColorSpaceRelease(space);
        }];
        [fade drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }
    CGRect tag = CGRectMake(size.width * 0.06, size.height * 0.035, 0, size.height * 0.034);
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
    for (NSString *rowText in rowsText) {
        CGFloat w = [rowText sizeWithAttributes:@{NSFontAttributeName: font}].width + size.width * 0.03;
        fillRect(CGRectMake(x0 - size.width * 0.012, y, w, rowH), [UIColor colorWithWhite:0.05 alpha:1]);
        drawText(rowText, CGRectMake(x0, y + size.height * 0.006, w, rowH), font, UIColor.whiteColor, NSTextAlignmentLeft);
        y += rowH + size.height * 0.008;
    }
}

// Tiles: the cover in a mosaic of twelve, the lines beneath.
static void drawTiles(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    if (c->cover.CGImage) {
        CGFloat gridW = size.width * 0.88, gridH = size.height * 0.42;
        CGFloat gx = (size.width - gridW) / 2, gy = size.height * 0.05, gap = size.width * 0.012;
        CGFloat tileW = (gridW - 3 * gap) / 4, tileH = (gridH - 2 * gap) / 3;
        CGFloat px = CGImageGetWidth(c->cover.CGImage), py = CGImageGetHeight(c->cover.CGImage);
        for (int row = 0; row < 3; row++) {
            for (int col = 0; col < 4; col++) {
                CGRect crop = CGRectMake(px * col / 4, py * row / 3, px / 4, py / 3);
                CGImageRef piece = CGImageCreateWithImageInRect(c->cover.CGImage, crop);
                if (!piece) continue;
                UIImage *tile = [UIImage imageWithCGImage:piece];
                CGImageRelease(piece);
                CGRect tileRect = CGRectMake(gx + col * (tileW + gap), gy + row * (tileH + gap), tileW, tileH);
                if (sg_frameTime >= 0) {
                    double k = MIN(1, MAX(0, (sg_frameTime - (row * 4 + col) * 0.045) / 0.3));
                    double e = 1 - pow(1 - k, 3);
                    CGContextRef ctx = UIGraphicsGetCurrentContext();
                    CGContextSaveGState(ctx);
                    CGContextTranslateCTM(ctx, CGRectGetMidX(tileRect), CGRectGetMidY(tileRect));
                    CGContextScaleCTM(ctx, MAX(0.001, e), 1);
                    CGContextTranslateCTM(ctx, -CGRectGetMidX(tileRect), -CGRectGetMidY(tileRect));
                    [tile drawInRect:tileRect];
                    CGContextRestoreGState(ctx);
                } else {
                    [tile drawInRect:tileRect];
                }
            }
        }
    }
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    CGFloat y = size.height * 0.55;
    UIFont *nowFont = [UIFont boldSystemFontOfSize:size.height * 0.032];
    drawText(c->current, CGRectMake(margin, y, width, size.height * 0.10), nowFont, UIColor.whiteColor, NSTextAlignmentLeft);
    y += textHeight(c->current, nowFont, width) + size.height * 0.012;
    drawText(c->next, CGRectMake(margin, y, width, size.height * 0.05),
             [UIFont systemFontOfSize:size.height * 0.021], [UIColor colorWithWhite:1 alpha:0.5], NSTextAlignmentLeft);
}

// Polaroid: an instant print, taped and tipped, the line handwritten in the
// white strip.
static void drawPolaroid(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithRed:0.15 green:0.10 blue:0.075 alpha:1]);
    if (c->average) fillRect(CGRectMake(0, 0, size.width, size.height), [c->average colorWithAlphaComponent:0.10]);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGPoint centre = CGPointMake(size.width / 2, size.height * 0.38);
    CGContextTranslateCTM(ctx, centre.x, centre.y);
    CGContextRotateCTM(ctx, -0.045 + (sg_frameTime >= 0 ? sin(sg_frameTime * (2 * M_PI / 5)) * 0.012 : 0));
    CGContextTranslateCTM(ctx, -centre.x, -centre.y);
    CGRect print = CGRectMake(size.width * 0.15, size.height * 0.09, size.width * 0.70, size.height * 0.58);
    fillRect(print, [UIColor colorWithRed:0.97 green:0.96 blue:0.94 alpha:1]);
    CGRect photo = CGRectMake(print.origin.x + size.width * 0.035, print.origin.y + size.height * 0.028,
                              print.size.width - size.width * 0.07, print.size.height - size.height * 0.155);
    if (c->cover) drawCoverInRect(c->cover, photo);
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
    CGContextRestoreGState(ctx);
    // The tape tab, unrotated, over the top edge.
    CGRect tape = CGRectMake(size.width * 0.40, size.height * 0.062, size.width * 0.20, size.height * 0.034);
    fillRect(tape, [UIColor colorWithRed:0.92 green:0.87 blue:0.70 alpha:0.75]);
}

// Subtitles: a letterboxed film frame, the cover in greyscale, the line as a
// yellow subtitle with its translation under it.
static void drawSubtitles(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), UIColor.blackColor);
    CGRect frame = CGRectMake(0, size.height * 0.19, size.width, size.height * 0.62);
    if (c->cover) {
        CIFilter *grey = [CIFilter filterWithName:@"CIColorControls"];
        [grey setValue:[CIImage imageWithCGImage:c->cover.CGImage] forKey:kCIInputImageKey];
        [grey setValue:@0 forKey:@"inputSaturation"];
        UIImage *mono = ciResult(c->cover, grey);
        drawCoverInRect(mono ?: c->cover, frame);
    }
    UIFont *font = monoFont(size.height * 0.027, UIFontWeightBold);
    NSMutableAttributedString *sub = [[NSMutableAttributedString alloc] initWithString:c->current ?: @""];
    [sub addAttributes:@{NSFontAttributeName: font,
                         NSForegroundColorAttributeName: [UIColor colorWithRed:1 green:0.85 blue:0.20 alpha:1],
                         NSStrokeColorAttributeName: UIColor.blackColor,
                         NSStrokeWidthAttributeName: @(-3.5)}
                range:NSMakeRange(0, sub.length)];
    NSMutableParagraphStyle *centre = [NSMutableParagraphStyle new];
    centre.alignment = NSTextAlignmentCenter;
    [sub addAttribute:NSParagraphStyleAttributeName value:centre range:NSMakeRange(0, sub.length)];
    CGFloat h = ceil([sub boundingRectWithSize:CGSizeMake(size.width * 0.86, frame.size.height * 0.4)
                                       options:NSStringDrawingUsesLineFragmentOrigin context:nil].size.height);
    if (sg_frameTime >= 0) {
        double k = MIN(1, sg_frameTime / 0.3);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, 0, (1 - (1 - pow(1 - k, 3))) * size.height * 0.012);
        [sub drawWithRect:CGRectMake(size.width * 0.07, CGRectGetMaxY(frame) - h - size.height * 0.045, size.width * 0.86, h)
                  options:NSStringDrawingUsesLineFragmentOrigin context:nil];
        CGContextRestoreGState(ctx);
    } else {
        [sub drawWithRect:CGRectMake(size.width * 0.07, CGRectGetMaxY(frame) - h - size.height * 0.045, size.width * 0.86, h)
                  options:NSStringDrawingUsesLineFragmentOrigin context:nil];
    }
    if (c->line.translation.length) {
        drawText(c->line.translation, CGRectMake(size.width * 0.07, CGRectGetMaxY(frame) - size.height * 0.035, size.width * 0.86, size.height * 0.03),
                 [UIFont systemFontOfSize:size.height * 0.017], UIColor.whiteColor, NSTextAlignmentCenter);
    }
}

// Line number: editorial cream, the line's number enormous and pale behind
// its words, a slim progress rule under them.
static void drawLineNumber(SGWCtx *c) {
    CGSize size = c->size;
    fillRect(CGRectMake(0, 0, size.width, size.height), [UIColor colorWithRed:0.955 green:0.945 blue:0.915 alpha:1]);
    CGFloat margin = size.width * 0.07, width = size.width - 2 * margin;
    drawText([NSString stringWithFormat:@"%ld", (long)(c->index + 1)],
             CGRectMake(margin, size.height * 0.015, width, size.height * 0.30),
             [UIFont boldSystemFontOfSize:size.height * 0.26], [UIColor colorWithWhite:0 alpha:0.07], NSTextAlignmentLeft);
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
        SGWCtx c = {size, prev, current, next, title, artist, cover, line, index, count,
                    prevStart, nextStart, duration, averageColor(cover), nil};
        c.accent = c.average ? lifted(c.average) : nil;
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
// The clip's size and rate, from the quality choice: Saver for the battery,
// Max for the full 900x1200 the stills use, Balanced between.
static void clipSpec(CGSize *size, NSInteger *fps) {
    switch (SGInt(SGKeyLyricArtworkClipQuality, 1)) {
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
    @synchronized (sg_lock) {
        sg_frameTime = t;
        if (style == SGLyricArtworkRecord) {
            image = drawRecordArtwork(size, prev, current, next, coverImage, line, title, artist);
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
                         (long)SGInt(SGKeyLyricArtworkClipQuality, 1)];
    if ([clipKey isEqualToString:sg_clipFor]) return;
    sg_clipFor = clipKey;
    sg_clipArtwork = nil;
    MPMediaItemArtwork *still = sg_artwork;
    void (^publish)(NSURL *) = ^(NSURL *file) {
        if (!file) return;
        id clip = clipArtworkFor(clipKey, file, still);
        if (!clip) return;
        @synchronized (sg_lock) { sg_clipArtwork = clip; }
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
    UIImage *coverImage = cover ? [cover imageWithSize:specSize] : nil;
    SGLyricClipRender(clipKey, specSize, specFps, clipSeconds(style, line),
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
    CGSize specSize;
    NSInteger specFps;
    clipSpec(&specSize, &specFps);
    UIImage *coverImage = nil;
    for (NSInteger ahead = 1; ahead <= 2; ahead++) {
        NSInteger j = index + ahead;
        if (j < 0 || j >= (NSInteger)lines.count) continue;
        NSString *clipKey = [NSString stringWithFormat:@"%@/%ld-%ld-%ld", trackID, (long)j, (long)style,
                             (long)SGInt(SGKeyLyricArtworkClipQuality, 1)];
        if (SGLyricClipCachedFile(clipKey)) continue;
        if (!coverImage) coverImage = cover ? [cover imageWithSize:specSize] : nil;
        NSString *jPrev = j > 0 ? SGKaraokeLineText(lines[j - 1]) : @"";
        NSString *jCurrent = SGKaraokeLineText(lines[j]);
        NSString *jNext = j + 1 < (NSInteger)lines.count ? SGKaraokeLineText(lines[j + 1]) : @"";
        SGKaraokeLine *jLine = lines[j];
        NSInteger jPrevStart = j > 0 ? lines[j - 1].start : 0;
        NSInteger jNextStart = j + 1 < (NSInteger)lines.count ? lines[j + 1].start : 0;
        NSInteger count = lines.count;
        SGLyricClipRender(clipKey, specSize, specFps, clipSeconds(style, jLine),
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
    @synchronized (sg_lock) { info = sg_info; }
    if (info.count) MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
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
    // The Workshop styles' facts: where this line sits in the song, its
    // neighbours' starts, and how long the track runs.
    NSInteger lineIndex = MAX(index, 0), lineCount = lines.count;
    NSInteger prevStart = index > 0 ? lines[index - 1].start : 0;
    NSInteger nextStart = index + 1 < (NSInteger)lines.count ? lines[index + 1].start : 0;
    double duration = [player.state respondsToSelector:@selector(duration)] ? player.state.duration : 0;
    MPMediaItemArtwork *cover;
    @synchronized (sg_lock) { cover = sg_cover; }
    sg_artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:CGSizeMake(900, 1200)
        requestHandler:^UIImage *(CGSize size) {
            @synchronized (sg_lock) {
                UIImage *coverImage = cover ? [cover imageWithSize:size] : nil;
                if (style == SGLyricArtworkRecord) {
                    return drawRecordArtwork(size, prev, current, next, coverImage, line, title, artist);
                }
                if (style == SGLyricArtworkChat) {
                    return drawChatArtwork(size, prev, current, next, coverImage, title, artist);
                }
                if (style >= SGLyricArtworkTwitter) {
                    return drawWorkshopArtwork(style, size, prev, current, next, coverImage, line, title, artist,
                                               lineIndex, lineCount, prevStart, nextStart, duration);
                }
                return drawLyricArtwork(size, prev, current, next, style, coverImage, line, title, artist);
            }
        }];
    offerClip(key, style, line, prev, current, next, cover, title, artist,
              lineIndex, lineCount, prevStart, nextStart, duration);
    warmClips(trackID, lines, index, style, cover, title, artist, duration);
    SGLog(@"lyric artwork: %@ — %@", trackID, current);
    resend();
}

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    MPMediaItemArtwork *artwork;
    id clip;
    @synchronized (sg_lock) {
        id theirs = info[MPMediaItemPropertyArtwork];
        if (theirs && theirs != sg_artwork) sg_cover = theirs;
        sg_info = info;
        artwork = sg_artwork;
        clip = sg_clipArtwork;
    }
    NSDictionary *shown = info;
    if (artwork && shown[MPMediaItemPropertyArtwork] != artwork) {
        NSMutableDictionary *swapped = [shown mutableCopy];
        swapped[MPMediaItemPropertyArtwork] = artwork;
        shown = swapped;
    }
    if (clip) {
        static NSString *animatedKey;
        if (!animatedKey) animatedKey = SGAnimatedArtworkKey(NULL);
        shown = SGArtworkInInfo(shown, clip, animatedKey);
    }
    %orig(shown);
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
