// App font (personal fork): a font of the user's own in place of Spotify's, from a
// local library — Documents/spoti.pw/Fonts, the pattern the audio effects' file
// libraries set (Shared/AudioEffects) — picked in Mod Settings and applied at
// launch. No Workshop, no downloads: the files are the user's, imported from Files.
//
// The substitution covers what goes through UIFont — system fonts and anything
// asked for by name, Spotify's Circular included. Text Encore draws without
// UIFont keeps its own face; that limit is Spotify's, and the page says so.
#import <UIKit/UIKit.h>

// The chosen font's file name in the library; unset is Spotify's own font.
#define SGKeyAppFont @"spotifyglass.font"

NSString *SGFontsDirectory(void);
// The library's font files (.ttf, .otf), by name.
NSArray<NSString *> *SGFontFiles(void);
NSString *SGChosenFontFile(void);
void SGSetChosenFontFile(NSString *file);
// What the page calls a file: its family's name and style, read out of the file.
NSString *SGFontDisplayName(NSString *file);

// Registers every file in the library with this process, so a family's weights
// resolve; called once from the hooks' %ctor before anything is drawn.
void SGRegisterFonts(void);
// The chosen font at a size, the bold of its family when asked and it has one;
// nil when no font is chosen or the file will not load.
UIFont *SGAppFont(CGFloat size, BOOL bold);
NSString *SGChosenFontPostScriptName(void);

UIViewController *SGAppFontSettingsPage(void);
// The Appearance row's readout: the chosen font's name, or Off.
NSString *SGAppFontSummary(void);
