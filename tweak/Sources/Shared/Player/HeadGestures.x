// Head gestures: the AirPods report the head's attitude many times a
// second; a nod and a shake are shapes in that stream, read against a
// slow-moving baseline so the wearer's resting pose is never the
// trigger. A nod is a pitch dip out and back inside a second or so; a
// shake is the yaw crossing to both sides in turn. Either fires once
// and rests — a held pose or a dance floor cannot machine-gun the
// player. Everything is read on the main thread; the motion queue only
// measures.
#import <CoreMotion/CoreMotion.h>
#import "Core/SGCore.h"
#import "HeadGestures.h"
#import "PlayerState.h"
#import "Shared/Gestures/Gestures.h"

static CMHeadphoneMotionManager *sg_motion;
static BOOL sg_running, sg_seeded, sg_denied;
static double sg_basePitch, sg_baseYaw;
static BOOL sg_dipped;
static CFTimeInterval sg_dipAt, sg_shakeAt, sg_cooldownUntil;
static NSInteger sg_shakeSign, sg_shakeCrossings;

static void stopMotion(void) {
    if (sg_motion && sg_running) [sg_motion stopDeviceMotionUpdates];
    sg_running = NO;
}

static void fire(NSString *key, SGGestureAction fallback) {
    NSInteger stored = SGInt(key, fallback);
    if (stored < 0 || stored >= (NSInteger)SGGestureActionNames().count) stored = fallback;
    SGLog(@"head gestures: %@ -> %@", key, SGGestureActionNames()[(NSUInteger)stored]);
    SGGesturePerform((SGGestureAction)stored);
}

// One attitude sample, pitch and yaw in radians against the baselines.
// The shake was read off the ROLL until Batch 95 — an ear-to-shoulder
// tilt — and a head turned left and right barely moves it, so no
// natural shake could ever cross its threshold. Turning the head is
// yaw; that is what the shake reads now. Yaw wraps at ±π, so every
// delta against the baseline takes the short way round.
static double wrappedDelta(double angle, double base) {
    double delta = angle - base;
    while (delta > M_PI) delta -= M_PI * 2;
    while (delta < -M_PI) delta += M_PI * 2;
    return delta;
}

static void sample(double pitch, double yaw) {
    // Samples hop from the motion queue; ones already in flight when
    // stopMotion ran land here after the stop (Batch 93) and must not
    // complete a gesture nobody is listening for anymore.
    if (!sg_running) return;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (!sg_seeded) {
        sg_basePitch = pitch;
        sg_baseYaw = yaw;
        sg_seeded = YES;
        return;
    }
    // The baseline follows drift only; a gesture is over before it moves.
    sg_basePitch += (pitch - sg_basePitch) * 0.02;
    sg_baseYaw += wrappedDelta(yaw, sg_baseYaw) * 0.02;
    if (now < sg_cooldownUntil) return;
    double dip = fabs(pitch - sg_basePitch);
    double tilt = wrappedDelta(yaw, sg_baseYaw);
    // The nod: out past the dip, then home again while it is still a nod.
    if (!sg_dipped && dip > 0.30) {
        sg_dipped = YES;
        sg_dipAt = now;
    } else if (sg_dipped && dip < 0.08) {
        sg_dipped = NO;
        if (now - sg_dipAt < 1.2) {
            sg_cooldownUntil = now + 1.5;
            sg_shakeCrossings = 0;
            fire(SGKeyHeadGestureNod, SGGestureRateUp);
            return;
        }
    } else if (sg_dipped && now - sg_dipAt > 1.2) {
        sg_dipped = NO;   // a look down that stayed down is not a nod
    }
    // The shake: an extreme, then the other, then back — two crossings
    // past the middle in quick succession. A natural turn reaches
    // further than the roll ever did, and the bar sits a little lower
    // (Batch 95): 0.25 rad, about fourteen degrees each way.
    NSInteger sign = tilt > 0.25 ? 1 : tilt < -0.25 ? -1 : 0;
    if (sign && sign != sg_shakeSign) {
        if (now - sg_shakeAt > 1.4) sg_shakeCrossings = 0;
        sg_shakeSign = sign;
        sg_shakeAt = now;
        if (++sg_shakeCrossings >= 3) {
            sg_shakeCrossings = 0;
            sg_cooldownUntil = now + 1.5;
            fire(SGKeyHeadGestureShake, SGGestureNextTrack);
        }
    }
}

// The switch is read on every player state change, so flipping it (or
// putting AirPods in) takes hold on the next track at the latest, with
// no restart: starting is cheap and stopping is a no-op when stopped.
static void refresh(void) {
    if (!SGFlag(SGKeyHeadGestures, NO)) {
        stopMotion();
        return;
    }
    if (sg_running || sg_denied) return;
    if (CMHeadphoneMotionManager.authorizationStatus == CMAuthorizationStatusDenied) {
        sg_denied = YES;
        SGLog(@"head gestures: motion access denied for this app");
        return;
    }
    if (!sg_motion) sg_motion = [CMHeadphoneMotionManager new];
    if (!sg_motion.deviceMotionAvailable) return;   // no AirPods that track: try again next track
    sg_seeded = NO;
    sg_dipped = NO;
    sg_shakeCrossings = 0;
    sg_running = YES;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    [sg_motion startDeviceMotionUpdatesToQueue:queue withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (error || !motion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) SGLog(@"head gestures: updates stopped, %@", error.localizedDescription);
                stopMotion();
            });
            return;
        }
        double pitch = motion.attitude.pitch, yaw = motion.attitude.yaw;
        dispatch_async(dispatch_get_main_queue(), ^{ sample(pitch, yaw); });
    }];
    SGLog(@"head gestures: listening");
}

@interface SGHeadGestureWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGHeadGestureWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    refresh();
}
@end

// Held in a static: the observer registry is weak (PlayerState.x), so a
// bare temporary deallocates as the constructor returns — after launch,
// putting AirPods in never started motion and turning the switch off
// never stopped it.
static SGHeadGestureWatcher *sg_watcher;
static id sg_defaultsObserver;

%ctor {
    sg_watcher = [SGHeadGestureWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    // The switch also re-reads the moment it changes (Batch 94):
    // state changes alone left a paused session's motion running
    // after the switch went off, and one more shake fired its action
    // on a stopped player. refresh() is a no-op in the right state.
    sg_defaultsObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSUserDefaultsDidChangeNotification object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) { refresh(); }];
    refresh();
}
