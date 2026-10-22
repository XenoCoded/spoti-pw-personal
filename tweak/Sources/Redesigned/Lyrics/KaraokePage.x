// The karaoke view goes over the lyrics part of the full screen lyrics page (trees/lyrics.txt:
// Lyrics_FullscreenElementPageImpl.LyricsView, between the header and the controls), so Spotify's
// header, close button and controls stay working. It is laid over rather than swapped in: Spotify's
// list keeps running underneath and comes back the moment a track has no synced lyrics.
#import "Core/SGCore.h"
#import "SGRKaraokeView.h"
#import "LyricsText.h"
#import "Redesigned/Kit/SGRBridges.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"

static char kKaraokeKey, kCoverKey, kCoverWrapKey, kTitleKey, kArtistKey, kQueueKey;

#pragma mark - turning sideways

// The split layout below only ever *answered* a wide page; nothing made
// the page wide. Spotify is a portrait app — its orientation mask says
// so — and turning the phone on the lyrics page changed nothing, which
// is what "landscape lyrics doesn't work" meant on the device. So while
// the lyrics page is on screen with the switch on, the mask is widened
// for as long as the page stays: the app delegate's answer is replaced
// (its original kept and called whenever the page is not up), every
// view controller answers all-but-upside-down and may rotate, and the
// scene is asked for landscape once. Closing the page asks for portrait
// back. Rotating the phone while the page is up then moves between the
// two layouts the ordinary way.
static BOOL sg_orientationUnlocked;
static IMP sg_delegateOrientations;

static UIInterfaceOrientationMask sg_supportedOrientations(id self, SEL _cmd, UIApplication *app, UIWindow *window) {
    if (sg_orientationUnlocked) return UIInterfaceOrientationMaskAllButUpsideDown;
    if (sg_delegateOrientations) {
        return ((UIInterfaceOrientationMask (*)(id, SEL, UIApplication *, UIWindow *))sg_delegateOrientations)(self, _cmd, app, window);
    }
    return UIInterfaceOrientationMaskPortrait;
}

static void sg_installOrientationHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class delegateClass = object_getClass(UIApplication.sharedApplication.delegate);
        SEL sel = @selector(application:supportedInterfaceOrientationsForWindow:);
        if (!delegateClass) return;
        Method method = class_getInstanceMethod(delegateClass, sel);
        if (method) {
            sg_delegateOrientations = method_getImplementation(method);
            method_setImplementation(method, (IMP)sg_supportedOrientations);
        } else {
            class_addMethod(delegateClass, sel, (IMP)sg_supportedOrientations, "Q@:@@");
        }
    });
}

static void sg_requestOrientation(UIInterfaceOrientationMask mask, UIWindow *window) {
    UIWindowScene *scene = window.windowScene;
    if (!scene) return;
    UIWindowSceneGeometryPreferencesIOS *prefs =
        [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
    [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
        SGLog(@"karaoke: the orientation request was refused (%@)", error.localizedDescription);
    }];
    [window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
}

static void sg_karaokeAppeared(UIView *host) {
    if (!SGFlag(SGRKeyLandscapeLyrics, NO) || sg_orientationUnlocked) return;
    sg_installOrientationHook();
    sg_orientationUnlocked = YES;
    sg_requestOrientation(UIInterfaceOrientationMaskLandscape, host.window);
    SGLog(@"karaoke: landscape unlocked while the lyrics page is up");
}

static void sg_karaokeVanished(UIView *host) {
    if (!sg_orientationUnlocked) return;
    sg_orientationUnlocked = NO;
    // Called from didMoveToWindow, where the host's own window is already
    // gone; the portrait request goes to whatever window the scene has.
    UIWindow *window = host.window;
    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            window = ((UIWindowScene *)scene).windows.firstObject;
            if (window) break;
        }
    }
    sg_requestOrientation(UIInterfaceOrientationMaskPortrait, window);
}

%hook UIViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return sg_orientationUnlocked ? UIInterfaceOrientationMaskAllButUpsideDown : %orig;
}
- (BOOL)shouldAutorotate {
    return sg_orientationUnlocked ? YES : %orig;
}
%end

