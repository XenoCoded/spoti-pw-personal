// Vinyl mode (Batch 82): the Redesigned player's cover becomes a spinning
// record. The playing artwork is the label, the grooves are etched in,
// and the spin freezes at its angle when playback pauses — a turntable
// stopping, not a view snapping back. The cover itself is only dimmed to
// alpha 0 (hidden would upset Spotify's stacks), and the disc inherits the
// tilt view's layout, so it follows the player's own geometry.
//
// The spin is a plain CABasicAnimation on the layer — no display link, so
// the player's 120 Hz transitions are never dragged down to 60.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRBridges.h"
#import "Shared/Player/PlayerState.h"
#import "PlayerVinyl.h"
#import <objc/runtime.h>

// A real LP turns at 33 1/3 rpm: 1.8 seconds a revolution.
static const CGFloat kRevolutionSeconds = 1.8;
static const CGFloat kMinTiltWidth = 200;

static NSHashTable<UIView *> *sg_vinylTilts;
static char kDiscKey, kURIKey;
static NSString *const kSpinKey = @"sg.vinyl.spin";

static BOOL inCoverCell(UIView *tilt) {
    static Class cell;
    if (!cell) cell = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl");
    for (UIView *v = tilt.superview; v; v = v.superview) {
        if ([v isKindOfClass:cell]) return YES;
    }
    return NO;
}

// The tilt view's cover: the size-matching subview that is not the mod's
// own shadow plate. (The same lookup PlayerArtwork.x keeps for itself;
// each side keeps its own copy, per the house rules.)
static UIView *vinylCoverIn(UIView *tilt) {
    for (UIView *sub in tilt.subviews) {
        if ([sub isKindOfClass:SGRShadowPlate.class]) continue;
        if (objc_getAssociatedObject(tilt, &kDiscKey) == sub) continue;
        if (CGSizeEqualToSize(sub.bounds.size, tilt.bounds.size)) return sub;
    }
    return nil;
}

static UIView *discFor(UIView *tilt) {
    return objc_getAssociatedObject(tilt, &kDiscKey);
}

static void setSpinning(UIView *disc, BOOL spinning) {
    if (spinning) {
        if ([disc.layer animationForKey:kSpinKey]) return;
        // The model transform still holds the frozen angle from the last
        // pause; the animation adds full turns on top of it, so resuming
        // never jumps.
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0;
        spin.toValue = @(M_PI * 2);
        spin.duration = kRevolutionSeconds;
        spin.repeatCount = HUGE_VALF;
        spin.removedOnCompletion = NO;
        [disc.layer addAnimation:spin forKey:kSpinKey];
    } else {
        CALayer *presented = (CALayer *)disc.layer.presentationLayer;
        if (presented) {
            CGFloat angle = atan2(presented.transform.m12, presented.transform.m11);
            [disc.layer removeAnimationForKey:kSpinKey];
            disc.transform = CGAffineTransformMakeRotation(angle);
        } else {
            [disc.layer removeAnimationForKey:kSpinKey];
        }
    }
}

static UIView *makeDisc(CGFloat diameter) {
    UIView *disc = [[UIView alloc] initWithFrame:CGRectMake(0, 0, diameter, diameter)];
    disc.backgroundColor = UIColor.blackColor;
    disc.layer.cornerRadius = diameter / 2;
    disc.clipsToBounds = YES;
    CGPoint center = CGPointMake(diameter / 2, diameter / 2);
    // The grooves: concentric hairlines, barely lit.
    CAShapeLayer *grooves = [CAShapeLayer layer];
    grooves.frame = disc.bounds;
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat labelR = diameter * 0.17;
    for (CGFloat r = labelR + 10; r < diameter / 2 - 3; r += 6) {
        [path addArcWithCenter:center radius:r startAngle:0 endAngle:M_PI * 2 clockwise:YES];
    }
    grooves.path = path.CGPath;
    grooves.strokeColor = [UIColor colorWithWhite:1 alpha:0.06].CGColor;
    grooves.fillColor = nil;
    grooves.lineWidth = 1;
    [disc.layer addSublayer:grooves];
    // The label: the playing artwork, round.
    CGFloat labelD = diameter * 0.34;
    UIImageView *label = [[UIImageView alloc] initWithFrame:
        CGRectMake((diameter - labelD) / 2, (diameter - labelD) / 2, labelD, labelD)];
    label.layer.cornerRadius = labelD / 2;
    label.clipsToBounds = YES;
    label.tag = 7;
    [disc addSubview:label];
    // The spindle hole.
    UIView *spindle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    spindle.center = center;
    spindle.backgroundColor = [UIColor colorWithWhite:0.85 alpha:0.9];
    spindle.layer.cornerRadius = 5;
    [disc addSubview:spindle];
    return disc;
}

