// Vinyl mode (Batch 82): the Redesigned player's cover becomes a spinning
// record. The playing artwork is the label, the grooves are etched in,
// and the spin freezes at its angle when playback pauses — a turntable
// stopping, not a view snapping back. The cover itself is only dimmed to
// alpha 0 (hidden would upset Spotify's stacks), and the disc inherits the
// tilt view's layout, so it follows the player's own geometry.
//
// The spin is a plain CABasicAnimation on the layer — no display link, so
// the player's 120 Hz transitions are never dragged down to 60.
//
// Batch 92: the deck furniture the first cut lacked. The disc gets a lit
// rim and a sheen, so its circle reads against the player's black instead
// of vanishing into it (all a first user could see was the label,
// spinning in a void). A tonearm parks beside the record while paused
// and swings onto it to play, creeping inward with the track. And the
// record can be scrubbed: drag it in a circle and the playhead follows
// the finger, a full turn for thirty seconds, the music seeking as it
// goes the way a hand on a real record drags the song with it.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRBridges.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Lyrics/Lyrics.h"
#import "PlayerVinyl.h"
#import <objc/runtime.h>

// A real LP turns at 33 1/3 rpm: 1.8 seconds a revolution.
static const CGFloat kRevolutionSeconds = 1.8;
static const CGFloat kMinTiltWidth = 200;

static NSHashTable<UIView *> *sg_vinylTilts;
static char kDiscKey, kURIKey, kArmKey, kArmSizeKey, kArmStateKey, kPanKey;
static NSString *const kSpinKey = @"sg.vinyl.spin";

// Scrubbing (Batch 92): one revolution of the finger is thirty seconds
// of song, and the disc being scrubbed is left out of the refresh's
// spin and arm decisions until the finger lifts.
static const CGFloat kSecondsPerRevolution = 30;
static __weak UIView *sg_scrubDisc;

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
    // The rim (Batch 92): a hairline of light around the edge, and a body
    // a shade above the player's black — without them the circle is
    // invisible on the black page and the record reads as a floating
    // label.
    disc.layer.borderWidth = 1;
    disc.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    disc.clipsToBounds = YES;
    CGPoint center = CGPointMake(diameter / 2, diameter / 2);
    // The sheen: light pooled toward the top left, the way a record
    // catches a room. It turns with the disc; at this strength it reads
    // as the grooves' own light play.
    CAGradientLayer *sheen = [CAGradientLayer layer];
    sheen.frame = disc.bounds;
    sheen.type = kCAGradientLayerRadial;
    sheen.colors = @[(id)[UIColor colorWithWhite:0.22 alpha:1].CGColor,
                     (id)[UIColor colorWithWhite:0.07 alpha:1].CGColor,
                     (id)[UIColor colorWithWhite:0.0 alpha:1].CGColor];
    sheen.locations = @[@0, @0.72, @1];
    sheen.startPoint = CGPointMake(0.32, 0.3);
    sheen.endPoint = CGPointMake(0.95, 0.95);
    [disc.layer addSublayer:sheen];
    // The grooves: concentric hairlines, barely lit.
    CAShapeLayer *grooves = [CAShapeLayer layer];
    grooves.frame = disc.bounds;
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat labelR = diameter * 0.17;
    for (CGFloat r = labelR + 10; r < diameter / 2 - 3; r += 6) {
        [path addArcWithCenter:center radius:r startAngle:0 endAngle:M_PI * 2 clockwise:YES];
    }
    grooves.path = path.CGPath;
    grooves.strokeColor = [UIColor colorWithWhite:1 alpha:0.1].CGColor;
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


#pragma mark - the tonearm

// The arm's geometry, all in fractions of the disc's diameter: the pivot
// sits at the top right corner the way a deck's does, the bar hangs
// straight down from it at rotation 0, and rotation swings the stylus
// across the surface. Parked is a third of a radian out (the tip just
// clear of the rim); playing runs from the outer groove to the inner.
static const CGFloat kArmPivotX = 0.88, kArmPivotY = 0.10, kArmLength = 0.55;
static const CGFloat kArmParked = -0.30, kArmOuter = -0.15, kArmInner = 0.38;

static CGFloat armAngle(BOOL playing, double fraction) {
    if (!playing) return kArmParked;
    fraction = MIN(1, MAX(0, fraction));
    return kArmOuter + (CGFloat)fraction * (kArmInner - kArmOuter);
}

