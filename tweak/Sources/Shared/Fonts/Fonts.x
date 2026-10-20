// The substitution itself: UIFont's doors in. Registered and read once at launch, so
// the hooks exist only while a font is chosen, and a phone without one pays nothing.
// What is asked for by name keeps its size, and a name that says bold (CircularSp-Bold,
// a Semibold, a Black) gets the chosen family's bold where it has one.
#import "Core/SGCore.h"
#import "Fonts.h"

static BOOL looksBold(NSString *name) {
    for (NSString *mark in @[@"Bold", @"Black", @"Heavy", @"Semibold", @"SemiBold", @"ExtraBold"]) {
        if ([name containsString:mark]) return YES;
    }
    return NO;
}

%hook UIFont
+ (UIFont *)fontWithName:(NSString *)name size:(CGFloat)size {
    if ([name isEqualToString:SGChosenFontPostScriptName()]) return %orig;
    UIFont *font = SGAppFont(size, looksBold(name));
    return font ?: %orig;
}
+ (UIFont *)systemFontOfSize:(CGFloat)size {
    return SGAppFont(size, NO) ?: %orig;
}
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size {
    return SGAppFont(size, YES) ?: %orig;
}
+ (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)weight {
    return SGAppFont(size, weight >= UIFontWeightSemibold) ?: %orig;
}
+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style {
    UIFont *stock = %orig;
    return SGAppFont(stock.pointSize, NO) ?: stock;
}
%end

%ctor {
    if (!SGChosenFontFile()) return;
    SGRegisterFonts();
    if (!SGAppFont(17, NO)) {
        SGLog(@"app font: %@ is chosen but will not load, keeping Spotify's", SGChosenFontFile());
        return;
    }
    %init;
    SGLog(@"app font: %@ in use", SGFontDisplayName(SGChosenFontFile()));
}
