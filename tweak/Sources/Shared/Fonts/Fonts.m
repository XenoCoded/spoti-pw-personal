#import <CoreText/CoreText.h>
#import "Core/SGCore.h"
#import "Fonts.h"

NSString *SGFontsDirectory(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = [[documents stringByAppendingPathComponent:@"spoti.pw"] stringByAppendingPathComponent:@"Fonts"];
    if (![NSFileManager.defaultManager fileExistsAtPath:directory]) {
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return directory;
}

NSArray<NSString *> *SGFontFiles(void) {
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:SGFontsDirectory() error:nil]) {
        NSString *ext = name.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"ttf"] || [ext isEqualToString:@"otf"]) [files addObject:name];
    }
    return [files sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

NSString *SGChosenFontFile(void) {
    NSString *file = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyAppFont];
    return file && [SGFontFiles() containsObject:file] ? file : nil;
}

void SGSetChosenFontFile(NSString *file) {
    if (file) [NSUserDefaults.standardUserDefaults setObject:file forKey:SGKeyAppFont];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyAppFont];
}

// The first descriptor a font file offers, the regular face of the family in it.
static CTFontDescriptorRef descriptorOfFile(NSString *file) {
    NSURL *url = [NSURL fileURLWithPath:[SGFontsDirectory() stringByAppendingPathComponent:file]];
    CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
    CTFontDescriptorRef first = descriptors && CFArrayGetCount(descriptors) ? CFArrayGetValueAtIndex(descriptors, 0) : NULL;
    if (first) CFRetain(first);
    if (descriptors) CFRelease(descriptors);
    return first;
}

NSString *SGFontDisplayName(NSString *file) {
    CTFontDescriptorRef descriptor = descriptorOfFile(file);
    if (!descriptor) return file.stringByDeletingPathExtension;
    NSString *family = (__bridge_transfer NSString *)CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute);
    NSString *style = (__bridge_transfer NSString *)CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute);
    CFRelease(descriptor);
    if (!family.length) return file.stringByDeletingPathExtension;
    return style.length && ![style isEqualToString:@"Regular"]
        ? [NSString stringWithFormat:@"%@ %@", family, style] : family;
}

void SGRegisterFonts(void) {
    for (NSString *file in SGFontFiles()) {
        NSURL *url = [NSURL fileURLWithPath:[SGFontsDirectory() stringByAppendingPathComponent:file]];
        CFErrorRef error = NULL;
        if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error)) {
            // Already registered is the one failure that is not one.
            NSString *note = error ? (__bridge_transfer NSString *)CFErrorCopyDescription(error) : @"";
            if (![note containsString:@"already"]) SGLog(@"app font: %@ would not register: %@", file, note);
            if (error) CFRelease(error);
        }
    }
}

NSString *SGChosenFontPostScriptName(void) {
    NSString *file = SGChosenFontFile();
    if (!file) return nil;
    CTFontDescriptorRef descriptor = descriptorOfFile(file);
    if (!descriptor) return nil;
    NSString *name = (__bridge_transfer NSString *)CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);
    CFRelease(descriptor);
    return name;
}

CGFloat SGFontScaleFactor(void) {
    static const CGFloat steps[] = {0.90, 0.95, 1.0, 1.05, 1.10, 1.20};
    NSInteger index = SGInt(SGKeyFontScale, 2);
    return steps[MIN(5, MAX(0, index))];
}

UIFont *SGAppFont(CGFloat size, BOOL bold) {
    NSString *file = SGChosenFontFile();
    if (!file) return nil;
    size *= SGFontScaleFactor();
    CTFontDescriptorRef descriptor = descriptorOfFile(file);
    if (!descriptor) return nil;
    // Through the family name, so the bold asked for is the family's own bold face
    // where it has one, and not a smear of the regular.
    NSString *family = (__bridge_transfer NSString *)CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute);
    CFRelease(descriptor);
    if (!family.length) return nil;
    UIFontDescriptor *ui = [UIFontDescriptor fontDescriptorWithName:family size:size];
    if (bold) ui = [ui fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    return [UIFont fontWithDescriptor:ui size:size];
}

NSString *SGAppFontSummary(void) {
    NSString *file = SGChosenFontFile();
    return file ? SGFontDisplayName(file) : @"Off";
}
