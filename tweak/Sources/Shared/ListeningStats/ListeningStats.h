// Listening stats (personal fork): what the phone itself has heard — time listened and
// plays per track and artist — counted from the player state the mod already watches,
// kept in a file in the app's own Application Support, and never sent anywhere. The
// file, not a settings key, so Export settings does not carry it and Reset all
// settings does not clear it; the page has its own clear.
#import <UIKit/UIKit.h>

#define SGKeyListeningStats @"spotifyglass.listeningStats"

// The watcher in ListeningStats.x calls these as the state changes; the page reads a
// snapshot. Main thread only: the player state and the pages both live there.
void SGStatsCountPlay(NSString *uri, NSString *title, NSString *artist);
void SGStatsAddListening(NSString *uri, NSTimeInterval seconds);
NSDictionary *SGStatsSnapshot(void);
void SGStatsClear(void);

// "3 h 25 min" for a count of seconds; the pages' way of writing a span out.
NSString *SGStatsFormatTime(NSTimeInterval seconds);

UIViewController *SGListeningStatsPage(void);
// The row's readout on the Player page: Off, or the total time so far.
NSString *SGListeningStatsSummary(void);