static UILabel *coverLabel(char *key, UIView *host, UIFont *font, UIColor *color) {
    UILabel *label = objc_getAssociatedObject(host, key);
    if (!label) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.font = font;
        label.textColor = color;
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 1;
        objc_setAssociatedObject(host, key, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:label];
    }
    return label;
}

%hook _TtC32Lyrics_FullscreenElementPageImpl10LyricsView
- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) sg_karaokeAppeared((UIView *)self);
    else sg_karaokeVanished((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    UIView *host = (UIView *)self;
    // The switch turned off again while the page is up: hand portrait back.
    if (sg_orientationUnlocked && !SGFlag(SGRKeyLandscapeLyrics, NO)) sg_karaokeVanished(host);
    SGRKaraokeView *view = objc_getAssociatedObject(host, &kKaraokeKey);
    if (!view) {
        SGLog(@"karaoke: page opened, playing %@", SGKaraokePlayingTrack());
        view = [[SGRKaraokeView alloc] initWithFrame:host.bounds];
        objc_setAssociatedObject(host, &kKaraokeKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (view.superview == host) [host bringSubviewToFront:view];
    else [host addSubview:view];
    // Landscape (Batch 24): sideways with the switch on, the lyrics take
    // the right-hand three-fifths and the cover stands on the left — the
    // karaoke view lays its lines out from its own bounds, so a narrower
    // frame is the whole change. Portrait, or the switch off, it has the
    // page to itself as before.
    BOOL split = SGFlag(SGRKeyLandscapeLyrics, NO) && host.bounds.size.width > host.bounds.size.height;
    // The cover rides in a wrapper that carries its shadow (Batch 27): a
    // rounded picture cannot cast one on its own layer.
    UIView *wrap = objc_getAssociatedObject(host, &kCoverWrapKey);
    UIImageView *cover = objc_getAssociatedObject(host, &kCoverKey);
    UIView *queue = objc_getAssociatedObject(host, &kQueueKey);
    if (split) {
        // The pane's three choices (Batch 63): what it holds, which side
        // it stands on, and how the width is shared. zoneX is the pane's
        // left edge; the lyrics take the rest, on the other side.
        BOOL queuePane = SGInt(SGRKeyLandscapePane, 0) == 1;
        BOOL swap = SGFlag(SGRKeyLandscapeSwap, NO);
        NSInteger share = SGInt(SGRKeyLandscapeShare, 0);
        CGFloat zone = host.bounds.size.width * (share == 1 ? 0.5 : share == 2 ? 0.3 : 0.4);
        CGFloat zoneX = swap ? host.bounds.size.width - zone : 0;
        if (queuePane) {
            wrap.hidden = YES;
            ((UILabel *)objc_getAssociatedObject(host, &kTitleKey)).hidden = YES;
            ((UILabel *)objc_getAssociatedObject(host, &kArtistKey)).hidden = YES;
            if (!queue) {
                queue = [[UIView alloc] initWithFrame:CGRectZero];
                objc_setAssociatedObject(host, &kQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [host addSubview:queue];
                UILabel *head = [[UILabel alloc] initWithFrame:CGRectZero];
                head.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
                head.textColor = [UIColor colorWithWhite:1 alpha:0.6];
                head.text = @"Up next";
                head.tag = 100;
                [queue addSubview:head];
                for (NSInteger i = 0; i < 7; i++) {
                    UILabel *row = [[UILabel alloc] initWithFrame:CGRectZero];
                    row.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
                    row.textColor = UIColor.whiteColor;
                    row.lineBreakMode = NSLineBreakByTruncatingTail;
                    row.tag = 101 + i;
                    [queue addSubview:row];
                }
            }
            queue.hidden = NO;
            queue.frame = CGRectMake(zoneX + 20, 44, zone - 40, host.bounds.size.height - 88);
            [queue viewWithTag:100].frame = CGRectMake(0, 0, zone - 40, 20);
            // The queue to come, read the way the queue text reads it:
            // the state's future tracks, type-checked one by one.
            SPTPlayerState *state = SGPlayerState();
            id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
            NSInteger shown = 0;
            if ([future isKindOfClass:NSArray.class]) {
                for (id candidate in (NSArray *)future) {
                    if (shown >= 7) break;
                    if (![candidate isKindOfClass:objc_getClass("SPTPlayerTrack")]) continue;
                    SPTPlayerTrack *track = candidate;
                    UILabel *row = (UILabel *)[queue viewWithTag:101 + shown];
                    NSString *artist = track.artistName.length ? [@" — " stringByAppendingString:track.artistName] : @"";
                    row.text = [NSString stringWithFormat:@"%@%@", track.trackTitle ?: @"", artist];
                    row.hidden = NO;
                    shown++;
                }
            }
            for (NSInteger i = 0; i < 7; i++) {
                UILabel *row = (UILabel *)[queue viewWithTag:101 + i];
                row.frame = CGRectMake(0, 32 + i * 30, zone - 40, 22);
                if (i >= shown) row.hidden = YES;
            }
            if (!shown) {
                UILabel *row = (UILabel *)[queue viewWithTag:101];
                row.text = @"Nothing queued";
                row.hidden = NO;
            }
        } else {
            queue.hidden = YES;
            if (!wrap) {
                wrap = [[UIView alloc] initWithFrame:CGRectZero];
                wrap.backgroundColor = UIColor.clearColor;
                wrap.layer.shadowColor = UIColor.blackColor.CGColor;
                wrap.layer.shadowOpacity = 0.5;
                wrap.layer.shadowRadius = 28;
                wrap.layer.shadowOffset = CGSizeMake(0, 14);
                objc_setAssociatedObject(host, &kCoverWrapKey, wrap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [host addSubview:wrap];
                cover = [[UIImageView alloc] initWithFrame:wrap.bounds];
                cover.contentMode = UIViewContentModeScaleAspectFill;
                cover.layer.cornerRadius = 18;
                cover.layer.cornerCurve = kCACornerCurveContinuous;
                cover.layer.masksToBounds = YES;
                cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                objc_setAssociatedObject(host, &kCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [wrap addSubview:cover];
            }
            wrap.hidden = NO;
            UIImage *art = SGRNowPlayingArtwork(NULL, NULL);
            if (art && cover.image != art) cover.image = art;
            CGFloat side = MIN(zone - 56, host.bounds.size.height - 190);
            wrap.frame = CGRectMake(zoneX + (zone - side) / 2, (host.bounds.size.height - side - 64) / 2, side, side);
            SPTPlayerTrack *playing = SGPlayerState().track;
            UILabel *titleLabel = coverLabel(&kTitleKey, host,
                [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], UIColor.whiteColor);
            UILabel *artistLabel = coverLabel(&kArtistKey, host,
                [UIFont systemFontOfSize:13 weight:UIFontWeightRegular], [UIColor colorWithWhite:1 alpha:0.6]);
            titleLabel.hidden = artistLabel.hidden = NO;
            titleLabel.text = playing.trackTitle ?: @"";
            artistLabel.text = playing.artistName ?: @"";
            titleLabel.frame = CGRectMake(zoneX + 16, CGRectGetMaxY(wrap.frame) + 14, zone - 32, 22);
            artistLabel.frame = CGRectMake(zoneX + 16, CGRectGetMaxY(titleLabel.frame) + 2, zone - 32, 18);
        }
        view.frame = CGRectMake(swap ? 0 : zone, 0, host.bounds.size.width - zone, host.bounds.size.height);
        [host bringSubviewToFront:view];
    } else {
        wrap.hidden = YES;
        queue.hidden = YES;
        ((UILabel *)objc_getAssociatedObject(host, &kTitleKey)).hidden = YES;
        ((UILabel *)objc_getAssociatedObject(host, &kArtistKey)).hidden = YES;
        view.frame = host.bounds;
    }
    [view syncSiblings];
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC32Lyrics_FullscreenElementPageImpl10LyricsView"]);
}