// Builds the arm over a disc of the given diameter: a base and pivot the
// bar turns on. The assembly takes no touches — the scrub recognizer
// lives on the disc under it.
static UIView *makeArm(CGFloat diameter) {
    UIView *assembly = [[UIView alloc] initWithFrame:CGRectMake(0, 0, diameter, diameter)];
    assembly.userInteractionEnabled = NO;
    CGPoint pivot = CGPointMake(diameter * kArmPivotX, diameter * kArmPivotY);
    // The base the pivot stands on.
    UIView *base = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 34, 34)];
    base.center = pivot;
    base.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
    base.layer.cornerRadius = 17;
    base.layer.borderWidth = 1;
    base.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    [assembly addSubview:base];
    // The moving part: a full-size view whose anchor is the pivot, so
    // rotating it swings the bar around the pivot and nothing else.
    UIView *swing = [[UIView alloc] initWithFrame:assembly.bounds];
    swing.layer.anchorPoint = CGPointMake(kArmPivotX, kArmPivotY);
    // The layer's position is where the anchor sits: the pivot itself.
    // (The view's center would offset it by the anchor's distance from
    // the middle, and the bar would hang off its own base.)
    swing.layer.position = pivot;
    swing.tag = 12;
    [assembly addSubview:swing];
    CGFloat length = diameter * kArmLength;
    // The counterweight stub, above the pivot.
    UIView *weight = [[UIView alloc] initWithFrame:CGRectMake(pivot.x - 5, pivot.y - 20, 10, 18)];
    weight.backgroundColor = [UIColor colorWithWhite:0.55 alpha:1];
    weight.layer.cornerRadius = 3;
    [swing addSubview:weight];
    // The bar itself.
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(pivot.x - 2.5, pivot.y, 5, length)];
    bar.backgroundColor = [UIColor colorWithWhite:0.82 alpha:1];
    bar.layer.cornerRadius = 2.5;
    [swing addSubview:bar];
    // The headshell at the bar's end, angled the way a cartridge sits,
    // with the stylus point under it.
    UIView *shell = [[UIView alloc] initWithFrame:CGRectMake(pivot.x - 6, pivot.y + length - 16, 12, 20)];
    shell.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    shell.layer.cornerRadius = 3;
    shell.transform = CGAffineTransformMakeRotation(0.32);
    [swing addSubview:shell];
    UIView *stylus = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4, 4)];
    stylus.center = CGPointMake(pivot.x, pivot.y + length + 1);
    stylus.backgroundColor = [UIColor colorWithRed:0.95 green:0.3 blue:0.25 alpha:1];
    stylus.layer.cornerRadius = 2;
    [swing addSubview:stylus];
    // The pivot cap, on top of everything.
    UIView *cap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 13, 13)];
    cap.center = pivot;
    cap.backgroundColor = [UIColor colorWithWhite:0.75 alpha:1];
    cap.layer.cornerRadius = 6.5;
    [swing addSubview:cap];
    swing.transform = CGAffineTransformMakeRotation(kArmParked);
    return assembly;
}

static UIView *armFor(UIView *tilt) {
    return objc_getAssociatedObject(tilt, &kArmKey);
}

// Points the arm for the state of play: parked while paused, on the
// record and as far in as the playhead while playing. A change of
// playing-ness swings; a change of fraction alone (a seek, time's
// passing between refreshes) is set plainly, so the arm never swims.
static void updateArm(UIView *tilt, BOOL playing, double fraction, BOOL animated) {
    UIView *assembly = armFor(tilt);
    UIView *swing = [assembly viewWithTag:12];
    if (!swing) return;
    NSNumber *was = objc_getAssociatedObject(tilt, &kArmStateKey);
    BOOL stateChanged = !was || (was.boolValue != playing);
    objc_setAssociatedObject(tilt, &kArmStateKey, @(playing), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat target = armAngle(playing, fraction);
    if (animated && stateChanged) {
        [UIView animateWithDuration:0.5 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            swing.transform = CGAffineTransformMakeRotation(target);
        } completion:nil];
    } else {
        swing.transform = CGAffineTransformMakeRotation(target);
    }
}

#pragma mark - scrubbing the record

// One scrub in flight: where the song was when the finger landed, how
// far the finger has turned since, and where it last sought to.
static void refreshTilts(void);

@interface SGRVinylScrubber : NSObject
@property (nonatomic) double start, duration, accumulated, lastAngle, lastSought;
@end
@implementation SGRVinylScrubber

static CGFloat touchAngle(UIPanGestureRecognizer *pan, UIView *disc) {
    // Measured in the superview's space, around the disc's centre: in
    // the disc's own space the reading would rotate with the disc and
    // the finger would seem to stand still.
    CGPoint p = [pan locationInView:disc.superview];
    return atan2(p.y - disc.center.y, p.x - disc.center.x);
}

