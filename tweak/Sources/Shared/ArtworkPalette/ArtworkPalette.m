// The palette watcher: on a track change it takes the cover Spotify itself put in
// the now playing info, averages it on a small bitmap — 24 by 24 pixels is plenty
// to know a cover's colour — and lifts the result until it can stand as an accent:
// dark covers would vanish as a tint, grey ones would read as no colour at all.
// The average runs off the main thread; only the answer is kept, and only in
// memory, swapped atomically as songs change.
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <os/lock.h>
#import "ArtworkPalette.h"
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"

NSNotificationName const SGArtworkPaletteChangedNotification = @"SGArtworkPaletteChanged";

static uint32_t sg_rgb;
static BOOL sg_have;
static BOOL sg_started;
static os_unfair_lock sg_lock = OS_UNFAIR_LOCK_INIT;

// The cover's average and its lift, in one pass over a thumbnail. Lightness is
// pulled into the accent band and saturation floored, so a near-black or
// near-white cover still gives a colour with a hue.
static BOOL paletteFromImage(UIImage *image, uint32_t *out) {
    if (!image) return NO;
    CGSize thumb = CGSizeMake(24, 24);
    uint8_t pixels[24 * 24 * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels, 24, 24, 8, 24 * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return NO;
    CGContextDrawImage(context, CGRectMake(0, 0, thumb.width, thumb.height), image.CGImage);
    CGContextRelease(context);
    double r = 0, g = 0, b = 0;
    NSUInteger count = 24 * 24;
    for (NSUInteger i = 0; i < count; i++) {
        r += pixels[i * 4] / 255.0;
        g += pixels[i * 4 + 1] / 255.0;
        b += pixels[i * 4 + 2] / 255.0;
    }
    UIColor *average = [UIColor colorWithRed:r / count green:g / count blue:b / count alpha:1];
    CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 0;
    if (![average getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha]) return NO;
    saturation = MAX(saturation, 0.35);
    brightness = MIN(0.88, MAX(0.55, brightness + 0.18));
    CGFloat fr = 0, fg = 0, fb = 0;
    [[UIColor colorWithHue:hue saturation:saturation brightness:brightness alpha:1]
        getRed:&fr green:&fg blue:&fb alpha:NULL];
    *out = ((uint32_t)(fr * 255) << 16) | ((uint32_t)(fg * 255) << 8) | (uint32_t)(fb * 255);
    return YES;
}

@interface SGPaletteWatcher : NSObject <SGPlayerStateObserver>
@property (nonatomic, copy) NSString *uri;
@end

@implementation SGPaletteWatcher

- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *uri = SGURIString(state.track.URI);
    if (!uri.length || [uri isEqualToString:self.uri]) return;
    self.uri = uri;
    // The cover lands in the now playing info a beat after the state does; look
    // now and once more shortly, and keep whichever attempt finds it.
    for (NSNumber *delay in @[@0, @0.8]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay.doubleValue * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (![self.uri isEqualToString:uri]) return;
            MPMediaItemArtwork *artwork = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyArtwork];
            UIImage *cover = [artwork imageWithSize:CGSizeMake(120, 120)];
            if (!cover) return;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                uint32_t rgb = 0;
                if (!paletteFromImage(cover, &rgb)) return;
                os_unfair_lock_lock(&sg_lock);
                BOOL changed = !sg_have || sg_rgb != rgb;
                sg_rgb = rgb;
                sg_have = YES;
                os_unfair_lock_unlock(&sg_lock);
                SGLog(@"palette: %@ -> #%06X", uri, rgb);
                if (changed) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [NSNotificationCenter.defaultCenter postNotificationName:SGArtworkPaletteChangedNotification object:nil];
                    });
                }
            });
        });
    }
}

@end

void SGArtworkPaletteStart(void) {
    if (sg_started) return;
    sg_started = YES;
    static SGPaletteWatcher *watcher;
    watcher = [SGPaletteWatcher new];
    SGAddPlayerStateObserver(watcher);
}

BOOL SGArtworkPaletteRGB(uint32_t *rgbOut) {
    os_unfair_lock_lock(&sg_lock);
    BOOL have = sg_have;
    if (have && rgbOut) *rgbOut = sg_rgb;
    os_unfair_lock_unlock(&sg_lock);
    return have;
}
