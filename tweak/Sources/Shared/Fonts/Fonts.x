// The substitution itself: UIFont's doors in. Registered and read once at launch, so
// the hooks exist only while a font is chosen or the text size is off 100%, and a
// phone with neither pays nothing. What is asked for by name keeps its size, and a
// name that says bold (CircularSp-Bold, a Semibold, a Black) gets the chosen
// family's bold where it has one. With no font chosen the size step still applies,
// to Spotify's own font — the step is a size, not a face.
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
    return SGAppFont(size, looksBold(name)) ?: %orig(name, size * SGFontScaleFactor());
}
+ (UIFont *)systemFontOfSize:(CGFloat)size {
    return SGAppFont(size, NO) ?: %orig(size * SGFontScaleFactor());
}
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size {
    return SGAppFont(size, YES) ?: %orig(size * SGFontScaleFactor());
}
+ (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)weight {
    return SGAppFont(size, weight >= UIFontWeightSemibold) ?: %orig(size * SGFontScaleFactor(), weight);
}
+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style {
    UIFont *stock = %orig;
    UIFont *font = SGAppFont(stock.pointSize, NO);
    if (font) return font;
    CGFloat factor = SGFontScaleFactor();
    return factor == 1 ? stock : [UIFont fontWithDescriptor:stock.fontDescriptor size:stock.pointSize * factor];
}
%end

%ctor {
    BOOL scaled = SGFontScaleFactor() != 1;
    if (!SGChosenFontFile() && !scaled) return;
    SGRegisterFonts();
    if (SGChosenFontFile() && !SGAppFont(17, NO)) {
        SGLog(@"app font: %@ is chosen but will not load, keeping Spotify's", SGChosenFontFile());
        if (!scaled) return;
    }
    %init;
    SGLog(@"app font: %@ in use, text at %.0f%%",
          SGChosenFontFile() ? SGFontDisplayName(SGChosenFontFile()) : @"Spotify's own",
          SGFontScaleFactor() * 100);
}