- (void)scrub:(UIPanGestureRecognizer *)pan {
    UIView *disc = pan.view;
    if (!disc) return;
    if (pan.state == UIGestureRecognizerStateBegan) {
        sg_scrubDisc = disc;
        setSpinning(disc, NO);
        SPTPlayerState *state = SGPlayerState();
        NSInteger ms = SGKaraokePositionMs();
        self.start = ms >= 0 ? ms / 1000.0 : state.position;
        self.duration = state.duration;
        self.accumulated = 0;
        self.lastSought = self.start;
        self.lastAngle = touchAngle(pan, disc);
        return;
    }
    if (pan.state == UIGestureRecognizerStateChanged) {
        CGFloat angle = touchAngle(pan, disc);
        CGFloat delta = angle - (CGFloat)self.lastAngle;
        // Angles wrap at pi; a step across the seam is the small way round.
        while (delta > M_PI) delta -= (CGFloat)(M_PI * 2);
        while (delta < -M_PI) delta += (CGFloat)(M_PI * 2);
        self.lastAngle = angle;
        self.accumulated += delta;
        disc.transform = CGAffineTransformRotate(disc.transform, delta);
        if (self.duration <= 0) return;
        double target = self.start + self.accumulated * (kSecondsPerRevolution / (M_PI * 2));
        target = MIN(self.duration, MAX(0, target));
        // The song follows the finger, in steps coarse enough not to
        // flood the player with seeks.
        if (fabs(target - self.lastSought) >= 0.3) {
            self.lastSought = target;
            id<SPTPlayer> player = SGKaraokePlayer();
            [player seekTo:target];
        }
        return;
    }
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        if (self.duration > 0) {
            double target = self.start + self.accumulated * (kSecondsPerRevolution / (M_PI * 2));
            target = MIN(self.duration, MAX(0, target));
            if (fabs(target - self.lastSought) >= 0.05) {
                id<SPTPlayer> player = SGKaraokePlayer();
                [player seekTo:target];
            }
        }
        sg_scrubDisc = nil;
        refreshTilts();
    }
}
@end

static SGRVinylScrubber *scrubber(void) {
    static SGRVinylScrubber *scrubber;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ scrubber = [SGRVinylScrubber new]; });
    return scrubber;
}

static void refreshTilts(void) {
    // Nothing tracked, nothing to do — the common case with the switch
    // off, since the layout hook only tracks a tilt when there is a disc
    // to manage or the switch is on.
    if (sg_vinylTilts.count == 0) return;
    BOOL vinyl = SGFlag(SGKeyVinyl, NO);
    SPTPlayerState *state = SGPlayerState();
    NSString *uri = SGURIString(state.track.URI);
    for (UIView *tilt in sg_vinylTilts.allObjects) {
        if (!tilt.window) {
            UIView *dead = discFor(tilt);
            [dead removeFromSuperview];
            [armFor(tilt) removeFromSuperview];
            objc_setAssociatedObject(tilt, &kDiscKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tilt, &kArmKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [sg_vinylTilts removeObject:tilt];
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
            [armFor(tilt) removeFromSuperview];
            objc_setAssociatedObject(tilt, &kArmKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tilt, &kArmStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (cover) cover.alpha = 1;
            [sg_vinylTilts removeObject:tilt];
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
        // The scrub recognizer rides the disc (Batch 92), attached once.
        if (!objc_getAssociatedObject(disc, &kPanKey)) {
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                initWithTarget:scrubber() action:@selector(scrub:)];
            pan.maximumNumberOfTouches = 1;
            [disc addGestureRecognizer:pan];
            objc_setAssociatedObject(disc, &kPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // The arm (Batch 92): built over the disc at its size, rebuilt
        // when the size moves, and left entirely alone mid-scrub — the
        // finger owns the disc and the playhead until it lifts.
        BOOL scrubbing = (sg_scrubDisc == disc);
        UIView *arm = armFor(tilt);
        NSNumber *armSize = objc_getAssociatedObject(tilt, &kArmSizeKey);
        if (!arm || armSize.doubleValue != tilt.bounds.size.width) {
            [arm removeFromSuperview];
            arm = makeArm(tilt.bounds.size.width);
            arm.frame = tilt.bounds;
            [tilt addSubview:arm];
            objc_setAssociatedObject(tilt, &kArmKey, arm, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tilt, &kArmSizeKey, @(tilt.bounds.size.width),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tilt, &kArmStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!scrubbing) {
            double fraction = state.duration > 0 ? state.position / state.duration : 0;
            updateArm(tilt, !state.isPaused, fraction, YES);
            setSpinning(disc, !state.isPaused);
        }
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
    // Off and nothing to clean up: skip the view-tree walk entirely.
    // A disc left behind by a recent toggle-off still takes the road
    // below, which removes it.
    if (!discFor(tilt) && !SGFlag(SGKeyVinyl, NO)) return;
    if (!vinylCoverIn(tilt) && !discFor(tilt)) return;
    [sg_vinylTilts addObject:tilt];
    UIView *disc = discFor(tilt);
    if (disc) {
        disc.frame = tilt.bounds;
        disc.layer.cornerRadius = tilt.bounds.size.width / 2;
    }
    UIView *arm = armFor(tilt);
    if (arm) arm.frame = tilt.bounds;
    refreshTilts();
}
%end

NSArray<SGModRow *> *SGRVinylRows(void) {
    return @[SGWithSymbol(SGSwitchRow(@"Vinyl mode", @"The cover becomes a spinning record with a tonearm, artwork as the label. Drag the record in a circle to scrub.", SGKeyVinyl), @"opticaldisc")];
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
