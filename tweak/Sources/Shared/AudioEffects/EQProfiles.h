// EQ by output (personal fork, Batch 79): the community's most-wanted
// EQ trick, keyed to where the sound is going. Each output class —
// speaker, headphones, Bluetooth, car — keeps its own EQ profile: the
// parametric gains, the graphic nodes and the bass lift. Leaving an
// output saves what it sounded like; arriving at one restores its
// profile through the DSP's own apply path. The effects' on/off
// switches stay global — a profile is a shape, not a power state.
#import <Foundation/Foundation.h>

@class UIViewController;
UIViewController *SGEQProfilesSettingsPage(void);

#define SGKeyDSPAutoEQ @"spotifyglass.dsp.autoEQ"
#define SGKeyDSPProfiles @"spotifyglass.dsp.profiles"

// The current output's class: @"speaker", @"headphones",
// @"bluetooth" or @"car".
NSString *SGEQCurrentRouteClass(void);
NSString *SGEQRouteClassName(NSString *routeClass);

// Capture the live EQ keys as the class's profile / restore a saved
// profile into the live keys and re-apply it. Applying a class with
// no profile does nothing.
void SGEQCaptureProfile(NSString *routeClass);
void SGEQApplyProfile(NSString *routeClass);
BOOL SGEQHasProfile(NSString *routeClass);
void SGEQClearProfile(NSString *routeClass);
