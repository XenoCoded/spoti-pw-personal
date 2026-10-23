// The Live Activity (Mod Settings > Live Activity), on the lock screen and in the Dynamic
// Island (iOS 17+), under either look: it draws on no Spotify screen of its own. In one of three views: the line being sung with the next one under it, the tracks
// up next (a tap on one skipping ahead to it), or the control menu, tabs of Controls (previous, play and
// pause, next, shuffle, repeat), Queue and a sleep Timer of the mod's own that pauses Spotify.
//
//     LiveActivity.x              polls the player, sends the activity a new state when what it shows changes
//     LiveActivityBridge.swift    ActivityKit, which is Swift only
//     LiveActivityShared.swift    the attributes and the taps' intents, compiled into the extension too
//     LiveActivitySettings.m      its page, opened from the root of Mod Settings
//
// Every tap in the card runs an intent inside Spotify and takes a second or two to show on the card.
//
// The widget is extension/LiveActivity, built into the IPA by scripts/build-extension.sh; the tap's
// intent runs in Spotify, so scripts/merge-appintents.py adds it to Spotify's App Intents metadata. The lines and
// the clock come from Shared/Lyrics, the queue from the player's state. The switch and the view apply at
// once: iOS lets an activity start only while the app is in front, which it is when the switch is flipped.
//
// The Swift names crossing into the widget (SGLyricsAttributes, the two intents, the notifications)
// are a contract with extension/LiveActivity and with the App Intents metadata merged into Spotify:
// ActivityKit and App Intents pair the two processes by type name, so a change here is a change there.
// Threading: main thread only.
#import <Foundation/Foundation.h>

@class SGModRow;

#define SGKeyLiveActivity @"spotifyglass.liveActivity"
// Which view it shows, the index into the page's list.
#define SGKeyLiveActivityView @"spotifyglass.liveActivity.view"
// What happens while nothing plays, SGLiveActivityIdleEnd's values.
#define SGKeyLiveActivityIdleEnd @"spotifyglass.liveActivity.idleEnd"
// The idle clock's start, persisted (Batch 94) so a relaunch over a
// still-paused player resumes the clock instead of restarting it.
#define SGKeyLiveActivityIdleStamp @"spotifyglass.liveActivity.idleStamp"
// Whether the lyrics view sends the next line with the current one
// (Batch 59): 0 current + next, 1 current only.
#define SGKeyLiveActivityLines @"spotifyglass.liveActivity.lines"
// Whether a long break between lines counts down to the next one on the
// card (Batch 59), on until switched off.
#define SGKeyLiveActivityInterlude @"spotifyglass.liveActivity.interlude"
// The card's accent (Batch 69): 0 the playing cover's colour, from the
// artwork palette; 1 Spotify green, whatever plays.
#define SGKeyLiveActivityTint @"spotifyglass.liveActivity.tint"
// What the keys were called while this was the redesign's alone; LiveActivity.x's %ctor moves them over.
#define SGKeyLiveActivityWas @"spotifyglass.redesign.liveActivity"
#define SGKeyLiveActivityViewWas @"spotifyglass.redesign.liveActivity.view"

typedef NS_ENUM(NSInteger, SGLiveActivityView) {
    SGLiveActivityLyrics = 0,
    SGLiveActivityQueue,
    SGLiveActivityPanel,   // the control menu
};

// How long a paused or trackless player keeps its activity before the mod ends it.
// Personal fork: upstream left the activity up until the system expired it (8 h), so a
// card outlived the listening that started it, looking live the whole time.
typedef NS_ENUM(NSInteger, SGLiveActivityIdleEnd) {
    SGLiveActivityIdleEnd5Min = 0,
    SGLiveActivityIdleEnd1Min,
    SGLiveActivityIdleEndNever,
};

// From the switch: starts following the player (and the activity, the app being in front) or ends both.
void SGSetLiveActivityEnabled(BOOL on);

@class UIViewController;
// The Live Activity page: its switch and which view it shows.
UIViewController *SGLiveActivitySettingsPage(void);
NSArray<SGModRow *> *SGLiveActivityRows(void);
// What the root's row reads out beside its chevron: the view shown, or Off.
NSString *SGLiveActivitySummary(void);
