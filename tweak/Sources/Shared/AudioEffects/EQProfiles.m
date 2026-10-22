// The profiles' store and hands: one defaults dictionary of profiles,
// each a small dictionary of whichever EQ pieces were set when it was
// captured. Only the gains are profiled — the parametric EQ's gains,
// the graphic EQ's nodes, the bass lift — and only pieces that exist
// are written or restored, so a profile captured before the graphic
// EQ was ever touched leaves it alone forever.
#import <AVFoundation/AVFoundation.h>
#import "EQProfiles.h"
#import "AudioEffects.h"
#import "AudioEffectsApply.h"
#import "Core/SGCore.h"

NSString *SGEQCurrentRouteClass(void) {
    NSString *type = AVAudioSession.sharedInstance.currentRoute.outputs.firstObject.portType;
    if ([type isEqualToString:AVAudioSessionPortCarAudio]) return @"car";
    if ([type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
        [type isEqualToString:AVAudioSessionPortBluetoothLE] ||
        [type isEqualToString:AVAudioSessionPortBluetoothHFP] ||
        [type isEqualToString:AVAudioSessionPortUSBAudio] ||
        [type isEqualToString:AVAudioSessionPortAirPlay]) return @"bluetooth";
    if ([type isEqualToString:AVAudioSessionPortHeadphones] ||
        [type isEqualToString:AVAudioSessionPortHeadsetMic] ||
        [type isEqualToString:AVAudioSessionPortLineOut]) return @"headphones";
    return @"speaker";
}

NSString *SGEQRouteClassName(NSString *routeClass) {
    if ([routeClass isEqualToString:@"car"]) return @"Car";
    if ([routeClass isEqualToString:@"bluetooth"]) return @"Bluetooth";
    if ([routeClass isEqualToString:@"headphones"]) return @"Headphones";
    return @"Speaker";
}

static NSMutableDictionary<NSString *, NSDictionary *> *profiles(void) {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyDSPProfiles];
    // Only well-shaped pieces come back (Batch 91): applying a profile
    // writes its pieces straight into the effects' own keys, and the
    // effects read the gains as strings and the bass as a number — a
    // restored store with anything else in a slot crashed the apply.
    NSMutableDictionary<NSString *, NSDictionary *> *clean = [NSMutableDictionary dictionary];
    for (NSString *route in stored) {
        id profile = stored[route];
        if (![profile isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *kept = [NSMutableDictionary dictionary];
        if ([profile[@"eq"] isKindOfClass:NSString.class]) kept[@"eq"] = profile[@"eq"];
        if ([profile[@"geq"] isKindOfClass:NSString.class]) kept[@"geq"] = profile[@"geq"];
        if ([profile[@"bass"] isKindOfClass:NSNumber.class]) kept[@"bass"] = profile[@"bass"];
        if (kept.count) clean[route] = kept;
    }
    return clean;
}

BOOL SGEQHasProfile(NSString *routeClass) {
    return profiles()[routeClass] != nil;
}

void SGEQCaptureProfile(NSString *routeClass) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    id eq = [defaults objectForKey:SGKeyDSPEqualizerGains];
    if (eq) profile[@"eq"] = eq;
    id geq = [defaults objectForKey:SGKeyDSPGraphicEqNodes];
    if (geq) profile[@"geq"] = geq;
    id bass = [defaults objectForKey:SGKeyDSPBassGain];
    if (bass) profile[@"bass"] = bass;
    NSMutableDictionary *all = profiles();
    if (profile.count) all[routeClass] = profile;
    else [all removeObjectForKey:routeClass];
    [defaults setObject:all forKey:SGKeyDSPProfiles];
    SGLog(@"eq profiles: captured %@ (%lu pieces)", routeClass, (unsigned long)profile.count);
}

void SGEQApplyProfile(NSString *routeClass) {
    NSDictionary *profile = profiles()[routeClass];
    if (!profile) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (profile[@"eq"]) {
        [defaults setObject:profile[@"eq"] forKey:SGKeyDSPEqualizerGains];
        SGDSPApply(SGKeyDSPEqualizer);
    }
    if (profile[@"geq"]) {
        [defaults setObject:profile[@"geq"] forKey:SGKeyDSPGraphicEqNodes];
        SGDSPApply(SGKeyDSPGraphicEq);
    }
    if (profile[@"bass"]) {
        [defaults setObject:profile[@"bass"] forKey:SGKeyDSPBassGain];
        SGDSPApply(SGKeyDSPBass);
    }
    SGLog(@"eq profiles: applied %@", routeClass);
}

void SGEQClearProfile(NSString *routeClass) {
    NSMutableDictionary *all = profiles();
    [all removeObjectForKey:routeClass];
    [NSUserDefaults.standardUserDefaults setObject:all forKey:SGKeyDSPProfiles];
}
