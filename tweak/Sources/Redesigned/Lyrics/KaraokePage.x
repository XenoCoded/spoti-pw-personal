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

static char kKaraokeKey, kCoverKey, kTitleKey, kArtistKey;

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
- (void)layoutSubviews {
    %orig;
    UIView *host = (UIView *)self;
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
    UIImageView *cover = objc_getAssociatedObject(host, &kCoverKey);
    if (split) {
        if (!cover) {
            cover = [[UIImageView alloc] initWithFrame:CGRectZero];
            cover.contentMode = UIViewContentModeScaleAspectFill;
            cover.clipsToBounds = YES;
            cover.layer.cornerRadius = 18;
            cover.layer.cornerCurve = kCACornerCurveContinuous;
            objc_setAssociatedObject(host, &kCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [host addSubview:cover];
        }
        cover.hidden = NO;
        UIImage *art = SGRNowPlayingArtwork(NULL, NULL);
        if (art && cover.image != art) cover.image = art;
        CGFloat zone = host.bounds.size.width * 0.40;
        CGFloat side = MIN(zone - 56, host.bounds.size.height - 190);
        cover.frame = CGRectMake((zone - side) / 2, (host.bounds.size.height - side - 64) / 2, side, side);
        SPTPlayerTrack *playing = SGPlayerState().track;
        UILabel *titleLabel = coverLabel(&kTitleKey, host,
            [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], UIColor.whiteColor);
        UILabel *artistLabel = coverLabel(&kArtistKey, host,
            [UIFont systemFontOfSize:13 weight:UIFontWeightRegular], [UIColor colorWithWhite:1 alpha:0.6]);
        titleLabel.hidden = artistLabel.hidden = NO;
        titleLabel.text = playing.trackTitle ?: @"";
        artistLabel.text = playing.artistName ?: @"";
        titleLabel.frame = CGRectMake(16, CGRectGetMaxY(cover.frame) + 14, zone - 32, 22);
        artistLabel.frame = CGRectMake(16, CGRectGetMaxY(titleLabel.frame) + 2, zone - 32, 18);
        view.frame = CGRectMake(zone, 0, host.bounds.size.width - zone, host.bounds.size.height);
        [host bringSubviewToFront:view];
    } else {
        cover.hidden = YES;
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
