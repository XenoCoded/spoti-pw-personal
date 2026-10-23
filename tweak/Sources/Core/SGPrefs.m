#import "SGPrefs.h"

NSNumber *SGCoerceNumber(id value) {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSString.class]) return @([value doubleValue]);
    return nil;
}

NSInteger SGCoerceInteger(id value, NSInteger fallback) {
    NSNumber *number = SGCoerceNumber(value);
    return number ? number.integerValue : fallback;
}

double SGCoerceDouble(id value, double fallback) {
    NSNumber *number = SGCoerceNumber(value);
    return number ? number.doubleValue : fallback;
}

BOOL SGCoerceBool(id value, BOOL fallback) {
    NSNumber *number = SGCoerceNumber(value);
    return number ? number.boolValue : fallback;
}

BOOL SGFlag(NSString *key, BOOL fallback) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    id value = [store objectForKey:key];
    // The stored class is not guaranteed (Backup import plants values
    // at keys this phone never wrote, Batch 94): a non-number there
    // used to raise inside -boolValue, in %ctor paths — a launch loop.
    if (value) return SGCoerceBool(value, fallback);
    return fallback && ![store boolForKey:SGKeyStock];
}

BOOL SGEnabled(NSString *key) {
    return SGFlag(key, YES);
}

BOOL SGHidden(NSString *key) {
    return SGFlag(key, NO);
}

void SGSetEnabled(NSString *key, BOOL on) {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:key];
}

NSInteger SGInt(NSString *key, NSInteger fallback) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value ? SGCoerceInteger(value, fallback) : fallback;
}

void SGSetInt(NSString *key, NSInteger value) {
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:key];
}

NSString *const SGFlagOverridePrefix = @"spotifyglass.flag.";

id SGFlagOverride(NSString *key) {
    return [NSUserDefaults.standardUserDefaults objectForKey:[SGFlagOverridePrefix stringByAppendingString:key]];
}

void SGSetFlagOverride(NSString *key, id value) {
    key = [SGFlagOverridePrefix stringByAppendingString:key];
    if (value) [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
}

void SGMigrateKey(NSString *from, NSString *to) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    id value = [store objectForKey:from];
    if (!value || [store objectForKey:to]) return;
    [store setObject:value forKey:to];
    [store removeObjectForKey:from];
}

void SGRestartSpotify(void) {
    [NSUserDefaults.standardUserDefaults synchronize];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
}