static void refreshTilts(void) {
    BOOL vinyl = SGFlag(SGKeyVinyl, NO);
    SPTPlayerState *state = SGPlayerState();
    NSString *uri = SGURIString(state.track.URI);
    for (UIView *tilt in sg_vinylTilts.allObjects) {
        if (!tilt.window) {
            UIView *dead = discFor(tilt);
            [dead removeFromSuperview];
            objc_setAssociatedObject(tilt, &kDiscKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }
        UIView *cover = vinylCoverIn(tilt);
        if (!vinyl) {
            UIView *disc = discFor(tilt);
            if (disc) {
                setSpinning(disc, NO);
                [disc removeFromSuperview];
                objc_setAssociatedObject(tilt, &kDiscKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (cover) cover.alpha = 1;
            continue;
        }
        if (cover) cover.alpha = 0;
        UIView *disc = discFor(tilt);
        BOOL fresh = NO;
        if (!disc) {
            disc = makeDisc(tilt.bounds.size.width);
            disc.center = CGPointMake(CGRectGetMidX(tilt.bounds), CGRectGetMidY(tilt.bounds));
            [tilt addSubview:disc];
            objc_setAssociatedObject(tilt, &kDiscKey, disc, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            fresh = YES;
        }
        NSString *last = objc_getAssociatedObject(tilt, &kURIKey);
        if (uri.length && (fresh || ![uri isEqualToString:last])) {
            objc_setAssociatedObject(tilt, &kURIKey, uri, OBJC_ASSOCIATION_COPY_NONATOMIC);
            UIImageView *label = (UIImageView *)[disc viewWithTag:7];
            NSString *trackURI = nil, *identity = nil;
            label.image = SGRNowPlayingArtwork(&trackURI, &identity);
        }
        setSpinning(disc, !state.isPaused);
    }
}

@interface SGRVinylWatcher : NSObject <SGPlayerStateObserver>
@end
@implementation SGRVinylWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    refreshTilts();
}
@end

%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews {
    %orig;
    UIView *tilt = (UIView *)self;
    if (tilt.bounds.size.width < kMinTiltWidth || !inCoverCell(tilt)) return;
    if (!vinylCoverIn(tilt) && !discFor(tilt)) return;
    [sg_vinylTilts addObject:tilt];
    UIView *disc = discFor(tilt);
    if (disc) {
        disc.frame = tilt.bounds;
        disc.layer.cornerRadius = tilt.bounds.size.width / 2;
    }
    refreshTilts();
}
%end

NSArray<SGModRow *> *SGRVinylRows(void) {
    return @[SGWithSymbol(SGSwitchRow(@"Vinyl mode", @"The cover becomes a spinning record, artwork as the label", SGKeyVinyl), @"opticaldisc")];
}

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    sg_vinylTilts = [NSHashTable weakObjectsHashTable];
    static SGRVinylWatcher *watcher;
    watcher = [SGRVinylWatcher new];
    SGAddPlayerStateObserver(watcher);
    // The artwork can arrive after the track change that asked for it;
    // forgetting the stored URIs makes the next refresh repaint labels.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:SGRNowPlayingArtworkDidChangeNotification object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            for (UIView *tilt in sg_vinylTilts.allObjects)
                objc_setAssociatedObject(tilt, &kURIKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            refreshTilts();
        }];
}
